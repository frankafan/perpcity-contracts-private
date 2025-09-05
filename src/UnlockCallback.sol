// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {UniV4Broker} from "./libraries/UniV4Broker.sol";

contract UnlockCallback {
    using UniV4Broker for IPoolManager;

    error NotPoolManager();

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory encodedDelta) {
        // make sure caller is pool manager
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        // decode action and corresponding encoded params
        (uint8 action, bytes memory encodedParams) = abi.decode(data, (uint8, bytes));

        // use action to determine how to decode params and which function to call
        if (action == UniV4Broker.CREATE_POOL) {
            UniV4Broker.CreatePoolParams memory params = abi.decode(encodedParams, (UniV4Broker.CreatePoolParams));
            return poolManager.createPool(params);
        } else if (action == UniV4Broker.MODIFY_LIQUIDITY) {
            UniV4Broker.LiquidityConfig memory params = abi.decode(encodedParams, (UniV4Broker.LiquidityConfig));
            return poolManager.modifyLiquidity(params);
        } else if (action == UniV4Broker.SWAP) {
            UniV4Broker.SwapConfig memory params = abi.decode(encodedParams, (UniV4Broker.SwapConfig));
            return poolManager.swap(params);
        } else {
            revert UniV4Broker.InvalidAction(action);
        }
    }
}