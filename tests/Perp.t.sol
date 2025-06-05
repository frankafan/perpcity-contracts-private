// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { CurrencyLibrary, Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import { TestnetUSDC } from "../src/testnet/TestnetUSDC.sol";
import { TestnetBeacon } from "../src/testnet/TestnetBeacon.sol";
import { PerpHook } from "../src/PerpHook.sol";
import { Perp } from "../src/Perp.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { EasyPosm } from "./utils/EasyPosm.sol";
import { Fixtures } from "./utils/Fixtures.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { UniversalRouter } from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import { RouterParameters } from "@uniswap/universal-router/contracts/types/RouterParameters.sol";

contract PerpTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for *;

    int24 constant TICK_SPACING = 60;

    UniversalRouter router;
    TestnetUSDC usdc;
    TestnetBeacon beacon;
    PerpHook hook;
    Perp perp;
    PoolId poolId;

    address maker1 = vm.addr(1);
    address maker2 = vm.addr(2);
    address taker1 = vm.addr(3);
    address taker2 = vm.addr(4);

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

        beacon = new TestnetBeacon();
        beacon.updateData(bytes(""), bytes(abi.encode(44 * FixedPoint96.Q96)));

        // Deploy the hook to an address with the correct flag
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager); //Add all the necessary constructor arguments from the hook
        deployCodeTo("PerpHook.sol:PerpHook", constructorArgs, flags);
        hook = PerpHook(flags);

        Perp.UniswapV4Contracts memory uniswapV4Contracts = Perp.UniswapV4Contracts({
            poolManager: address(manager),
            router: address(router),
            positionManager: address(posm),
            permit2: address(permit2)
        });

        Perp.PerpConfig memory perpConfig = Perp.PerpConfig({
            usdc: address(usdc),
            beacon: address(beacon),
            tradingFee: 10_000,
            minMargin: 0,
            maxMargin: type(uint128).max,
            minOpeningLeverageX96: (1 * FixedPoint96.Q96 / 10).toUint128(),
            maxOpeningLeverageX96: (10 * FixedPoint96.Q96).toUint128(),
            liquidationMarginRatioX96: (15 * FixedPoint96.Q96 / 100).toUint128(),
            liquidationFeeX96: (5 * FixedPoint96.Q96 / 100).toUint128(),
            liquidationFeeSplitX96: (50 * FixedPoint96.Q96 / 100).toUint128()
        });

        Perp.UniswapV4PoolConfig memory uniswapV4PoolConfig = Perp.UniswapV4PoolConfig({
            tickSpacing: TICK_SPACING,
            hook: address(hook),
            startingSqrtPriceX96: 560_227_709_747_861_399_187_319_863_744
        });

        perp = new Perp(uniswapV4Contracts, perpConfig, uniswapV4PoolConfig);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(0x94621d8f396Cc8255f99FF3435c0Cb6c7828F3C7),
            currency1: Currency.wrap(0xCDfc4483dfC62f9072de6b740b996EB0E295A467),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });

        poolId = key.toId();
    }

    function testOpenMakerPosition() public {
        usdc.mint(maker1, 100e6);

        vm.startPrank(maker1);
        usdc.approve(address(perp), 100e6);

        int24 tickLower = TickMath.getTickAtSqrtPrice(177_182_550_711_944_926_153_578_529_406); // 2 ** 96 *sqrt(5)
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING; // round to the nearest ticks

        int24 tickUpper = TickMath.getTickAtSqrtPrice(772_281_544_885_511_706_881_122_982_743); // 2 ** 96 *sqrt(95)
        tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING; // round to the nearest tick

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        console2.log("liquidity", liquidity);
        console2.log("tickLower", tickLower);
        console2.log("tickUpper", tickUpper);
        console2.log("sqrtPriceAX96", TickMath.getSqrtPriceAtTick(tickLower));
        console2.log("sqrtPriceBX96", TickMath.getSqrtPriceAtTick(tickUpper));
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(poolId);
        console2.log("sqrtPriceX96 at current tick", sqrtPriceX96);
        console2.log("current tick", tick);
        console2.log();

        uint256 makerPosId = perp.openMakerPosition(100e6, liquidity, tickLower, tickUpper);

        console2.log("makerPosId", makerPosId);

        vm.stopPrank();
    }

    function testOpenTakerLongPosition() public {
        vm.startPrank(maker1);
        usdc.mint(maker1, 100e6);
        usdc.approve(address(perp), 100e6);

        int24 tickLower = TickMath.getTickAtSqrtPrice(177_182_550_711_944_926_153_578_529_406); // 2 ** 96 *sqrt(5)
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING; // round to the nearest ticks

        int24 tickUpper = TickMath.getTickAtSqrtPrice(772_281_544_885_511_706_881_122_982_743); // 2 ** 96 *sqrt(95)
        tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING; // round to the nearest tick

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        uint256 makerPosId = perp.openMakerPosition(100e6, liquidity, tickLower, tickUpper);

        console2.log("liquidity", liquidity);
        console2.log("tickLower", tickLower);
        console2.log("tickUpper", tickUpper);
        console2.log("sqrtPriceAX96", TickMath.getSqrtPriceAtTick(tickLower));
        console2.log("sqrtPriceBX96", TickMath.getSqrtPriceAtTick(tickUpper));
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(poolId);
        console2.log("sqrtPriceX96 at current tick", sqrtPriceX96);
        console2.log("current tick", tick);
        (uint160 sqrtPriceX96FromSlot0,,,) = manager.getSlot0(poolId);
        console2.log("sqrtPriceX96 from slot0", sqrtPriceX96FromSlot0);
        console2.log();

        vm.stopPrank();
        vm.startPrank(taker1);
        usdc.mint(taker1, 20e6);
        usdc.approve(address(perp), 20e6);

        (uint160 sqrtPriceX96Before,,,) = manager.getSlot0(poolId);
        console2.log("sqrtPriceX96Before", sqrtPriceX96Before);

        uint256 takerPosId = perp.openTakerPosition(true, 20e6, SafeCast.toUint128(2 * FixedPoint96.Q96));

        (uint160 sqrtPriceX96After,,,) = manager.getSlot0(poolId);
        console2.log("sqrtPriceX96After", sqrtPriceX96After);

        vm.stopPrank();
    }

    function testCloseTakerLongPosition() public {
        vm.startPrank(maker1);
        usdc.mint(maker1, 100e6);
        usdc.approve(address(perp), 100e6);

        int24 tickLower = TickMath.getTickAtSqrtPrice(177_182_550_711_944_926_153_578_529_406); // 2 ** 96 *sqrt(5)
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING; // round to the nearest ticks

        int24 tickUpper = TickMath.getTickAtSqrtPrice(772_281_544_885_511_706_881_122_982_743); // 2 ** 96 *sqrt(95)
        tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING; // round to the nearest tick

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        uint256 makerPosId = perp.openMakerPosition(100e6, liquidity, tickLower, tickUpper);

        vm.stopPrank();
        vm.startPrank(taker1);
        usdc.mint(taker1, 20e6);
        usdc.approve(address(perp), 20e6);

        uint256 takerPosId = perp.openTakerPosition(true, 20e6, SafeCast.toUint128(2 * FixedPoint96.Q96));

        perp.closeTakerPosition(takerPosId);

        vm.stopPrank();
    }

    function testOpenTakerShortPosition() public {
        vm.startPrank(maker1);
        usdc.mint(maker1, 100e6);
        usdc.approve(address(perp), 100e6);

        int24 tickLower = TickMath.getTickAtSqrtPrice(177_182_550_711_944_926_153_578_529_406); // 2 ** 96 *sqrt(5)
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING; // round to the nearest ticks

        int24 tickUpper = TickMath.getTickAtSqrtPrice(772_281_544_885_511_706_881_122_982_743); // 2 ** 96 *sqrt(95)
        tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING; // round to the nearest tick

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        uint256 makerPosId = perp.openMakerPosition(100e6, liquidity, tickLower, tickUpper);

        console2.log("liquidity", liquidity);
        console2.log("tickLower", tickLower);
        console2.log("tickUpper", tickUpper);
        console2.log("sqrtPriceAX96", TickMath.getSqrtPriceAtTick(tickLower));
        console2.log("sqrtPriceBX96", TickMath.getSqrtPriceAtTick(tickUpper));
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(poolId);
        console2.log("sqrtPriceX96 at current tick", sqrtPriceX96);
        console2.log("current tick", tick);
        (uint160 sqrtPriceX96FromSlot0,,,) = manager.getSlot0(poolId);
        console2.log("sqrtPriceX96 from slot0", sqrtPriceX96FromSlot0);
        console2.log();

        vm.stopPrank();
        vm.startPrank(taker1);
        usdc.mint(taker1, 20e6);
        usdc.approve(address(perp), 20e6);

        (uint160 sqrtPriceX96Before,,,) = manager.getSlot0(poolId);
        console2.log("sqrtPriceX96Before", sqrtPriceX96Before);

        uint256 takerPosId = perp.openTakerPosition(false, 20e6, SafeCast.toUint128(2 * FixedPoint96.Q96));

        (uint160 sqrtPriceX96After,,,) = manager.getSlot0(poolId);
        console2.log("sqrtPriceX96After", sqrtPriceX96After);

        vm.stopPrank();
    }

    function testCloseTakerShortPosition() public {
        vm.startPrank(maker1);
        usdc.mint(maker1, 100e6);
        usdc.approve(address(perp), 100e6);

        int24 tickLower = TickMath.getTickAtSqrtPrice(177_182_550_711_944_926_153_578_529_406); // 2 ** 96 *sqrt(5)
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING; // round to the nearest ticks

        int24 tickUpper = TickMath.getTickAtSqrtPrice(772_281_544_885_511_706_881_122_982_743); // 2 ** 96 *sqrt(95)
        tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING; // round to the nearest tick

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        uint256 makerPosId = perp.openMakerPosition(100e6, liquidity, tickLower, tickUpper);

        vm.stopPrank();
        vm.startPrank(taker1);
        usdc.mint(taker1, 20e6);
        usdc.approve(address(perp), 20e6);

        uint256 takerPosId = perp.openTakerPosition(false, 20e6, SafeCast.toUint128(2 * FixedPoint96.Q96));

        perp.closeTakerPosition(takerPosId);

        vm.stopPrank();
    }

    function testCloseMakerPositionAgainstTakerLong() public {
        vm.startPrank(maker1);
        usdc.mint(maker1, 100e6);
        usdc.approve(address(perp), 100e6);

        int24 tickLower = TickMath.getTickAtSqrtPrice(177_182_550_711_944_926_153_578_529_406); // 2 ** 96 *sqrt(5)
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING; // round to the nearest ticks

        int24 tickUpper = TickMath.getTickAtSqrtPrice(772_281_544_885_511_706_881_122_982_743); // 2 ** 96 *sqrt(95)
        tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING; // round to the nearest tick

        uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        uint256 maker1PosId = perp.openMakerPosition(100e6, liquidity1, tickLower, tickUpper);

        vm.stopPrank();
        vm.startPrank(maker2);
        usdc.mint(maker2, 100e6);
        usdc.approve(address(perp), 100e6);

        uint128 liquidity2 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        uint256 maker2PosId = perp.openMakerPosition(100e6, liquidity2, tickLower, tickUpper);

        vm.stopPrank();
        vm.startPrank(taker1);
        usdc.mint(taker1, 20e6);
        usdc.approve(address(perp), 20e6);

        uint256 takerPosId = perp.openTakerPosition(true, 20e6, SafeCast.toUint128(2 * FixedPoint96.Q96));

        vm.stopPrank();
        vm.startPrank(maker2);

        perp.closeMakerPosition(maker2PosId);

        vm.stopPrank();
    }

    function testCloseMakerPositionAgainstTakerShort() public {
        vm.startPrank(maker1);
        usdc.mint(maker1, 100e6);
        usdc.approve(address(perp), 100e6);

        int24 tickLower = TickMath.getTickAtSqrtPrice(177_182_550_711_944_926_153_578_529_406); // 2 ** 96 *sqrt(5)
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING; // round to the nearest ticks

        int24 tickUpper = TickMath.getTickAtSqrtPrice(772_281_544_885_511_706_881_122_982_743); // 2 ** 96 *sqrt(95)
        tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING; // round to the nearest tick

        uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        uint256 maker1PosId = perp.openMakerPosition(100e6, liquidity1, tickLower, tickUpper);

        vm.stopPrank();
        vm.startPrank(maker2);
        usdc.mint(maker2, 100e6);
        usdc.approve(address(perp), 100e6);

        uint128 liquidity2 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        uint256 maker2PosId = perp.openMakerPosition(100e6, liquidity2, tickLower, tickUpper);

        vm.stopPrank();
        vm.startPrank(taker1);
        usdc.mint(taker1, 20e6);
        usdc.approve(address(perp), 20e6);

        uint256 takerPosId = perp.openTakerPosition(false, 20e6, SafeCast.toUint128(2 * FixedPoint96.Q96));

        vm.stopPrank();
        vm.startPrank(maker2);

        perp.closeMakerPosition(maker2PosId);

        vm.stopPrank();
    }

    function testTakerLongWithFunding() public {
        vm.startPrank(maker1);
        usdc.mint(maker1, 100e6);
        usdc.approve(address(perp), 100e6);

        int24 tickLower = TickMath.getTickAtSqrtPrice(177_182_550_711_944_926_153_578_529_406); // 2 ** 96 *sqrt(5)
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING; // round to the nearest ticks

        int24 tickUpper = TickMath.getTickAtSqrtPrice(772_281_544_885_511_706_881_122_982_743); // 2 ** 96 *sqrt(95)
        tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING; // round to the nearest tick

        uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);

        (uint256 token0Amount, uint256 token1Amount) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, 177_182_550_711_944_926_153_578_529_406, 772_281_544_885_511_706_881_122_982_743, liquidity1
        );
        console2.log("token0 amount when opening maker position", token0Amount);
        console2.log("token1 amount when opening maker position", token1Amount);

        uint256 maker1PosId = perp.openMakerPosition(100e6, liquidity1, tickLower, tickUpper);

        vm.stopPrank();
        vm.startPrank(maker2);
        usdc.mint(maker2, 100e6);
        usdc.approve(address(perp), 100e6);

        uint128 liquidity2 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        uint256 maker2PosId = perp.openMakerPosition(100e6, liquidity2, tickLower, tickUpper);

        vm.stopPrank();
        vm.startPrank(taker1);
        usdc.mint(taker1, 20e6);
        usdc.approve(address(perp), 20e6);

        uint256 takerPosId = perp.openTakerPosition(true, 20e6, SafeCast.toUint128(2 * FixedPoint96.Q96));

        vm.stopPrank();

        (sqrtPriceX96,,,) = manager.getSlot0(poolId);
        console2.log("markPriceX96", uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / FixedPoint96.Q96);
        (uint256 indexPriceX96,) = beacon.getData();
        console2.log("indexPriceX96", indexPriceX96);
        console2.log("fundingRateX96", perp.fundingRateX96());

        vm.warp(block.timestamp + 24 hours);

        vm.startPrank(taker1);

        perp.closeTakerPosition(takerPosId);
        console2.log("taker1 usd", usdc.balanceOf(taker1));

        vm.stopPrank();
        vm.startPrank(maker2);

        perp.closeMakerPosition(maker2PosId);

        usdc.mint(maker2, 100e6);
        usdc.approve(address(perp), 100e6);

        liquidity2 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        maker2PosId = perp.openMakerPosition(100e6, liquidity2, tickLower, tickUpper);

        vm.stopPrank();
        vm.startPrank(maker1);

        perp.closeMakerPosition(maker1PosId);
        console2.log("maker1 usd", usdc.balanceOf(maker1));

        vm.stopPrank();
    }

    function testTakerShortWithFunding() public {
        vm.warp(block.timestamp + 24 hours);
        vm.startPrank(maker1);
        usdc.mint(maker1, 100e6);
        usdc.approve(address(perp), 100e6);

        int24 tickLower = TickMath.getTickAtSqrtPrice(177_182_550_711_944_926_153_578_529_406); // 2 ** 96 *sqrt(5)
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING; // round to the nearest ticks

        int24 tickUpper = TickMath.getTickAtSqrtPrice(772_281_544_885_511_706_881_122_982_743); // 2 ** 96 *sqrt(95)
        tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING; // round to the nearest tick

        uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);

        (uint256 token0Amount, uint256 token1Amount) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, 177_182_550_711_944_926_153_578_529_406, 772_281_544_885_511_706_881_122_982_743, liquidity1
        );
        console2.log("token0 amount when opening maker position", token0Amount);
        console2.log("token1 amount when opening maker position", token1Amount);

        uint256 maker1PosId = perp.openMakerPosition(100e6, liquidity1, tickLower, tickUpper);

        vm.stopPrank();
        vm.startPrank(maker2);
        usdc.mint(maker2, 100e6);
        usdc.approve(address(perp), 100e6);

        uint128 liquidity2 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        uint256 maker2PosId = perp.openMakerPosition(100e6, liquidity2, tickLower, tickUpper);

        vm.stopPrank();
        vm.startPrank(taker1);
        usdc.mint(taker1, 20e6);
        usdc.approve(address(perp), 20e6);

        uint256 takerPosId = perp.openTakerPosition(false, 20e6, SafeCast.toUint128(2 * FixedPoint96.Q96));

        vm.stopPrank();

        (sqrtPriceX96,,,) = manager.getSlot0(poolId);
        console2.log("markPriceX96", uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / FixedPoint96.Q96);
        (uint256 indexPriceX96,) = beacon.getData();
        console2.log("indexPriceX96", indexPriceX96);
        console2.log("fundingRateX96", perp.fundingRateX96());

        vm.warp(block.timestamp + 48 hours);

        vm.startPrank(taker1);

        perp.closeTakerPosition(takerPosId);
        console2.log("taker1 usd", usdc.balanceOf(taker1));

        vm.stopPrank();
        vm.startPrank(maker2);

        perp.closeMakerPosition(maker2PosId);

        usdc.mint(maker2, 100e6);
        usdc.approve(address(perp), 100e6);

        liquidity2 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), 500e18
        );

        maker2PosId = perp.openMakerPosition(100e6, liquidity2, tickLower, tickUpper);

        vm.stopPrank();
        vm.startPrank(maker1);

        perp.closeMakerPosition(maker1PosId);
        console2.log("maker1 usd", usdc.balanceOf(maker1));

        vm.stopPrank();
    }
}
