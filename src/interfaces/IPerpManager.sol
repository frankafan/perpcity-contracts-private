// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Tick} from "../libraries/Tick.sol";
import {TimeWeightedAvg} from "../libraries/TimeWeightedAvg.sol";
import {TradingFee} from "../libraries/TradingFee.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IPerpManager {
    // TODO: reorder & fix comments
    struct Perp {
        address vault; // Address holding all usdc for the perp
        address beacon; // Address of the beacon contract that gives index price
        address creator; // Address of the creator of the perp that receives a portion of the trading fee
        uint32 creationTimestamp; // Timestamp of perp creation
        uint32 makerLockupPeriod; // Time makers must wait before closing their position
        uint32 twapWindow; // Duration over which the mark and index TWAPs are calculated
        uint32 lastTwPremiumsUpdate; // Timestamp of last twPremiumX96 & twPremiumDivBySqrtPriceX96 update
        uint24 creatorFee; // Creator’s share of the trading fee (e.g. 0.05 = 5%)
        uint24 insuranceFee; // Share of the trading fee that goes towards insurance (e.g. 0.05 = 5%)
        uint24 liquidationFee;
        uint24 liquidatorFeeSplit;
        uint128 nextPosId; // ID of the next position opened; starts at 1
        uint256 sqrtPriceLowerMultiX96; // Maximum allowed divergence between mark and mark twap (e.g. 0.05 = 5%)
        uint256 sqrtPriceUpperMultiX96; // Maximum allowed divergence between mark and mark twap (e.g. 0.05 = 5%)
        uint24 minOpeningMargin;
        uint24 minMakerOpeningMarginRatio;
        uint24 maxMakerOpeningMarginRatio;
        uint24 makerLiquidationMarginRatio;
        uint24 minTakerOpeningMarginRatio;
        uint24 maxTakerOpeningMarginRatio;
        uint24 takerLiquidationMarginRatio;
        int256 twPremiumX96; // Time-weighted cumulative funding premium (mark - index), scaled by Q96 & WAD
        int256 twPremiumDivBySqrtPriceX96; // Time-weighted cumulative (premium / sqrtPrice), scaled by Q96 & WAD
        int256 premiumPerSecondX96; // Current funding premium per second, scaled by Q96 and WAD
        PoolKey key; // Uniswap's poolKey for identifying a pool
        TradingFee.Config tradingFeeConfig; // Configuration for the trading fee curve
        TimeWeightedAvg.State twapState; // Helpers for computing mark twap
        mapping(uint128 => Position) positions; // All open maker positions
        mapping(int24 => Tick.GrowthInfo) tickGrowthInfo; // Growth info for each tick, used to help compute funding
    }

    struct Position {
        address holder; // Address of the maker or taker
        uint256 margin;
        int256 perpDelta;
        int256 usdDelta;
        int256 entryTwPremiumX96; // twPremiumX96 at the time of entry
        MakerDetails makerDetails;
    }

    struct MakerDetails {
        uint32 entryTimestamp; // Timestamp of when the position was opened
        int24 tickLower; // Lower tick of the position
        int24 tickUpper; // Upper tick of the position
        uint128 liquidity; // Liquidity in Uniswap liquidity units
        int256 entryTwPremiumGrowthInsideX96; // twPremiumGrowthInsideX96 at the time of entry
        int256 entryTwPremiumDivBySqrtPriceGrowthInsideX96; // twPremiumDivBySqrtPriceGrowthInsideX96 at time of entry
        int256 entryTwPremiumGrowthBelowX96; // twPremiumGrowthBelowX96 at the time of entry
    }

    struct CreatePerpParams {
        uint160 startingSqrtPriceX96; // Initial sqrt price for the perp's Uniswap pool
        address beacon; // Address of the beacon contract that gives index price
    }

    struct OpenMakerPositionParams {
        uint256 margin; // Margin in usdc (e.g. 100e6 = 100 usdc)
        uint128 liquidity; // Liquidity in Uniswap liquidity units
        int24 tickLower; // Lower tick of the maker's position
        int24 tickUpper; // Upper tick of the maker's position
        uint128 maxAmt0In; // Maximum amount of token0 to send in
        uint128 maxAmt1In; // Maximum amount of token1 to send in
    }

    struct OpenTakerPositionParams {
        bool isLong; // Whether the taker is long or short
        uint256 margin; // Margin in usdc (e.g. 100e6 = 100 usdc)
        uint256 levX96; // Leverage to open the position at
        uint128 unspecifiedAmountLimit; // min perps out if long; max perps in if short
    }

    struct AddMarginParams {
        uint128 posId; // ID of the maker or taker position
        uint256 margin; // Amount of usdc to add as margin (e.g. 100e6 = 100 usdc)
    }

    struct ClosePositionParams {
        uint128 posId; // ID of the maker or taker position
        uint128 minAmt0Out; // Used for closing maker positions, otherwise ignored
        uint128 minAmt1Out; // Minimum usd to sell for if long, otherwise ignored
        uint128 maxAmt1In; // Maximum usd to buy for if short, otherwise ignored
    }

    event PerpCreated(PoolId perpId, address beacon, uint256 startingSqrtPriceX96);
    event PositionOpened(PoolId perpId, uint256 posId, bool isMaker, uint256 margin, uint256 sqrtPriceX96);
    event MarginAdded(PoolId perpId, uint256 posId, uint256 newMargin);
    event PositionClosed(PoolId perpId, uint256 posId, bool wasLiquidated, uint256 sqrtPriceX96);

    error InvalidClose(address caller, address holder, bool isLiquidated);
    error InvalidLiquidity(uint128 liquidity);
    error InvalidMargin(uint256 margin);
    error InvalidCaller(address caller, address expectedCaller);
    error MakerPositionLocked(uint256 currentTimestamp, uint256 lockupPeriodEnd);
}
