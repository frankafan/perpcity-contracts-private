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
    /* HELPER FUNCTIONS */

    /// @notice Create symbolic perp parameters
    function _createSymbolicPerpParams() internal returns (IPerpManager.CreatePerpParams memory) {
        uint160 startingSqrtPriceX96 = uint160(svm.createUint(160, "startingSqrtPriceX96"));
        address beacon = svm.createAddress("beacon");

        // Assume valid sqrt price range
        // MIN_SQRT_RATIO = 4295128739, MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342
        vm.assume(startingSqrtPriceX96 >= 4295128739);
        vm.assume(startingSqrtPriceX96 <= type(uint160).max);
        vm.assume(beacon != address(0));

        return IPerpManager.CreatePerpParams({startingSqrtPriceX96: startingSqrtPriceX96, beacon: beacon});
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
        vm.assume(liq > 0);
        vm.assume(tickLower < tickUpper);
        vm.assume(maxAmt0 > 0);
        vm.assume(maxAmt1 > 0);

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
        vm.assume(levX96 > 0);
        vm.assume(limit > 0);

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
        // Compute function selectors
        bytes4 openMakerPositionSel = bytes4(
            keccak256("openMakerPosition(bytes32,(uint256,uint128,int24,int24,uint128,uint128))")
        );
        bytes4 openTakerPositionSel = bytes4(keccak256("openTakerPosition(bytes32,(bool,uint256,uint256,uint128))"));
        bytes4 addMarginSel = bytes4(keccak256("addMargin(bytes32,(uint128,uint256))"));
        bytes4 closePositionSel = bytes4(keccak256("closePosition(bytes32,(uint128,uint128,uint128,uint128))"));
        bytes4 increaseCardinalityCapSel = bytes4(keccak256("increaseCardinalityCap(bytes32,uint16)"));

        // Limit the functions tested
        vm.assume(selector == openMakerPositionSel);
        // vm.assume(
        //     selector == openMakerPositionSel ||
        //         selector == openTakerPositionSel ||
        //         selector == addMarginSel ||
        //         selector == closePositionSel ||
        //         selector == increaseCardinalityCapSel
        // );

        bytes memory args;

        if (selector == openMakerPositionSel) {
            IPerpManager.OpenMakerPositionParams memory params = _createSymbolicMakerParams();
            args = abi.encode(perpId, params);
        } else if (selector == openTakerPositionSel) {
            IPerpManager.OpenTakerPositionParams memory params = _createSymbolicTakerParams();
            args = abi.encode(perpId, params);
        } else if (selector == addMarginSel) {
            uint128 posId = uint128(svm.createUint(128, "posId"));
            uint256 margin = svm.createUint256("margin");
            vm.assume(margin > 0);
            IPerpManager.AddMarginParams memory params = IPerpManager.AddMarginParams({posId: posId, margin: margin});
            args = abi.encode(perpId, params);
        } else if (selector == closePositionSel) {
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
        } else if (selector == increaseCardinalityCapSel) {
            uint16 cardinalityCap = uint16(svm.createUint(16, "cardinalityCap"));
            args = abi.encode(perpId, cardinalityCap);
        } else {
            revert("Unsupported selector");
        }

        vm.prank(caller);
        (bool success, ) = address(perpManager).call(abi.encodePacked(selector, args));
        vm.assume(success);
    }
}
