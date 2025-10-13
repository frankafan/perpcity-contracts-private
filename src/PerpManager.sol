// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {UnlockCallback} from "./UnlockCallback.sol";
import {IPerpManager} from "./interfaces/IPerpManager.sol";
import {PerpLogic} from "./libraries/PerpLogic.sol";
import {QuoteReverter} from "./libraries/QuoteReverter.sol";
import {TimeWeightedAvg} from "./libraries/TimeWeightedAvg.sol";
import {TradingFee} from "./libraries/TradingFee.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

/// @title PerpManager
/// @notice Manages state for all perps
contract PerpManager is IPerpManager, UnlockCallback {
    /* IMMUTABLES */

    /// @notice The address of the USDC token
    address public immutable USDC;

    /* STORAGE */

    /// @notice Mapping to store state of all perps
    mapping(PoolId => IPerpManager.Perp) private perps;

    /* CONSTRUCTOR */

    /// @notice Instantiates the PerpManager
    /// @dev This inherits UnlockCallback so it can accept callbacks from Uniswap PoolManager
    /// @param poolManager The address of the pool manager
    /// @param usdc The address of the USDC token
    constructor(IPoolManager poolManager, address usdc) UnlockCallback(poolManager) {
        USDC = usdc;
    }

    /* FUNCTIONS */

    /// @notice Creates a new perp
    /// @param params The parameters for creating the perp
    /// @return perpId The ID of the new perp
    function createPerp(CreatePerpParams calldata params) external returns (PoolId perpId) {
        perpId = PerpLogic.createPerp(perps, POOL_MANAGER, USDC, params);
    }

    /// @notice Opens a maker position
    /// @param perpId The ID of the perp to open the position in
    /// @param params The parameters for opening the position
    /// @return makerPosId The ID of the new maker position
    function openMakerPosition(PoolId perpId, OpenMakerPositionParams calldata params)
        external
        returns (uint128 makerPosId)
    {
        (makerPosId,,,,) = PerpLogic.openPosition(perps[perpId], POOL_MANAGER, USDC, abi.encode(params), true, false);
    }

    /// @notice Opens a taker position
    /// @param perpId The ID of the perp to open the position in
    /// @param params The parameters for opening the position
    /// @return takerPosId The ID of the new taker position
    function openTakerPosition(PoolId perpId, OpenTakerPositionParams calldata params)
        external
        returns (uint128 takerPosId)
    {
        (takerPosId,,,,) = PerpLogic.openPosition(perps[perpId], POOL_MANAGER, USDC, abi.encode(params), false, false);
    }

    /// @notice Adds margin to an open position
    /// @param perpId The ID of the perp to add margin to
    /// @param params The parameters for adding margin
    function addMargin(PoolId perpId, AddMarginParams calldata params) external {
        PerpLogic.addMargin(perps[perpId], POOL_MANAGER, USDC, params);
    }

    /// @notice Closes an open position
    /// @param perpId The ID of the perp to close the position in
    /// @param params The parameters for closing the position
    /// @return posId The ID of the taker position created if the position closed was a maker. Otherwise, 0
    function closePosition(PoolId perpId, ClosePositionParams calldata params) external returns (uint128 posId) {
        return PerpLogic.closePosition(perps[perpId], POOL_MANAGER, USDC, params, false);
    }

    /// @notice Increases the cardinality cap for a perp
    /// @param perpId The ID of the perp to increase the cardinality cap for
    /// @param cardinalityCap The new cardinality cap
    function increaseCardinalityCap(PoolId perpId, uint16 cardinalityCap) external {
        TimeWeightedAvg.increaseCardinalityCap(perps[perpId].twapState, cardinalityCap);
    }

    /* VIEW FUNCTIONS */
    /// TODO: remove as many read functions as possible. Ideally, we can remove quoter and integrate logic into base fns
    ///       comment functions that must remain

    function tickSpacing(PoolId perpId) external view returns (int24) {
        return perps[perpId].key.tickSpacing;
    }

    function sqrtPriceX96(PoolId perpId) external view returns (uint160 sqrtPrice) {
        (sqrtPrice,,,) = StateLibrary.getSlot0(POOL_MANAGER, perpId);
    }

    function fees(PoolId perpId)
        external
        view
        returns (uint24 creatorFee, uint24 insurnaceFee, uint24 lpFee, uint24 liquidationFee)
    {
        creatorFee = perps[perpId].creatorFee;
        insurnaceFee = perps[perpId].insuranceFee;
        lpFee = TradingFee.calculateTradingFee(perps[perpId], POOL_MANAGER);
        liquidationFee = perps[perpId].liquidationFee;
    }

    function tradingBounds(PoolId perpId)
        external
        view
        returns (
            uint24 minOpeningMargin,
            uint24 minMakerMarginRatio,
            uint24 maxMakerMarginRatio,
            uint24 makerLiquidationMarginRatio,
            uint24 minTakerMarginRatio,
            uint24 maxTakerMarginRatio,
            uint24 takerLiquidationMarginRatio
        )
    {
        minOpeningMargin = perps[perpId].minOpeningMargin;
        minMakerMarginRatio = perps[perpId].minMakerOpeningMarginRatio;
        maxMakerMarginRatio = perps[perpId].maxMakerOpeningMarginRatio;
        makerLiquidationMarginRatio = perps[perpId].makerLiquidationMarginRatio;
        minTakerMarginRatio = perps[perpId].minTakerOpeningMarginRatio;
        maxTakerMarginRatio = perps[perpId].maxTakerOpeningMarginRatio;
        takerLiquidationMarginRatio = perps[perpId].takerLiquidationMarginRatio;
    }

    function estimateLiquidityForAmount1(int24 tickA, int24 tickB, uint256 amount1)
        external
        pure
        returns (uint128 liquidity)
    {
        return LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickA), TickMath.getSqrtPriceAtTick(tickB), amount1
        );
    }

    function timeWeightedAvgSqrtPriceX96(PoolId perpId, uint32 lookbackWindow) external view returns (uint256) {
        (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(POOL_MANAGER, perpId);
        return TimeWeightedAvg.timeWeightedAvg(
            perps[perpId].twapState, lookbackWindow, SafeCastLib.toUint32(block.timestamp), sqrtPrice
        );
    }

    function getPosition(PoolId perpId, uint128 posId) external view returns (IPerpManager.Position memory) {
        return perps[perpId].positions[posId];
    }

    function quoteOpenMakerPosition(PoolId perpId, OpenMakerPositionParams calldata params)
        external
        returns (bool success, QuoteReverter.OpenQuote memory quote)
    {
        // pass revert == true into close so we can parse live position details from the reason
        try PerpLogic.openPosition(perps[perpId], POOL_MANAGER, USDC, abi.encode(params), true, true) {}
        catch (bytes memory reason) {
            (success, quote) = QuoteReverter.parseOpenQuote(reason);
        }
    }

    function quoteOpenTakerPosition(PoolId perpId, OpenTakerPositionParams calldata params)
        external
        returns (bool success, QuoteReverter.OpenQuote memory quote)
    {
        // pass revert == true into close so we can parse live position details from the reason
        try PerpLogic.openPosition(perps[perpId], POOL_MANAGER, USDC, abi.encode(params), false, true) {}
        catch (bytes memory reason) {
            (success, quote) = QuoteReverter.parseOpenQuote(reason);
        }
    }

    function quoteClosePosition(PoolId perpId, uint128 posId)
        external
        returns (bool success, QuoteReverter.CloseQuote memory quote)
    {
        // params are minimized / maximized where possible to ensure no reverts
        ClosePositionParams memory params = ClosePositionParams(posId, 0, 0, type(uint128).max);

        // pass revert == true into close so we can parse live position details from the reason
        try PerpLogic.closePosition(perps[perpId], POOL_MANAGER, USDC, params, true) {}
        catch (bytes memory reason) {
            (success, quote) = QuoteReverter.parseCloseQuote(reason);
        }
    }

    // // returns max notional size scaled by WAD
    // function maxNotionalTakerSize(PoolId perpId, bool isLong) external view returns (uint256 maxNotionalSize) {
    //     (,int24 currentTick) = c.poolManager.getSqrtPriceX96AndTick(perpId);

    //     // get mark twap, and calculate price band around it
    //     uint256 markTwapX96 = getTWAP(perpId);

    //     int24 tickBound;
    //     if (isLong) {
    //         uint256 priceImpactMultiplierX96 = FixedPoint96.UINT_Q96 + perps[perpId].priceImpactBandX96;
    //         uint256 priceBoundX96 = markTwapX96.fullMulDiv(priceImpactMultiplierX96, FixedPoint96.UINT_Q96);
    //         uint256 sqrtPriceBoundX96 = FixedPointMathLib.mulSqrt(priceBoundX96, FixedPoint96.UINT_Q96);
    //         if (sqrtPriceBoundX96 > TickMath.MAX_SQRT_PRICE) {
    //             tickBound = TickMath.MAX_TICK;
    //         } else if (sqrtPriceBoundX96 < TickMath.MIN_SQRT_PRICE) {
    //             tickBound = TickMath.MIN_TICK;
    //         } else {
    //             tickBound = TickMath.getTickAtSqrtPrice(sqrtPriceBoundX96.toUint160());
    //         }
    //     } else {
    //         uint256 priceImpactMultiplierX96 = FixedPoint96.UINT_Q96 - perps[perpId].priceImpactBandX96;
    //         uint256 priceBoundX96 = markTwapX96.fullMulDiv(priceImpactMultiplierX96, FixedPoint96.UINT_Q96);
    //         uint256 sqrtPriceBoundX96 = FixedPointMathLib.mulSqrt(priceBoundX96, FixedPoint96.UINT_Q96);
    //         if (sqrtPriceBoundX96 < TickMath.MIN_SQRT_PRICE) {
    //             tickBound = TickMath.MIN_TICK;
    //         } else if (sqrtPriceBoundX96 > TickMath.MAX_SQRT_PRICE) {
    //             tickBound = TickMath.MAX_TICK;
    //         } else {
    //             tickBound = TickMath.getTickAtSqrtPrice(sqrtPriceBoundX96.toUint160());
    //         }
    //     }

    //     int24 tickSpacing = perps[perpId].key.tickSpacing;
    //     int128 liquidity = int128(c.poolManager.getLiquidity(perpId));

    //     int24 tickUpper = currentTick;
    //     bool isInitialized;
    //     if (isLong) {
    //         while (tickUpper < tickBound) {
    //             (tickUpper, isInitialized) =
    //                 c.poolManager.nextInitializedTickWithinOneWord(perpId, tickUpper, tickSpacing, false);

    //             if (isInitialized || tickUpper > tickBound) {
    //                 if (tickUpper > tickBound) tickUpper = tickBound;
    //                 uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(currentTick);
    //                 uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
    //                 maxNotionalSize += uint128(liquidity).fullMulDiv(sqrtPriceUpperX96 - sqrtPriceLowerX96,
    //                        FixedPoint96.UINT_Q96);
    //                 (,int128 liquidityToAdd) = c.poolManager.getTickLiquidity(perpId, tickUpper);
    //                 liquidity += liquidityToAdd;
    //                 currentTick = tickUpper;
    //             }

    //             // stop if we pass the ending tick
    //         }
    //     } else {
    //         while (tickUpper > tickBound) {
    //             (tickUpper, isInitialized) =
    //                 c.poolManager.nextInitializedTickWithinOneWord(perpId, tickUpper, tickSpacing, true);

    //             if (isInitialized || tickUpper < tickBound) {
    //                 if (tickUpper < tickBound) tickUpper = tickBound;
    //                 uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickUpper);
    //                 uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(currentTick);
    //                 maxNotionalSize += uint128(liquidity).fullMulDiv(sqrtPriceUpperX96 - sqrtPriceLowerX96,
    //                        FixedPoint96.UINT_Q96);
    //                 (,int128 liquidityToAdd) = c.poolManager.getTickLiquidity(perpId, tickUpper);
    //                 liquidity -= liquidityToAdd;
    //                 currentTick = tickUpper;
    //             }
    //             tickUpper--;

    //             // stop if we pass the ending tick
    //         }
    //     }
    // }
}
