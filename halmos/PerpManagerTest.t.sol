// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "@halmos-cheatcodes/src/SymTest.sol";

import {PerpManager} from "../src/PerpManager.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

// Mocks
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {PoolManagerMock} from "./mocks/PoolManagerMock.sol";

/// @custom:halmos --solver-timeout-assertion 0
contract PerpManagerHalmosTest is SymTest, Test {
    using PoolIdLibrary for PoolId;

    // Mock PoolManager using inheritance
    IPoolManager internal poolManager;

    // Mock USDC using inheritance
    address internal usdc;

    PerpManager internal perpManager;

    function setUp() public virtual {
        // Create simple mock addresses
        poolManager = IPoolManager(address(0x1234567890123456789012345678901234567890));
        usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // Mainnet USDC address

        perpManager = new PerpManager(poolManager, usdc);

        // Enable symbolic storage for key contracts
        svm.enableSymbolicStorage(address(this));
        svm.enableSymbolicStorage(address(perpManager));

        // Set symbolic block number and timestamp
        vm.roll(svm.createUint(64, "block.number"));
        vm.warp(svm.createUint(64, "block.timestamp"));
    }

    // PoolManager address is always the one set in constructor
    function check_poolManager_immutable() public view {
        address poolManagerAddress = address(perpManager.POOL_MANAGER());

        assert(poolManagerAddress == address(poolManager));
        assert(poolManagerAddress != address(0));
    }
}
