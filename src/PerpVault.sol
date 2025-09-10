// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";

// one instance per perp; holds all usdc for the perp
contract PerpVault {
    constructor(address perpManager, address usdc) {
        SafeTransferLib.safeApprove(usdc, perpManager, type(uint256).max);
    }
}
