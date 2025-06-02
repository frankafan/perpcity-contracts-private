// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { BaseHook } from "v4-periphery/src/utils/BaseHook.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { IMsgSender } from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";

contract PerpHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => address) public perps;

    error CallerNotPerp(address caller, address perp);
    error PoolFeeNotDynamic();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) { }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    )
        internal
        override
        returns (bytes4)
    {
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert PoolFeeNotDynamic();

        perps[key.toId()] = sender;

        return BaseHook.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    )
        internal
        view
        override
        returns (bytes4)
    {
        if (IMsgSender(sender).msgSender() != perps[key.toId()]) revert CallerNotPerp(sender, perps[key.toId()]);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    )
        internal
        view
        override
        returns (bytes4)
    {
        if (IMsgSender(sender).msgSender() != perps[key.toId()]) revert CallerNotPerp(sender, perps[key.toId()]);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    )
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (IMsgSender(sender).msgSender() != perps[key.toId()]) revert CallerNotPerp(sender, perps[key.toId()]);

        uint24 feeWithFlag = abi.decode(hookData, (uint24)) | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    function _beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    )
        internal
        view
        override
        returns (bytes4)
    {
        if (IMsgSender(sender).msgSender() != perps[key.toId()]) revert CallerNotPerp(sender, perps[key.toId()]);
        return BaseHook.beforeDonate.selector;
    }
}
