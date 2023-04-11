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
  address private constant DEFAULT_REFERRAL = 0xEe9Aa828fF4cBF294063168E78BEB7BcF441fEa1;

  uint private constant BASE_PERIOD = 1 days;                        // base period for time (mainnet: 1 day, devnet: minutes)
  uint private constant WITHDRAW_PROCESSING_TIME = 14 * BASE_PERIOD; // user requests withdrawal -> 14 days waiting -> withdrawal can be executed
  uint private constant INTEREST_PERIOD = 30 * BASE_PERIOD;          // period for Tier.monthlyGainBps
  uint private constant DAILY_CLAIM_LIMIT = 1000;                    // daily claim limit of USDT for NotApproved users
  uint private constant MIRIAD = 10000;                              // helper for divisor
  uint private constant REFERRAL_MONTHLY_GAIN_BPS = 20;              // 0.2% reward for referrals
  uint private constant REFERRAL_CLAIM_FEE_BPS = 1000;               // 10% referral claim fee
  
  /**
    0: NotApproved (daily claim limit of $1000)
    1: Approved (no daily limit)
    2: Forbidden (claim forbidden)
  */
  enum ApprovalLevel{ NotApproved, Approved, Forbidden }

  mapping(uint8 => Tier) private tierMap;
  struct Tier {
    uint minDeposit;
    bool compoundInterest;     
    
    uint monthlyGainBps;
    uint claimFeeBps;

    uint lockupSeconds;
    uint lockupBreachFeeBps;
  }

  mapping(address => User) private userMap;
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

    uint userPendingReward;
    uint userPendingPandaiBurn;

    uint referralPendingReward;
    uint referralPendingPandaiBurn;

    uint depositUnlockTimestamp;
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

  constructor(address usdtTokenAddress, address pandaiTokenAddress) {
    usdtToken = IERC20Extended(usdtTokenAddress);
    pandaiToken = IERC20Burnable(pandaiTokenAddress);

    tierMap[1] = Tier(  100, false, 100, 1000,   7 * BASE_PERIOD, 4000);
    tierMap[2] = Tier(  500, false, 125,  900,  30 * BASE_PERIOD, 3500);
    tierMap[3] = Tier( 1000, false, 150,  800,  60 * BASE_PERIOD, 3000);
    tierMap[4] = Tier( 5000,  true, 180,  650,  90 * BASE_PERIOD, 2500);
    tierMap[5] = Tier(10000,  true, 220,  500, 180 * BASE_PERIOD, 2000);

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
  }
 
  /**
    returns info about given user. Returns stored values (stored in mapping) and calculated values (contract calculates them from stored values)
  */
  function getUser(address userAddress) external view returns (User memory stored, UserCalculated memory calculated) {    
    require(userAddress != address(0));    
    uint8 tier = getUserTier(userAddress);
    uint userReward = getUserReward(userAddress, tier);
    uint referralReward = userMap[userAddress].referralPendingReward + getNewReferralReward(userAddress);
    return (
      userMap[userAddress],
      UserCalculated(
        tier,
        userReward,
        getUserRewardClaimFeePandai(userReward, tier),
        referralReward,
        getReferralRewardClaimFeePandai(referralReward),
        getDepositUnlokTimestamp(userAddress, tier)
      )
    );
  }

  /**
    returns info about given tier.
  */
  function getTier(uint8 tier) external view returns (Tier memory) {
    require(tier >= 1 && tier <= 5);
    return tierMap[tier];
  }

  /**
    returns address of liquidty pool that swaps USDT and PANDAI. Used to define PANDAI price in USDT.
  */
  function getLpAddress() external view returns (address) {
    return lpAddress;
  }

  /**
    paused contract prohibits deposits
  */
  function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
    _pause();
  }

  /**
    unpauses paused contract
  */
  function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
    _unpause();
  }

  /**
    sets address for liquidity pool
  */
  function setLpAddress(address newLpAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(newLpAddress != address(0));
    require(usdtToken.balanceOf(newLpAddress) > 0);
    require(pandaiToken.balanceOf(newLpAddress) > 0);
    
    address oldLpAddress = newLpAddress;
    lpAddress = newLpAddress;
    emit LpAddressChanged(oldLpAddress, newLpAddress);
  }

  /**
    withdraws USDT from contract
  */
  function withdrawTreasury(uint usdtAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(usdtToken.balanceOf(address(this)) >= usdtAmount);
    usdtToken.transfer(msg.sender, usdtAmount);
    emit TreasuryWithdraw(usdtAmount);
  }

  /**
    deposits USDT from contract. USDT can be sent in ordinary transaction, this event is helpful to use as it produces event.
  */
  function depositTreasury(uint usdtAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(usdtToken.balanceOf(msg.sender) >= usdtAmount);
    require(usdtToken.allowance(msg.sender, address(this)) >= usdtAmount);
    usdtToken.transferFrom(msg.sender, address(this), usdtAmount);
    emit TreasuryDeposit(usdtAmount);
  }

  /**
    sets ApprovalLevel of given address. 
  */
  function setUserApprovalLevel(address userAddress, ApprovalLevel newApprovalLevel) external onlyRole(UPDATER_ROLE) {
    ApprovalLevel oldApprovalLevel = ApprovalLevel(userMap[userAddress].approvalLevel);
    userMap[userAddress].approvalLevel = uint8(newApprovalLevel);
    emit ApprovalLevelChanged(userAddress, oldApprovalLevel, newApprovalLevel);
  }

  /**
    deposits USDT, default referral is used
  */
  function deposit(uint usdtDepositAmount) external {
    depositWithReferral(usdtDepositAmount, DEFAULT_REFERRAL);
  }

  /**
    deposits USDT, referralAddress is used only if no referral is set for address making deposit (the first deposit of the address).
    If there's a pending user reward, the reward is lost because this method restarts User.lastClaimTimestamp and makes no claim.
    It's recommended to call claim() before this method.
  */
  function depositWithReferral(uint usdtDepositAmount, address referralAddress) public whenNotPaused {
    require(usdtDepositAmount >= tierMap[1].minDeposit * (10 ** usdtToken.decimals()));
    require(referralAddress != address(0));
    require(referralAddress != msg.sender);
    
    require(usdtToken.balanceOf(msg.sender) >= usdtDepositAmount);
    require(usdtToken.allowance(msg.sender, address(this)) >= usdtDepositAmount);

    // assign referral
    if (userMap[msg.sender].referral == address(0)) {
      userMap[msg.sender].referral = referralAddress;
    }

    // update user
    userMap[msg.sender].deposit += usdtDepositAmount;
    userMap[msg.sender].lastDepositTimestamp = block.timestamp;
    userMap[msg.sender].lastClaimTimestamp = block.timestamp;
    
    // update referral
    uint newReferralReward = getNewReferralReward(userMap[msg.sender].referral);
    userMap[userMap[msg.sender].referral].referralDeposit += usdtDepositAmount;
    userMap[userMap[msg.sender].referral].referralPendingReward += newReferralReward;
    userMap[userMap[msg.sender].referral].referralLastUpdateTimestamp = block.timestamp;
    
    // transfer USDT
    usdtToken.transferFrom(msg.sender, address(this), usdtDepositAmount);
    emit UserDeposited(msg.sender, usdtDepositAmount);
  }

  /**
    requests USDT withdraw. USDTs will be available for withdraw (other method) after WITHDRAW_PROCESSING_TIME.
    If there's a pending user reward, the reward will be partialy lost because this method decresese deposit and performs no claim.
    It's recommended to call claim() before this method.
    In case there's already a withdraw pending, it's increased by usdtWithdrawAmount and WITHDRAW_PROCESSING_TIME is reset.
  */
  function requestWithdraw(uint usdtWithdrawAmount) external {
    require(usdtWithdrawAmount <= userMap[msg.sender].deposit);
    if (usdtWithdrawAmount < userMap[msg.sender].deposit) {
      require(userMap[msg.sender].deposit - usdtWithdrawAmount >= tierMap[1].minDeposit * (10 ** usdtToken.decimals()));
    }

    uint8 tier = getUserTier(msg.sender);
    require(tier > 0);

    // if withdraw is called before lockup, there's a fee paid in PANDAI
    uint withdrawFeePandai;
    if (getDepositUnlokTimestamp(msg.sender, tier) > block.timestamp) {
      withdrawFeePandai = getPandaiWorthOf(usdtWithdrawAmount * tierMap[tier].lockupBreachFeeBps / MIRIAD);

      require(pandaiToken.balanceOf(msg.sender) >= withdrawFeePandai);
      require(pandaiToken.allowance(msg.sender, address(this)) >= withdrawFeePandai);
    }

    // update user
    userMap[msg.sender].deposit -= usdtWithdrawAmount;
    userMap[msg.sender].withdrawRequestAmount += usdtWithdrawAmount;
    userMap[msg.sender].withdrawPossibleTimestamp = block.timestamp + WITHDRAW_PROCESSING_TIME;
    
    // update referral
    uint newReferralReward = getNewReferralReward(userMap[msg.sender].referral);
    if (userMap[userMap[msg.sender].referral].referralDeposit >= usdtWithdrawAmount) {
      userMap[userMap[msg.sender].referral].referralDeposit -= usdtWithdrawAmount;
    } else {
      userMap[userMap[msg.sender].referral].referralDeposit = 0;
    }
    userMap[userMap[msg.sender].referral].referralPendingReward += newReferralReward;
    userMap[userMap[msg.sender].referral].referralLastUpdateTimestamp = block.timestamp;

    // if needed, burn PANDAI
    if (withdrawFeePandai > 0) {
      pandaiToken.burnFrom(msg.sender, withdrawFeePandai);
      emit PandaiBurnedForWithdrawFee(msg.sender, withdrawFeePandai);
    }
    emit UserRequestedWithdraw(msg.sender, usdtWithdrawAmount);
  }

  /**
    withdraws requested amount of USDT
  */
  function withdraw() external {
    require(userMap[msg.sender].withdrawRequestAmount > 0);
    require(userMap[msg.sender].withdrawRequestAmount <= usdtToken.balanceOf(address(this)));
    require(userMap[msg.sender].withdrawPossibleTimestamp <= block.timestamp);

    // update user
    uint usdtWithdrawAmount = userMap[msg.sender].withdrawRequestAmount;
    userMap[msg.sender].withdrawRequestAmount = 0;
    userMap[msg.sender].withdrawPossibleTimestamp = 0;

    // transfer USDT
    usdtToken.transfer(msg.sender, usdtWithdrawAmount);
    emit UserWithdrew(msg.sender, usdtWithdrawAmount);
  }

  /**
    claims user reward (derived from it's own deposit)
  */
  function claimUser() external {
    uint8 tier = getUserTier(msg.sender);
    require(tier > 0);

    uint userClaimUsdt = getUserReward(msg.sender, tier);
    require(userClaimUsdt > 0);
    require(canClaim(msg.sender, userClaimUsdt));
    
    uint userClaimFeePandai = getUserRewardClaimFeePandai(userClaimUsdt, tier);
    require(pandaiToken.balanceOf(msg.sender) >= userClaimFeePandai);
    require(pandaiToken.allowance(msg.sender, address(this)) >= userClaimFeePandai);

    // update user
    if (isToday(userMap[msg.sender].lastClaimTimestamp)) {
      userMap[msg.sender].dailyClaim += userClaimUsdt;
    } else {
      userMap[msg.sender].dailyClaim = userClaimUsdt;
    }
    userMap[msg.sender].totalClaim += userClaimUsdt;
    userMap[msg.sender].lastClaimTimestamp = block.timestamp;

    // transfer USDT
    usdtToken.transfer(msg.sender, userClaimUsdt);
    emit UserRewardClaimed(msg.sender, userClaimUsdt);
    
    // burn PANDAI
    pandaiToken.burnFrom(msg.sender, userClaimFeePandai);
    emit PandaiBurnedForUserRewardClaim(msg.sender, userClaimFeePandai);
  }
 
  /**
    claims referral reward (derived from deposits of users with referral being the caller)
  */
  function claimReferral() external {
    uint referralClaimUsdt = userMap[msg.sender].referralPendingReward + getNewReferralReward(msg.sender);
    require(referralClaimUsdt > 0);
    require(canClaim(msg.sender, referralClaimUsdt));
    
    uint referralClaimFeePandai = getReferralRewardClaimFeePandai(referralClaimUsdt);
    require(pandaiToken.balanceOf(msg.sender) >= referralClaimFeePandai);
    require(pandaiToken.allowance(msg.sender, address(this)) >= referralClaimFeePandai);

    // update user
    if (isToday(userMap[msg.sender].lastClaimTimestamp)) {
      userMap[msg.sender].dailyClaim += referralClaimUsdt;
    } else {
      userMap[msg.sender].dailyClaim = referralClaimUsdt;
    }
    userMap[msg.sender].totalClaim += referralClaimUsdt;

    // update referral
    userMap[msg.sender].referralPendingReward = 0;
    userMap[msg.sender].referralLastUpdateTimestamp = block.timestamp;

    // transfer USDT
    usdtToken.transfer(msg.sender, referralClaimUsdt);
    emit ReferralRewardClaimed(msg.sender, referralClaimUsdt);
    
    // transfer PANDAI
    pandaiToken.burnFrom(msg.sender, referralClaimFeePandai);
    emit PandaiBurnedForReferralRewardClaim(msg.sender, referralClaimFeePandai);
  }

  /**
    combines claimUser() and claimReferral() into a single contract call.
  */
  function claimAll() external {
    uint8 tier = getUserTier(msg.sender);
    uint userClaimUsdt = getUserReward(msg.sender, tier);
    uint referralClaimUsdt = userMap[msg.sender].referralPendingReward + getNewReferralReward(msg.sender);
    require(userClaimUsdt + referralClaimUsdt > 0);
    require(canClaim(msg.sender, userClaimUsdt + referralClaimUsdt));
    
    uint userClaimFeePandai = getUserRewardClaimFeePandai(userClaimUsdt, tier);
    uint referralClaimFeePandai = getReferralRewardClaimFeePandai(referralClaimUsdt);
    require(pandaiToken.balanceOf(msg.sender) >= userClaimFeePandai + referralClaimFeePandai);
    require(pandaiToken.allowance(msg.sender, address(this)) >= userClaimFeePandai + referralClaimFeePandai);

    // update user
    if (isToday(userMap[msg.sender].lastClaimTimestamp)) {
      userMap[msg.sender].dailyClaim += userClaimUsdt + referralClaimUsdt;
    } else {
      userMap[msg.sender].dailyClaim = userClaimUsdt + referralClaimUsdt;
    }
    userMap[msg.sender].totalClaim += userClaimUsdt + referralClaimUsdt;
    userMap[msg.sender].lastClaimTimestamp = block.timestamp;

    // update referral
    userMap[msg.sender].referralPendingReward = 0;
    userMap[msg.sender].referralLastUpdateTimestamp = block.timestamp;

    // transfer USDT, burn PANDAI
    usdtToken.transfer(msg.sender, userClaimUsdt + referralClaimUsdt);
    pandaiToken.burnFrom(msg.sender, userClaimFeePandai + referralClaimFeePandai);
    if (userClaimUsdt > 0) {
      emit UserRewardClaimed(msg.sender, userClaimUsdt);
      emit PandaiBurnedForUserRewardClaim(msg.sender, userClaimFeePandai);
    }
    if (referralClaimUsdt > 0) {
      emit ReferralRewardClaimed(msg.sender, referralClaimUsdt);
      emit PandaiBurnedForReferralRewardClaim(msg.sender, referralClaimFeePandai);
    }
  }

  /**
    checks whether given user is able claiming given amount of usdt. Depends on user approvalLevel and his dailyClaim
  */
  function canClaim(address userAddress, uint claimUsdt) private view returns (bool) {
    ApprovalLevel approvalLevel = ApprovalLevel(userMap[userAddress].approvalLevel);
    if (approvalLevel == ApprovalLevel.Approved) {
      return true;
    } else if (approvalLevel == ApprovalLevel.Forbidden) {
      return false;
    }
    if (isToday(userMap[userAddress].lastClaimTimestamp)) {
      claimUsdt += userMap[userAddress].dailyClaim;
    }
    return claimUsdt / (10 ** usdtToken.decimals()) < DAILY_CLAIM_LIMIT;
  }

  /**
    simple check whether given timestamp falls into same day
  */
  function isToday(uint timestamp) private view returns (bool) {
    return block.timestamp / BASE_PERIOD == timestamp / 1 * BASE_PERIOD;
  }

  /**
    converts USDT into pandai according to current price in the liquity pool
  */
  function getPandaiWorthOf(uint usdtAmount) private view returns (uint) {
    if (usdtAmount == 0) {
      return 0;
    }
    uint usdtInLp = usdtToken.balanceOf(lpAddress);
    uint pandaiInLp = pandaiToken.balanceOf(lpAddress);
    require (usdtInLp * pandaiInLp > 0);

    return usdtAmount * pandaiInLp / usdtInLp;
  }

  /**
    gets user tier from his deposit
  */
  function getUserTier(address userAddress) private view returns (uint8) {
    uint userDeposit = userMap[userAddress].deposit / (10 ** usdtToken.decimals());
    for (uint8 i = 5; i >= 1; i--) {
      if (userDeposit >= tierMap[i].minDeposit) {
        return i;
      }
    }
    return 0;
  }

  /**
    claculates user reward that follows eiterh simple or compounc interest. 
    In case of compound iterest, the calculatio follows taylor series for exponential
  */
  function getUserReward(address userAddress, uint8 userTier) private view returns (uint) {
    if (userTier == 0) {
      return 0;
    }
    uint g = tierMap[userTier].monthlyGainBps;
    uint t = block.timestamp - userMap[userAddress].lastClaimTimestamp;
    uint f1 = userMap[userAddress].deposit * g * t / MIRIAD / INTEREST_PERIOD;
    if (!tierMap[userTier].compoundInterest) {
      return f1;
    }
    uint f2 = f1 * g * t / MIRIAD / INTEREST_PERIOD / 2;
    uint f3 = f2 * g * t / MIRIAD / INTEREST_PERIOD / 3;
    return f1 + f2 + f3;
  }

  /**
    how much PANDAI user in given tier should burn when claiming given user reward
  */
  function getUserRewardClaimFeePandai(uint userRewardUsdt, uint8 userTier) private view returns (uint) {
    if (userTier == 0) {
      return 0;
    }
    return getPandaiWorthOf(userRewardUsdt * tierMap[userTier].claimFeeBps / MIRIAD);
  }

  /**
    calculates referral reward from time when the reward has been updated the last
  */
  function getNewReferralReward(address userAddress) private view returns (uint) {
    uint t = block.timestamp - userMap[userAddress].referralLastUpdateTimestamp;
    return userMap[userAddress].referralDeposit * REFERRAL_MONTHLY_GAIN_BPS * t / MIRIAD / INTEREST_PERIOD;
  }

  /**
    how much PANDAI user should burn when claiming given referral reward 
  */
  function getReferralRewardClaimFeePandai(uint referralRewardUsdt) private view returns (uint) {
    return getPandaiWorthOf(referralRewardUsdt * REFERRAL_CLAIM_FEE_BPS / MIRIAD);
  }

  /**
    timestamp when it's no longer required to burn PANDAI when requesting withdraw
  */
  function getDepositUnlokTimestamp(address userAddress, uint8 userTier) private view returns (uint) {
    if (userTier == 0) {
      return 0;
    }
    return userMap[userAddress].lastDepositTimestamp + tierMap[userTier].lockupSeconds;
  }

}
