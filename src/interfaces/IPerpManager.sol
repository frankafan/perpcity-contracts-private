// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {Tick} from "../libraries/Tick.sol";
import {TickTWAP} from "../libraries/TickTWAP.sol";

import {TradingFee} from "../libraries/TradingFee.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

interface IPerpManager {
    struct Perp {
        address vault; // Address holding all usdc for the perp
        uint32 creationTimestamp; // Timestamp of perp creation
        uint32 makerLockupPeriod; // Time makers must wait before closing their position
        address beacon; // Address of the beacon contract that gives index price
        uint32 fundingInterval; // Amount of time it takes to experience 1 premium worth of funding per position size
        uint32 twapWindow; // Duration over which the mark and index TWAPs are calculated
        uint32 lastTwPremiumsUpdate; // Timestamp of last twPremiumX96 & twPremiumDivBySqrtPriceX96 update
        address creator; // Address of the creator of the perp that receives a portion of the trading fee
        uint128 tradingFeeCreatorSplitX96; // Creator’s share of the trading fee (e.g. 0.05 = 5%)
        uint128 tradingFeeInsuranceSplitX96; // Share of the trading fee that goes towards insurance (e.g. 0.05 = 5%)
        int256 twPremiumX96; // Time-weighted cumulative funding premium (mark - index), scaled by Q96 & WAD
        int256 twPremiumDivBySqrtPriceX96; // Time-weighted cumulative (premium / sqrtPrice), scaled by Q96 & WAD
        int256 premiumPerSecondX96; // Current funding premium per second, scaled by Q96 and WAD
        uint128 nextMakerPosId; // ID of the next maker position opened; starts at 1
        uint128 nextTakerPosId; // ID of the next taker position opened; starts at 1
        uint128 priceImpactBandX96; // Maximum allowed divergence between mark and mark twap (e.g. 0.05 = 5%)
        uint128 maxOpeningLevX96; // Maximum leverage allowed when opening any position
        uint128 liquidationLevX96; // Leverage at which a position is considered liquidatable
        uint128 liquidationFeeX96; // Fee charged in usdc when a position is liquidated (e.g. 0.05 = 5%)
        uint128 liquidatorFeeSplitX96; // Share of liquidation fee that goes towards the liquidator (e.g. 0.05 = 5%)
        PoolKey key; // Uniswap's poolKey for identifying a pool
        TradingFee.Config tradingFeeConfig; // Configuration for the trading fee curve
        TickTWAP.State twapState; // Helpers for computing mark twap
        mapping(uint128 => MakerPos) makerPositions; // All open maker positions
        mapping(uint128 => TakerPos) takerPositions; // All open taker positions
        mapping(int24 => Tick.GrowthInfo) tickGrowthInfo; // Growth info for each tick, used to help compute funding
    }

    struct MakerPos {
        uint256 uniswapLiqPosTokenId; // ID of the token representing the liquidity position in the uniswap pool
        address holder; // Address of the maker
        uint32 entryTimestamp; // Timestamp of when the maker opened their position
        int24 tickLower; // Lower tick of the maker's position
        int24 tickUpper; // Upper tick of the maker's position
        uint128 margin; // Margin in usdc (e.g. 100e6 = 100 usdc)
        uint128 liquidity; // Liquidity in Uniswap liquidity units
        uint128 perpsBorrowed; // Amount of perp accounting tokens borrowed as liquidity in WAD (e.g. 2e18 = 2 perps)
        uint128 usdBorrowed; // Amount of usd accounting tokens borrowed as liquidity in WAD (e.g. 100e10 = 100 usd)
        int256 entryTwPremiumX96; // twPremiumX96 at the time of entry
        int256 entryTwPremiumGrowthInsideX96; // twPremiumGrowthInsideX96 at the time of entry
        int256 entryTwPremiumDivBySqrtPriceGrowthInsideX96; // twPremiumDivBySqrtPriceGrowthInsideX96 at time of entry
        int256 entryTwPremiumGrowthBelowX96; // twPremiumGrowthBelowX96 at the time of entry
    }

    struct TakerPos {
        address holder; // Address of the taker
        bool isLong; // Whether the taker is long or short
        uint128 size; // Size of the taker's position in WAD (e.g. 1e18 = 1 perp contracts)
        uint128 margin; // Margin in usdc (e.g. 100e6 = 100 usdc)
        uint128 entryValue; // Usd value of the taker's position at the time of entry in WAD (e.g. 100e18 = 100 usd)
        int256 entryTwPremiumX96; // twPremiumX96 at the time of entry
    }

