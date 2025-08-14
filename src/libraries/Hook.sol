// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IPerpManager} from "../interfaces/IPerpManager.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {PerpLogic} from "./PerpLogic.sol";
import {Tick} from "./Tick.sol";
import {TickTWAP} from "./TickTWAP.sol";
import {TokenMath} from "./TokenMath.sol";

import {MAX_CARDINALITY} from "../utils/Constants.sol";
import {TradingFee} from "./TradingFee.sol";
import {UniswapV4Utility} from "./UniswapV4Utility.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

library Hook {
    using PerpLogic for *;
    using Tick for mapping(int24 => Tick.GrowthInfo);
    using UniswapV4Utility for IPoolManager;
    using StateLibrary for IPoolManager;
    using TokenMath for uint256;
    using SafeTransferLib for address;
    using SafeCastLib for *;
    using TickTWAP for TickTWAP.Observation[MAX_CARDINALITY];
    using FixedPointMathLib for *;
    using TradingFee for IPerpManager.Perp;

    modifier validateCaller(IPerpManager.ExternalContracts storage c, address hookSender) {
        // ensures sender hook param is either the router or position manager
        if (hookSender != address(c.router) && hookSender != address(c.posm)) {
            revert IPerpManager.InvalidPeriphery(hookSender, address(c.router), address(c.posm));
        }

        // ensures original caller of action is the hook (perp manager)
        address msgSender = IMsgSender(hookSender).msgSender();
        if (msgSender != address(this)) revert IPerpManager.InvalidCaller(msgSender, address(this));
        _;
    }

    function beforeAddLiquidity(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts storage c,
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params
    )
        internal
        validateCaller(c, sender)
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96, int24 currentTick) = c.poolManager.getSqrtPriceX96AndTick(poolId);
        perp.updateTwPremiums(sqrtPriceX96);

        bool isTickLowerInitializedBefore = c.poolManager.isTickInitialized(poolId, params.tickLower);
        bool isTickUpperInitializedBefore = c.poolManager.isTickInitialized(poolId, params.tickUpper);

        // update tick mapping to mimick intialized ticks in uniswap pool
        if (!isTickLowerInitializedBefore) {
            perp.tickGrowthInfo.initialize(
                params.tickLower, currentTick, perp.twPremiumX96, perp.twPremiumDivBySqrtPriceX96
            );
        }
        if (!isTickUpperInitializedBefore) {
            perp.tickGrowthInfo.initialize(
                params.tickUpper, currentTick, perp.twPremiumX96, perp.twPremiumDivBySqrtPriceX96
            );
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts storage c,
        PoolKey calldata key
    )
        internal
        returns (bytes4, BalanceDelta)
    {
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96, int24 currentTick) = c.poolManager.getSqrtPriceX96AndTick(poolId);

        // update funding accounting
        perp.updatePremiumPerSecond(sqrtPriceX96);

        // update mark twap
        (perp.twapState.index, perp.twapState.cardinality) = perp.twapState.observations.write(
            perp.twapState.index,
            block.timestamp.toUint32(),
            currentTick,
            perp.twapState.cardinality,
            perp.twapState.cardinalityNext
        );

        // update liquidity-based fee component
        perp.updateBaseFeeX96(c);

        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts storage c,
        PoolKey calldata key
    )
        internal
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = c.poolManager.getSlot0(poolId);
        perp.updateTwPremiums(sqrtPriceX96);

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts storage c,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params
    )
        internal
        returns (bytes4, BalanceDelta)
    {
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96, int24 currentTick) = c.poolManager.getSqrtPriceX96AndTick(poolId);

        // update funding accounting
        perp.updatePremiumPerSecond(sqrtPriceX96);

        // update mark twap
        (perp.twapState.index, perp.twapState.cardinality) = perp.twapState.observations.write(
            perp.twapState.index,
            block.timestamp.toUint32(),
            currentTick,
            perp.twapState.cardinality,
            perp.twapState.cardinalityNext
        );

        // update liquidity-based fee component
        perp.updateBaseFeeX96(c);

        bool isTickLowerInitializedAfter = c.poolManager.isTickInitialized(poolId, params.tickLower);
        bool isTickUpperInitializedAfter = c.poolManager.isTickInitialized(poolId, params.tickUpper);

        // clear tick mapping to mimick uniswap pool ticks cleared
        if (!isTickLowerInitializedAfter) perp.tickGrowthInfo.clear(params.tickLower);
        if (!isTickUpperInitializedAfter) perp.tickGrowthInfo.clear(params.tickUpper);

        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // only set non-zero fee if the swap is for opening a position
    function beforeSwap(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts storage c,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    )
        internal
        validateCaller(c, sender)
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96, int24 startingTick) = c.poolManager.getSqrtPriceX96AndTick(poolId);
        perp.updateTwPremiums(sqrtPriceX96);

        // used in afterSwap to iterate over crossed ticks
        assembly {
            tstore(poolId, startingTick)
        }

        // determine whether or not to charge fee based on hookData passed in
        bool chargeFee = abi.decode(hookData, (bool));
        if (!chargeFee) return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // if charging a fee, calculate the fee amount
        uint256 tradingFeeX96 = perp.calculateTradingFeeX96(c);
        uint256 feeAmount = params.amountSpecified.abs().mulDiv(tradingFeeX96, FixedPoint96.UINT_Q96);

        // use market splits to determine how much of fee goes to each party
        uint256 creatorFeeAmount = feeAmount.mulDiv(perp.tradingFeeCreatorSplitX96, FixedPoint96.UINT_Q96);
        uint256 insuranceFeeAmount = feeAmount.mulDiv(perp.tradingFeeInsuranceSplitX96, FixedPoint96.UINT_Q96);
        uint256 lpFeeAmount = feeAmount - creatorFeeAmount - insuranceFeeAmount;

        // take usd accounting tokens from pool
        // send same amount of usdc to creator's address
        c.poolManager.mint(address(this), key.currency1.toId(), creatorFeeAmount);
        c.usdc.safeTransferFrom(perp.vault, perp.creator, creatorFeeAmount.scale18To6());

        // take usd accounting tokens from pool
        // the vault will keep this amount of usdc instead of it being used for LP fees
        c.poolManager.mint(address(this), key.currency1.toId(), insuranceFeeAmount);

        // send the remainder accounting tokens to liquidity positions
        // they can claim this amount in usdc when they remove liquidity
        c.poolManager.donate(key, 0, lpFeeAmount, bytes(""));

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(feeAmount.toInt128(), 0), 0);
    }

    function afterSwap(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts storage c,
        PoolKey calldata key,
        SwapParams calldata params
    )
        internal
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96, int24 endingTick) = c.poolManager.getSqrtPriceX96AndTick(poolId);
        perp.updatePremiumPerSecond(sqrtPriceX96);

        int24 startingTick;
        assembly {
            startingTick := tload(poolId)
        }

        int24 currentTick = startingTick;
        bool isInitialized;
        bool zeroForOne = params.zeroForOne;

        // iterate over crossed ticks, and cross them in our tick mapping to mimick uniswap pool's ticks
        do {
            (currentTick, isInitialized) =
                c.poolManager.nextInitializedTickWithinOneWord(poolId, currentTick, key.tickSpacing, zeroForOne);

            if (isInitialized) {
                perp.tickGrowthInfo.cross(currentTick, perp.twPremiumX96, perp.twPremiumDivBySqrtPriceX96);
            }
            // stop if we pass the ending tick
        } while (zeroForOne ? (currentTick > endingTick) : (currentTick < endingTick));

        // update mark twap
        (perp.twapState.index, perp.twapState.cardinality) = perp.twapState.observations.write(
            perp.twapState.index,
            block.timestamp.toUint32(),
            endingTick,
            perp.twapState.cardinality,
            perp.twapState.cardinalityNext
        );

        return (BaseHook.afterSwap.selector, 0);
    }

    function beforeDonate(
        IPerpManager.ExternalContracts storage c,
        address sender
    )
        internal
        view
        validateCaller(c, sender)
        returns (bytes4)
    {
        return BaseHook.beforeDonate.selector;
    }
}
