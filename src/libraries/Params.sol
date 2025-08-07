// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Bounds } from "./Bounds.sol";
import { Fees } from "./Fees.sol";

library Params {
    struct CreatePerpParams {
        address beacon;
        Fees.FeeInfo fees;
        Bounds.MarginBounds marginBounds;
        Bounds.LeverageBounds leverageBounds;
        int128 fundingInterval;
        int24 tickSpacing;
        uint160 startingSqrtPriceX96;
        uint32 initialCardinalityNext;
        uint32 twapWindow;
        uint256 priceImpactBandX96;
        uint256 makerLockupPeriod;
    }

    struct OpenMakerPositionParams {
        uint128 margin;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint128 maxAmount0In;
        uint128 maxAmount1In;
        uint256 expiryWindow;
    }

    struct OpenTakerPositionParams {
        bool isLong;
        uint128 margin;
        uint256 leverageX96;
        uint128 minAmount0Out; // will be used if long, otherwise ignored
        uint128 maxAmount0In; // will be used if short, otherwise ignored
        uint256 expiryWindow;
    }

    struct AddMarginParams {
        uint256 posId; // maker or taker position id
        uint128 amount;
    }

    struct ClosePositionParams {
        uint256 posId; // maker or taker position id
        uint128 minAmount1Out; // will be used if long, otherwise ignored; used on excess position for makers
        uint128 maxAmount1In; // will be used if short, otherwise ignored; used on excess position for makers
        uint256 expiryWindow;
    }
}
