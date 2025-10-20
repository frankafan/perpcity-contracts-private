// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Funding} from "../libraries/Funding.sol";
import {TimeWeightedAvg} from "../libraries/TimeWeightedAvg.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IFees} from "./modules/IFees.sol";
import {IMarginRatios} from "./modules/IMarginRatios.sol";
import {ILockupPeriod} from "./modules/ILockupPeriod.sol";
import {ISqrtPriceImpactLimit} from "./modules/ISqrtPriceImpactLimit.sol";

/// @title IPerpManager
/// @notice Interface for the PerpManager contract
/// TODO: add comments / fix for modularity
interface IPerpManager {
    /* STRUCTS */

    struct PerpConfig {
        PoolKey key;
        address creator;
        address vault;
        address beacon;
        IFees fees;
        IMarginRatios marginRatios;
        ILockupPeriod lockupPeriod;
        ISqrtPriceImpactLimit sqrtPriceImpactLimit;
    }

    struct PerpState {
        TimeWeightedAvg.State twAvgState;
        Funding.State fundingState;
        mapping(uint128 => Position) positions;
        uint128 nextPosId;
        uint128 badDebtGrowthX96;
        uint128 insurance;
        uint128 takerOpenInterest;
    }

    // min margin & tw avg window hardcoded

    struct Position {
        address holder;
        uint256 margin;
        int256 entryPerpDelta;
        int256 entryUsdDelta;
        int256 entryCumlFundingX96;
        uint128 entryBadDebtGrowthX96;
        uint24 liquidationMarginRatio;
        MakerDetails makerDetails;
    }

    struct MakerDetails {
        uint32 unlockTimestamp;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        int256 entryCumlFundingBelowX96;
        int256 entryCumlFundingWithinX96;
        int256 entryCumlFundingDivSqrtPWithinX96;
    }

    struct CreatePerpParams {
        address beacon;
        IFees fees;
        IMarginRatios marginRatios;
        ILockupPeriod lockupPeriod;
        ISqrtPriceImpactLimit sqrtPriceImpactLimit;
        uint160 startingSqrtPriceX96;
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
        uint256 amtToAdd;
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
        PoolId perpId, uint256 posId, Position position, uint256 sqrtPriceX96, int256 fundingPerSecX96
    );
    event MarginAdded(PoolId perpId, uint256 posId, uint256 newMargin);
    event PositionClosed(
        PoolId perpId,
        uint256 posId,
        Position position,
        int256 netUsdDelta,
        bool wasLiquidated,
        uint256 sqrtPriceX96,
        int256 fundingPerSecX96
    );
    event FeesModuleRegistered(IFees feesModule);
    event MarginRatiosModuleRegistered(IMarginRatios marginRatiosModule);
    event LockupPeriodModuleRegistered(ILockupPeriod lockupPeriodModule);
    event SqrtPriceImpactLimitModuleRegistered(ISqrtPriceImpactLimit sqrtPriceImpactLimitModule);

    /* ERRORS */

    error InvalidClose(address caller, address holder, bool isLiquidated);
    error InvalidLiquidity(uint128 liquidity);
    error InvalidMargin(uint256 margin);
    error InvalidCaller(address caller, address expectedCaller);
    error PositionLocked();
    error ZeroDeltaPosition();
    error InvalidMarginRatio(uint256 marginRatio, uint256 minMarginRatio, uint256 maxMarginRatio);
    error FeesNotRegistered();
    error MarginRatiosNotRegistered();
    error LockupPeriodNotRegistered();
    error SqrtPriceImpactLimitNotRegistered();
    error ModuleAlreadyRegistered();
}
