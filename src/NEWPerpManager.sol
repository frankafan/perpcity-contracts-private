// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IPerpManager} from "./interfaces/IPerpManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PerpLogic} from "./libraries/NEWPerpLogic.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// manages state for all perps and contains hooks for uniswap pools
contract PerpManager is IPerpManager {
    using PerpLogic for *;

    IPoolManager public immutable POOL_MANAGER;
    address public immutable USDC;
    uint256 public immutable CREATION_FEE_AMT;
    address public immutable CREATION_FEE_RECIPIENT;

    mapping(PoolId => IPerpManager.Perp) public perps;

    constructor(
        IPoolManager poolManager,
        address usdc,
        uint256 creationFee,
        address creationFeeRecipient
    ) {
        POOL_MANAGER = poolManager;
        USDC = usdc;
        CREATION_FEE_AMT = creationFee;
        CREATION_FEE_RECIPIENT = creationFeeRecipient;
    }

    // ------------
    // PERP ACTIONS
    // ------------

    function createPerp(CreatePerpParams calldata params) external returns (PoolId perpId) {
        perpId = perps.createPerp(POOL_MANAGER, USDC, params);
        // transfer creation fee from sender to creation fee recipient
        c.usdc.safeTransferFrom(msg.sender, CREATION_FEE_RECIPIENT, CREATION_FEE_AMT);
    }

    // function openMakerPosition(
    //     PoolId perpId,
    //     OpenMakerPositionParams calldata params
    // )
    //     external
    //     returns (uint128 makerPosId)
    // {
    //     return perps[perpId].openMakerPosition(c, params); // in MakerActions library
    // }

    // function addMakerMargin(PoolId perpId, AddMarginParams calldata params) external {
    //     perps[perpId].addMakerMargin(c, params); // in MakerActions library
    // }

    // function closeMakerPosition(PoolId perpId, ClosePositionParams calldata params) external {
    //     perps[perpId].closeMakerPosition(c, params, false, false); // in MakerActions library
    // }

    // function openTakerPosition(
    //     PoolId perpId,
    //     OpenTakerPositionParams calldata params
    // )
    //     external
    //     returns (uint128 takerPosId)
    // {
    //     return perps[perpId].openTakerPosition(c, params); // in TakerActions library
    // }

    // function addTakerMargin(PoolId perpId, AddMarginParams calldata params) external {
    //     perps[perpId].addTakerMargin(c, params); // in TakerActions library
    // }

    // function closeTakerPosition(PoolId perpId, ClosePositionParams calldata params) external {
    //     perps[perpId].closeTakerPosition(c, params, false, false); // in TakerActions library
    // }

    // // -------------
    // // TWAP ACTIONS
    // // -------------

    // function increaseCardinalityNext(PoolId perpId, uint32 cardinalityNext) external {
    //     perps[perpId].increaseCardinalityNext(cardinalityNext);
    // }

    // // ----
    // // VIEW / READ
    // // ----

    // function getTWAP(PoolId perpId) public view returns (uint256) {
    //     uint32 oldestObservationTimestamp = perps[perpId].twapState.observations.getOldestObservationTimestamp(
    //         perps[perpId].twapState.index, perps[perpId].twapState.cardinality
    //     );
    //     uint32 twapSecondsAgo = (block.timestamp - oldestObservationTimestamp).toUint32();
    //     uint32 twapWindow = perps[perpId].twapWindow;
    //     twapSecondsAgo = twapSecondsAgo > twapWindow ? twapWindow : twapSecondsAgo;

    //     (, int24 currentTick) = c.poolManager.getSqrtPriceX96AndTick(perpId);
    //     return perps[perpId].getTWAP(twapSecondsAgo, currentTick);
    // }

    // function getMakerPosition(PoolId perpId, uint128 makerPosId) external view returns (IPerpManager.MakerPos memory) {
    //     return perps[perpId].makerPositions[makerPosId];
    // }

    // function getTakerPosition(PoolId perpId, uint128 takerPosId) external view returns (IPerpManager.TakerPos memory) {
    //     return perps[perpId].takerPositions[takerPosId];
    // }

    // // isn't view since it calls a non-view function that reverts with live position details
    // function liveMakerDetails(
    //     PoolId perpId,
    //     uint128 makerPosId
    // )
    //     external
    //     returns (int256 pnl, int256 fundingPayment, int256 effectiveMargin, bool isLiquidatable, uint256 newPriceX96)
    // {
    //     // params are minimized / maximized where possible to ensure no reverts
    //     ClosePositionParams memory params = ClosePositionParams({
    //         posId: makerPosId,
    //         minAmt0Out: 0,
    //         minAmt1Out: 0,
    //         maxAmt1In: type(uint128).max,
    //         timeout: type(uint32).max
    //     });

    //     // pass revert == true into close so we can parse live position details from the reason
    //     try perps[perpId].closeMakerPosition(c, params, true, false) {}
    //     catch (bytes memory reason) {
    //         (pnl, fundingPayment, effectiveMargin, isLiquidatable, newPriceX96) = reason.parseLivePositionDetails();
    //     }
    // }

    // // isn't view since it calls a non-view function that reverts with live position details
    // function liveTakerDetails(
    //     PoolId perpId,
    //     uint128 takerPosId
    // )
    //     external
    //     returns (int256 pnl, int256 fundingPayment, int256 effectiveMargin, bool isLiquidatable, uint256 newPriceX96)
    // {
    //     // params are minimized / maximized where possible to ensure no reverts
    //     ClosePositionParams memory params = ClosePositionParams({
    //         posId: takerPosId,
    //         minAmt0Out: 0,
    //         minAmt1Out: 0,
    //         maxAmt1In: type(uint128).max,
    //         timeout: type(uint32).max
    //     });

    //     // pass revert == true into close so we can parse live position details from the reason
    //     try perps[perpId].closeTakerPosition(c, params, true, false) {}
    //     catch (bytes memory reason) {
    //         (pnl, fundingPayment, effectiveMargin, isLiquidatable, newPriceX96) = reason.parseLivePositionDetails();
    //     }
    // }

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

    // // -----
    // // HOOKS
    // // -----

    // function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    //     return Hooks.Permissions({
    //         beforeInitialize: false,
    //         afterInitialize: false,
    //         beforeAddLiquidity: true,
    //         afterAddLiquidity: true,
    //         beforeRemoveLiquidity: true,
    //         afterRemoveLiquidity: true,
    //         beforeSwap: true,
    //         afterSwap: true,
    //         beforeDonate: true,
    //         afterDonate: false,
    //         beforeSwapReturnDelta: true,
    //         afterSwapReturnDelta: false,
    //         afterAddLiquidityReturnDelta: false,
    //         afterRemoveLiquidityReturnDelta: false
    //     });
    // }

    // function _beforeAddLiquidity(
    //     address sender,
    //     PoolKey calldata key,
    //     ModifyLiquidityParams calldata params,
    //     bytes calldata // hookData
    // )
    //     internal
    //     override
    //     returns (bytes4)
    // {
    //     return perps[key.toId()].beforeAddLiquidity(c, sender, key, params);
    // }

    // function _afterAddLiquidity(
    //     address, // sender
    //     PoolKey calldata key,
    //     ModifyLiquidityParams calldata, // params
    //     BalanceDelta, // delta
    //     BalanceDelta, // feesAccrued
    //     bytes calldata // hookData
    // )
    //     internal
    //     override
    //     returns (bytes4, BalanceDelta)
    // {
    //     return perps[key.toId()].afterAddLiquidity(c, key);
    // }

    // function _beforeRemoveLiquidity(
    //     address, // sender
    //     PoolKey calldata key,
    //     ModifyLiquidityParams calldata, // params
    //     bytes calldata // hookData
    // )
    //     internal
    //     override
    //     returns (bytes4)
    // {
    //     return perps[key.toId()].beforeRemoveLiquidity(c, key);
    // }

    // function _afterRemoveLiquidity(
    //     address, // sender
    //     PoolKey calldata key,
    //     ModifyLiquidityParams calldata params,
    //     BalanceDelta, // delta
    //     BalanceDelta, // feesAccrued
    //     bytes calldata // hookData
    // )
    //     internal
    //     override
    //     returns (bytes4, BalanceDelta)
    // {
    //     return perps[key.toId()].afterRemoveLiquidity(c, key, params);
    // }

    // // only set non-zero fee if the swap is for opening a position
    // function _beforeSwap(
    //     address sender,
    //     PoolKey calldata key,
    //     SwapParams calldata params,
    //     bytes calldata hookData
    // )
    //     internal
    //     override
    //     returns (bytes4, BeforeSwapDelta, uint24)
    // {
    //     return perps[key.toId()].beforeSwap(c, sender, key, params, hookData);
    // }

    // function _afterSwap(
    //     address, // sender
    //     PoolKey calldata key,
    //     SwapParams calldata params,
    //     BalanceDelta, // delta
    //     bytes calldata // hookData
    // )
    //     internal
    //     override
    //     returns (bytes4, int128)
    // {
    //     return perps[key.toId()].afterSwap(c, key, params);
    // }

    // function _beforeDonate(
    //     address sender,
    //     PoolKey calldata, // key
    //     uint256, // amount0
    //     uint256, // amount1
    //     bytes calldata // hookData
    // )
    //     internal
    //     view
    //     override
    //     returns (bytes4)
    // {
    //     return Hook.beforeDonate(c, sender);
    // }
}
