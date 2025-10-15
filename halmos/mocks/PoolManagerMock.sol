// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Mock PoolManager for Halmos Testing
/// @notice Minimal implementation focusing on functions used by PerpManager
contract PoolManagerMock {
    mapping(PoolId => uint160) public sqrtPriceX96;
    mapping(PoolId => int24) public tick;
    mapping(PoolId => uint128) public liquidity;
    mapping(PoolId => bool) public initialized;

    function initialize(PoolKey memory key, uint160 _sqrtPriceX96) external returns (int24) {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        sqrtPriceX96[id] = _sqrtPriceX96;
        initialized[id] = true;
        // Simplified tick calculation
        tick[id] = 0;
        return 0;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        // Simple passthrough for testing
        return data;
    }

    function getSlot0(PoolId id) external view returns (uint160, int24, uint24, uint24) {
        return (sqrtPriceX96[id], tick[id], 0, 0);
    }

    function isTickInitialized(PoolId id, int24 _tick) external view returns (bool) {
        return initialized[id];
    }

    function executeAction(uint8 action, bytes memory data) external returns (bytes memory) {
        // Simplified action execution for testing
        return data;
    }
}
