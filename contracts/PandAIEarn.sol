// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol"; 

interface IERC20Extended is IERC20{
    function decimals() external view returns (uint8);
}

interface IERC20Burnable is IERC20Extended {
    function burnFrom(address account, uint256 amount) external;
}

contract PandAIEarn is AccessControl, Pausable {

  IERC20Extended private usdtToken;
  IERC20Burnable private pandaiToken;
  
  address private lpAddress;

  bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");
  address public constant DEFAULT_REFERRAL = 0xEe9Aa828fF4cBF294063168E78BEB7BcF441fEa1;

  uint256 public constant WITHDRAW_PROCESSING_TIME = 14 days;
  uint256 public constant DAILY_CLAIM_LIMIT = 1000;
  
  enum ApprovalLevel{ NotApproved, Approved, Forbidden }

  mapping(uint8 => Tier) public tierMap;
  struct Tier {
    uint256 minDeposit;
    bool compoundInterest;
    
    uint256 monthlyGainBps;
    uint256 claimFeeBps;

    uint256 lockupSeconds;
    uint256 lockupBreachFee;
  }

  mapping(address => User) public userMap;
  struct User {
    address referral;                     // referral address for this account
    uint8 approvalLevel;                  // approval level of this user (from ApprovalLevel enum)
    
    uint256 deposit;                      // usdt deposit of given user
    uint256 lastDepositTimestamp;         // last time of usdt deposit
    
    uint256 withdrawRequestAmount;        // usdt user request to withdraw
    uint256 withdrawPossibleTimestamp;    // time when the withdraw of requested amount can be done
    
    uint256 dailyClaim;                   // usdt user claimed today
    uint256 totalClaim;                   // usdt user claimed in total
    uint256 lastClaimTimestamp;           // last time when user called claim

    uint256 referralDeposit;              // sum of usdt deposits of users bellow this user (in referral program)
    uint256 referralPendingReward;        // pending referral reward (calculated in referralLastUpdateTimestamp)
    uint256 referralLastUpdateTimestamp;  // time when referalPendingReward was updated
  }

  struct UserCalculated {
    uint8 tier;
    // TODO
  }

  event TreasuryWithdraw(uint256 usdtAmount);
  event TreasuryDeposit(uint256 usdtAmount);
  event LpAddressChanged(address indexed previousLp, address indexed newLp);
  event ApprovalLevelChanged(address indexed userAddress, ApprovalLevel previousApprovalLevel, ApprovalLevel newApprovalLevel);
  
  event UserDeposited(address indexed userAddress, uint256 usdtAmount);
  event UserRequestedWithdraw(address indexed userAddress, uint256 usdtAmount);
  event UserWithdrew(address indexed userAddress, uint256 usdtAmount);

  event PandaiBurnedForUserRewardClaim(address indexed userAddress, uint256 pandaiAmount);
  event PandaiBurnedForReferralRewardClaim(address indexed userAddress, uint256 pandaiAmount);
  event PandaiBurnedForWithdrawFee(address indexed userAddress, uint256 pandaiAmount);
  
  event UserRewardClaimed(address indexed userAddress, uint256 usdtAmount);
  event ReferralRewardClaimed(address indexed userAddress, uint256 usdtAmount);

  constructor(address _usdtTokenAddress, address _pandaiTokenAddress) {
    usdtToken = IERC20Extended(_usdtTokenAddress);
    pandaiToken = IERC20Burnable(_pandaiTokenAddress);

    tierMap[1] = Tier(  100, false, 100, 1000,   7 days, 4000);
    tierMap[2] = Tier(  500, false, 125,  900,  30 days, 3500);
    tierMap[3] = Tier( 1000, false, 150,  800,  60 days, 3000);
    tierMap[4] = Tier( 5000,  true, 180,  650,  90 days, 2500);
    tierMap[5] = Tier(10000,  true, 220,  500, 180 days, 2000);

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
  }

  function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
    _pause();
  }

  function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
    _unpause();
  }

  function setLpAddress(address newLpAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(lpAddress != address(0), "lpAddress cannot be zero address");
    require(usdtToken.balanceOf(lpAddress) > 0, "No USDT on LP");
    require(pandaiToken.balanceOf(lpAddress) > 0, "No PANDAI on LP");
    
    address oldLpAddress = lpAddress;
    lpAddress = newLpAddress;
    emit LpAddressChanged(oldLpAddress, newLpAddress);
  }

  function withdrawTreasury(uint256 usdtAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(usdtToken.balanceOf(address(this)) >= usdtAmount, "not enough USDT in treasury");
    usdtToken.transfer(msg.sender, usdtAmount);
    emit TreasuryWithdraw(usdtAmount);
  }

  function depositTreasury(uint256 usdtAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(usdtToken.balanceOf(msg.sender) >= usdtAmount, "not enough USDT");
    require(usdtToken.allowance(msg.sender, address(this)) >= usdtAmount, "USDT allowance too small");
    usdtToken.transferFrom(msg.sender, address(this), usdtAmount);
    emit TreasuryDeposit(usdtAmount);
  }

  function getUser(address userAddress) external view returns (User memory stored, UserCalculated memory calculated) {    
    require(userAddress != address(0), "userAddress cannot be zero address");    
    uint8 tier = getUserTier(userAddress);
    return (
      userMap[userAddress],
      UserCalculated(
        tier
        // TODO
      )
    );
  }

  function getTier(uint8 tier) external view returns (Tier memory) {
    require(tier >= 1 && tier <= 5, "tier out of range");
    return tierMap[tier];
  }

  function getLpAddress() external view returns (address) {
    return lpAddress;
  }

  function setUserApprovalLevel(address userAddress, ApprovalLevel newApprovalLevel) external onlyRole(UPDATER_ROLE) {
    ApprovalLevel oldApprovalLevel = ApprovalLevel(userMap[userAddress].approvalLevel);
    userMap[userAddress].approvalLevel = uint8(newApprovalLevel);
    emit ApprovalLevelChanged(userAddress, oldApprovalLevel, newApprovalLevel);
  }

  function deposit(uint256 usdtAmount) external {
    deposit(usdtAmount, DEFAULT_REFERRAL);
  }

  function deposit(uint256 usdtDepositAmount, address referralAddress) public whenNotPaused {
    require(usdtDepositAmount >= tierMap[1].minDeposit * (10 ** usdtToken.decimals()), "deposit amount too small");
    require(referralAddress != address(0), "referralAddress cannot be zero address");
    require(referralAddress != msg.sender, "referralAddress cannot be sender");
    
    uint8 tier = getUserTier(msg.sender);
    uint256 claimUsdt = getUserReward(msg.sender, tier);
    require(canClaim(msg.sender, claimUsdt), "daily limit for claim reached");
    
    uint256 claimFeeUsdt = getUserRewardClaimFeeUsdt(claimUsdt, tier);
    uint256 claimFeePandai = getPandaiWorthOf(claimFeeUsdt);
    require(pandaiToken.balanceOf(msg.sender) >= claimFeePandai, "not enough PANDAI");
    require(pandaiToken.allowance(msg.sender, address(this)) >= claimFeePandai, "PANDAI allowance too small");
    if (claimUsdt < usdtDepositAmount) {
      require(usdtToken.balanceOf(msg.sender) >= usdtDepositAmount - claimUsdt, "not enough USDT");
      require(usdtToken.allowance(msg.sender, address(this)) >= usdtDepositAmount - claimUsdt, "USDT allowance too small");
    } else if (claimUsdt > usdtDepositAmount) {
      require(usdtToken.balanceOf(address(this)) >= claimUsdt - usdtDepositAmount, "not enough USDT in treasury");
    }

    if (userMap[msg.sender].referral == address(0)) {
      userMap[msg.sender].referral = referralAddress;
    }

    userMap[msg.sender].deposit += usdtDepositAmount;
    userMap[msg.sender].lastDepositTimestamp = block.timestamp;

    if (isToday(userMap[msg.sender].lastClaimTimestamp)) {
      userMap[msg.sender].dailyClaim += claimUsdt;
    } else {
      userMap[msg.sender].dailyClaim = claimUsdt;
    }
    userMap[msg.sender].totalClaim += claimUsdt;
    userMap[msg.sender].lastClaimTimestamp = block.timestamp;
    
    uint256 newReferralReward = getNewReferralReward(userMap[msg.sender].referral);
    userMap[userMap[msg.sender].referral].referralDeposit += usdtDepositAmount;
    userMap[userMap[msg.sender].referral].referralPendingReward += newReferralReward;
    userMap[userMap[msg.sender].referral].referralLastUpdateTimestamp = block.timestamp;
    
    if (claimUsdt < usdtDepositAmount) {
      usdtToken.transferFrom(msg.sender, address(this), usdtDepositAmount - claimUsdt);
    } else if (claimUsdt > usdtDepositAmount) {
      usdtToken.transfer(msg.sender, claimUsdt - usdtDepositAmount);
    }
    pandaiToken.burnFrom(msg.sender, claimFeePandai);

    emit UserDeposited(msg.sender, usdtDepositAmount);
    emit PandaiBurnedForUserRewardClaim(msg.sender, claimFeePandai);
    emit UserRewardClaimed(msg.sender, claimUsdt);
  }

  function requestWithdraw(uint256 usdtWithdrawAmount) public {
    require(usdtWithdrawAmount <= userMap[msg.sender].deposit, "withdraw amount bigger than deposit");
    if (usdtWithdrawAmount < userMap[msg.sender].deposit) {
      require(userMap[msg.sender].deposit - usdtWithdrawAmount >= tierMap[1].minDeposit * (10 ** usdtToken.decimals()), "remaining deposit must be tier1 at least");
    }

    uint256 withdrawFeePandai;
    uint8 tier = getUserTier(msg.sender);
    if (getWithdrawFreeTimestamp(msg.sender, tier) > block.timestamp) {
      uint256 withdrawFeeBps = getWithdrawFeeBps(tier);
      uint256 withdrawFeeUsdt = usdtWithdrawAmount * withdrawFeeBps / 10_000;
      withdrawFeePandai = getPandaiWorthOf(withdrawFeeUsdt);

      require(pandaiToken.balanceOf(msg.sender) >= withdrawFeePandai, "not enough PANDAI");
      require(pandaiToken.allowance(msg.sender, address(this)) >= withdrawFeePandai, "PANDAI allowance too small");
    }

    userMap[msg.sender].deposit -= usdtWithdrawAmount;
    userMap[msg.sender].withdrawRequestAmount += usdtWithdrawAmount;
    userMap[msg.sender].withdrawPossibleTimestamp = block.timestamp + WITHDRAW_PROCESSING_TIME;
    
    uint256 newReferralReward = getNewReferralReward(userMap[msg.sender].referral);
    if (userMap[userMap[msg.sender].referral].referralDeposit >= usdtWithdrawAmount) {
      userMap[userMap[msg.sender].referral].referralDeposit -= usdtWithdrawAmount;
    } else {
      userMap[userMap[msg.sender].referral].referralDeposit = 0;
    }
    userMap[userMap[msg.sender].referral].referralPendingReward += newReferralReward;
    userMap[userMap[msg.sender].referral].referralLastUpdateTimestamp = block.timestamp;

    if (withdrawFeePandai > 0) {
      pandaiToken.burnFrom(msg.sender, withdrawFeePandai);
      emit PandaiBurnedForWithdrawFee(msg.sender, withdrawFeePandai);
    }
    emit UserRequestedWithdraw(msg.sender, usdtWithdrawAmount);
  }

  function withdraw() public {
    require(userMap[msg.sender].withdrawRequestAmount > 0, "requested amount must be positive");
    require(userMap[msg.sender].withdrawRequestAmount <= usdtToken.balanceOf(address(this)), "not enough USDT in treasury");
    require(userMap[msg.sender].withdrawPossibleTimestamp <= block.timestamp, "withdraw not possible yet");

    uint256 usdtWithdrawAmount = userMap[msg.sender].withdrawRequestAmount;
    userMap[msg.sender].withdrawRequestAmount = 0;
    userMap[msg.sender].withdrawPossibleTimestamp = 0;

    usdtToken.transfer(msg.sender, usdtWithdrawAmount);
    emit UserWithdrew(msg.sender, usdtWithdrawAmount);
  }

  function canClaim(address userAddress, uint256 claimUsdt) private view returns (bool) {
    ApprovalLevel approvalLevel = ApprovalLevel(userMap[userAddress].approvalLevel);
    if (approvalLevel == ApprovalLevel.Approved) {
      return true;
    } else if (approvalLevel == ApprovalLevel.Forbidden) {
      return false;
    }
    if (!isToday(userMap[userAddress].lastClaimTimestamp)) {
      return claimUsdt * (10 ** usdtToken.decimals()) < DAILY_CLAIM_LIMIT;
    } else {
      return userMap[userAddress].dailyClaim + claimUsdt * (10 ** usdtToken.decimals()) < DAILY_CLAIM_LIMIT;
    }
  }

  function isToday(uint256 timestamp) private view returns (bool) {
    return block.timestamp / 1 days == timestamp / 1 days;
  }

  function getPandaiWorthOf(uint256 usdtAmount) private view returns (uint256) {
    uint256 usdtInLp = usdtToken.balanceOf(lpAddress);
    uint256 pandaiInLp = pandaiToken.balanceOf(lpAddress);
    require (usdtInLp * pandaiInLp > 0, "not enough tokens in Lp");

    return usdtAmount * pandaiInLp / usdtInLp;
  }

  function getUserTier(address userAddress) private view returns (uint8) {
    uint256 userDeposit = userMap[userAddress].deposit / (10 ** usdtToken.decimals());
    for (uint8 i = 5; i >= 1; i--) {
      if (userDeposit >= tierMap[i].minDeposit) {
        return i;
      }
    }
    return 0;
  }

  function getUserReward(address userAddress, uint8 userTier) private view returns (uint256) {
    // TODO
    return 0;
  }

  function getUserRewardClaimFeeUsdt(uint256 userReward, uint8 userTier) private view returns (uint256) {
    // TODO
    return 0;
  }

  function getNewReferralReward(address userAddress) private view returns (uint256) {
    // TODO
    return 0;
  }

  function getReferralRewardClaimFeeUsdt(uint256 referralReward) private view returns (uint256) {
    // TODO
    return 0;
  }

  function getWithdrawFeeBps(uint8 userTier) private view returns (uint256) {
    // TODO
    return 0;
  }

  function getWithdrawFreeTimestamp(address userAddress, uint8 userTier) private view returns (uint256) {
    // TODO
    return 0;    
  }

}
