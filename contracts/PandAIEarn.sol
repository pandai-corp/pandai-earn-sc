// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol"; 

interface IERC20Burnable is IERC20 {
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

contract PandAIEarn is AccessControl, Pausable {

  IERC20 private usdtToken;
  IERC20Burnable private pandaiToken;
  
  address private lpAddress;

  bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");
  
  enum ApprovalLevel{ NotApproved, Approved, Forbidden }

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

  event LpAddressChanged(address indexed previousLp, address indexed newLp);
  event TreasuryWithdraw(uint256 amount);
  event ApprovalLevelChanged(address indexed userAddress, ApprovalLevel previousApprovalLevel, ApprovalLevel newApprovalLevel);

  modifier enoughUsdtInTreasury(uint256 amountToWithdraw) {
    require(usdtToken.balanceOf(address(this)) >= amountToWithdraw);
    _;
  }

  constructor(address _usdtTokenAddress, address _pandaiTokenAddress) {
    usdtToken = IERC20(_usdtTokenAddress);
    pandaiToken = IERC20Burnable(_pandaiTokenAddress);
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
  }

  function pause() public onlyRole(DEFAULT_ADMIN_ROLE) {
    _pause();
  }

  function unpause() public onlyRole(DEFAULT_ADMIN_ROLE) {
    _unpause();
  }

  function setLpAddress(address newLpAddress) public onlyRole(DEFAULT_ADMIN_ROLE) {
    require(lpAddress != address(0), "lpAddress cannot be zero address");
    require(usdtToken.balanceOf(lpAddress) > 0, "No USDT on LP");
    require(pandaiToken.balanceOf(lpAddress) > 0, "No PANDAI on LP");
    
    address oldLpAddress = lpAddress;
    lpAddress = newLpAddress;
    emit LpAddressChanged(oldLpAddress, newLpAddress);
  }

  function withdrawTreasury(uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) enoughUsdtInTreasury(amount) {
    usdtToken.transfer(msg.sender, amount);
    emit TreasuryWithdraw(amount);
  }

  function getLpAddress() external view returns (address) {
    return lpAddress;
  }

  function setUserApprovalLevel(address userAddress, ApprovalLevel newApprovalLevel) public onlyRole(UPDATER_ROLE) {
    ApprovalLevel oldApprovalLevel = ApprovalLevel(userMap[userAddress].approvalLevel);
    userMap[userAddress].approvalLevel = uint8(newApprovalLevel);
    emit ApprovalLevelChanged(userAddress, oldApprovalLevel, newApprovalLevel);
  }

  function getUser(address userAddress) external view returns (User memory) {
    return userMap[userAddress];
  }

}
