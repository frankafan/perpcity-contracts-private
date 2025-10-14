// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {UniV4Router} from "./libraries/UniV4Router.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// @title UnlockCallback
/// @notice Contract that the PoolManager calls back after UniV4Router unlocks the pool manager
contract UnlockCallback is IUnlockCallback {
    /* IMMUTABLES */

    /// @notice The pool manager that this contract expects calls from. Calls from other addresses will revert
    IPoolManager public immutable POOL_MANAGER;

    /* ERRORS */

    /// @notice Thrown when the caller is not the pool manager
    error NotPoolManager();
    /// @notice Thrown when an invalid action number is provided
    error InvalidAction(uint8 action);

    /* CONSTRUCTOR */

    /// @notice Instantiates UnlockCallback
    /// @param poolManager The pool manager that this contract expects calls from
    constructor(IPoolManager poolManager) {
        POOL_MANAGER = poolManager;
    }

    /* FUNCTIONS */

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory encodedDelta) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();

        // decode action to take and related encoded params to input
        (uint8 action, bytes memory encodedParams) = abi.decode(data, (uint8, bytes));

        // use specified action to decode params and call the corresponding function
        if (action == UniV4Router.CREATE_POOL) {
            UniV4Router.CreatePoolConfig memory params = abi.decode(encodedParams, (UniV4Router.CreatePoolConfig));
            return UniV4Router.createPool(POOL_MANAGER, params);
        } else if (action == UniV4Router.MODIFY_LIQUIDITY) {
            UniV4Router.LiquidityConfig memory params = abi.decode(encodedParams, (UniV4Router.LiquidityConfig));
            return UniV4Router.modifyLiquidity(POOL_MANAGER, params);
        } else if (action == UniV4Router.SWAP) {
            UniV4Router.SwapConfig memory params = abi.decode(encodedParams, (UniV4Router.SwapConfig));
            return UniV4Router.swap(POOL_MANAGER, params);
        } else if (action == UniV4Router.DONATE) {
            UniV4Router.DonateConfig memory params = abi.decode(encodedParams, (UniV4Router.DonateConfig));
            UniV4Router.donate(POOL_MANAGER, params);
            /// TODO: add back or remove
            // return "";
        } else {
            // will revert if action is not valid
            revert InvalidAction(action);
        }
    }
}
