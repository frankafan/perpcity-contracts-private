// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IMarginRatios} from "../interfaces/modules/IMarginRatios.sol";
import {IPerpManager} from "../interfaces/IPerpManager.sol";

/// @title MarginRatios
/// @notice A basic implementation of a margin ratios module
contract MarginRatios is IMarginRatios {
    /* CONSTANTS */

    /// @notice The minimum margin ratio for maker positions, equivalent to 90% or 1.11x leverage
    uint24 public constant MIN_MAKER_RATIO = 0.9e6;
    /// @notice The maximum margin ratio for maker positions, equivalent to 200% or 0.5x leverage
    uint24 public constant MAX_MAKER_RATIO = 2e6;
    /// @notice The margin ratio at which maker positions are liquidatable, equivalent to 50% or 2x leverage
    uint24 public constant LIQUIDATION_MAKER_RATIO = 0.5e6; // 50% / 2x leverage

    /// @notice The minimum margin ratio for taker positions, equivalent to 10% or 10x leverage
    uint24 public constant MIN_TAKER_RATIO = 0.1e6;
    /// @notice The maximum margin ratio for taker positions, equivalent to 200% or 0.5x leverage
    uint24 public constant MAX_TAKER_RATIO = 2e6;
    /// @notice The margin ratio at which taker positions are liquidatable, equivalent to 5% or 20x leverage
    uint24 public constant LIQUIDATION_TAKER_RATIO = 0.05e6;

    /* FUNCTIONS */

    /// @inheritdoc IMarginRatios
    function marginRatios(IPerpManager.PerpConfig calldata, bool maker) external pure returns (uint24, uint24, uint24) {
        if (maker) return (MIN_MAKER_RATIO, MAX_MAKER_RATIO, LIQUIDATION_MAKER_RATIO);
        else return (MIN_TAKER_RATIO, MAX_TAKER_RATIO, LIQUIDATION_TAKER_RATIO);
    }
}