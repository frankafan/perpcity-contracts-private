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

// Helper functions
import {HelperFunctions} from "./HelperFunctions.sol";

/// @custom:halmos --solver-timeout-assertion 0
contract PerpManagerHalmosTest is SymTest, Test {
    using HelperFunctions for *;
    using PoolIdLibrary for PoolId;

    // Contracts
    PoolManagerMock internal poolManagerMock;
    ERC20Mock internal usdcMock;
    PerpManager internal perpManager;

    // Test actors
    address internal creator;
    address internal maker;
    address internal taker;
    address internal liquidator;

    function setUp() public virtual {
        // Initialize mock contracts
        poolManagerMock = new PoolManagerMock();
        usdcMock = new ERC20Mock("USD Coin", "USDC", 6);

        perpManager = new PerpManager(IPoolManager(address(poolManagerMock)), address(usdcMock));

        // Create symbolic addresses for test actors
        creator = svm.createAddress("creator");
        maker = svm.createAddress("maker");
        taker = svm.createAddress("taker");
        liquidator = svm.createAddress("liquidator");

        // Assumptions for actors
        vm.assume(creator != address(0));
        vm.assume(maker != address(0));
        vm.assume(taker != address(0));
        vm.assume(liquidator != address(0));
        vm.assume(creator != address(perpManager));
        vm.assume(maker != address(perpManager));
        vm.assume(taker != address(perpManager));
        vm.assume(creator != maker);
        vm.assume(creator != taker);
        vm.assume(creator != liquidator);
        vm.assume(maker != taker);
        vm.assume(maker != liquidator);
        vm.assume(taker != liquidator);

        // Enable symbolic storage for key contracts
        svm.enableSymbolicStorage(address(this));
        svm.enableSymbolicStorage(address(perpManager));
        svm.enableSymbolicStorage(address(poolManagerMock));
        svm.enableSymbolicStorage(address(usdcMock));

        // Set symbolic block number and timestamp
        uint256 blockNumber = svm.createUint(32, "block.number");
        uint256 blockTimestamp = svm.createUint(32, "block.timestamp");

        // Assumptions for block values
        vm.assume(blockNumber > 0 && blockNumber < type(uint32).max);
        vm.assume(blockTimestamp > 1700000000 && blockTimestamp < type(uint32).max); // After Nov 2023

        vm.roll(blockNumber);
        vm.warp(blockTimestamp);
    }

    /// PoolManager address is always the one set in constructor
    function check_poolManager_immutable() public view {
        address poolManagerAddress = address(perpManager.POOL_MANAGER());

        assert(poolManagerAddress == address(poolManagerMock));
        assert(poolManagerAddress != address(0));
    }
}
