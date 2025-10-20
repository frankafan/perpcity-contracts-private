// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IMarginRatios} from "../interfaces/modules/IMarginRatios.sol";
import {IPerpManager} from "../interfaces/IPerpManager.sol";

contract MarginRatios is IMarginRatios {
    uint24 public constant MIN_MAKER_RATIO = 0.9e6; // 90% / 1.11x leverage
    uint24 public constant MAX_MAKER_RATIO = 2e6; // 200% / 0.5x leverage
    uint24 public constant LIQUIDATION_MAKER_RATIO = 0.5e6; // 50% / 2x leverage
    uint24 public constant MIN_TAKER_RATIO = 0.1e6; // 10% / 10x leverage
    uint24 public constant MAX_TAKER_RATIO = 2e6; // 200% / 0.5x leverage
    uint24 public constant LIQUIDATION_TAKER_RATIO = 0.05e6; // 5% / 20x leverage

    function marginRatios(IPerpManager.PerpConfig calldata perp, bool isMaker) external returns (uint24 minRatio, uint24 maxRatio, uint24 liquidationRatio) {
        if (isMaker) return (MIN_MAKER_RATIO, MAX_MAKER_RATIO, LIQUIDATION_MAKER_RATIO);
        else return (MIN_TAKER_RATIO, MAX_TAKER_RATIO, LIQUIDATION_TAKER_RATIO);
    }
}