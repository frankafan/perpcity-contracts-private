// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "@halmos-cheatcodes/src/SymTest.sol";

import {PerpManager} from "../src/PerpManager.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

// Mock contracts
contract MockPoolManager {
    function unlock(bytes calldata) external pure returns (bytes memory) {
        return "";
    }
}

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @custom:halmos --solver-timeout-assertion 0
contract PerpManagerHalmosTest is SymTest, Test {
    using PoolIdLibrary for PoolId;

    PerpManager internal perpManager;
    MockPoolManager internal poolManager;
    MockUSDC internal usdc;

    function setUp() public virtual {
        poolManager = new MockPoolManager();
        usdc = new MockUSDC();
        perpManager = new PerpManager(IPoolManager(address(poolManager)), address(usdc));

        // Enable symbolic storage for key contracts
        svm.enableSymbolicStorage(address(this));
        svm.enableSymbolicStorage(address(perpManager));
        svm.enableSymbolicStorage(address(poolManager));
        svm.enableSymbolicStorage(address(usdc));

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
