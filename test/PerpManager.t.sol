// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";
import {OwnableBeacon} from "../src/beacons/ownable/OwnableBeacon.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {IBeacon} from "../src/interfaces/beacons/IBeacon.sol";

import {IFees} from "../src/interfaces/modules/IFees.sol";

import {ILockupPeriod} from "../src/interfaces/modules/ILockupPeriod.sol";
import {IMarginRatios} from "../src/interfaces/modules/IMarginRatios.sol";
import {ISqrtPriceImpactLimit} from "../src/interfaces/modules/ISqrtPriceImpactLimit.sol";
import {SCALE_1E6, UINT_Q96} from "../src/libraries/Constants.sol";
import {PerpLogic} from "../src/libraries/PerpLogic.sol";
import {Quoter} from "../src/libraries/Quoter.sol";
import {Fees} from "../src/modules/Fees.sol";
import {Lockup} from "../src/modules/Lockup.sol";
import {MarginRatios} from "../src/modules/MarginRatios.sol";
import {SqrtPriceImpactLimit} from "../src/modules/SqrtPriceImpactLimit.sol";
import {DeployPoolManager} from "./utils/DeployPoolManager.sol";
import {TestnetUSDC} from "./utils/TestnetUSDC.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolKey} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {console2} from "forge-std/console2.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract PerpManagerTest is DeployPoolManager {
    using SafeTransferLib for address;
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for *;

    uint160 public constant SQRT_40_X96 = 501082896750095862372827603139;
    uint160 public constant SQRT_49_X96 = 554597137599850363154807652352;
    uint160 public constant SQRT_51_X96 = 565802252120580303859488394989;
    uint160 public constant SQRT_60_X96 = 613698707936721051257405563936;

    IPoolManager public poolManager;

    address public usdc;
    PerpManager public perpManager;

    address public owner = makeAddr("owner");
    address public maker1 = makeAddr("maker1");
    address public maker2 = makeAddr("maker2");
    address public taker1 = makeAddr("taker1");
    address public taker2 = makeAddr("taker2");

    function setUp() public {
        poolManager = deployPoolManager();
        usdc = address(new TestnetUSDC());
        perpManager = new PerpManager(poolManager, usdc, owner);
    }

    function test_informal() public {
        vm.startPrank(owner);

        IBeacon beacon = new OwnableBeacon(owner, 50 * UINT_Q96, 100);

        IFees fees = new Fees();
        IMarginRatios marginRatios = new MarginRatios();
        ILockupPeriod lockupPeriod = new Lockup();
        ISqrtPriceImpactLimit sqrtPriceImpactLimit = new SqrtPriceImpactLimit();

        perpManager.registerFeesModule(fees);
        perpManager.registerMarginRatiosModule(marginRatios);
        perpManager.registerLockupPeriodModule(lockupPeriod);
        perpManager.registerSqrtPriceImpactLimitModule(sqrtPriceImpactLimit);

        PoolId perpId = perpManager.createPerp(
            IPerpManager.CreatePerpParams({
                beacon: address(beacon),
                fees: fees,
                marginRatios: marginRatios,
                lockupPeriod: lockupPeriod,
                sqrtPriceImpactLimit: sqrtPriceImpactLimit,
                startingSqrtPriceX96: 560227709747861399187319382275 // sqrt(50)
            })
        );

        (PoolKey memory key,,,,,,,) = perpManager.configs(perpId);
        int24 tickSpacing = key.tickSpacing;
        uint256 sqrtMarkPrice;
        uint256 markPriceX96;
        uint256 markPriceWAD;

        console2.log("perp created with id: ", vm.toString(PoolId.unwrap(perpId)));
        (sqrtMarkPrice,,,) = poolManager.getSlot0(perpId);
        markPriceX96 = sqrtMarkPrice.fullMulDiv(sqrtMarkPrice, UINT_Q96);
        markPriceWAD = markPriceX96.mulDiv(SCALE_1E6, UINT_Q96);
        console2.log("mark price %6e", markPriceWAD);
        console2.log("time: ", this.time());

        vm.stopPrank();

        // 1 hour passes
        skip(1 hours);
        console2.log("time: ", this.time());
        console2.log();

        vm.startPrank(maker1);

        int24 maker1TickLower = TickMath.getTickAtSqrtPrice(SQRT_40_X96);
        maker1TickLower = (maker1TickLower / tickSpacing) * tickSpacing;

        int24 maker1TickUpper = TickMath.getTickAtSqrtPrice(SQRT_51_X96);
        maker1TickUpper = (maker1TickUpper / tickSpacing) * tickSpacing;

        uint256 maker1Margin = 300e6;

        uint128 maker1Liq = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(maker1TickLower), TickMath.getSqrtPriceAtTick(maker1TickUpper), maker1Margin
        );

        deal(usdc, maker1, maker1Margin);
        usdc.safeApprove(address(perpManager), maker1Margin);

        uint128 maker1PosId = perpManager.openMakerPos(
            perpId,
            IPerpManager.OpenMakerPositionParams({
                margin: maker1Margin,
                liquidity: maker1Liq,
                tickLower: maker1TickLower,
                tickUpper: maker1TickUpper,
                maxAmt0In: type(uint128).max,
                maxAmt1In: type(uint128).max
            })
        );

        IPerpManager.Position memory maker1Pos = perpManager.position(perpId, maker1PosId);

        console2.log("maker position opened with posId ", maker1PosId);
        console2.log("margin %6e", maker1Pos.margin);
        console2.log("perpDelta %6e", maker1Pos.entryPerpDelta);
        console2.log("usdDelta %6e", maker1Pos.entryUsdDelta);
        (sqrtMarkPrice,,,) = poolManager.getSlot0(perpId);
        markPriceX96 = sqrtMarkPrice.fullMulDiv(sqrtMarkPrice, UINT_Q96);
        markPriceWAD = markPriceX96.mulDiv(SCALE_1E6, UINT_Q96);
        console2.log("mark price %6e", markPriceWAD);
        console2.log();

        vm.stopPrank();

        // 1 hour passes
        skip(1 hours);

        vm.startPrank(maker2);

        int24 maker2TickLower = TickMath.getTickAtSqrtPrice(SQRT_49_X96);
        maker2TickLower = (maker2TickLower / tickSpacing) * tickSpacing;

        int24 maker2TickUpper = TickMath.getTickAtSqrtPrice(SQRT_60_X96);
        maker2TickUpper = (maker2TickUpper / tickSpacing) * tickSpacing;

        uint256 maker2Margin = 300e6;

        uint128 maker2Liq = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(maker2TickLower), TickMath.getSqrtPriceAtTick(maker2TickUpper), maker2Margin
        );

        deal(usdc, maker2, maker2Margin);
        usdc.safeApprove(address(perpManager), maker2Margin);

        uint128 maker2PosId = perpManager.openMakerPos(
            perpId,
            IPerpManager.OpenMakerPositionParams({
                margin: maker2Margin,
                liquidity: maker2Liq,
                tickLower: maker2TickLower,
                tickUpper: maker2TickUpper,
                maxAmt0In: type(uint128).max,
                maxAmt1In: type(uint128).max
            })
        );

        IPerpManager.Position memory maker2Pos = perpManager.position(perpId, maker2PosId);

        console2.log("maker position opened with posId ", maker2PosId);
        console2.log("margin %6e", maker2Pos.margin);
        console2.log("perpDelta %6e", maker2Pos.entryPerpDelta);
        console2.log("usdDelta %6e", maker2Pos.entryUsdDelta);
        (sqrtMarkPrice,,,) = poolManager.getSlot0(perpId);
        markPriceX96 = sqrtMarkPrice.fullMulDiv(sqrtMarkPrice, UINT_Q96);
        markPriceWAD = markPriceX96.mulDiv(SCALE_1E6, UINT_Q96);
        console2.log("mark price %6e", markPriceWAD);
        console2.log();

        vm.stopPrank();

        // 1 hour passes
        skip(1 hours);
        console2.log("time: ", this.time());
        console2.log();

        vm.startPrank(taker1);

        uint256 taker1Margin = 50e6;

        deal(usdc, taker1, taker1Margin);
        usdc.safeApprove(address(perpManager), taker1Margin);

        uint128 taker1PosId = perpManager.openTakerPos(
            perpId,
            IPerpManager.OpenTakerPositionParams({
                isLong: true,
                margin: taker1Margin,
                levX96: 2 * UINT_Q96,
                unspecifiedAmountLimit: 0
            })
        );

        IPerpManager.Position memory taker1Pos = perpManager.position(perpId, taker1PosId);

        console2.log("taker position opened with posId ", taker1PosId);
        console2.log("margin %6e", taker1Pos.margin);
        console2.log("perpDelta %6e", taker1Pos.entryPerpDelta);
        console2.log("usdDelta %6e", taker1Pos.entryUsdDelta);
        (sqrtMarkPrice,,,) = poolManager.getSlot0(perpId);
        markPriceX96 = sqrtMarkPrice.fullMulDiv(sqrtMarkPrice, UINT_Q96);
        markPriceWAD = markPriceX96.mulDiv(SCALE_1E6, UINT_Q96);
        console2.log("mark price %6e", markPriceWAD);
        console2.log();

        vm.stopPrank();

        // 1 hour passes
        skip(1 hours);
        console2.log("time: ", this.time());
        console2.log();

        vm.startPrank(taker2);

        uint256 taker2Margin = 100e6;

        deal(usdc, taker2, taker2Margin);
        usdc.safeApprove(address(perpManager), taker2Margin);

        uint128 taker2PosId = perpManager.openTakerPos(
            perpId,
            IPerpManager.OpenTakerPositionParams({
                isLong: false,
                margin: taker2Margin,
                levX96: 2 * UINT_Q96,
                unspecifiedAmountLimit: type(uint128).max
            })
        );

        IPerpManager.Position memory taker2Pos = perpManager.position(perpId, taker2PosId);

        console2.log("taker position opened with posId ", taker2PosId);
        console2.log("margin %6e", taker2Pos.margin);
        console2.log("perpDelta %6e", taker2Pos.entryPerpDelta);
        console2.log("usdDelta %6e", taker2Pos.entryUsdDelta);
        (sqrtMarkPrice,,,) = poolManager.getSlot0(perpId);
        markPriceX96 = sqrtMarkPrice.fullMulDiv(sqrtMarkPrice, UINT_Q96);
        markPriceWAD = markPriceX96.mulDiv(SCALE_1E6, UINT_Q96);
        console2.log("mark price %6e", markPriceWAD);
        console2.log();

        vm.stopPrank();

        // 1 hour passes
        skip(1 hours);
        console2.log("time: ", this.time());
        console2.log();

        bool success;
        int256 pnl;
        int256 funding;
        uint256 effectiveMargin;
        bool wasLiquidated;

        vm.startPrank(maker1);
        (success, pnl, funding, effectiveMargin, wasLiquidated) = perpManager.quoteClosePosition(perpId, maker1PosId);
        console2.log("maker1 closePosition success: ", success);
        console2.log("maker1 closePosition pnl: %6e", pnl);
        console2.log("maker1 closePosition funding: %6e", funding);
        console2.log("maker1 closePosition effectiveMargin: %6e", effectiveMargin);
        console2.log("maker1 closePosition wasLiquidated: ", wasLiquidated);
        console2.log();
        vm.stopPrank();

        vm.startPrank(maker2);
        (success, pnl, funding, effectiveMargin, wasLiquidated) = perpManager.quoteClosePosition(perpId, maker2PosId);
        console2.log("maker2 closePosition success: ", success);
        console2.log("maker2 closePosition pnl: %6e", pnl);
        console2.log("maker2 closePosition funding: %6e", funding);
        console2.log("maker2 closePosition effectiveMargin: %6e", effectiveMargin);
        console2.log("maker2 closePosition wasLiquidated: ", wasLiquidated);
        console2.log();
        vm.stopPrank();

        vm.startPrank(taker1);
        (success, pnl, funding, effectiveMargin, wasLiquidated) = perpManager.quoteClosePosition(perpId, taker1PosId);
        console2.log("taker1 closePosition success: ", success);
        console2.log("taker1 closePosition pnl: %6e", pnl);
        console2.log("taker1 closePosition funding: %6e", funding);
        console2.log("taker1 closePosition effectiveMargin: %6e", effectiveMargin);
        console2.log("taker1 closePosition wasLiquidated: ", wasLiquidated);
        console2.log();
        vm.stopPrank();

        vm.startPrank(taker2);
        (success, pnl, funding, effectiveMargin, wasLiquidated) = perpManager.quoteClosePosition(perpId, taker2PosId);
        console2.log("taker2 closePosition success: ", success);
        console2.log("taker2 closePosition pnl: %6e", pnl);
        console2.log("taker2 closePosition funding: %6e", funding);
        console2.log("taker2 closePosition effectiveMargin: %6e", effectiveMargin);
        console2.log("taker2 closePosition wasLiquidated: ", wasLiquidated);
        console2.log();
        vm.stopPrank();
    }

    // this is a workaround via ir caching block.timestamp
    function time() external view returns (uint256) {
        return block.timestamp;
    }
}
