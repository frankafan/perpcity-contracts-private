// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

/// @title Mock PoolManager for Halmos Testing
/// @notice Minimal implementation focusing on functions used by PerpManager
contract PoolManagerMock {
    function unlock(bytes calldata data) external returns (bytes memory) {
        // Simple passthrough for testing
        return data;
    }
}
