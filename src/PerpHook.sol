// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IMsgSender } from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import { Tick } from "./libraries/Tick.sol";
import { Perp } from "./libraries/Perp.sol";
import { Positions } from "./libraries/Positions.sol";
import { ExternalContracts } from "./libraries/ExternalContracts.sol";
import { UniswapV4Utility } from "./libraries/UniswapV4Utility.sol";
import { LivePositionDetailsReverter } from "./libraries/LivePositionDetailsReverter.sol";
import { Params } from "./libraries/Params.sol";
import { FixedPoint96 } from "./libraries/FixedPoint96.sol";
import { TokenMath } from "./libraries/TokenMath.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PerpHook is BaseHook {
    using Perp for *;
    using Tick for mapping(int24 => Tick.GrowthInfo);
    using UniswapV4Utility for IPoolManager;
    using StateLibrary for IPoolManager;
    using LivePositionDetailsReverter for *;
    using TokenMath for uint256;
    using SafeERC20 for IERC20;

    ExternalContracts.Contracts public externalContracts;

    mapping(PoolId => Perp.Info) public perps;

    error InvalidPeriphery(address periphery, address expectedRouter, address expectedPositionManager);
    error InvalidCaller(address caller, address expectedCaller);

    modifier validateCaller(address hookSender) {
        if (hookSender != address(externalContracts.router) && hookSender != address(externalContracts.positionManager))
        {
            revert InvalidPeriphery(
                hookSender, address(externalContracts.router), address(externalContracts.positionManager)
            );
        }

        address msgSender = IMsgSender(hookSender).msgSender();
        if (msgSender != address(this)) revert InvalidCaller(msgSender, address(this));
        _;
    }

    constructor(ExternalContracts.Contracts memory _externalContracts) BaseHook(_externalContracts.poolManager) {
        externalContracts = _externalContracts;
    }

    // ------------
    // PERP ACTIONS
    // ------------

    function createPerp(Params.CreatePerpParams memory params) external returns (PoolId perpId) {
        return perps.createPerp(externalContracts, params);
    }

    function openMakerPosition(
        PoolId perpId,
        Params.OpenMakerPositionParams memory params
    )
        external
        returns (uint256 makerPosId)
    {
        return perps[perpId].openMakerPosition(externalContracts, perpId, params);
    }

    function closeMakerPosition(PoolId perpId, Params.ClosePositionParams memory params) external {
        perps[perpId].closeMakerPosition(externalContracts, perpId, params, false);
    }

    function openTakerPosition(
        PoolId perpId,
        Params.OpenTakerPositionParams memory params
    )
        external
        returns (uint256 takerPosId)
    {
        return perps[perpId].openTakerPosition(externalContracts, perpId, params);
    }

    function closeTakerPosition(PoolId perpId, Params.ClosePositionParams memory params) external {
        perps[perpId].closeTakerPosition(externalContracts, perpId, params, false);
    }

    // ----
    // VIEW / READ
    // ----

    function getMakerPosition(PoolId perpId, uint256 makerPosId) external view returns (Positions.MakerInfo memory) {
        return perps[perpId].makerPositions[makerPosId];
    }

    function getTakerPosition(PoolId perpId, uint256 takerPosId) external view returns (Positions.TakerInfo memory) {
        return perps[perpId].takerPositions[takerPosId];
    }

    // can't be view since it calls a non-view function that reverts with live position details
    // this is inefficient to call on-chain
    function liveMakerDetails(
        PoolId perpId,
        uint256 makerPosId
    )
        external
        returns (int256 pnl, int256 fundingPayment, int256 effectiveMargin, bool isLiquidatable)
    {
        Params.ClosePositionParams memory params =
            Params.ClosePositionParams({ posId: makerPosId, minAmount1Out: 0, maxAmount1In: Perp.UINT128_MAX });
        try perps[perpId].closeMakerPosition(externalContracts, perpId, params, true) { }
        catch (bytes memory reason) {
            (pnl, fundingPayment, effectiveMargin, isLiquidatable) = reason.parseLivePositionDetails();
        }
    }

    function liveTakerDetails(
        PoolId perpId,
        uint256 takerPosId
    )
        external
        returns (int256 pnl, int256 fundingPayment, int256 effectiveMargin, bool isLiquidatable)
    {
        Params.ClosePositionParams memory params =
            Params.ClosePositionParams({ posId: takerPosId, minAmount1Out: 0, maxAmount1In: Perp.UINT128_MAX });
        try perps[perpId].closeTakerPosition(externalContracts, perpId, params, true) { }
        catch (bytes memory reason) {
            (pnl, fundingPayment, effectiveMargin, isLiquidatable) = reason.parseLivePositionDetails();
        }
    }

    // -----
    // HOOKS
    // -----

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata // hookData
    )
        internal
        override
        validateCaller(sender)
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        bool isTickLowerInitializedBefore = poolManager.isTickInitialized(poolId, params.tickLower);
        bool isTickUpperInitializedBefore = poolManager.isTickInitialized(poolId, params.tickUpper);

        (uint160 sqrtPriceX96, int24 currentTick) = poolManager.getSqrtPriceX96AndTick(poolId);

        perps[poolId].updateTwPremiums(sqrtPriceX96);

        if (!isTickLowerInitializedBefore) {
            perps[poolId].tickGrowthInfo.initialize(
                params.tickLower, currentTick, perps[poolId].twPremiumX96, perps[poolId].twPremiumDivBySqrtPriceX96
            );
        }
        if (!isTickUpperInitializedBefore) {
            perps[poolId].tickGrowthInfo.initialize(
                params.tickUpper, currentTick, perps[poolId].twPremiumX96, perps[poolId].twPremiumDivBySqrtPriceX96
            );
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _afterAddLiquidity(
        address, // sender
        PoolKey calldata key,
        ModifyLiquidityParams calldata, // params
        BalanceDelta, // delta
        BalanceDelta, // feesAccrued
        bytes calldata // hookData
    )
        internal
        override
        returns (bytes4, BalanceDelta)
    {
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        perps[poolId].updatePremiumPerSecond(sqrtPriceX96);

        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata, // params
        bytes calldata // hookData
    )
        internal
        override
        validateCaller(sender)
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        perps[poolId].updateTwPremiums(sqrtPriceX96);

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address, // sender
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta, // delta
        BalanceDelta, // feesAccrued
        bytes calldata // hookData
    )
        internal
        override
        returns (bytes4, BalanceDelta)
    {
        PoolId poolId = key.toId();

        bool isTickLowerInitializedAfter = poolManager.isTickInitialized(poolId, params.tickLower);
        bool isTickUpperInitializedAfter = poolManager.isTickInitialized(poolId, params.tickUpper);

        if (!isTickLowerInitializedAfter) {
            perps[poolId].tickGrowthInfo.clear(params.tickLower);
        }
        if (!isTickUpperInitializedAfter) {
            perps[poolId].tickGrowthInfo.clear(params.tickUpper);
        }

        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // only set non-zero fee if the swap is for opening a position
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    )
        internal
        override
        validateCaller(sender)
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 startingTick) = poolManager.getSqrtPriceX96AndTick(poolId);

        perps[poolId].updateTwPremiums(sqrtPriceX96);

        assembly {
            tstore(poolId, startingTick)
        }

        uint24 fee = abi.decode(hookData, (uint24));
        if (fee == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 absAmountSpecified =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 feeAmount = FullMath.mulDiv(absAmountSpecified, fee, LPFeeLibrary.MAX_LP_FEE);

        uint256 creatorFeeAmount =
            FullMath.mulDiv(feeAmount, perps[poolId].tradingFeeCreatorSplitX96, FixedPoint96.UINT_Q96);
        poolManager.mint(address(this), key.currency1.toId(), creatorFeeAmount);
        externalContracts.usdc.safeTransferFrom(
            perps[poolId].vault, perps[poolId].creator, creatorFeeAmount.scale18To6()
        );

        uint256 lpFeeAmount = feeAmount - creatorFeeAmount;
        poolManager.donate(key, 0, lpFeeAmount, bytes(""));

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(SafeCast.toInt128(feeAmount), 0), 0);
    }

    function _afterSwap(
        address, // sender
        PoolKey calldata key,
        SwapParams calldata, // params
        BalanceDelta, // delta
        bytes calldata // hookData
    )
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

        int24 startingTick;
        assembly {
            startingTick := tload(poolId)
        }

        (uint160 sqrtPriceX96, int24 endingTick) = poolManager.getSqrtPriceX96AndTick(poolId);

        perps[poolId].updatePremiumPerSecond(sqrtPriceX96);

        perps[poolId].tickGrowthInfo.crossTicksInRange(
            poolManager,
            poolId,
            startingTick,
            endingTick,
            key.tickSpacing,
            perps[poolId].twPremiumX96,
            perps[poolId].twPremiumDivBySqrtPriceX96
        );

        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeDonate(
        address sender,
        PoolKey calldata, // key
        uint256, // amount0
        uint256, // amount1
        bytes calldata // hookData
    )
        internal
        view
        override
        validateCaller(sender)
        returns (bytes4)
    {
        return BaseHook.beforeDonate.selector;
    }
}
