// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol"; 

interface IERC20Extended is IERC20 {
  function decimals() external view returns (uint8);
}

interface IERC20Burnable is IERC20Extended {
  function burnFrom(address account, uint amount) external;
}

contract PandAIEarnV1 is AccessControl, Pausable {

  IERC20Extended private immutable usdtToken;
  IERC20Burnable private immutable pandaiToken;
  
  address private lpAddress;

  bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");
  address private constant DEFAULT_REFERRAL = 0xeA51341bb930E2D8561ad2a4430873D6d18997BD;

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
    uint16 minDeposit;
    bool compoundInterest;     
    
    uint8 monthlyGainBps;
    uint16 claimFeeBps;

    uint lockupSeconds;
    uint16 lockupBreachFeeBps;
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
   
    uint userPendingReward;            // user reward that hasn't been claimed because of deposit or request withdraw

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
    require(userAddress != address(0), "empty address");    

    uint8 tier = getUserTier(userAddress);
    uint userReward = userMap[msg.sender].userPendingReward + getNewUserReward(userAddress, tier);
    uint referralReward = userMap[userAddress].referralPendingReward + getNewReferralReward(userAddress);
    return (
      userMap[userAddress],
      UserCalculated(
        tier,
        userReward,
        getUserRewardClaimFeePandai(userReward, tier),
        referralReward,
        getReferralRewardClaimFeePandai(referralReward),
        getDepositUnlockTimestamp(userAddress, tier)
      )
    );
  }

  /**
    returns info about given tier.
  */
  function getTier(uint8 tier) external view returns (Tier memory) {
    require(tier >= 1 && tier <= 5, "invalid tier");
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
    require(newLpAddress != address(0), "empty address");
    require(usdtToken.balanceOf(newLpAddress) > 0, "no usdt in lp");
    require(pandaiToken.balanceOf(newLpAddress) > 0, "no pandai in lp");
    
    address oldLpAddress = lpAddress;
    lpAddress = newLpAddress;
    emit LpAddressChanged(oldLpAddress, newLpAddress);
  }

  /**
    withdraws USDT from contract
  */
  function withdrawTreasury(uint usdtAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(usdtToken.transfer(msg.sender, usdtAmount), "usdt transfer");
    emit TreasuryWithdraw(usdtAmount);
  }

  /**
    deposits USDT from contract. USDT can be sent in ordinary transaction, this event is helpful to use as it produces event.
  */
  function depositTreasury(uint usdtAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(usdtToken.transferFrom(msg.sender, address(this), usdtAmount), "usdt transfer");
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
  */
  function depositWithReferral(uint usdtDepositAmount, address referralAddress) public whenNotPaused {
    require(msg.sender == tx.origin, "calls from contract disallowed");
    require(userMap[msg.sender].deposit + usdtDepositAmount >= tierMap[1].minDeposit * (10 ** usdtToken.decimals()), "small deposit");
    require(referralAddress != address(0), "invalid referral");
    require(referralAddress != msg.sender, "invalid referral");

    // assign referral
    if (userMap[msg.sender].referral == address(0)) {
      userMap[msg.sender].referral = referralAddress;
    }

    // update user
    uint8 tier = getUserTier(msg.sender);
    if (tier > 0) {
      userMap[msg.sender].userPendingReward += getNewUserReward(msg.sender, tier);
    }

    userMap[msg.sender].deposit += usdtDepositAmount;
    userMap[msg.sender].lastDepositTimestamp = block.timestamp;
    userMap[msg.sender].lastClaimTimestamp = block.timestamp;
    
    // update referral
    uint newReferralReward = getNewReferralReward(userMap[msg.sender].referral);
    userMap[userMap[msg.sender].referral].referralDeposit += usdtDepositAmount;
    userMap[userMap[msg.sender].referral].referralPendingReward += newReferralReward;
    userMap[userMap[msg.sender].referral].referralLastUpdateTimestamp = block.timestamp;
    
    // transfer USDT
    require(usdtToken.transferFrom(msg.sender, address(this), usdtDepositAmount), "usdt transfer");
    emit UserDeposited(msg.sender, usdtDepositAmount);
  }

  /**
    requests USDT withdraw. USDTs will be available for withdraw (other method) after WITHDRAW_PROCESSING_TIME.
    In case there's already a withdraw pending, it's increased by usdtWithdrawAmount and WITHDRAW_PROCESSING_TIME is reset.
  */
  function requestWithdraw(uint usdtWithdrawAmount) external {
    require(msg.sender == tx.origin, "calls from contract disallowed");
    require(usdtWithdrawAmount <= userMap[msg.sender].deposit, "withdraw bigger than deposit");
    if (usdtWithdrawAmount < userMap[msg.sender].deposit) {
      require(userMap[msg.sender].deposit - usdtWithdrawAmount >= tierMap[1].minDeposit * (10 ** usdtToken.decimals()), "small deposit remaining");
    }

    uint8 tier = getUserTier(msg.sender);
    require(tier > 0, "invalid tier");

    // if withdraw is called before lockup, there's a fee paid in PANDAI
    uint withdrawFeePandai;
    if (getDepositUnlockTimestamp(msg.sender, tier) > block.timestamp) {
      withdrawFeePandai = getPandaiWorthOf(usdtWithdrawAmount * tierMap[tier].lockupBreachFeeBps / MIRIAD);

      require(pandaiToken.balanceOf(msg.sender) >= withdrawFeePandai, "pandai balance");
      require(pandaiToken.allowance(msg.sender, address(this)) >= withdrawFeePandai, "pandai allowance");
    }

    // update user
    userMap[msg.sender].userPendingReward += getNewUserReward(msg.sender, tier);
    userMap[msg.sender].lastClaimTimestamp = block.timestamp;

    userMap[msg.sender].deposit -= usdtWithdrawAmount;
    userMap[msg.sender].withdrawRequestAmount += usdtWithdrawAmount;
    userMap[msg.sender].withdrawPossibleTimestamp = block.timestamp + WITHDRAW_PROCESSING_TIME;
    
    // update referral
    userMap[userMap[msg.sender].referral].referralPendingReward += getNewReferralReward(userMap[msg.sender].referral);
    userMap[userMap[msg.sender].referral].referralDeposit -= usdtWithdrawAmount;
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
    require(userMap[msg.sender].withdrawRequestAmount > 0, "no withdraw requested");
    require(userMap[msg.sender].withdrawPossibleTimestamp <= block.timestamp, "withdraw not possible yet");

    // update user
    uint usdtWithdrawAmount = userMap[msg.sender].withdrawRequestAmount;
    userMap[msg.sender].withdrawRequestAmount = 0;
    userMap[msg.sender].withdrawPossibleTimestamp = 0;

    // transfer USDT
    require(usdtToken.transfer(msg.sender, usdtWithdrawAmount), "usdt transfer");
    emit UserWithdrew(msg.sender, usdtWithdrawAmount);
  }

  /**
    claims user reward (derived from it's own deposit) and
    referral reward (derived from deposits of users with referral being the caller)
  */
  function claim() external whenNotPaused {
    require(msg.sender == tx.origin, "calls from contract disallowed");

    uint8 tier = getUserTier(msg.sender);
    uint userClaimUsdt = userMap[msg.sender].userPendingReward + getNewUserReward(msg.sender, tier);
    uint referralClaimUsdt = userMap[msg.sender].referralPendingReward + getNewReferralReward(msg.sender);
    require(userClaimUsdt + referralClaimUsdt > 0, "empty claim");
    require(canClaim(msg.sender, userClaimUsdt + referralClaimUsdt), "user cannot claim");
    
    uint userClaimFeePandai = getUserRewardClaimFeePandai(userClaimUsdt, tier);
    uint referralClaimFeePandai = getReferralRewardClaimFeePandai(referralClaimUsdt);
    require(pandaiToken.balanceOf(msg.sender) >= userClaimFeePandai + referralClaimFeePandai, "pandai balance");
    require(pandaiToken.allowance(msg.sender, address(this)) >= userClaimFeePandai + referralClaimFeePandai, "pandai allowance");

    // update user
    userMap[msg.sender].userPendingReward = 0;
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
    require(usdtToken.transfer(msg.sender, userClaimUsdt + referralClaimUsdt), "usdt transfer");
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
    return block.timestamp / BASE_PERIOD == timestamp / BASE_PERIOD;
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
    require (usdtInLp * pandaiInLp > 0, "empty lp");

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
  function getNewUserReward(address userAddress, uint8 userTier) private view returns (uint) {
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
  function getDepositUnlockTimestamp(address userAddress, uint8 userTier) private view returns (uint) {
    if (userTier == 0) {
      return 0;
    }
    return userMap[userAddress].lastDepositTimestamp + tierMap[userTier].lockupSeconds;
  }

}
