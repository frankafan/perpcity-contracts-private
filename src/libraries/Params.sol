// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

library Params {
    struct CreatePerpParams {
        address beacon;
        uint24 tradingFee;
        uint128 minMargin;
        uint128 maxMargin;
        uint128 minOpeningLeverageX96;
        uint128 maxOpeningLeverageX96;
        uint128 liquidationLeverageX96;
        uint128 liquidationFeeX96;
        uint128 liquidationFeeSplitX96;
        int128 fundingInterval;
        int24 tickSpacing;
        uint160 startingSqrtPriceX96;
    }

    struct OpenMakerPositionParams {
        uint128 margin;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
    }

    struct OpenTakerPositionParams {
        bool isLong;
        uint128 margin;
        uint256 leverageX96;
    }
}
