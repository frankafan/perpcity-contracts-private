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
// import {PoolManagerMock} from "./mocks/PoolManagerMock.sol";
import {PoolManagerMock} from "./mocks/PoolManagerMockSimplified.sol";
import {BeaconMock} from "./mocks/BeaconMock.sol";

// TODO: give a list of symbolic values assumed

/// @custom:halmos --solver-timeout-assertion 0
contract PerpManagerHalmosTest is SymTest, Test {
    using PoolIdLibrary for PoolId;

    // Contracts
    PoolManagerMock internal poolManagerMock;
    ERC20Mock internal usdcMock;
    PerpManagerHarness internal perpManager;
    BeaconMock internal beaconMock;

    // Modules
    Fees internal fees;
    MarginRatios internal marginRatios;
    Lockup internal lockup;
    SqrtPriceImpactLimit internal sqrtPriceImpactLimit;

    // Test actors
    address internal creator;

    // Perps
    PoolId internal perpId1;

    function setUp() public virtual {
        // Initialize mock contracts
        poolManagerMock = new PoolManagerMock();
        usdcMock = new ERC20Mock();
        beaconMock = new BeaconMock(address(this), 50 * UINT_Q96, 100);
        // TODO: remove hardcoded typecast
        perpManager = new PerpManagerHarness(IPoolManager(address(poolManagerMock)), address(usdcMock));

        // Create symbolic storage
        // svm.enableSymbolicStorage(address(usdcMock));
        // svm.enableSymbolicStorage(address(beaconMock));
        // svm.enableSymbolicStorage(address(poolManagerMock));

        // Initialize and register modules
        fees = new Fees();
        marginRatios = new MarginRatios();
        lockup = new Lockup();
        sqrtPriceImpactLimit = new SqrtPriceImpactLimit();

        // TODO: make sure the rest also aligns with the current version PerpManager
        perpManager.registerFeesModule(fees);
        perpManager.registerMarginRatiosModule(marginRatios);
        perpManager.registerLockupPeriodModule(lockup);
        perpManager.registerSqrtPriceImpactLimitModule(sqrtPriceImpactLimit);

        // TODO: try with concrete vs symbolic and see if the number of paths is different
        // Create symbolic addresses for test actors
        creator = svm.createAddress("creator");

        // Assumptions for actors
        vm.assume(creator != address(0));
        vm.assume(creator != address(perpManager));

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

    // TODO: write out methodology / justifications in docstring
    function check_vaultBalanceIntegrity(bytes4 selector, address caller) public {
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

        _callPerpManagerNTimes(selector, caller, perpId1, 10);

        uint256 vaultBalanceAfter = usdcMock.balanceOf(vault);
        uint128 insuranceAfter = perpManager.getInsurance(perpId1);
        uint128 nextPosId = perpManager.getNextPosId(perpId1); // TODO: verify if this always gives open position

        // Calculate total effective margin in open positions
        uint256 totalEffectiveMargin = 0;
        for (uint128 i = 0; i < nextPosId; i++) {
            // TODO: add check for if the position is already closed
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
        IPerpManager.CreatePerpParams memory perpParams = _createSymbolicPerpParams(address(beaconMock));
        vm.prank(perpCreator);
        return perpManager.createPerp(perpParams);
    }

    /// @notice Create symbolic perp parameters
    /// @param beacon The beacon address to use for the perp
    function _createSymbolicPerpParams(address beacon) internal returns (IPerpManager.CreatePerpParams memory) {
        uint160 startingSqrtPriceX96 = uint160(svm.createUint(160, "startingSqrtPriceX96"));

        // TODO: use their hardcoded constant
        // Assume valid sqrt price range
        // MIN_SQRT_RATIO = 4295128739, MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342
        vm.assume(startingSqrtPriceX96 >= 4295128739);
        vm.assume(startingSqrtPriceX96 <= type(uint160).max);

        // TODO: take variables from arguments or this
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

    /// @notice Call PerpManager with symbolic arguments
    /// @param selector Function selector to call
    /// @param caller Address to call from
    /// @param perpId Perp ID to use
    function _callPerpManager(bytes4 selector, address caller, PoolId perpId) internal {
        // Get function selectors from contract
        // TODO: don't make variables for these
        bytes4 openMakerPositionSel = perpManager.openMakerPos.selector;
        bytes4 openTakerPositionSel = perpManager.openTakerPos.selector;
        bytes4 addMarginSel = perpManager.addMargin.selector;
        bytes4 closePositionSel = perpManager.closePosition.selector;
        bytes4 increaseCardinalityCapSel = perpManager.increaseCardinalityCap.selector;

        // Limit the functions tested
        // TODO: document that these are entry points
        // TODO: check vault balance integrity by only calling one entry point one time manually - the sum of all should be the same as calling callPerpManager once
        vm.assume(
            selector == openMakerPositionSel ||
                selector == openTakerPositionSel ||
                selector == addMarginSel ||
                selector == closePositionSel ||
                selector == increaseCardinalityCapSel
        );

        // Create symbolic parameters
        IPerpManager.OpenMakerPositionParams memory makerParams = _createSymbolicMakerParams();
        IPerpManager.OpenTakerPositionParams memory takerParams = _createSymbolicTakerParams();

        // TODO: make a wrapper for svm.createUint that does the same thing called simulateAllPossibleValues
        // TODO: put these symbolic variables into the if-else block
        uint128 posId = uint128(svm.createUint(128, "posId"));

        // addMargin parameters
        uint256 addMarginAmount = svm.createUint256("addMarginAmount");

        // closePosition parameters
        uint128 minAmt0Out = uint128(svm.createUint(128, "minAmt0Out"));
        uint128 minAmt1Out = uint128(svm.createUint(128, "minAmt1Out"));
        uint128 maxAmt1In = uint128(svm.createUint(128, "maxAmt1In"));

        // increaseCardinalityCap parameters
        uint16 cardinalityCap = uint16(svm.createUint(16, "cardinalityCap"));

        bytes memory args;

        if (selector == openMakerPositionSel) {
            args = abi.encode(perpId, makerParams);
        } else if (selector == openTakerPositionSel) {
            args = abi.encode(perpId, takerParams);
        } else if (selector == addMarginSel) {
            IPerpManager.AddMarginParams memory params = IPerpManager.AddMarginParams({
                posId: posId,
                amtToAdd: addMarginAmount
            });
            args = abi.encode(perpId, params);
        } else if (selector == closePositionSel) {
            IPerpManager.ClosePositionParams memory params = IPerpManager.ClosePositionParams({
                posId: posId,
                minAmt0Out: minAmt0Out,
                minAmt1Out: minAmt1Out,
                maxAmt1In: maxAmt1In
            });
            args = abi.encode(perpId, params);
        } else if (selector == increaseCardinalityCapSel) {
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
