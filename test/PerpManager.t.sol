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
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {SignedMath} from "../src/libraries/SignedMath.sol";
import "../src/libraries/Constants.sol";

contract PerpManagerTest is DeployPoolManager {
    using SafeCastLib for *;

    uint256 public constant NUM_50_X96 = 3961408125713216879677197516800;

    uint160 public constant SQRT_1_X96 = 79228162514264337593543950336;
    uint160 public constant SQRT_40_X96 = 501082896750095862372827603139;
    uint160 public constant SQRT_49_X96 = 554597137599850363154807652352;
    uint160 public constant SQRT_50_X96 = 560227709747861399187319382275;
    uint160 public constant SQRT_51_X96 = 565802252120580303859488394989;
    uint160 public constant SQRT_60_X96 = 613698707936721051257405563936;
    uint160 public constant SQRT_100_X96 = 792281625142643375935439503360;

    uint16 public constant INITIAL_CARDINALITY_CAP = 50;
    uint256 public constant MAX_OPENING_MARGIN = 1000e6;

    address public immutable OWNER = makeAddr("owner");
    address public immutable MAKER1 = makeAddr("maker1");
    address public immutable MAKER2 = makeAddr("maker2");
    address public immutable TAKER1 = makeAddr("taker1");
    address public immutable TAKER2 = makeAddr("taker2");

    IPoolManager public poolManager;
    address public usdc;
    PerpManager public perpManager;
    PoolId public perpId;
    IPerpManager.PerpConfig public perpConfig;

    function setUp() public {
        poolManager = deployPoolManager();
        usdc = address(new TestnetUSDC());
        perpManager = new PerpManager(poolManager, usdc, OWNER);

        perpConfig.beacon = address(new OwnableBeacon(OWNER, NUM_50_X96, INITIAL_CARDINALITY_CAP));
        perpConfig.fees = new Fees();
        perpConfig.marginRatios = new MarginRatios();
        perpConfig.lockupPeriod = new Lockup();
        perpConfig.sqrtPriceImpactLimit = new SqrtPriceImpactLimit();

        vm.startPrank(OWNER);

        perpManager.registerFeesModule(perpConfig.fees);
        perpManager.registerMarginRatiosModule(perpConfig.marginRatios);
        perpManager.registerLockupPeriodModule(perpConfig.lockupPeriod);
        perpManager.registerSqrtPriceImpactLimitModule(perpConfig.sqrtPriceImpactLimit);

        perpId = perpManager.createPerp(
            IPerpManager.CreatePerpParams({
                beacon: perpConfig.beacon,
                fees: perpConfig.fees,
                marginRatios: perpConfig.marginRatios,
                lockupPeriod: perpConfig.lockupPeriod,
                sqrtPriceImpactLimit: perpConfig.sqrtPriceImpactLimit,
                startingSqrtPriceX96: SQRT_50_X96
            })
        );

        (PoolKey memory key,address creator,address vault,,,,,) = perpManager.configs(perpId);

        perpConfig.key = key;
        perpConfig.creator = creator;
        perpConfig.vault = vault;

        console2.log("PerpManager: ", address(perpManager));
        console2.log("Beacon: ", perpConfig.beacon);
        console2.log("Fees: ", address(perpConfig.fees));
        console2.log("MarginRatios: ", address(perpConfig.marginRatios));
        console2.log("LockupPeriod: ", address(perpConfig.lockupPeriod));
        console2.log("SqrtPriceImpactLimit: ", address(perpConfig.sqrtPriceImpactLimit));
        console2.log();

        console2.log("PerpId: ", vm.toString(PoolId.unwrap(perpId)));
        printMarkAndIndex();
        console2.log();

        vm.stopPrank();
    }

    function testFuzz_OpenMakerPosition(uint256 margin, int24 tickLower, int24 tickUpper) public {
        margin = bound(margin, MIN_OPENING_MARGIN, MAX_OPENING_MARGIN);
        console2.log("Margin: %6e", margin);

        int24 tickAtSqrtPrice = TickMath.getTickAtSqrtPrice(SQRT_50_X96);
        (PoolKey memory key,,,,,,,) = perpManager.configs(perpId);
        int24 tickSpacing = key.tickSpacing;

        tickLower = bound(tickLower, TickMath.getTickAtSqrtPrice(SQRT_1_X96), tickAtSqrtPrice).toInt24();
        tickUpper = bound(tickUpper, tickAtSqrtPrice, TickMath.getTickAtSqrtPrice(SQRT_100_X96)).toInt24();

        tickLower = (tickLower / tickSpacing) * tickSpacing - tickSpacing;
        tickUpper = (tickUpper / tickSpacing) * tickSpacing + tickSpacing;
        console2.log("Tick Lower: ", tickLower);
        console2.log("Tick Upper: ", tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), margin
        );
        vm.assume(liquidity != 0);
        console2.log("Liquidity: ", liquidity);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_50_X96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
        console2.log("Amount0: %6e", amount0);
        console2.log("Amount1: %6e", amount1);

        IPerpManager.OpenMakerPositionParams memory params = IPerpManager.OpenMakerPositionParams({
            margin: margin,
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper,
            maxAmt0In: type(uint128).max,
            maxAmt1In: type(uint128).max
        });

        deal(usdc, MAKER1, margin);

        vm.startPrank(MAKER1);

        SafeTransferLib.safeApprove(usdc, address(perpManager), margin);
        uint128 makerPosId = perpManager.openMakerPos(perpId, params);

        vm.stopPrank();

        assertGt(makerPosId, 0);
        IPerpManager.Position memory makerPos = perpManager.position(perpId, makerPosId);

        assertEq(makerPos.holder, MAKER1);

        assertGe(makerPos.margin, MIN_OPENING_MARGIN);
        assertLe(makerPos.margin, MAX_OPENING_MARGIN);
        assertEq(makerPos.margin, margin);

        assertEq(makerPos.entryPerpDelta, -int256(amount0) - 1);
        assertEq(makerPos.entryUsdDelta, -int256(amount1) - 1);

        assertEq(makerPos.entryCumlFundingX96, 0); // TODO: change to check its the same as before opening
        assertEq(makerPos.entryCumlBadDebtX96, 0); // TODO: change to check its the same as before opening

        // TODO: add liquidation margin ratio assert

        assertEq(makerPos.makerDetails.unlockTimestamp, this.time() + perpConfig.lockupPeriod.lockupPeriod(perpConfig));

        assertEq(makerPos.makerDetails.tickLower, tickLower);
        assertEq(makerPos.makerDetails.tickUpper, tickUpper);

        assertEq(makerPos.makerDetails.liquidity, liquidity);

        // TODO: change to check these are the same as before opening
        assertEq(makerPos.makerDetails.entryCumlFundingBelowX96, 0);
        assertEq(makerPos.makerDetails.entryCumlFundingWithinX96, 0);
        assertEq(makerPos.makerDetails.entryCumlFundingDivSqrtPWithinX96, 0);

        console2.log("Maker Position ", makerPosId);
        printMakerPosition(makerPos);
        console2.log();
    }

    // function test_informal() public {
    //     vm.startPrank(owner);

    //     IBeacon beacon = new OwnableBeacon(owner, 50 * UINT_Q96, 100);

    //     IFees fees = new Fees();
    //     IMarginRatios marginRatios = new MarginRatios();
    //     ILockupPeriod lockupPeriod = new Lockup();
    //     ISqrtPriceImpactLimit sqrtPriceImpactLimit = new SqrtPriceImpactLimit();

    //     perpManager.registerFeesModule(fees);
    //     perpManager.registerMarginRatiosModule(marginRatios);
    //     perpManager.registerLockupPeriodModule(lockupPeriod);
    //     perpManager.registerSqrtPriceImpactLimitModule(sqrtPriceImpactLimit);

    //     PoolId perpId = perpManager.createPerp(
    //         IPerpManager.CreatePerpParams({
    //             beacon: address(beacon),
    //             fees: fees,
    //             marginRatios: marginRatios,
    //             lockupPeriod: lockupPeriod,
    //             sqrtPriceImpactLimit: sqrtPriceImpactLimit,
    //             startingSqrtPriceX96: 560227709747861399187319382275 // sqrt(50)
    //         })
    //     );

    //     (PoolKey memory key,,,,,,,) = perpManager.configs(perpId);
    //     int24 tickSpacing = key.tickSpacing;
    //     uint256 sqrtMarkPrice;
    //     uint256 markPriceX96;
    //     uint256 markPriceWAD;

    //     console2.log("perp created with id: ", vm.toString(PoolId.unwrap(perpId)));
    //     (sqrtMarkPrice,,,) = poolManager.getSlot0(perpId);
    //     markPriceX96 = sqrtMarkPrice.fullMulDiv(sqrtMarkPrice, UINT_Q96);
    //     markPriceWAD = markPriceX96.mulDiv(SCALE_1E6, UINT_Q96);
    //     console2.log("mark price %6e", markPriceWAD);
    //     console2.log("time: ", this.time());

    //     vm.stopPrank();

    //     // 1 hour passes
    //     skip(1 hours);
    //     console2.log("time: ", this.time());
    //     console2.log();

    //     vm.startPrank(maker1);

    //     int24 maker1TickLower = TickMath.getTickAtSqrtPrice(SQRT_40_X96);
    //     maker1TickLower = (maker1TickLower / tickSpacing) * tickSpacing;

    //     int24 maker1TickUpper = TickMath.getTickAtSqrtPrice(SQRT_51_X96);
    //     maker1TickUpper = (maker1TickUpper / tickSpacing) * tickSpacing;

    //     uint256 maker1Margin = 300e6;

    //     uint128 maker1Liq = LiquidityAmounts.getLiquidityForAmount1(
    //         TickMath.getSqrtPriceAtTick(maker1TickLower), TickMath.getSqrtPriceAtTick(maker1TickUpper), maker1Margin
    //     );

    //     deal(usdc, maker1, maker1Margin);
    //     usdc.safeApprove(address(perpManager), maker1Margin);

    //     uint128 maker1PosId = perpManager.openMakerPos(
    //         perpId,
    //         IPerpManager.OpenMakerPositionParams({
    //             margin: maker1Margin,
    //             liquidity: maker1Liq,
    //             tickLower: maker1TickLower,
    //             tickUpper: maker1TickUpper,
    //             maxAmt0In: type(uint128).max,
    //             maxAmt1In: type(uint128).max
    //         })
    //     );

    //     IPerpManager.Position memory maker1Pos = perpManager.position(perpId, maker1PosId);

    //     console2.log("maker position opened with posId ", maker1PosId);
    //     console2.log("margin %6e", maker1Pos.margin);
    //     console2.log("perpDelta %6e", maker1Pos.entryPerpDelta);
    //     console2.log("usdDelta %6e", maker1Pos.entryUsdDelta);
    //     (sqrtMarkPrice,,,) = poolManager.getSlot0(perpId);
    //     markPriceX96 = sqrtMarkPrice.fullMulDiv(sqrtMarkPrice, UINT_Q96);
    //     markPriceWAD = markPriceX96.mulDiv(SCALE_1E6, UINT_Q96);
    //     console2.log("mark price %6e", markPriceWAD);
    //     console2.log();

    //     vm.stopPrank();

    //     // 1 hour passes
    //     skip(1 hours);

    //     vm.startPrank(maker2);

    //     int24 maker2TickLower = TickMath.getTickAtSqrtPrice(SQRT_49_X96);
    //     maker2TickLower = (maker2TickLower / tickSpacing) * tickSpacing;

    //     int24 maker2TickUpper = TickMath.getTickAtSqrtPrice(SQRT_60_X96);
    //     maker2TickUpper = (maker2TickUpper / tickSpacing) * tickSpacing;

    //     uint256 maker2Margin = 300e6;

    //     uint128 maker2Liq = LiquidityAmounts.getLiquidityForAmount1(
    //         TickMath.getSqrtPriceAtTick(maker2TickLower), TickMath.getSqrtPriceAtTick(maker2TickUpper), maker2Margin
    //     );

    //     deal(usdc, maker2, maker2Margin);
    //     usdc.safeApprove(address(perpManager), maker2Margin);

    //     uint128 maker2PosId = perpManager.openMakerPos(
    //         perpId,
    //         IPerpManager.OpenMakerPositionParams({
    //             margin: maker2Margin,
    //             liquidity: maker2Liq,
    //             tickLower: maker2TickLower,
    //             tickUpper: maker2TickUpper,
    //             maxAmt0In: type(uint128).max,
    //             maxAmt1In: type(uint128).max
    //         })
    //     );

    //     IPerpManager.Position memory maker2Pos = perpManager.position(perpId, maker2PosId);

    //     console2.log("maker position opened with posId ", maker2PosId);
    //     console2.log("margin %6e", maker2Pos.margin);
    //     console2.log("perpDelta %6e", maker2Pos.entryPerpDelta);
    //     console2.log("usdDelta %6e", maker2Pos.entryUsdDelta);
    //     (sqrtMarkPrice,,,) = poolManager.getSlot0(perpId);
    //     markPriceX96 = sqrtMarkPrice.fullMulDiv(sqrtMarkPrice, UINT_Q96);
    //     markPriceWAD = markPriceX96.mulDiv(SCALE_1E6, UINT_Q96);
    //     console2.log("mark price %6e", markPriceWAD);
    //     console2.log();

    //     vm.stopPrank();

    //     // 1 hour passes
    //     skip(1 hours);
    //     console2.log("time: ", this.time());
    //     console2.log();

    //     vm.startPrank(taker1);

    //     uint256 taker1Margin = 50e6;

    //     deal(usdc, taker1, taker1Margin);
    //     usdc.safeApprove(address(perpManager), taker1Margin);

    //     uint128 taker1PosId = perpManager.openTakerPos(
    //         perpId,
    //         IPerpManager.OpenTakerPositionParams({
    //             isLong: true,
    //             margin: taker1Margin,
    //             levX96: 2 * UINT_Q96,
    //             unspecifiedAmountLimit: 0
    //         })
    //     );

    //     IPerpManager.Position memory taker1Pos = perpManager.position(perpId, taker1PosId);

    //     console2.log("taker position opened with posId ", taker1PosId);
    //     console2.log("margin %6e", taker1Pos.margin);
    //     console2.log("perpDelta %6e", taker1Pos.entryPerpDelta);
    //     console2.log("usdDelta %6e", taker1Pos.entryUsdDelta);
    //     (sqrtMarkPrice,,,) = poolManager.getSlot0(perpId);
    //     markPriceX96 = sqrtMarkPrice.fullMulDiv(sqrtMarkPrice, UINT_Q96);
    //     markPriceWAD = markPriceX96.mulDiv(SCALE_1E6, UINT_Q96);
    //     console2.log("mark price %6e", markPriceWAD);
    //     console2.log();

    //     vm.stopPrank();

    //     // 1 hour passes
    //     skip(1 hours);
    //     console2.log("time: ", this.time());
    //     console2.log();

    //     vm.startPrank(taker2);

    //     uint256 taker2Margin = 100e6;

    //     deal(usdc, taker2, taker2Margin);
    //     usdc.safeApprove(address(perpManager), taker2Margin);

    //     uint128 taker2PosId = perpManager.openTakerPos(
    //         perpId,
    //         IPerpManager.OpenTakerPositionParams({
    //             isLong: false,
    //             margin: taker2Margin,
    //             levX96: 2 * UINT_Q96,
    //             unspecifiedAmountLimit: type(uint128).max
    //         })
    //     );

    //     IPerpManager.Position memory taker2Pos = perpManager.position(perpId, taker2PosId);

    //     console2.log("taker position opened with posId ", taker2PosId);
    //     console2.log("margin %6e", taker2Pos.margin);
    //     console2.log("perpDelta %6e", taker2Pos.entryPerpDelta);
    //     console2.log("usdDelta %6e", taker2Pos.entryUsdDelta);
    //     (sqrtMarkPrice,,,) = poolManager.getSlot0(perpId);
    //     markPriceX96 = sqrtMarkPrice.fullMulDiv(sqrtMarkPrice, UINT_Q96);
    //     markPriceWAD = markPriceX96.mulDiv(SCALE_1E6, UINT_Q96);
    //     console2.log("mark price %6e", markPriceWAD);
    //     console2.log();

    //     vm.stopPrank();

    //     // 1 hour passes
    //     skip(1 hours);
    //     console2.log("time: ", this.time());
    //     console2.log();

    //     bool success;
    //     int256 pnl;
    //     int256 funding;
    //     uint256 effectiveMargin;
    //     bool wasLiquidated;

    //     vm.startPrank(maker1);
    //     (success, pnl, funding, effectiveMargin, wasLiquidated) = perpManager.quoteClosePosition(perpId, maker1PosId);
    //     console2.log("maker1 closePosition success: ", success);
    //     console2.log("maker1 closePosition pnl: %6e", pnl);
    //     console2.log("maker1 closePosition funding: %6e", funding);
    //     console2.log("maker1 closePosition effectiveMargin: %6e", effectiveMargin);
    //     console2.log("maker1 closePosition wasLiquidated: ", wasLiquidated);
    //     console2.log();
    //     vm.stopPrank();

    //     vm.startPrank(maker2);
    //     (success, pnl, funding, effectiveMargin, wasLiquidated) = perpManager.quoteClosePosition(perpId, maker2PosId);
    //     console2.log("maker2 closePosition success: ", success);
    //     console2.log("maker2 closePosition pnl: %6e", pnl);
    //     console2.log("maker2 closePosition funding: %6e", funding);
    //     console2.log("maker2 closePosition effectiveMargin: %6e", effectiveMargin);
    //     console2.log("maker2 closePosition wasLiquidated: ", wasLiquidated);
    //     console2.log();
    //     vm.stopPrank();

    //     vm.startPrank(taker1);
    //     (success, pnl, funding, effectiveMargin, wasLiquidated) = perpManager.quoteClosePosition(perpId, taker1PosId);
    //     console2.log("taker1 closePosition success: ", success);
    //     console2.log("taker1 closePosition pnl: %6e", pnl);
    //     console2.log("taker1 closePosition funding: %6e", funding);
    //     console2.log("taker1 closePosition effectiveMargin: %6e", effectiveMargin);
    //     console2.log("taker1 closePosition wasLiquidated: ", wasLiquidated);
    //     console2.log();
    //     vm.stopPrank();

    //     vm.startPrank(taker2);
    //     (success, pnl, funding, effectiveMargin, wasLiquidated) = perpManager.quoteClosePosition(perpId, taker2PosId);
    //     console2.log("taker2 closePosition success: ", success);
    //     console2.log("taker2 closePosition pnl: %6e", pnl);
    //     console2.log("taker2 closePosition funding: %6e", funding);
    //     console2.log("taker2 closePosition effectiveMargin: %6e", effectiveMargin);
    //     console2.log("taker2 closePosition wasLiquidated: ", wasLiquidated);
    //     console2.log();
    //     vm.stopPrank();
    // }

    // this is a workaround via ir caching block.timestamp
    function time() external view returns (uint256) {
        return block.timestamp;
    }

    function printMarkAndIndex() public view {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, perpId);
        uint256 priceX96 = FixedPointMathLib.fullMulDiv(sqrtPriceX96, sqrtPriceX96, UINT_Q96);
        uint256 priceWAD = FixedPointMathLib.mulDiv(priceX96, SCALE_1E6, UINT_Q96);
        console2.log("Price: %6e", priceWAD);

        uint256 indexPriceX96 = IBeacon(perpConfig.beacon).data();
        console2.log("Index Price: %6e", X96toE6(indexPriceX96));
    }

    function X96toE6(uint256 x96) public pure returns (uint256) {
        return FixedPointMathLib.mulDiv(x96, SCALE_1E6, UINT_Q96);
    }

    function X96toE6(int256 x96) public pure returns (int256) {
        return SignedMath.fullMulDivSigned(x96, SCALE_1E6.toInt256(), UINT_Q96);
    }

    function printMakerPosition(IPerpManager.Position memory makerPos) public view {
        console2.log("Holder: ", makerPos.holder);
        console2.log("Margin: %6e", makerPos.margin);
        console2.log("Entry Perp Delta: %6e", makerPos.entryPerpDelta);
        console2.log("Entry Usd Delta: %6e", makerPos.entryUsdDelta);
        console2.log("Entry Cuml Funding: %6e", X96toE6(makerPos.entryCumlFundingX96));
        console2.log("Unlock Timestamp: ", makerPos.makerDetails.unlockTimestamp);
        console2.log("Tick Lower: ", makerPos.makerDetails.tickLower);
        console2.log("Tick Upper: ", makerPos.makerDetails.tickUpper);
        console2.log("Liquidity: ", makerPos.makerDetails.liquidity);
        console2.log("Entry Cuml Funding Below: %6e", X96toE6(makerPos.makerDetails.entryCumlFundingBelowX96));
        console2.log("Entry Cuml Funding Within: %6e", X96toE6(makerPos.makerDetails.entryCumlFundingWithinX96));
        console2.log("Entry Cuml Funding Div Sqrt P Within: %6e", X96toE6(makerPos.makerDetails.entryCumlFundingDivSqrtPWithinX96));
    }
}
