// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPerpManager} from "../IPerpManager.sol";

/// @title ISqrtPriceImpactLimit
/// @notice Interface that a sqrt price impact limit module must implement to be usable by the PerpManager
interface ISqrtPriceImpactLimit {
    /* FUNCTIONS */

    /// @notice Returns the sqrt price impact limit for a perp scaled by 2^96
    /// @param perp The configuration for the perp
    /// @param zeroForOne Whether the swap is currency0 in for currency1 out or vice versa
    /// @return sqrtPriceImpactLimitX96 The sqrt price impact limit scaled by 2^96
    function sqrtPriceImpactLimit(IPerpManager.PerpConfig calldata perp, bool zeroForOne) external returns (uint256);
}
