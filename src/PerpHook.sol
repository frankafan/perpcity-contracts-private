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

/// @title PerpHook
/// @notice A Uniswap V4 hook contract that manages perpetual protocol interactions
/// @dev This hook ensures that only authorized perpetual contracts can interact with specific pools
contract PerpHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Maps pool IDs to their associated perpetual contract addresses
    mapping(PoolId => address) public perps;

    /// @notice Error thrown when a non-perpetual contract attempts to interact with a pool
    /// @param caller The address that attempted the interaction
    /// @param perp The authorized perpetual contract address for the pool
    error CallerNotPerp(address caller, address perp);

    /// @notice Error thrown when a pool is initialized without dynamic fees
    error PoolFeeNotDynamic();

    /// @notice Creates a new PerpHook instance
    /// @param _poolManager The Uniswap V4 pool manager contract
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) { }

    /// @notice Returns the hook permissions configuration
    /// @return permissions The set of hook permissions for this contract
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

    /// @notice Hook called before pool initialization
    /// @dev Ensures the pool uses dynamic fees and records the perpetual contract address
    /// @param sender The address initializing the pool
    /// @param key The pool key containing pool parameters
    /// @param sqrtPriceX96 The initial sqrt price of the pool
    /// @return The selector of the beforeInitialize function
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

    /// @notice Hook called before adding liquidity
    /// @dev Verifies that the caller is the authorized perpetual contract for the pool
    /// @param sender The address adding liquidity
    /// @param key The pool key containing pool parameters
    /// @param params The liquidity modification parameters
    /// @param hookData Additional data passed to the hook
    /// @return The selector of the beforeAddLiquidity function
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

    /// @notice Hook called before removing liquidity
    /// @dev Verifies that the caller is the authorized perpetual contract for the pool
    /// @param sender The address removing liquidity
    /// @param key The pool key containing pool parameters
    /// @param params The liquidity modification parameters
    /// @param hookData Additional data passed to the hook
    /// @return The selector of the beforeRemoveLiquidity function
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

    /// @notice Hook called before executing a swap
    /// @dev Verifies that the caller is the authorized perpetual contract and sets the dynamic fee
    /// @param sender The address executing the swap
    /// @param key The pool key containing pool parameters
    /// @param params The swap parameters
    /// @param hookData Additional data containing the fee to be used
    /// @return The selector of the beforeSwap function, zero delta, and the fee with override flag
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

    /// @notice Hook called before donating to the pool
    /// @dev Verifies that the caller is the authorized perpetual contract for the pool
    /// @param sender The address donating to the pool
    /// @param key The pool key containing pool parameters
    /// @param amount0 The amount of token0 being donated
    /// @param amount1 The amount of token1 being donated
    /// @param hookData Additional data passed to the hook
    /// @return The selector of the beforeDonate function
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