    struct CreatePerpParams {
        uint160 startingSqrtPriceX96; // Initial sqrt price for the perp's Uniswap pool
        uint32 initialCardinalityNext; // Initial number of observations that can be stored for computing mark twap
        uint32 makerLockupPeriod; // Time makers must wait before closing their position
        uint32 fundingInterval; // Amount of time it takes to experience 1 premium worth of funding per position size
        address beacon; // Address of the beacon contract that gives index price
        int24 tickSpacing; // Tick spacing for the perp's Uniswap pool
        uint32 twapWindow; // Duration over which the mark and index TWAPs are calculated
        uint128 tradingFeeCreatorSplitX96; // Creator’s share of the trading fee (e.g. 0.05 = 5%)
        uint128 tradingFeeInsuranceSplitX96; // Share of the trading fee that goes towards insurance (e.g. 0.05 = 5%)
        uint128 priceImpactBandX96; // Maximum allowed divergence between mark and mark twap (e.g. 0.05 = 5%)
        uint128 maxOpeningLevX96; // Maximum leverage allowed when opening any position
        uint128 liquidationLevX96; // Leverage at which a position is considered liquidatable
        uint128 liquidationFeeX96; // Fee charged in usdc when a position is liquidated (e.g. 0.05 = 5%)
        uint128 liquidatorFeeSplitX96; // Share of liquidation fee that goes towards the liquidator (e.g. 0.05 = 5%)
        TradingFee.Config tradingFeeConfig; // Configuration for the trading fee curve
    }

    struct OpenMakerPositionParams {
        uint128 margin; // Margin in usdc (e.g. 100e6 = 100 usdc)
        uint128 liquidity; // Liquidity in Uniswap liquidity units
        int24 tickLower; // Lower tick of the maker's position
        int24 tickUpper; // Upper tick of the maker's position
        uint128 maxAmt0In; // Maximum amount of token0 to send in
        uint128 maxAmt1In; // Maximum amount of token1 to send in
        uint32 timeout; // Amount of time after which execution will revert
    }

    struct OpenTakerPositionParams {
        bool isLong; // Whether the taker is long or short
        uint128 margin; // Margin in usdc (e.g. 100e6 = 100 usdc)
        uint128 levX96; // Leverage to open the position at
        uint128 minAmt0Out; // Minimum amount of perp contracts to receive if long, otherwise ignored
        uint128 maxAmt0In; // Maximum amount of perp contracts to borrow and sell if short, otherwise ignored
        uint32 timeout; // Amount of time after which execution will revert
    }

    struct AddMarginParams {
        uint128 posId; // ID of the maker or taker position
        uint128 margin; // Amount of usdc to add as margin (e.g. 100e6 = 100 usdc)
    }

    struct ClosePositionParams {
        uint128 posId; // ID of the maker or taker position
        uint128 minAmt0Out; // Used for closing maker positions, otherwise ignored
        uint128 minAmt1Out; // Minimum usd to sell for if long, otherwise ignored
        uint128 maxAmt1In; // Maximum usd to buy for if short, otherwise ignored
        uint32 timeout; // Amount of time after which execution will revert
    }

    event PerpCreated(PoolId perpId, address beacon, uint256 startingSqrtPriceX96);
    event MakerPositionOpened(PoolId perpId, uint256 makerPosId, MakerPos makerPos, uint256 sqrtPriceX96);
    event MakerMarginAdded(PoolId perpId, uint256 makerPosId, uint128 amount);
    event MakerPositionClosed(
        PoolId perpId, uint256 makerPosId, bool wasLiquidated, MakerPos makerPos, uint256 sqrtPriceX96
    );
    event TakerPositionOpened(PoolId perpId, uint256 takerPosId, TakerPos takerPos, uint256 sqrtPriceX96);
    event TakerMarginAdded(PoolId perpId, uint256 takerPosId, uint128 amount);
    event TakerPositionClosed(
        PoolId perpId, uint256 takerPosId, bool wasLiquidated, TakerPos takerPos, uint256 sqrtPriceX96
    );
    event MarketKilled(PoolId perpId);

    error InvalidBeaconAddress(address beacon);
    error InvalidTradingFeeSplits(uint256 tradingFeeInsuranceSplitX96, uint256 tradingFeeCreatorSplitX96);
    error InvalidMaxOpeningLev(uint128 maxOpeningLevX96);
    error InvalidLiquidationLev(uint128 liquidationLevX96, uint128 maxOpeningLevX96);
    error InvalidLiquidationFee(uint128 liquidationFeeX96);
    error InvalidLiquidatorFeeSplit(uint128 liquidatorFeeSplitX96);
    error InvalidClose(address caller, address holder, bool isLiquidated);
    error InvalidLiquidity(uint128 liquidity);
    error InvalidMargin(uint128 margin);
    error InvalidLevX96(uint256 levX96, uint128 maxOpeningLevX96);
    error InvalidCaller(address caller, address expectedCaller);
    error MakerPositionLocked(uint256 currentTimestamp, uint256 lockupPeriodEnd);
    error InvalidPeriphery(address periphery, address expectedRouter, address expectedPositionManager);
    error PriceImpactTooHigh(uint256 priceX96, uint256 minPriceX96, uint256 maxPriceX96);
    error InvalidFundingInterval(uint32 fundingInterval);
    error InvalidPriceImpactBand(uint128 priceImpactBandX96);
    error InvalidTickRange(int24 tickLower, int24 tickUpper);
    error InvalidTradingFeeConfig(TradingFee.Config tradingFeeConfig);
    error InvalidStartingSqrtPriceX96(uint160 startingSqrtPriceX96);
}
