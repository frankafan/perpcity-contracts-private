// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "@halmos-cheatcodes/src/SymTest.sol";

import {PerpManager} from "../src/PerpManager.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {UINT_Q96} from "../src/libraries/Constants.sol";

// Modules
import {IFees, Fees} from "../src/modules/Fees.sol";
import {IMarginRatios, MarginRatios} from "../src/modules/MarginRatios.sol";
import {ILockupPeriod, Lockup} from "../src/modules/Lockup.sol";
import {ISqrtPriceImpactLimit, SqrtPriceImpactLimit} from "../src/modules/SqrtPriceImpactLimit.sol";

// Test harness
import {PerpManagerHarness} from "./PerpManagerHarness.sol";

// Mocks
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {PoolManagerMock} from "./mocks/PoolManagerMock.sol";
// import {PoolManagerMock} from "./mocks/PoolManagerMockSimplified.sol";
import {OwnableBeacon} from "../src/beacons/ownable/OwnableBeacon.sol";

// TODO: give a list of symbolic values assumed

/// @custom:halmos --solver-timeout-assertion 0
contract PerpManagerHalmosTest is SymTest, Test {
    using PoolIdLibrary for PoolId;

    // Constants
    uint256 public constant NUM_CALLS = 1;

    // Contracts
    PoolManagerMock internal poolManagerMock;
    ERC20Mock internal usdcMock;
    PerpManagerHarness internal perpManager;
    OwnableBeacon internal beaconMock;

    // Modules
    Fees internal _fees;
    MarginRatios internal _marginRatios;
    Lockup internal _lockup;
    SqrtPriceImpactLimit internal _sqrtPriceImpactLimit;

    // Test actors
    address internal creator;
    address internal beaconOwner;

    // Perps
    PoolId internal perpId1;

    function setUp() public virtual {
        if (false) {
            // Initialize mock contracts
            poolManagerMock = new PoolManagerMock();
            usdcMock = new ERC20Mock();
            perpManager = new PerpManagerHarness(IPoolManager(address(poolManagerMock)), address(usdcMock));

            // Create symbolic storage
            // svm.enableSymbolicStorage(address(usdcMock));
            // svm.enableSymbolicStorage(address(beaconMock));
            // svm.enableSymbolicStorage(address(poolManagerMock));

            // Initialize and register modules
            _fees = new Fees();
            _marginRatios = new MarginRatios();
            _lockup = new Lockup();
            _sqrtPriceImpactLimit = new SqrtPriceImpactLimit();

            // TODO: make sure the rest also aligns with the current version PerpManager
            perpManager.registerFeesModule(_fees);
            perpManager.registerMarginRatiosModule(_marginRatios);
            perpManager.registerLockupPeriodModule(_lockup);
            perpManager.registerSqrtPriceImpactLimitModule(_sqrtPriceImpactLimit);

            // TODO: try with concrete vs symbolic and see if the number of paths is different
            // Create symbolic addresses for test actors
            creator = svm.createAddress("creator");
            beaconOwner = svm.createAddress("beacon.owner");

            // Assumptions for actors
            vm.assume(creator != address(0));
            vm.assume(creator != address(perpManager));
            vm.assume(beaconOwner != address(0));

            // TODO: remove if possible
            // Set symbolic block number and timestamp
            uint256 blockNumber = svm.createUint(32, "block.number");
            uint256 blockTimestamp = svm.createUint(32, "block.timestamp");

            // Assumptions for block values
            vm.assume(blockNumber > 0);
            vm.assume(blockTimestamp > 0);

            vm.roll(blockNumber);
            vm.warp(blockTimestamp);
        }
    }

    // TODO: write out methodology / justifications in docstring
    function vaultBalanceIntegrity(bytes4 selector, address caller) public {
        // TODO: verify the function arguments are symbolic

        // Create perp
        perpId1 = _createPerp(creator); // TODO: document that we assume independence of markets / market fungible

        (, , address vault, , , , , ) = perpManager.configs(perpId1);

        uint128 initialInsurance = perpManager.getInsurance(perpId1);
        uint256 initialVaultBalance = usdcMock.balanceOf(vault);

        // Initial assumptions
        vm.assume(vault != address(0));
        vm.assume(initialVaultBalance >= initialInsurance);
        vm.assume(caller != address(0));
        vm.assume(caller != address(perpManager));
        vm.assume(caller != vault);

        _callPerpManagerNTimes(selector, caller, perpId1, NUM_CALLS);

        uint256 vaultBalanceAfter = usdcMock.balanceOf(vault);
        uint128 insuranceAfter = perpManager.getInsurance(perpId1);
        uint128 nextPosId = perpManager.getNextPosId(perpId1); // TODO: verify if this always gives open position

        // Calculate total effective margin in open positions
        uint256 totalEffectiveMargin = 0;
        for (uint128 i = 0; i < nextPosId; i++) {
            IPerpManager.Position memory pos = perpManager.getPosition(perpId1, i);
            if (pos.holder != address(0)) {
                // Use quoteClosePosition to get effective margin for this position
                (bool success, uint256 netMargin) = perpManager.getNetMargin(perpId1, i);
                if (!success) {
                    // XXX: bug if valid position cannot be quoted
                    assert(false);
                }
                totalEffectiveMargin += netMargin;
            }
        }

        // Invariant
        // TODO: print and verify these are all symbolic
        assert(vaultBalanceAfter >= totalEffectiveMargin + insuranceAfter);
    }

    /* HELPER FUNCTIONS */

    /// @notice Create symbolic perp
    /// @param perpCreator Address creating the perp
    function _createPerp(address perpCreator) internal returns (PoolId) {
        // Create beaconMock with symbolic inputs
        uint256 initialIndexX96 = svm.createUint256("beacon.initialIndexX96");
        uint16 initialCardinalityCap = uint16(svm.createUint(16, "beacon.initialCardinalityCap"));

        // Assumptions for beacon parameters
        vm.assume(initialCardinalityCap > 0);

        beaconMock = new OwnableBeacon(beaconOwner, initialIndexX96, initialCardinalityCap);

        IPerpManager.CreatePerpParams memory perpParams = _createSymbolicPerpParams(
            address(beaconMock),
            _fees,
            _marginRatios,
            _lockup,
            _sqrtPriceImpactLimit
        );
        vm.prank(perpCreator);
        return perpManager.createPerp(perpParams);
    }

    /// @notice Create symbolic perp parameters
    /// @param beacon The beacon address to use for the perp
    /// @param fees The fees module
    /// @param marginRatios The margin ratios module
    /// @param lockup The lockup period module
    /// @param sqrtPriceImpactLimit The sqrt price impact limit module
    function _createSymbolicPerpParams(
        address beacon,
        IFees fees,
        IMarginRatios marginRatios,
        ILockupPeriod lockup,
        ISqrtPriceImpactLimit sqrtPriceImpactLimit
    ) internal returns (IPerpManager.CreatePerpParams memory) {
        uint160 startingSqrtPriceX96 = uint160(svm.createUint(160, "startingSqrtPriceX96"));

        // Assume valid sqrt price range
        // From TickMath.sol: MIN_SQRT_PRICE = 4295128739, MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342
        vm.assume(startingSqrtPriceX96 >= 4295128739);
        vm.assume(startingSqrtPriceX96 <= 1461446703485210103287273052203988822378723970342);

        return
            IPerpManager.CreatePerpParams({
                beacon: beacon,
                fees: fees,
                marginRatios: marginRatios,
                lockupPeriod: lockup,
                sqrtPriceImpactLimit: sqrtPriceImpactLimit,
                startingSqrtPriceX96: startingSqrtPriceX96
            });
    }

    /// @notice Create symbolic maker position parameters
    function _createSymbolicMakerParams() internal returns (IPerpManager.OpenMakerPositionParams memory) {
        uint256 margin = svm.createUint256("maker.margin");
        uint128 liq = uint128(svm.createUint(128, "maker.liquidity"));
        int24 tickLower = int24(int256(svm.createUint(24, "maker.tickLower")));
        int24 tickUpper = int24(int256(svm.createUint(24, "maker.tickUpper")));
        uint128 maxAmt0 = uint128(svm.createUint(128, "maker.maxAmt0In"));
        uint128 maxAmt1 = uint128(svm.createUint(128, "maker.maxAmt1In"));

        // Assumptions
        vm.assume(margin > 0);

        return
            IPerpManager.OpenMakerPositionParams({
                margin: margin,
                liquidity: liq,
                tickLower: tickLower,
                tickUpper: tickUpper,
                maxAmt0In: maxAmt0,
                maxAmt1In: maxAmt1
            });
    }

    /// @notice Create symbolic taker position parameters
    function _createSymbolicTakerParams() internal returns (IPerpManager.OpenTakerPositionParams memory) {
        bool isLong = svm.createBool("taker.isLong");
        uint256 margin = svm.createUint256("taker.margin");
        uint256 levX96 = svm.createUint256("taker.levX96");
        uint128 limit = uint128(svm.createUint(128, "taker.limit"));

        // Assumptions
        vm.assume(margin > 0);

        return
            IPerpManager.OpenTakerPositionParams({
                isLong: isLong,
                margin: margin,
                levX96: levX96,
                unspecifiedAmountLimit: limit
            });
    }

    // Set to internal for now (skipped)
    function check_totalPriceBuggy(uint32 quantity) public view {
        // even this generates two paths
        //assert(quantity == 0);
    }
    function check_vaultBalanceIntegrity_2(address caller) internal {
        // Create perp
        perpId1 = _createPerp(creator); // TODO: document that we assume independence of markets / market fungible

        (, , address vault, , , , , ) = perpManager.configs(perpId1);

        uint128 initialInsurance = perpManager.getInsurance(perpId1);
        uint256 initialVaultBalance = usdcMock.balanceOf(vault);

        // Initial assumptions
        vm.assume(vault != address(0));
        vm.assume(initialVaultBalance >= initialInsurance);
        vm.assume(caller != address(0));
        vm.assume(caller != address(perpManager));
        vm.assume(caller != vault);

        uint256 margin = svm.createUint256("maker.margin");
        uint128 liq = uint128(svm.createUint(128, "maker.liquidity"));
        int24 tickLower = int24(int256(svm.createUint(24, "maker.tickLower")));
        int24 tickUpper = int24(int256(svm.createUint(24, "maker.tickUpper")));
        uint128 maxAmt0 = uint128(svm.createUint(128, "maker.maxAmt0In"));
        uint128 maxAmt1 = uint128(svm.createUint(128, "maker.maxAmt1In"));

        // Assumptions
        vm.assume(margin > 0);
        IPerpManager.OpenMakerPositionParams memory openMakerPosParams = IPerpManager.OpenMakerPositionParams({
                margin: margin,
                liquidity: liq,
                tickLower: tickLower,
                tickUpper: tickUpper,
                maxAmt0In: maxAmt0,
                maxAmt1In: maxAmt1
            });

        vm.prank(caller);
        perpManager.openMakerPos(perpId1, openMakerPosParams);

        // IPerpManager.AddMarginParams memory addMarginParams = IPerpManager.AddMarginParams({
        //     posId: uint128(svm.createUint(128, "posId")),
        //     amtToAdd: svm.createUint256("addMarginAmount")
        // });

        // vm.prank(caller);
        // perpManager.addMargin(perpId1, addMarginParams);

        // uint256 vaultBalanceAfter = usdcMock.balanceOf(vault);
        // uint128 insuranceAfter = perpManager.getInsurance(perpId1);
        // uint128 nextPosId = perpManager.getNextPosId(perpId1); // TODO: verify if this always gives open position

        // // Calculate total effective margin in open positions
        // uint256 totalEffectiveMargin = 0;
        // for (uint128 i = 0; i < nextPosId; i++) {
        //     IPerpManager.Position memory pos = perpManager.getPosition(perpId1, i);
        //     if (pos.holder != address(0)) {
        //         // Use quoteClosePosition to get effective margin for this position
        //         (bool success, uint256 netMargin) = perpManager.getNetMargin(perpId1, i);
        //         if (!success) {
        //             // XXX: bug if valid position cannot be quoted
        //             assert(false);
        //         }
        //         totalEffectiveMargin += netMargin;
        //     }
        // }

        // // Invariant
        // assert(vaultBalanceAfter >= totalEffectiveMargin + insuranceAfter);
    }

    /// @notice Call PerpManager with symbolic arguments
    /// @param selector Function selector to call
    /// @param caller Address to call from
    /// @param perpId Perp ID to use
    function _callPerpManager(bytes4 selector, address caller, PoolId perpId) internal {
        // Limit the functions tested
        // TODO: document that these are entry points
        // TODO: check vault balance integrity by only calling one entry point one time manually - the sum of all should be the same as calling callPerpManager once
        vm.assume(
            selector == perpManager.openMakerPos.selector ||
                selector == perpManager.openTakerPos.selector ||
                selector == perpManager.addMargin.selector ||
                selector == perpManager.closePosition.selector ||
                selector == perpManager.increaseCardinalityCap.selector
        );

        bytes memory args;

        if (selector == perpManager.openMakerPos.selector) {
            IPerpManager.OpenMakerPositionParams memory makerParams = _createSymbolicMakerParams();
            args = abi.encode(perpId, makerParams);
        } else if (selector == perpManager.openTakerPos.selector) {
            IPerpManager.OpenTakerPositionParams memory takerParams = _createSymbolicTakerParams();
            args = abi.encode(perpId, takerParams);
        } else if (selector == perpManager.addMargin.selector) {
            uint128 posId = uint128(svm.createUint(128, "posId"));
            uint256 addMarginAmount = svm.createUint256("addMarginAmount");
            IPerpManager.AddMarginParams memory params = IPerpManager.AddMarginParams({
                posId: posId,
                amtToAdd: addMarginAmount
            });
            args = abi.encode(perpId, params);
        } else if (selector == perpManager.closePosition.selector) {
            uint128 posId = uint128(svm.createUint(128, "posId"));
            uint128 minAmt0Out = uint128(svm.createUint(128, "minAmt0Out"));
            uint128 minAmt1Out = uint128(svm.createUint(128, "minAmt1Out"));
            uint128 maxAmt1In = uint128(svm.createUint(128, "maxAmt1In"));
            IPerpManager.ClosePositionParams memory params = IPerpManager.ClosePositionParams({
                posId: posId,
                minAmt0Out: minAmt0Out,
                minAmt1Out: minAmt1Out,
                maxAmt1In: maxAmt1In
            });
            args = abi.encode(perpId, params);
        } else if (selector == perpManager.increaseCardinalityCap.selector) {
            uint16 cardinalityCap = uint16(svm.createUint(16, "cardinalityCap"));
            args = abi.encode(perpId, cardinalityCap);
        } else {
            args = svm.createBytes(1024, "data");
        }

        vm.prank(caller);
        (bool success, ) = address(perpManager).call(abi.encodePacked(selector, args));
        vm.assume(success);
    }

    /// @notice Call `_callPerpManager` `n` times
    /// @param selector Function selector to call
    /// @param caller Address to call from
    /// @param perpId Perp ID to use
    /// @param n Number of times to call
    function _callPerpManagerNTimes(bytes4 selector, address caller, PoolId perpId, uint256 n) internal {
        vm.assume(n <= 256);
        for (uint256 i = 0; i < n; i++) {
            _callPerpManager(selector, caller, perpId);
        }
    }
}
