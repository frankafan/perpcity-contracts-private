// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {UniV4Router} from "./libraries/UniV4Router.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract UnlockCallback {
    using UniV4Router for IPoolManager;

    error NotPoolManager();

    IPoolManager public immutable POOL_MANAGER;

    constructor(IPoolManager _poolManager) {
        POOL_MANAGER = _poolManager;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory encodedDelta) {
        // make sure caller is pool manager
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();

        // decode action and corresponding encoded params
        (uint8 action, bytes memory encodedParams) = abi.decode(data, (uint8, bytes));

        // use action to determine how to decode params and which function to call
        if (action == UniV4Router.CREATE_POOL) {
            UniV4Router.CreatePoolConfig memory params = abi.decode(encodedParams, (UniV4Router.CreatePoolConfig));
            return POOL_MANAGER.createPool(params);
        } else if (action == UniV4Router.MODIFY_LIQUIDITY) {
            UniV4Router.LiquidityConfig memory params = abi.decode(encodedParams, (UniV4Router.LiquidityConfig));
            return POOL_MANAGER.modifyLiquidity(params);
        } else if (action == UniV4Router.SWAP) {
            UniV4Router.SwapConfig memory params = abi.decode(encodedParams, (UniV4Router.SwapConfig));
            return POOL_MANAGER.swap(params);
        } else {
            revert UniV4Router.InvalidAction(action);
        }
    }
}
