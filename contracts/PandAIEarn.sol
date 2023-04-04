// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20Burnable is IERC20 {
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

contract PandAIEarn {

  IERC20 private usdtToken;
  IERC20Burnable private pandaiToken;
  address private lpAddress;

  constructor(address _usdtTokenAddress, address _pandaiTokenAddress, address _lpAddress) {
    usdtToken = IERC20(_usdtTokenAddress);
    pandaiToken = IERC20Burnable(_pandaiTokenAddress);
    lpAddress = _lpAddress;
  }

  function usdtOnLp() public view returns (uint256) {
    return usdtToken.balanceOf(lpAddress);
  }

  function pandaiOnLp() public view returns (uint256) {
    return pandaiToken.balanceOf(lpAddress);
  }

}
