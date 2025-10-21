// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPerpManager} from "../IPerpManager.sol";

/// @title IMarginRatios
/// @notice Interface that a margin ratios module must implement to be usable by the PerpManager
interface IMarginRatios {
    /* FUNCTIONS */

    /// @notice Returns the margin ratios checked against for maker or taker positions given a perp config
    /// @dev All margin ratios are scaled by 1e6
    /// @param perp The configuration for the perp
    /// @param isMaker Whether the position is a maker. If false, the position is a taker
    /// @return minRatio The minimum margin ratio
    /// @return maxRatio The maximum margin ratio
    /// @return liqRatio The margin ratio at which the position is liquidatable
    function marginRatios(IPerpManager.PerpConfig calldata perp, bool isMaker)
        external
        returns (uint24 minRatio, uint24 maxRatio, uint24 liqRatio);
}
