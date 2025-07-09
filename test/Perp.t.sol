// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import { TestnetUSDC } from "../src/testnet/TestnetUSDC.sol";
import { TestnetBeacon } from "../src/testnet/TestnetBeacon.sol";
import { PerpHook } from "../src/PerpHook.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { EasyPosm } from "./utils/EasyPosm.sol";
import { Fixtures } from "./utils/Fixtures.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { UniversalRouter } from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import { RouterParameters } from "@uniswap/universal-router/contracts/types/RouterParameters.sol";
import { Positions } from "../src/libraries/Positions.sol";
import { Perp } from "../src/libraries/Perp.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { TokenMath } from "../src/libraries/TokenMath.sol";
import { ExternalContracts } from "../src/libraries/ExternalContracts.sol";
import { IPermit2 } from "@uniswap/permit2/src/interfaces/IPermit2.sol";

contract PerpTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;
    using SafeCast for *;
    using TokenMath for uint128;

    UniversalRouter router;
    TestnetUSDC usdc;
    TestnetBeacon beacon;
    PerpHook perpHook;
    PoolId poolId;

    uint160 constant SQRT_5_X96 = 177_159_557_114_295_718_903_631_839_232; // 2 ** 96 * sqrt(5)
    uint160 constant SQRT_50_X96 = 560_227_709_747_861_419_891_227_623_424; // 2 ** 96 * sqrt(50)
    uint160 constant SQRT_95_X96 = 772_220_606_343_637_126_322_442_993_664; // 2 ** 96 * sqrt(95)

    uint256 constant NUMBER_45_X96 = 45 * FixedPoint96.Q96;
    uint256 constant NUMBER_50_X96 = 50 * FixedPoint96.Q96;
    uint256 constant NUMBER_55_X96 = 55 * FixedPoint96.Q96;

    uint24 constant TRADING_FEE = 5000; // 0.5%
    uint128 constant MIN_MARGIN = 0;
    uint128 constant MAX_MARGIN = 1000e6; // 1000 USDC
    uint128 constant MIN_OPENING_LEVERAGE_X96 = 0;
    uint128 immutable MAX_OPENING_LEVERAGE_X96 = (10 * FixedPoint96.Q96).toUint128(); // 10x
    uint128 immutable LIQUIDATION_LEVERAGE_X96 = (10 * FixedPoint96.Q96).toUint128(); // 10x
    uint128 immutable LIQUIDATION_FEE_X96 = (1 * FixedPoint96.Q96 / 100).toUint128(); // 1%
    uint128 immutable LIQUIDATION_FEE_SPLIT_X96 = (50 * FixedPoint96.Q96 / 100).toUint128(); // 50%
    int128 constant FUNDING_INTERVAL = 1 days;
    int24 constant TICK_SPACING = 30;
    uint160 constant STARTING_SQRT_PRICE_X96 = SQRT_50_X96;

    address maker1 = vm.addr(1);
    address taker1 = vm.addr(2);
    address taker2 = vm.addr(3);
    address beaconOwner = vm.addr(4);

    function setUp() public {
        // creates the pool manager, utility routers
        deployFreshManagerAndRouters();

        deployPosm(manager);

        RouterParameters memory params = RouterParameters({
            permit2: address(permit2),
            weth9: address(0),
            v2Factory: address(0),
            v3Factory: address(0),
            pairInitCodeHash: bytes32(0),
            poolInitCodeHash: bytes32(0),
            v4PoolManager: address(manager),
            v3NFTPositionManager: address(0),
            v4PositionManager: address(posm)
        });
        router = new UniversalRouter(params);

        usdc = new TestnetUSDC();

        ExternalContracts.Contracts memory externalContracts = ExternalContracts.Contracts({
            poolManager: manager,
            router: router,
            positionManager: posm,
            permit2: IPermit2(address(permit2)),
            usdc: usdc
        });

        beacon = new TestnetBeacon(beaconOwner);

        vm.prank(beaconOwner);
        beacon.updateData(bytes(""), bytes(abi.encode(NUMBER_50_X96)));
        vm.stopPrank();

        // Deploy the hook to an address with the correct flag
        address flags = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        // Add all the necessary constructor arguments from the hook
        bytes memory constructorArgs = abi.encode(externalContracts);
        deployCodeTo("PerpHook.sol:PerpHook", constructorArgs, flags);
        perpHook = PerpHook(flags);

        Perp.CreatePerpParams memory createPerpParams = Perp.CreatePerpParams({
            beacon: address(beacon),
            tradingFee: TRADING_FEE,
            minMargin: MIN_MARGIN,
            maxMargin: MAX_MARGIN,
            minOpeningLeverageX96: MIN_OPENING_LEVERAGE_X96,
            maxOpeningLeverageX96: MAX_OPENING_LEVERAGE_X96,
            liquidationLeverageX96: LIQUIDATION_LEVERAGE_X96,
            liquidationFeeX96: LIQUIDATION_FEE_X96,
            liquidationFeeSplitX96: LIQUIDATION_FEE_SPLIT_X96,
            fundingInterval: FUNDING_INTERVAL,
            tickSpacing: TICK_SPACING,
            startingSqrtPriceX96: STARTING_SQRT_PRICE_X96
        });

        poolId = perpHook.createPerp(createPerpParams);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        console2.log("perp created");
        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("priceX96", Perp.sqrtPriceX96ToPriceX96(sqrtPriceX96));
        console2.log("current tick", tick);
        console2.log();
    }

    function testInformal() public {
        vm.startPrank(maker1);

        usdc.mint(maker1, 100e6);
        usdc.approve(address(perpHook), 100e6);

        int24 tickLower = TickMath.getTickAtSqrtPrice(SQRT_5_X96);
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING; // round to the nearest ticks

        int24 tickUpper = TickMath.getTickAtSqrtPrice(SQRT_95_X96);
        tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING; // round to the nearest tick

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(SQRT_5_X96, SQRT_95_X96, 1000e18);

        Perp.OpenMakerPositionParams memory openMakerPositionParams = Perp.OpenMakerPositionParams({
            margin: 100e6,
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper
        });

        uint256 makerPosId = perpHook.openMakerPosition(poolId, openMakerPositionParams);

        Positions.MakerInfo memory makerPos = perpHook.getMakerPosition(poolId, makerPosId);

        (uint160 startingSqrtPriceX96,,,) = manager.getSlot0(poolId);

        uint256 notional = Perp.calculateMakerNotional(startingSqrtPriceX96, SQRT_5_X96, SQRT_95_X96, liquidity);

        uint256 makerLeverageX96 = FullMath.mulDiv(notional, FixedPoint96.Q96, makerPos.margin.scale6To18());

        console2.log("maker opens position with id", makerPosId);
        console2.log("holder", makerPos.holder);
        console2.log("tickLower", makerPos.tickLower);
        console2.log("tickUpper", makerPos.tickUpper);
        console2.log("sqrtPriceLowerX96", makerPos.sqrtPriceLowerX96);
        console2.log("sqrtPriceUpperX96", makerPos.sqrtPriceUpperX96);
        console2.log("priceLowerX96", Perp.sqrtPriceX96ToPriceX96(makerPos.sqrtPriceLowerX96));
        console2.log("priceUpperX96", Perp.sqrtPriceX96ToPriceX96(makerPos.sqrtPriceUpperX96));
        console2.log("margin", makerPos.margin);
        console2.log("liquidity", makerPos.liquidity);
        console2.log("perpsBorrowed", makerPos.perpsBorrowed);
        console2.log("usdBorrowed", makerPos.usdBorrowed);
        console2.log("notional", notional);
        console2.log("leverageX96", makerLeverageX96);
        console2.log("entryTwPremiumX96", makerPos.entryTwPremiumX96);
        console2.log("entryTwPremiumDivBySqrtPriceX96", makerPos.entryTwPremiumDivBySqrtPriceX96);
        console2.log();

        vm.stopPrank();
        vm.startPrank(taker1);

        usdc.mint(taker1, 20e6);
        usdc.approve(address(perpHook), 20e6);

        uint256 taker1LeverageX96 = 5 * FixedPoint96.Q96;

        Perp.OpenTakerPositionParams memory openTaker1PositionParams =
            Perp.OpenTakerPositionParams({ isLong: true, margin: 20e6, leverageX96: taker1LeverageX96 });

        uint256 taker1PosId = perpHook.openTakerPosition(poolId, openTaker1PositionParams);

        Positions.TakerInfo memory taker1Pos = perpHook.getTakerPosition(poolId, taker1PosId);

        (uint160 postTaker1LongSqrtPriceX96,,,) = manager.getSlot0(poolId);

        console2.log("taker1 longs with id", taker1PosId);
        console2.log("holder", taker1Pos.holder);
        console2.log("isLong", taker1Pos.isLong);
        console2.log("size", taker1Pos.size);
        console2.log("margin", taker1Pos.margin);
        console2.log("entryValue", taker1Pos.entryValue);
        console2.log("entryTwPremiumX96", taker1Pos.entryTwPremiumX96);
        console2.log("leverageX96", taker1LeverageX96);
        console2.log("new sqrtPriceX96", postTaker1LongSqrtPriceX96);
        console2.log("new priceX96", Perp.sqrtPriceX96ToPriceX96(postTaker1LongSqrtPriceX96));
        console2.log();

        vm.stopPrank();

        skip(8640);

        console2.log("2.4 hours passes");
        console2.log();

        vm.startPrank(taker2);

        usdc.mint(taker2, 20e6);
        usdc.approve(address(perpHook), 20e6);

        uint256 taker2LeverageX96 = FixedPoint96.Q96;

        Perp.OpenTakerPositionParams memory openTaker2PositionParams =
            Perp.OpenTakerPositionParams({ isLong: false, margin: 20e6, leverageX96: taker2LeverageX96 });

        uint256 taker2PosId = perpHook.openTakerPosition(poolId, openTaker2PositionParams);

        Positions.TakerInfo memory taker2Pos = perpHook.getTakerPosition(poolId, taker2PosId);

        (uint160 postTaker2ShortSqrtPriceX96,,,) = manager.getSlot0(poolId);

        console2.log("taker2 shorts with id", taker2PosId);
        console2.log("holder", taker2Pos.holder);
        console2.log("isLong", taker2Pos.isLong);
        console2.log("size", taker2Pos.size);
        console2.log("margin", taker2Pos.margin);
        console2.log("entryValue", taker2Pos.entryValue);
        console2.log("entryTwPremiumX96", taker2Pos.entryTwPremiumX96);
        console2.log("leverageX96", taker2LeverageX96);
        console2.log("new sqrtPriceX96", postTaker2ShortSqrtPriceX96);
        console2.log("new priceX96", Perp.sqrtPriceX96ToPriceX96(postTaker2ShortSqrtPriceX96));
        console2.log();

        vm.stopPrank();

        skip(8640);

        console2.log("2.4 hours passes");
        console2.log();

        vm.startPrank(taker1);

        (int256 taker1Pnl, int256 taker1Funding, int256 taker1EffectiveMargin, bool taker1IsLiquidatable) =
            perpHook.liveTakerDetails(poolId, taker1PosId);
        console2.log("liveTakerDetails before state change");
        console2.log("taker1 pnl", taker1Pnl);
        console2.log("taker1 funding", taker1Funding);
        console2.log("taker1 effectiveMargin", taker1EffectiveMargin);
        console2.log("taker1 isLiquidatable", taker1IsLiquidatable);
        console2.log();

        perpHook.closeTakerPosition(poolId, taker1PosId);

        console2.log("taker1 closes position with id", taker1PosId);
        console2.log("taker1 balance", usdc.balanceOf(taker1));
        console2.log();

        vm.stopPrank();
        vm.startPrank(taker2);

        (int256 taker2Pnl, int256 taker2Funding, int256 taker2EffectiveMargin, bool taker2IsLiquidatable) =
            perpHook.liveTakerDetails(poolId, taker2PosId);
        console2.log("liveTakerDetails before state change");
        console2.log("taker2 pnl", taker2Pnl);
        console2.log("taker2 funding", taker2Funding);
        console2.log("taker2 effectiveMargin", taker2EffectiveMargin);
        console2.log("taker2 isLiquidatable", taker2IsLiquidatable);
        console2.log();

        perpHook.closeTakerPosition(poolId, taker2PosId);

        console2.log("taker2 closes position with id", taker2PosId);
        console2.log("taker2 balance", usdc.balanceOf(taker2));
        console2.log();

        vm.stopPrank();
        vm.startPrank(maker1);

        (int256 maker1Pnl, int256 maker1Funding, int256 maker1EffectiveMargin, bool maker1IsLiquidatable) =
            perpHook.liveMakerDetails(poolId, makerPosId);
        console2.log("liveMakerDetails before state change");
        console2.log("maker1 pnl", maker1Pnl);
        console2.log("maker1 funding", maker1Funding);
        console2.log("maker1 effectiveMargin", maker1EffectiveMargin);
        console2.log("maker1 isLiquidatable", maker1IsLiquidatable);
        console2.log();

        perpHook.closeMakerPosition(poolId, makerPosId);

        console2.log("maker closes position with id", makerPosId);
        console2.log("maker balance", usdc.balanceOf(maker1));
        console2.log();

        vm.stopPrank();
    }
}
