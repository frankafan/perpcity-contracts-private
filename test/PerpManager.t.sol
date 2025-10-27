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
    using FixedPointMathLib for *;

    uint256 public constant NUM_50_X96 = 3961408125713216879677197516800;

    uint160 public constant SQRT_1_X96 = 79228162514264337593543950336;
    uint160 public constant SQRT_40_X96 = 501082896750095862372827603139;
    uint160 public constant SQRT_49_X96 = 554597137599850363154807652352;
    uint160 public constant SQRT_50_X96 = 560227709747861399187319382275;
    uint160 public constant SQRT_51_X96 = 565802252120580303859488394989;
    uint160 public constant SQRT_60_X96 = 613698707936721051257405563936;
    uint160 public constant SQRT_100_X96 = 792281625142643375935439503360;

    uint16 public constant INITIAL_CARDINALITY_CAP = 50;
    uint128 public constant MAX_OPENING_MARGIN = 1000e6;
    uint256 public constant MIN_NOTIONAL_TAKER_VALUE = 12e6;
    uint256 public constant MAX_NOTIONAL_TAKER_VALUE = 200e6;

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
        tickLower = bound(tickLower, TickMath.getTickAtSqrtPrice(SQRT_1_X96), tickAtSqrtPrice).toInt24();
        tickUpper = bound(tickUpper, tickAtSqrtPrice, TickMath.getTickAtSqrtPrice(SQRT_100_X96)).toInt24();

        (PoolKey memory key,,,,,,,) = perpManager.configs(perpId);
        int24 tickSpacing = key.tickSpacing;
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

        // TODO: change to check these are the same as before opening
        assertEq(makerPos.entryCumlFundingX96, 0); 
        assertEq(makerPos.entryCumlBadDebtX96, 0); 

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

    function testFuzz_OpenTakerPosition(uint24 marginRatio, uint256 notional, bool isLong) public {
        /* MAKER POSITION */

        uint128 makerMargin = MAX_OPENING_MARGIN;
        console2.log("Maker Margin: %6e", makerMargin);

        int24 tickLower = TickMath.getTickAtSqrtPrice(SQRT_1_X96);
        int24 tickUpper = TickMath.getTickAtSqrtPrice(SQRT_100_X96);

        (PoolKey memory key,,,,,,,) = perpManager.configs(perpId);
        int24 tickSpacing = key.tickSpacing;
        tickLower = (tickLower / tickSpacing) * tickSpacing - tickSpacing;
        tickUpper = (tickUpper / tickSpacing) * tickSpacing + tickSpacing;
        console2.log("Maker Tick Lower: ", tickLower);
        console2.log("Maker Tick Upper: ", tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), makerMargin
        );
        console2.log("Maker Liquidity: ", liquidity);

        IPerpManager.OpenMakerPositionParams memory makerParams = IPerpManager.OpenMakerPositionParams({
            margin: makerMargin,
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper,
            maxAmt0In: type(uint128).max,
            maxAmt1In: type(uint128).max
        });

        deal(usdc, MAKER1, makerMargin);

        vm.startPrank(MAKER1);

        SafeTransferLib.safeApprove(usdc, address(perpManager), makerMargin);
        uint128 makerPosId = perpManager.openMakerPos(perpId, makerParams);

        vm.stopPrank();

        console2.log("Maker Position ", makerPosId);
        console2.log();

        /* TAKER POSITION */

        (uint24 minMarginRatio, uint24 maxMarginRatio, uint24 liqMarginRatio) = perpConfig.marginRatios.marginRatios(perpConfig, false);
        console2.log("minMarginRatio: %6e", minMarginRatio);
        console2.log("maxMarginRatio: %6e", maxMarginRatio);
        console2.log("liqMarginRatio: %6e", liqMarginRatio);
        marginRatio = bound(marginRatio, minMarginRatio, maxMarginRatio).toUint24();
        console2.log("Taker Margin Ratio: %6e", marginRatio);

        uint256 levX96 = FixedPointMathLib.fullMulDiv(UINT_Q96, SCALE_1E6, marginRatio);
        console2.log("levX96: %6e", x96toE6(levX96));

        notional = bound(notional, MIN_NOTIONAL_TAKER_VALUE, MAX_NOTIONAL_TAKER_VALUE);
        console2.log("Taker Notional: %6e", notional);

        uint128 margin = FixedPointMathLib.fullMulDiv(notional, marginRatio, SCALE_1E6).toUint128();
        console2.log("Taker Margin: %6e", margin);

        IPerpManager.OpenTakerPositionParams memory takerParams = IPerpManager.OpenTakerPositionParams({
            isLong: isLong,
            margin: margin,
            levX96: levX96,
            unspecifiedAmountLimit: isLong ? 0 : type(uint128).max
        });

        deal(usdc, TAKER1, margin);

        vm.startPrank(TAKER1);

        SafeTransferLib.safeApprove(usdc, address(perpManager), margin);
        uint128 takerPosId = perpManager.openTakerPos(perpId, takerParams);

        vm.stopPrank();

        assertGt(takerPosId, makerPosId);
        IPerpManager.Position memory takerPos = perpManager.position(perpId, takerPosId);

        assertEq(takerPos.holder, TAKER1);

        assertGe(takerPos.margin, MIN_OPENING_MARGIN);
        assertLe(takerPos.margin, MAX_OPENING_MARGIN);
        assertLe(takerPos.margin, margin); // TODO: more specific check calculating fees

        if (isLong) assertGt(takerPos.entryPerpDelta, 0);
        else assertLt(takerPos.entryPerpDelta, 0);
        // TODO: more specific check calculating fees
        assertLe(takerPos.entryUsdDelta.abs(), notional);

        // TODO: change to check these are the same as before opening
        assertEq(takerPos.entryCumlFundingX96, 0);
        assertEq(takerPos.entryCumlBadDebtX96, 0);

        assertEq(takerPos.liquidationMarginRatio, liqMarginRatio);

        assertEq(takerPos.makerDetails.unlockTimestamp, 0);
        assertEq(takerPos.makerDetails.tickLower, 0);
        assertEq(takerPos.makerDetails.tickUpper, 0);
        assertEq(takerPos.makerDetails.liquidity, 0);
        assertEq(takerPos.makerDetails.entryCumlFundingBelowX96, 0);
        assertEq(takerPos.makerDetails.entryCumlFundingWithinX96, 0);
        assertEq(takerPos.makerDetails.entryCumlFundingDivSqrtPWithinX96, 0);

        console2.log("Taker Position ", takerPosId);
        printTakerPosition(takerPos);
        console2.log();
    }

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
        console2.log("Index Price: %6e", x96toE6(indexPriceX96));
    }

    function x96toE6(uint256 x96) public pure returns (uint256) {
        return FixedPointMathLib.mulDiv(x96, SCALE_1E6, UINT_Q96);
    }

    function x96toE6(int256 x96) public pure returns (int256) {
        return SignedMath.fullMulDivSigned(x96, SCALE_1E6.toInt256(), UINT_Q96);
    }

    function printMakerPosition(IPerpManager.Position memory makerPos) public pure {
        printTakerPosition(makerPos);
        console2.log("Unlock Timestamp: ", makerPos.makerDetails.unlockTimestamp);
        console2.log("Tick Lower: ", makerPos.makerDetails.tickLower);
        console2.log("Tick Upper: ", makerPos.makerDetails.tickUpper);
        console2.log("Liquidity: ", makerPos.makerDetails.liquidity);
        console2.log("Entry Cuml Funding Below: %6e", x96toE6(makerPos.makerDetails.entryCumlFundingBelowX96));
        console2.log("Entry Cuml Funding Within: %6e", x96toE6(makerPos.makerDetails.entryCumlFundingWithinX96));
        console2.log("Entry Cuml Funding Div Sqrt P Within: %6e", x96toE6(makerPos.makerDetails.entryCumlFundingDivSqrtPWithinX96));
    }

    function printTakerPosition(IPerpManager.Position memory takerPos) public pure {
        console2.log("Holder: ", takerPos.holder);
        console2.log("Margin: %6e", takerPos.margin);
        console2.log("Entry Perp Delta: %6e", takerPos.entryPerpDelta);
        console2.log("Entry Usd Delta: %6e", takerPos.entryUsdDelta);
        console2.log("Entry Cuml Funding: %6e", x96toE6(takerPos.entryCumlFundingX96));
        console2.log("Entry Cuml Bad Debt: %6e", x96toE6(takerPos.entryCumlBadDebtX96));
        console2.log("Liquidation Margin Ratio: %6e", takerPos.liquidationMarginRatio);
    }
}
