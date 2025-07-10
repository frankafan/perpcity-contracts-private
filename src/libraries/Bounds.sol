// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

library Bounds {
    struct MarginBounds {
        uint128 minOpeningMargin;
        uint128 maxOpeningMargin;
    }

    struct LeverageBounds {
        uint128 minOpeningLeverageX96;
        uint128 maxOpeningLeverageX96;
        uint256 liquidationLeverageX96;
    }
}
