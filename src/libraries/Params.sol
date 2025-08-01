// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

library Params {
    struct CreatePerpParams {
        address beacon;
        uint24 tradingFee;
        uint128 tradingFeeCreatorSplitX96;
        uint256 tradingFeeInsuranceSplitX96;
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
        uint128 maxAmount0In;
        uint128 maxAmount1In;
    }

    struct OpenTakerPositionParams {
        bool isLong;
        uint128 margin;
        uint256 leverageX96;
        uint128 minAmount0Out; // will be used if long, otherwise ignored
        uint128 maxAmount0In; // will be used if short, otherwise ignored
    }

    struct ClosePositionParams {
        uint256 posId; // maker or taker position id
        uint128 minAmount1Out; // will be used if long, otherwise ignored; used on excess position for makers
        uint128 maxAmount1In; // will be used if short, otherwise ignored; used on excess position for makers
    }
}
