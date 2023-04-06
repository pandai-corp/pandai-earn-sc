// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol"; 

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

interface IERC20Burnable is IERC20Extended {
    function burnFrom(address account, uint amount) external;
}

contract PandAIEarn is AccessControl, Pausable {

  IERC20Extended private usdtToken;
  IERC20Burnable private pandaiToken;
  
  address private lpAddress;

  bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");
  address public constant DEFAULT_REFERRAL = 0xEe9Aa828fF4cBF294063168E78BEB7BcF441fEa1;

  uint public constant WITHDRAW_PROCESSING_TIME = 14 days;
  uint public constant DAILY_CLAIM_LIMIT = 1000;
  
  enum ApprovalLevel{ NotApproved, Approved, Forbidden }

  mapping(uint8 => Tier) public tierMap;
  struct Tier {
    uint minDeposit;
    bool compoundInterest;
    
    uint monthlyGainBps;
    uint claimFeeBps;

    uint lockupSeconds;
    uint lockupBreachFee;
  }

  mapping(address => User) public userMap;
  struct User {
    address referral;                  // referral address for this account
    uint8 approvalLevel;               // approval level of this user (from ApprovalLevel enum)
    
    uint deposit;                      // usdt deposit of given user
    uint lastDepositTimestamp;         // last time of usdt deposit
    
    uint withdrawRequestAmount;        // usdt user request to withdraw
    uint withdrawPossibleTimestamp;    // time when the withdraw of requested amount can be done
    
    uint dailyClaim;                   // usdt user claimed today
    uint totalClaim;                   // usdt user claimed in total
    uint lastClaimTimestamp;           // last time when user called claim

    uint referralDeposit;              // sum of usdt deposits of users bellow this user (in referral program)
    uint referralPendingReward;        // pending referral reward (calculated in referralLastUpdateTimestamp)
    uint referralLastUpdateTimestamp;  // time when referalPendingReward was updated
  }

  struct UserCalculated {
    uint8 tier;
    // TODO
  }

  event TreasuryWithdraw(uint usdtAmount);
  event TreasuryDeposit(uint usdtAmount);
  event LpAddressChanged(address indexed previousLp, address indexed newLp);
  event ApprovalLevelChanged(address indexed userAddress, ApprovalLevel previousApprovalLevel, ApprovalLevel newApprovalLevel);
  
  event UserDeposited(address indexed userAddress, uint usdtAmount);
  event UserRequestedWithdraw(address indexed userAddress, uint usdtAmount);
  event UserWithdrew(address indexed userAddress, uint usdtAmount);

  event PandaiBurnedForUserRewardClaim(address indexed userAddress, uint pandaiAmount);
  event PandaiBurnedForReferralRewardClaim(address indexed userAddress, uint pandaiAmount);
  event PandaiBurnedForWithdrawFee(address indexed userAddress, uint pandaiAmount);
  
  event UserRewardClaimed(address indexed userAddress, uint usdtAmount);
  event ReferralRewardClaimed(address indexed userAddress, uint usdtAmount);

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

  function getUser(address userAddress) external view returns (User memory stored, UserCalculated memory calculated) {    
    require(userAddress != address(0));    
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
    require(tier >= 1 && tier <= 5);
    return tierMap[tier];
  }

  function getLpAddress() external view returns (address) {
    return lpAddress;
  }

  function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
    _pause();
  }

  function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
    _unpause();
  }

  function setLpAddress(address newLpAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(lpAddress != address(0));
    require(usdtToken.balanceOf(lpAddress) > 0);
    require(pandaiToken.balanceOf(lpAddress) > 0);
    
    address oldLpAddress = lpAddress;
    lpAddress = newLpAddress;
    emit LpAddressChanged(oldLpAddress, newLpAddress);
  }

  function withdrawTreasury(uint usdtAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(usdtToken.balanceOf(address(this)) >= usdtAmount);
    usdtToken.transfer(msg.sender, usdtAmount);
    emit TreasuryWithdraw(usdtAmount);
  }

  function depositTreasury(uint usdtAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(usdtToken.balanceOf(msg.sender) >= usdtAmount);
    require(usdtToken.allowance(msg.sender, address(this)) >= usdtAmount);
    usdtToken.transferFrom(msg.sender, address(this), usdtAmount);
    emit TreasuryDeposit(usdtAmount);
  }

  function setUserApprovalLevel(address userAddress, ApprovalLevel newApprovalLevel) external onlyRole(UPDATER_ROLE) {
    ApprovalLevel oldApprovalLevel = ApprovalLevel(userMap[userAddress].approvalLevel);
    userMap[userAddress].approvalLevel = uint8(newApprovalLevel);
    emit ApprovalLevelChanged(userAddress, oldApprovalLevel, newApprovalLevel);
  }

  function deposit(uint usdtAmount) external {
    deposit(usdtAmount, DEFAULT_REFERRAL);
  }

  function deposit(uint usdtDepositAmount, address referralAddress) public whenNotPaused {
    require(usdtDepositAmount >= tierMap[1].minDeposit * (10 ** usdtToken.decimals()));
    require(referralAddress != address(0));
    require(referralAddress != msg.sender);
    
    uint8 tier = getUserTier(msg.sender);
    uint claimUsdt = getUserReward(msg.sender, tier);
    require(canClaim(msg.sender, claimUsdt));
    
    uint claimFeePandai = getPandaiWorthOf(getUserRewardClaimFeeUsdt(claimUsdt, tier));
    require(pandaiToken.balanceOf(msg.sender) >= claimFeePandai);
    require(pandaiToken.allowance(msg.sender, address(this)) >= claimFeePandai);
    if (claimUsdt < usdtDepositAmount) {
      require(usdtToken.balanceOf(msg.sender) >= usdtDepositAmount - claimUsdt);
      require(usdtToken.allowance(msg.sender, address(this)) >= usdtDepositAmount - claimUsdt);
    } else if (claimUsdt > usdtDepositAmount) {
      require(usdtToken.balanceOf(address(this)) >= claimUsdt - usdtDepositAmount);
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
    
    uint newReferralReward = getNewReferralReward(userMap[msg.sender].referral);
    userMap[userMap[msg.sender].referral].referralDeposit += usdtDepositAmount;
    userMap[userMap[msg.sender].referral].referralPendingReward += newReferralReward;
    userMap[userMap[msg.sender].referral].referralLastUpdateTimestamp = block.timestamp;
    
    if (claimUsdt < usdtDepositAmount) {
      usdtToken.transferFrom(msg.sender, address(this), usdtDepositAmount - claimUsdt);
    } else if (claimUsdt > usdtDepositAmount) {
      usdtToken.transfer(msg.sender, claimUsdt - usdtDepositAmount);
    }
    emit UserDeposited(msg.sender, usdtDepositAmount);
    emit UserRewardClaimed(msg.sender, claimUsdt);
    
    pandaiToken.burnFrom(msg.sender, claimFeePandai);
    emit PandaiBurnedForUserRewardClaim(msg.sender, claimFeePandai);
  }

  function requestWithdraw(uint usdtWithdrawAmount) public {
    require(usdtWithdrawAmount <= userMap[msg.sender].deposit);
    if (usdtWithdrawAmount < userMap[msg.sender].deposit) {
      require(userMap[msg.sender].deposit - usdtWithdrawAmount >= tierMap[1].minDeposit * (10 ** usdtToken.decimals()));
    }

    uint withdrawFeePandai;
    uint8 tier = getUserTier(msg.sender);
    if (getWithdrawFreeTimestamp(msg.sender, tier) > block.timestamp) {
      uint withdrawFeeBps = getWithdrawFeeBps(tier);
      uint withdrawFeeUsdt = usdtWithdrawAmount * withdrawFeeBps / 10_000;
      withdrawFeePandai = getPandaiWorthOf(withdrawFeeUsdt);

      require(pandaiToken.balanceOf(msg.sender) >= withdrawFeePandai);
      require(pandaiToken.allowance(msg.sender, address(this)) >= withdrawFeePandai);
    }

    userMap[msg.sender].deposit -= usdtWithdrawAmount;
    userMap[msg.sender].withdrawRequestAmount += usdtWithdrawAmount;
    userMap[msg.sender].withdrawPossibleTimestamp = block.timestamp + WITHDRAW_PROCESSING_TIME;
    
    uint newReferralReward = getNewReferralReward(userMap[msg.sender].referral);
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
    require(userMap[msg.sender].withdrawRequestAmount > 0);
    require(userMap[msg.sender].withdrawRequestAmount <= usdtToken.balanceOf(address(this)));
    require(userMap[msg.sender].withdrawPossibleTimestamp <= block.timestamp);

    uint usdtWithdrawAmount = userMap[msg.sender].withdrawRequestAmount;
    userMap[msg.sender].withdrawRequestAmount = 0;
    userMap[msg.sender].withdrawPossibleTimestamp = 0;

    usdtToken.transfer(msg.sender, usdtWithdrawAmount);
    emit UserWithdrew(msg.sender, usdtWithdrawAmount);
  }

  function claimUser() public {
    uint8 tier = getUserTier(msg.sender);
    uint userClaimUsdt = getUserReward(msg.sender, tier);
    require(canClaim(msg.sender, userClaimUsdt));
    
    uint userClaimFeePandai = getPandaiWorthOf(getUserRewardClaimFeeUsdt(userClaimUsdt, tier));
    require(pandaiToken.balanceOf(msg.sender) >= userClaimFeePandai);
    require(pandaiToken.allowance(msg.sender, address(this)) >= userClaimFeePandai);

    if (isToday(userMap[msg.sender].lastClaimTimestamp)) {
      userMap[msg.sender].dailyClaim += userClaimUsdt;
    } else {
      userMap[msg.sender].dailyClaim = userClaimUsdt;
    }
    userMap[msg.sender].totalClaim += userClaimUsdt;
    userMap[msg.sender].lastClaimTimestamp = block.timestamp;

    usdtToken.transfer(msg.sender, userClaimUsdt);
    emit UserRewardClaimed(msg.sender, userClaimUsdt);
    
    pandaiToken.burnFrom(msg.sender, userClaimFeePandai);
    emit PandaiBurnedForUserRewardClaim(msg.sender, userClaimFeePandai);
  }
 
  function claimReferral() public {
    uint referralClaimUsdt = userMap[msg.sender].referralPendingReward + getNewReferralReward(msg.sender);
    require(canClaim(msg.sender, referralClaimUsdt));
    
    uint referralClaimFeePandai = getPandaiWorthOf(getReferralRewardClaimFeeUsdt(referralClaimUsdt));
    require(pandaiToken.balanceOf(msg.sender) >= referralClaimFeePandai);
    require(pandaiToken.allowance(msg.sender, address(this)) >= referralClaimFeePandai);

    if (isToday(userMap[msg.sender].lastClaimTimestamp)) {
      userMap[msg.sender].dailyClaim += referralClaimUsdt;
    } else {
      userMap[msg.sender].dailyClaim = referralClaimUsdt;
    }
    userMap[msg.sender].totalClaim += referralClaimUsdt;

    userMap[msg.sender].referralPendingReward = 0;
    userMap[msg.sender].referralLastUpdateTimestamp = block.timestamp;

    usdtToken.transfer(msg.sender, referralClaimUsdt);
    emit ReferralRewardClaimed(msg.sender, referralClaimUsdt);
    
    pandaiToken.burnFrom(msg.sender, referralClaimFeePandai);
    emit PandaiBurnedForReferralRewardClaim(msg.sender, referralClaimFeePandai);
  }

  function claimAll() public {
    uint8 tier = getUserTier(msg.sender);
    uint userClaimUsdt = getUserReward(msg.sender, tier);
    uint referralClaimUsdt = userMap[msg.sender].referralPendingReward + getNewReferralReward(msg.sender);
    require(canClaim(msg.sender, userClaimUsdt + referralClaimUsdt));
    
    uint userClaimFeePandai = getPandaiWorthOf(getUserRewardClaimFeeUsdt(userClaimUsdt, tier));
    uint referralClaimFeePandai = getPandaiWorthOf(getReferralRewardClaimFeeUsdt(referralClaimUsdt));
    require(pandaiToken.balanceOf(msg.sender) >= userClaimFeePandai + referralClaimFeePandai);
    require(pandaiToken.allowance(msg.sender, address(this)) >= userClaimFeePandai + referralClaimFeePandai);

    if (isToday(userMap[msg.sender].lastClaimTimestamp)) {
      userMap[msg.sender].dailyClaim += userClaimUsdt + referralClaimUsdt;
    } else {
      userMap[msg.sender].dailyClaim = userClaimUsdt + referralClaimUsdt;
    }
    userMap[msg.sender].totalClaim += userClaimUsdt + referralClaimUsdt;
    userMap[msg.sender].lastClaimTimestamp = block.timestamp;

    userMap[msg.sender].referralPendingReward = 0;
    userMap[msg.sender].referralLastUpdateTimestamp = block.timestamp;

    usdtToken.transfer(msg.sender, userClaimUsdt + referralClaimUsdt);
    emit UserRewardClaimed(msg.sender, userClaimUsdt);
    emit ReferralRewardClaimed(msg.sender, referralClaimUsdt);

    pandaiToken.burnFrom(msg.sender, userClaimFeePandai + referralClaimFeePandai);
    emit PandaiBurnedForUserRewardClaim(msg.sender, userClaimFeePandai);
    emit PandaiBurnedForReferralRewardClaim(msg.sender, referralClaimFeePandai);
  }

  function canClaim(address userAddress, uint claimUsdt) private view returns (bool) {
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

  function isToday(uint timestamp) private view returns (bool) {
    return block.timestamp / 1 days == timestamp / 1 days;
  }

  function getPandaiWorthOf(uint usdtAmount) private view returns (uint) {
    uint usdtInLp = usdtToken.balanceOf(lpAddress);
    uint pandaiInLp = pandaiToken.balanceOf(lpAddress);
    require (usdtInLp * pandaiInLp > 0);

    return usdtAmount * pandaiInLp / usdtInLp;
  }

  function getUserTier(address userAddress) private view returns (uint8) {
    uint userDeposit = userMap[userAddress].deposit / (10 ** usdtToken.decimals());
    for (uint8 i = 5; i >= 1; i--) {
      if (userDeposit >= tierMap[i].minDeposit) {
        return i;
      }
    }
    return 0;
  }

  function getUserReward(address userAddress, uint8 userTier) private view returns (uint) {
    // TODO
    return 0;
  }

  function getUserRewardClaimFeeUsdt(uint userReward, uint8 userTier) private view returns (uint) {
    // TODO
    return 0;
  }

  function getNewReferralReward(address userAddress) private view returns (uint) {
    // TODO
    return 0;
  }

  function getReferralRewardClaimFeeUsdt(uint referralReward) private view returns (uint) {
    // TODO
    return 0;
  }

  function getWithdrawFeeBps(uint8 userTier) private view returns (uint) {
    // TODO
    return 0;
  }

  function getWithdrawFreeTimestamp(address userAddress, uint8 userTier) private view returns (uint) {
    // TODO
    return 0;    
  }

}
