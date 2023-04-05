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

  event LpAddressChanged(address indexed previousLp, address indexed newLp);
  event TreasuryWithdraw(uint256 amount);

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



}
