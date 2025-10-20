// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPerpManager} from "../IPerpManager.sol";

/// @title ISqrtPriceImpactLimit
/// @notice Interface that a sqrt price impact limit module must implement to be usable by the PerpManager
interface ISqrtPriceImpactLimit {
    /* FUNCTIONS */

    function sqrtPriceImpactLimitX96(IPerpManager.PerpConfig calldata perp, bool zeroForOne) external returns (uint256);
}