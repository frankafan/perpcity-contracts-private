// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";

/// @title PerpVault
/// @notice A contract that holds all USDC for a perp
/// @dev Each perp matches to one PerpVault. This is so that USDC is isolated between perps
contract PerpVault {
    /* CONSTRUCTOR */

    /// @notice Instantiates the PerpVault
    /// @dev The perp manager provides its address on perp creation
    /// @param perpManager The address of the perp manager
    /// @param usdc The address of the USDC token
    constructor(address perpManager, address usdc) {
        SafeTransferLib.safeApprove(usdc, perpManager, type(uint256).max);
    }
}
