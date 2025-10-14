// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Funding} from "../libraries/Funding.sol";
import {TimeWeightedAvg} from "../libraries/TimeWeightedAvg.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IPerpManager
/// @notice Interface for the PerpManager contract
/// TODO: add comments
interface IPerpManager {
    /* STRUCTS */

    /// @notice A struct containing data that defines a perp and it's state
    struct Perp {
        address vault;
        uint24 creatorFee;
        uint24 insuranceFee;
        uint24 liquidationFee;
        uint24 liquidatorFeeSplit;
        address beacon;
        uint24 minOpeningMargin;
        uint24 minMakerOpeningMarginRatio;
        uint24 maxMakerOpeningMarginRatio;
        uint24 makerLiquidationMarginRatio;
        address creator;
        uint24 minTakerOpeningMarginRatio;
        uint24 maxTakerOpeningMarginRatio;
        uint24 takerLiquidationMarginRatio;
        uint128 nextPosId;
        uint32 creationTimestamp;
        uint32 makerLockupPeriod;
        uint32 twapWindow;
        uint256 sqrtPriceLowerMultiX96;
        uint256 sqrtPriceUpperMultiX96;
        uint256 adlGrowth;
        uint128 insurance;
        uint128 takerOpenInterest;
        PoolKey key;
        TimeWeightedAvg.State twapState;
        Funding.State fundingState;
        mapping(uint128 => Position) positions;
    }

    struct Position {
        address holder;
        uint256 margin;
        int256 perpDelta;
        int256 usdDelta;
        int256 entryCumlFundingX96;
        uint256 entryADLGrowth;
        MakerDetails makerDetails;
    }

    struct MakerDetails {
        uint32 entryTimestamp;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        int256 entryCumlFundingBelowX96;
        int256 entryCumlFundingWithinX96;
        int256 entryCumlFundingDivSqrtPWithinX96;
    }

    struct CreatePerpParams {
        uint160 startingSqrtPriceX96;
        address beacon;
    }

    struct OpenMakerPositionParams {
        uint256 margin;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint128 maxAmt0In; // Maximum amount of token0 to send in
        uint128 maxAmt1In; // Maximum amount of token1 to send in
    }

    struct OpenTakerPositionParams {
        bool isLong;
        uint256 margin;
        uint256 levX96;
        uint128 unspecifiedAmountLimit; // min perps out if long; max perps in if short
    }

    struct AddMarginParams {
        uint128 posId;
        uint256 margin;
    }

    struct ClosePositionParams {
        uint128 posId;
        uint128 minAmt0Out; // Used for closing maker positions, otherwise ignored
        uint128 minAmt1Out; // Minimum usd to sell for if long, otherwise ignored
        uint128 maxAmt1In; // Maximum usd to buy for if short, otherwise ignored
    }

    /* EVENTS */

    event PerpCreated(PoolId perpId, address beacon, uint256 startingSqrtPriceX96, uint256 indexPriceX96);
    event PositionOpened(
        PoolId perpId,
        uint256 posId,
        address holder,
        bool isMaker,
        int256 perpDelta,
        uint256 sqrtPriceX96,
        int256 fundingPremiumPerSecX96
    );
    event MarginAdded(PoolId perpId, uint256 posId, uint256 newMargin);
    event PositionClosed(
        PoolId perpId,
        uint256 posId,
        address holder,
        bool wasMaker,
        int256 perpDelta,
        int256 pnl,
        bool wasLiquidated,
        uint256 sqrtPriceX96,
        int256 fundingPremiumPerSecX96
    );

    /* ERRORS */

    error InvalidClose(address caller, address holder, bool isLiquidated);
    error InvalidLiquidity(uint128 liquidity);
    error InvalidMargin(uint256 margin);
    error InvalidCaller(address caller, address expectedCaller);
    error MakerPositionLocked(uint256 currentTimestamp, uint256 lockupPeriodEnd);
    error ZeroSizePosition(int256 perpDelta, int256 usdDelta);
}
