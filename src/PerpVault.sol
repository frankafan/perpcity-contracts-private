// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PerpVault {
    constructor(address perpHook, IERC20 usdc) {
        usdc.approve(perpHook, type(uint256).max);
    }
}
