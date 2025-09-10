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
    using LivePositionDetailsReverter for bytes;
    using PerpLogic for *;
    using TimeWeightedAvg for TimeWeightedAvg.State;
    using StateLibrary for *;

    address public immutable USDC;

    mapping(PoolId => IPerpManager.Perp) public perps;

    constructor(IPoolManager poolManager, address usdc) UnlockCallback(poolManager) {
        USDC = usdc;
    }

    // ------------
    // PERP ACTIONS
    // ------------

    function createPerp(CreatePerpParams calldata params) external returns (PoolId perpId) {
        perpId = perps.createPerp(POOL_MANAGER, USDC, params);
    }

    function openMakerPosition(
        PoolId perpId,
        OpenMakerPositionParams calldata params
    )
        external
        returns (uint128 makerPosId)
    {
        return perps[perpId].openMakerPosition(POOL_MANAGER, USDC, params); // in MakerActions library
    }

    function addMakerMargin(PoolId perpId, AddMarginParams calldata params) external {
        perps[perpId].addMakerMargin(POOL_MANAGER, USDC, params); // in MakerActions library
    }

    function closeMakerPosition(
        PoolId perpId,
        ClosePositionParams calldata params
    )
        external
        returns (uint128 takerPosId)
    {
        return perps[perpId].closeMakerPosition(POOL_MANAGER, USDC, params, false); // in MakerActions library
    }

    function openTakerPosition(
        PoolId perpId,
        OpenTakerPositionParams calldata params
    )
        external
        returns (uint128 takerPosId)
    {
        return perps[perpId].openTakerPosition(POOL_MANAGER, USDC, params); // in TakerActions library
    }

    function addTakerMargin(PoolId perpId, AddMarginParams calldata params) external {
        perps[perpId].addTakerMargin(POOL_MANAGER, USDC, params); // in TakerActions library
    }

    function closeTakerPosition(PoolId perpId, ClosePositionParams calldata params) external {
        perps[perpId].closeTakerPosition(POOL_MANAGER, USDC, params, false); // in TakerActions library
    }

    // // -------------
    // // TWAP ACTIONS
    // // -------------

    function increaseCardinalityNext(PoolId perpId, uint32 cardinalityNext) external {
        perps[perpId].increaseCardinalityNext(cardinalityNext);
    }

    // // ----
    // // VIEW / READ
    // // ----

    function getTimeWeightedAvg(PoolId perpId, uint32 secondsAgo) public view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(perpId);
        return perps[perpId].getTimeWeightedAvg(secondsAgo, sqrtPriceX96);
    }

    function getMakerPosition(PoolId perpId, uint128 makerPosId) external view returns (IPerpManager.MakerPos memory) {
        return perps[perpId].makerPositions[makerPosId];
    }

    function getTakerPosition(PoolId perpId, uint128 takerPosId) external view returns (IPerpManager.TakerPos memory) {
        return perps[perpId].takerPositions[takerPosId];
    }

    // isn't view since it calls a non-view function that reverts with live position details
    function liveMakerDetails(
        PoolId perpId,
        uint128 makerPosId
    )
        external
        returns (int256 pnl, int256 fundingPayment, int256 effectiveMargin, bool isLiquidatable, uint256 newPriceX96)
    {
        // params are minimized / maximized where possible to ensure no reverts
        ClosePositionParams memory params =
            ClosePositionParams({posId: makerPosId, minAmt0Out: 0, minAmt1Out: 0, maxAmt1In: type(uint128).max});

        // pass revert == true into close so we can parse live position details from the reason
        try perps[perpId].closeMakerPosition(POOL_MANAGER, USDC, params, true) {}
        catch (bytes memory reason) {
            (pnl, fundingPayment, effectiveMargin, isLiquidatable, newPriceX96) = reason.parseLivePositionDetails();
        }
    }

    // isn't view since it calls a non-view function that reverts with live position details
    function liveTakerDetails(
        PoolId perpId,
        uint128 takerPosId
    )
        external
        returns (int256 pnl, int256 fundingPayment, int256 effectiveMargin, bool isLiquidatable, uint256 newPriceX96)
    {
        // params are minimized / maximized where possible to ensure no reverts
        ClosePositionParams memory params =
            ClosePositionParams({posId: takerPosId, minAmt0Out: 0, minAmt1Out: 0, maxAmt1In: type(uint128).max});

        // pass revert == true into close so we can parse live position details from the reason
        try perps[perpId].closeTakerPosition(POOL_MANAGER, USDC, params, true) {}
        catch (bytes memory reason) {
            (pnl, fundingPayment, effectiveMargin, isLiquidatable, newPriceX96) = reason.parseLivePositionDetails();
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
