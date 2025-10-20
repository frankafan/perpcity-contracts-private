// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPerpManager} from "../IPerpManager.sol";

/// @title IMarginRatios
/// @notice Interface that a margin ratios module must implement to be usable by the PerpManager
interface IMarginRatios {
    /* FUNCTIONS */

    function marginRatios(IPerpManager.PerpConfig calldata perp, bool isMaker) external returns (uint24 minRatio, uint24 maxRatio, uint24 liquidationRatio);
}