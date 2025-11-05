// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "@halmos-cheatcodes/src/SymTest.sol";

import {PerpManager} from "../../src/PerpManager.sol";
import {IPerpManager} from "../../src/interfaces/IPerpManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {UINT_Q96} from "../../src/libraries/Constants.sol";

// Modules
import {IFees, Fees} from "../../src/modules/Fees.sol";
import {IMarginRatios, MarginRatios} from "../../src/modules/MarginRatios.sol";
import {ILockupPeriod, Lockup} from "../../src/modules/Lockup.sol";
import {ISqrtPriceImpactLimit, SqrtPriceImpactLimit} from "../../src/modules/SqrtPriceImpactLimit.sol";

// Test harness
import {PerpManagerHarness} from "../PerpManagerHarness.sol";

// Mocks
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {PoolManagerMockSimplified as PoolManagerMock} from "../mocks/PoolManagerMockSimplified.sol";
import {OwnableBeacon} from "../../src/beacons/ownable/OwnableBeacon.sol";

/// @custom:halmos --solver-timeout-assertion 0
contract PerpManagerHalmosDebugTest is SymTest, Test {
    using PoolIdLibrary for PoolId;

    // Contracts
    PoolManagerMock internal poolManagerMock;
    ERC20Mock internal usdcMock;
    PerpManagerHarness internal perpManager;
    OwnableBeacon internal beaconMock;

    // Modules
    Fees internal fees;
    MarginRatios internal marginRatios;
    Lockup internal lockup;
    SqrtPriceImpactLimit internal sqrtPriceImpactLimit;

    // Test actors
    address internal creator;

    // Perps
    PoolId internal perpId1;

    // Test 1: Minimal setup - no symbolic values
    function check_test1_minimalSetup() public {
        poolManagerMock = new PoolManagerMock();
        usdcMock = new ERC20Mock();
        perpManager = new PerpManagerHarness(IPoolManager(address(poolManagerMock)), address(usdcMock));

        assert(address(perpManager) != address(0));
    }

    // Test 2: Setup with modules but no perp creation
    function check_test2_setupWithModules() public {
        poolManagerMock = new PoolManagerMock();
        usdcMock = new ERC20Mock();
        perpManager = new PerpManagerHarness(IPoolManager(address(poolManagerMock)), address(usdcMock));

        fees = new Fees();
        marginRatios = new MarginRatios();
        lockup = new Lockup();
        sqrtPriceImpactLimit = new SqrtPriceImpactLimit();

        perpManager.registerFeesModule(fees);
        perpManager.registerMarginRatiosModule(marginRatios);
        perpManager.registerLockupPeriodModule(lockup);
        perpManager.registerSqrtPriceImpactLimitModule(sqrtPriceImpactLimit);

        assert(address(perpManager) != address(0));
    }

    // Test 3: Setup with concrete values and perp creation
    function check_test3_setupWithConcretePerp() public {
        poolManagerMock = new PoolManagerMock();
        usdcMock = new ERC20Mock();
        beaconMock = new OwnableBeacon(address(this), 50 * UINT_Q96, 100);
        perpManager = new PerpManagerHarness(IPoolManager(address(poolManagerMock)), address(usdcMock));

        fees = new Fees();
        marginRatios = new MarginRatios();
        lockup = new Lockup();
        sqrtPriceImpactLimit = new SqrtPriceImpactLimit();

        perpManager.registerFeesModule(fees);
        perpManager.registerMarginRatiosModule(marginRatios);
        perpManager.registerLockupPeriodModule(lockup);
        perpManager.registerSqrtPriceImpactLimitModule(sqrtPriceImpactLimit);

        // Create perp with concrete values
        IPerpManager.CreatePerpParams memory perpParams = IPerpManager.CreatePerpParams({
            beacon: address(beaconMock),
            fees: fees,
            marginRatios: marginRatios,
            lockupPeriod: lockup,
            sqrtPriceImpactLimit: sqrtPriceImpactLimit,
            startingSqrtPriceX96: 79228162514264337593543950336 // sqrt(1) in Q96
        });

        perpId1 = perpManager.createPerp(perpParams);

        assert(PoolId.unwrap(perpId1) != bytes32(0));
    }

    // Test 4: Setup with ONE symbolic value (startingSqrtPriceX96)
    function check_test4_oneSymbolicValue() public {
        poolManagerMock = new PoolManagerMock();
        usdcMock = new ERC20Mock();
        beaconMock = new OwnableBeacon(address(this), 50 * UINT_Q96, 100);
        perpManager = new PerpManagerHarness(IPoolManager(address(poolManagerMock)), address(usdcMock));

        fees = new Fees();
        marginRatios = new MarginRatios();
        lockup = new Lockup();
        sqrtPriceImpactLimit = new SqrtPriceImpactLimit();

        perpManager.registerFeesModule(fees);
        perpManager.registerMarginRatiosModule(marginRatios);
        perpManager.registerLockupPeriodModule(lockup);
        perpManager.registerSqrtPriceImpactLimitModule(sqrtPriceImpactLimit);

        // Create perp with ONE symbolic value
        uint160 startingSqrtPriceX96 = uint160(svm.createUint(160, "startingSqrtPriceX96"));
        vm.assume(startingSqrtPriceX96 >= 4295128739);
        vm.assume(startingSqrtPriceX96 <= type(uint160).max);

        IPerpManager.CreatePerpParams memory perpParams = IPerpManager.CreatePerpParams({
            beacon: address(beaconMock),
            fees: fees,
            marginRatios: marginRatios,
            lockupPeriod: lockup,
            sqrtPriceImpactLimit: sqrtPriceImpactLimit,
            startingSqrtPriceX96: startingSqrtPriceX96
        });

        perpId1 = perpManager.createPerp(perpParams);

        assert(PoolId.unwrap(perpId1) != bytes32(0));
    }

    // Test 5: Full setup like original (without the vault balance check)
    function check_test5_fullSetupNoVaultCheck() public {
        poolManagerMock = new PoolManagerMock();
        usdcMock = new ERC20Mock();
        beaconMock = new OwnableBeacon(address(this), 50 * UINT_Q96, 100);
        perpManager = new PerpManagerHarness(IPoolManager(address(poolManagerMock)), address(usdcMock));

        fees = new Fees();
        marginRatios = new MarginRatios();
        lockup = new Lockup();
        sqrtPriceImpactLimit = new SqrtPriceImpactLimit();

        perpManager.registerFeesModule(fees);
        perpManager.registerMarginRatiosModule(marginRatios);
        perpManager.registerLockupPeriodModule(lockup);
        perpManager.registerSqrtPriceImpactLimitModule(sqrtPriceImpactLimit);

        creator = svm.createAddress("creator");
        vm.assume(creator != address(0));
        vm.assume(creator != address(perpManager));

        uint256 blockNumber = svm.createUint(32, "block.number");
        uint256 blockTimestamp = svm.createUint(32, "block.timestamp");
        vm.assume(blockNumber > 0);
        vm.assume(blockTimestamp > 0);
        vm.roll(blockNumber);
        vm.warp(blockTimestamp);

        uint160 startingSqrtPriceX96 = uint160(svm.createUint(160, "startingSqrtPriceX96"));
        vm.assume(startingSqrtPriceX96 >= 4295128739);
        vm.assume(startingSqrtPriceX96 <= type(uint160).max);

        IPerpManager.CreatePerpParams memory perpParams = IPerpManager.CreatePerpParams({
            beacon: address(beaconMock),
            fees: fees,
            marginRatios: marginRatios,
            lockupPeriod: lockup,
            sqrtPriceImpactLimit: sqrtPriceImpactLimit,
            startingSqrtPriceX96: startingSqrtPriceX96
        });

        vm.prank(creator);
        perpId1 = perpManager.createPerp(perpParams);

        assert(PoolId.unwrap(perpId1) != bytes32(0));
    }

    // Test 6: Just the vault balance reading part (with concrete setup)
    function check_test6_vaultBalanceReadingConcrete() public {
        poolManagerMock = new PoolManagerMock();
        usdcMock = new ERC20Mock();
        beaconMock = new OwnableBeacon(address(this), 50 * UINT_Q96, 100);
        perpManager = new PerpManagerHarness(IPoolManager(address(poolManagerMock)), address(usdcMock));

        fees = new Fees();
        marginRatios = new MarginRatios();
        lockup = new Lockup();
        sqrtPriceImpactLimit = new SqrtPriceImpactLimit();

        perpManager.registerFeesModule(fees);
        perpManager.registerMarginRatiosModule(marginRatios);
        perpManager.registerLockupPeriodModule(lockup);
        perpManager.registerSqrtPriceImpactLimitModule(sqrtPriceImpactLimit);

        IPerpManager.CreatePerpParams memory perpParams = IPerpManager.CreatePerpParams({
            beacon: address(beaconMock),
            fees: fees,
            marginRatios: marginRatios,
            lockupPeriod: lockup,
            sqrtPriceImpactLimit: sqrtPriceImpactLimit,
            startingSqrtPriceX96: 79228162514264337593543950336
        });

        perpId1 = perpManager.createPerp(perpParams);

        // Now read vault balance
        (, , address vault, , , , , ) = perpManager.configs(perpId1);
        uint128 initialInsurance = perpManager.getInsurance(perpId1);
        uint256 initialVaultBalance = usdcMock.balanceOf(vault);

        assert(vault != address(0));
        assert(initialVaultBalance >= initialInsurance);
    }

    // Test 7: The loop that iterates through positions (THIS IS LIKELY THE CULPRIT)
    function check_test7_positionLoopWithSymbolicNextPosId() public {
        poolManagerMock = new PoolManagerMock();
        usdcMock = new ERC20Mock();
        beaconMock = new OwnableBeacon(address(this), 50 * UINT_Q96, 100);
        perpManager = new PerpManagerHarness(IPoolManager(address(poolManagerMock)), address(usdcMock));

        fees = new Fees();
        marginRatios = new MarginRatios();
        lockup = new Lockup();
        sqrtPriceImpactLimit = new SqrtPriceImpactLimit();

        perpManager.registerFeesModule(fees);
        perpManager.registerMarginRatiosModule(marginRatios);
        perpManager.registerLockupPeriodModule(lockup);
        perpManager.registerSqrtPriceImpactLimitModule(sqrtPriceImpactLimit);

        IPerpManager.CreatePerpParams memory perpParams = IPerpManager.CreatePerpParams({
            beacon: address(beaconMock),
            fees: fees,
            marginRatios: marginRatios,
            lockupPeriod: lockup,
            sqrtPriceImpactLimit: sqrtPriceImpactLimit,
            startingSqrtPriceX96: 79228162514264337593543950336
        });

        perpId1 = perpManager.createPerp(perpParams);

        uint128 nextPosId = perpManager.getNextPosId(perpId1);

        // THIS LOOP WITH SYMBOLIC BOUNDS IS THE PROBLEM
        uint256 totalEffectiveMargin = 0;
        for (uint128 i = 0; i < nextPosId; i++) {
            IPerpManager.Position memory pos = perpManager.getPosition(perpId1, i);
            if (pos.holder != address(0)) {
                (bool success, uint256 netMargin) = perpManager.getNetMargin(perpId1, i);
                if (!success) {
                    assert(false);
                }
                totalEffectiveMargin += netMargin;
            }
        }

        assert(totalEffectiveMargin >= 0);
    }
}
