// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./IERC20Extended.sol";

interface IERC20Burnable is IERC20Extended {
  function burnFrom(address account, uint amount) external;
}