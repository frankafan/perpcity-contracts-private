// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {UnlockCallback} from "./UnlockCallback.sol";
import {IPerpManager} from "./interfaces/IPerpManager.sol";
import {LivePositionDetailsReverter} from "./libraries/LivePositionDetailsReverter.sol";
import {PerpLogic} from "./libraries/PerpLogic.sol";
import {TimeWeightedAvg} from "./libraries/TimeWeightedAvg.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// manages state for all perps and contains hooks for uniswap pools
contract PerpManager is IPerpManager, UnlockCallback {
    address public immutable USDC;

    mapping(PoolId => IPerpManager.Perp) public perps;

    constructor(IPoolManager poolManager, address usdc) UnlockCallback(poolManager) {
        USDC = usdc;
    }

    // ------------
    // PERP ACTIONS
    // ------------

    function createPerp(CreatePerpParams calldata params) external returns (PoolId perpId) {
        perpId = PerpLogic.createPerp(perps, POOL_MANAGER, USDC, params);
    }

    function openMakerPosition(
        PoolId perpId,
        OpenMakerPositionParams calldata params
    )
        external
        returns (uint128 makerPosId)
    {
        return PerpLogic.openPosition(perps[perpId], POOL_MANAGER, USDC, abi.encode(params), true);
    }

    function openTakerPosition(
        PoolId perpId,
        OpenTakerPositionParams calldata params
    )
        external
        returns (uint128 takerPosId)
    {
        return PerpLogic.openPosition(perps[perpId], POOL_MANAGER, USDC, abi.encode(params), false);
    }

    function addMargin(PoolId perpId, AddMarginParams calldata params) external {
        PerpLogic.addMargin(perps[perpId], POOL_MANAGER, USDC, params);
    }

    function closePosition(PoolId perpId, ClosePositionParams calldata params) external returns (uint128 posId) {
        return PerpLogic.closePosition(perps[perpId], POOL_MANAGER, USDC, params, false);
    }

    // // -------------
    // // TWAP ACTIONS
    // // -------------

    function increaseCardinalityNext(PoolId perpId, uint32 cardinalityNext) external {
        TimeWeightedAvg.grow(perps[perpId].twapState, cardinalityNext);
    }

    // // ----
    // // VIEW / READ
    // // ----

    function getTimeWeightedAvg(PoolId perpId, uint32 secondsAgo) public view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(POOL_MANAGER, perpId);
        return PerpLogic.getTimeWeightedAvg(perps[perpId], secondsAgo, sqrtPriceX96);
    }

    function getPosition(PoolId perpId, uint128 posId) external view returns (IPerpManager.Position memory) {
        return perps[perpId].positions[posId];
    }

    // isn't view since it calls a non-view function that reverts with live position details
    function livePositionDetails(
        PoolId perpId,
        uint128 posId
    )
        external
        returns (int256 pnl, int256 fundingPayment, int256 effectiveMargin, bool isLiquidatable, uint256 newPriceX96)
    {
        // params are minimized / maximized where possible to ensure no reverts
        ClosePositionParams memory params =
            ClosePositionParams({posId: posId, minAmt0Out: 0, minAmt1Out: 0, maxAmt1In: type(uint128).max});

        // pass revert == true into close so we can parse live position details from the reason
        try PerpLogic.closePosition(perps[perpId], POOL_MANAGER, USDC, params, true) {}
        catch (bytes memory reason) {
            (pnl, fundingPayment, effectiveMargin, isLiquidatable, newPriceX96) =
                LivePositionDetailsReverter.parseLivePositionDetails(reason);
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
    //                 maxNotionalSize += uint128(liquidity).fullMulDiv(sqrtPriceUpperX96 - sqrtPriceLowerX96, FixedPoint96.UINT_Q96);
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
    //                 maxNotionalSize += uint128(liquidity).fullMulDiv(sqrtPriceUpperX96 - sqrtPriceLowerX96, FixedPoint96.UINT_Q96);
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
