// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {PerpManager} from "../src/PerpManager.sol";
import {OwnableBeacon} from "../src/beacons/ownable/OwnableBeacon.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {IFees} from "../src/interfaces/modules/IFees.sol";
import {IMarginRatios} from "../src/interfaces/modules/IMarginRatios.sol";
import {ILockupPeriod} from "../src/interfaces/modules/ILockupPeriod.sol";
import {ISqrtPriceImpactLimit} from "../src/interfaces/modules/ISqrtPriceImpactLimit.sol";
import {TimeWeightedAvg} from "../src/libraries/TimeWeightedAvg.sol";
import {UINT_Q96} from "../src/libraries/Constants.sol";
import {Fees} from "../src/modules/Fees.sol";
import {Lockup} from "../src/modules/Lockup.sol";
import {MarginRatios} from "../src/modules/MarginRatios.sol";
import {SqrtPriceImpactLimit} from "../src/modules/SqrtPriceImpactLimit.sol";
import {DeployPoolManager} from "./utils/DeployPoolManager.sol";
import {TestnetUSDC} from "./utils/TestnetUSDC.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

contract IncreaseCardinalityTest is Test, DeployPoolManager {
    uint256 public constant NUM_50_X96 = 3961408125713216879677197516800;
    uint160 public constant SQRT_50_X96 = 560227709747861399187319382275;
    uint16 public constant INITIAL_CARDINALITY_CAP = 1;
    uint16 public constant MAX_CARDINALITY_CAP = 65_535;

    address public immutable OWNER = makeAddr("owner");
    address public immutable CREATOR = makeAddr("creator");
    address public immutable CALLER = makeAddr("caller");
    address public immutable USER = makeAddr("user");

    IPoolManager public poolManager;
    address public usdc;
    PerpManager public perpManager;
    PoolId public perpId;

    function setUp() public {
        poolManager = deployPoolManager();
        usdc = address(new TestnetUSDC());
        perpManager = new PerpManager(poolManager, usdc, OWNER);

        vm.startPrank(OWNER);

        Fees fees = new Fees();
        MarginRatios marginRatios = new MarginRatios();
        Lockup lockupPeriod = new Lockup();
        SqrtPriceImpactLimit sqrtPriceImpactLimit = new SqrtPriceImpactLimit();

        perpManager.registerFeesModule(fees);
        perpManager.registerMarginRatiosModule(marginRatios);
        perpManager.registerLockupPeriodModule(lockupPeriod);
        perpManager.registerSqrtPriceImpactLimitModule(sqrtPriceImpactLimit);

        vm.stopPrank();

        vm.startPrank(CREATOR);
        OwnableBeacon beacon = new OwnableBeacon(CREATOR, NUM_50_X96, INITIAL_CARDINALITY_CAP);

        perpId = perpManager.createPerp(
            IPerpManager.CreatePerpParams({
                beacon: address(beacon),
                fees: fees,
                marginRatios: marginRatios,
                lockupPeriod: lockupPeriod,
                sqrtPriceImpactLimit: sqrtPriceImpactLimit,
                startingSqrtPriceX96: SQRT_50_X96
            })
        );

        vm.stopPrank();
    }

    function test_VaultBalanceIntegrityAfterIncreaseCardinality() public {
        uint16 targetCap = 1000;

        _setupPositions();

        (, , address vault, , , , , ) = perpManager.configs(perpId);
        (uint256 initialTotalEffectiveMargin, uint128 initialMaxPosId) = _calculateTotalEffectiveMargin();
        uint256 initialVaultBalance = TestnetUSDC(usdc).balanceOf(vault);

        console2.log("Initial vault balance:", initialVaultBalance);
        console2.log("Initial total effective margin:", initialTotalEffectiveMargin);
        console2.log("Initial max position ID checked:", initialMaxPosId);
        console2.log("");

        vm.startPrank(CALLER);
        perpManager.increaseCardinalityCap(perpId, targetCap);
        vm.stopPrank();

        (uint256 totalEffectiveMarginAfter, uint128 maxPosIdAfter) = _calculateTotalEffectiveMargin();
        uint256 vaultBalanceAfter = TestnetUSDC(usdc).balanceOf(vault);

        console2.log("Vault balance after:", vaultBalanceAfter);
        console2.log("Total effective margin after:", totalEffectiveMarginAfter);
        console2.log("Max position ID checked:", maxPosIdAfter);
        console2.log("");

        assertGe(vaultBalanceAfter, totalEffectiveMarginAfter, "Vault balance integrity error");
    }

    function _setupPositions() internal {
        deal(usdc, USER, 1000000e6);

        vm.startPrank(USER);
        TestnetUSDC(usdc).approve(address(perpManager), type(uint256).max);

        (PoolKey memory key, , , , , , , ) = perpManager.configs(perpId);

        int24 tickLower = -30;
        int24 tickUpper = 30;

        uint256 margin = 10000e6;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            margin
        );

        perpManager.openMakerPos(
            perpId,
            IPerpManager.OpenMakerPositionParams({
                margin: margin,
                liquidity: liquidity,
                tickLower: tickLower,
                tickUpper: tickUpper,
                maxAmt0In: type(uint128).max,
                maxAmt1In: type(uint128).max
            })
        );
        vm.stopPrank();
    }

    function _calculateTotalEffectiveMargin() internal returns (uint256 totalEffectiveMargin, uint128 maxPosId) {
        maxPosId = 0;

        for (uint128 i = 0; i < 1000; i++) {
            IPerpManager.Position memory pos = perpManager.position(perpId, i);

            if (pos.holder != address(0)) {
                maxPosId = i;

                (bool success, , , uint256 netMargin, ) = perpManager.quoteClosePosition(perpId, i);

                if (success) {
                    totalEffectiveMargin += netMargin;
                } else {
                    assert(false);
                }
            }
        }
    }
}
