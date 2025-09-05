// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {PerpManager} from "../src/PerpManager.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {FixedPoint96} from "../src/libraries/FixedPoint96.sol";
import {TradingFee} from "../src/libraries/TradingFee.sol";
import {TestnetUSDC} from "../src/testnet/TestnetUSDC.sol";
import {PerpHandler} from "./PerpHandler.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {RouterParameters} from "@uniswap/universal-router/contracts/types/RouterParameters.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Test} from "forge-std/Test.sol";
import {PerpManager} from "../src/PerpManager.sol";
import {IBeacon} from "../src/interfaces/IBeacon.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {FixedPoint96} from "../src/libraries/FixedPoint96.sol";
import {PerpLogic} from "../src/libraries/PerpLogic.sol";
import {TradingFee} from "../src/libraries/TradingFee.sol";
import {TestnetBeacon} from "../src/testnet/TestnetBeacon.sol";
import {MAX_CARDINALITY} from "../src/utils/Constants.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolKey} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {console2} from "forge-std/console2.sol";

contract InvariantTest is Test, Fixtures {
    using SafeTransferLib for address;
    using StateLibrary for IPoolManager;

    IUniversalRouter public universalRouter;
    address public usdc;

    uint128 public constant PERP_CREATION_FEE = 5e5; // 5 USDC
    address public immutable PERP_CREATION_FEE_RECIPIENT = makeAddr("perp creation fee recipient");

    PerpManager public perpManager;

    function setUp() public {
        // deploys the pool manager, utility routers, and permit2
        deployFreshManagerAndRouters();
        // deploys the position manager
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
        universalRouter = new UniversalRouter(params);

        usdc = address(new TestnetUSDC());

        // Since PerpManager.sol is a hook, we need to deploy it to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x5555 << 144) // Namespace the address to avoid collisions
        );

        // Add all necessary constructor arguments for PerpManager.sol
        bytes memory constructorArgs = abi.encode(
            IPerpManager.ExternalContracts({poolManager: manager, posm: posm, router: universalRouter, usdc: usdc}),
            PERP_CREATION_FEE,
            PERP_CREATION_FEE_RECIPIENT
        );

        // Use StdCheats.deployCodeTo to deploy the PerpManager.sol contract to the flags address
        deployCodeTo("PerpManager.sol:PerpManager", constructorArgs, flags);

        perpManager = PerpManager(flags);
    }

    function test_temp() public {
        address actor = makeAddr("actor");
        vm.startPrank(actor);

        // deploy a beacon
        IBeacon beacon = new TestnetBeacon(actor, 100 * FixedPoint96.UINT_Q96, 100);

        deal(usdc, actor, perpManager.CREATION_FEE_AMT());
        usdc.safeApprove(address(perpManager), perpManager.CREATION_FEE_AMT());

        // deploy a perp
        PoolId perpId = perpManager.createPerp(
            IPerpManager.CreatePerpParams({
                startingSqrtPriceX96: uint160(10 * FixedPoint96.UINT_Q96), // $100
                initialCardinalityNext: 100,
                makerLockupPeriod: 1 days,
                fundingInterval: 1 days,
                beacon: address(beacon),
                tickSpacing: 30,
                twapWindow: 1 hours,
                tradingFeeCreatorSplitX96: uint128(10 * FixedPoint96.UINT_Q96 / 100),
                tradingFeeInsuranceSplitX96: uint128(10 * FixedPoint96.UINT_Q96 / 100),
                priceImpactBandX96: uint128(50 * FixedPoint96.UINT_Q96 / 100),
                maxOpeningLevX96: uint128(10 * FixedPoint96.UINT_Q96),
                liquidationLevX96: uint128(15 * FixedPoint96.UINT_Q96),
                liquidationFeeX96: uint128(5 * FixedPoint96.UINT_Q96 / 100),
                liquidatorFeeSplitX96: uint128(50 * FixedPoint96.UINT_Q96 / 100),
                tradingFeeConfig: TradingFee.Config({
                    baseFeeX96: 0, // ignored
                    startFeeX96: uint128(3 * FixedPoint96.UINT_Q96 / 100),
                    targetFeeX96: uint128(1 * FixedPoint96.UINT_Q96 / 200),
                    decay: 1e18,
                    volatilityScalerX96: uint128(20 * FixedPoint96.UINT_Q96 / 100),
                    maxFeeMultiplierX96: uint128(2 * FixedPoint96.UINT_Q96)
                })
            })
        );

        (IPoolManager poolManager,,,) = perpManager.c();
        (,int24 currentTick,,) = poolManager.getSlot0(perpId);
        console2.log("currentTick", currentTick);

        // open a maker position
        uint160 sqrtPriceLowerX96 = uint160(FixedPointMathLib.mulSqrt(90, FixedPoint96.UINT_Q96 * FixedPoint96.UINT_Q96));
        uint160 sqrtPriceUpperX96 = uint160(FixedPointMathLib.mulSqrt(110, FixedPoint96.UINT_Q96 * FixedPoint96.UINT_Q96));

        (,,,,,,,,,,,,,,,,,,,, PoolKey memory key,,) = perpManager.perps(perpId);
        int24 tickSpacing = key.tickSpacing;

        int24 tickLower = TickMath.getTickAtSqrtPrice(sqrtPriceLowerX96);
        tickLower = (tickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = TickMath.getTickAtSqrtPrice(sqrtPriceUpperX96);
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;

        uint128 margin = 100e6;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLowerX96, sqrtPriceUpperX96, margin);

        deal(usdc, actor, margin);
        usdc.safeApprove(address(perpManager), margin);

        uint128 makerPosId = perpManager.openMakerPosition(
            perpId,
            IPerpManager.OpenMakerPositionParams({
                margin: margin,
                liquidity: liquidity,
                tickLower: tickLower,
                tickUpper: tickUpper,
                maxAmt0In: type(uint128).max,
                maxAmt1In: type(uint128).max,
                timeout: 1
            })
        );

        IPerpManager.MakerPos memory makerPos = perpManager.getMakerPosition(perpId, makerPosId);

        console2.log("tickLower", makerPos.tickLower);
        console2.log("tickUpper", makerPos.tickUpper);
        console2.log("liquidity", makerPos.liquidity);
        console2.log("perps borrowed", makerPos.perpsBorrowed);
        console2.log("usd borrowed", makerPos.usdBorrowed);

        // open another maker position
        // sqrtPriceLowerX96 = uint160(FixedPointMathLib.mulSqrt(90, FixedPoint96.UINT_Q96 * FixedPoint96.UINT_Q96));
        // sqrtPriceUpperX96 = uint160(FixedPointMathLib.mulSqrt(110, FixedPoint96.UINT_Q96 * FixedPoint96.UINT_Q96));

        // tickLower = TickMath.getTickAtSqrtPrice(sqrtPriceLowerX96);
        // tickLower = (tickLower / tickSpacing) * tickSpacing;
        // tickUpper = TickMath.getTickAtSqrtPrice(sqrtPriceUpperX96);
        // tickUpper = (tickUpper / tickSpacing) * tickSpacing;

        // liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLowerX96, sqrtPriceUpperX96, margin.scale6To18());

        // deal(usdc, actor, margin);
        // usdc.safeApprove(address(perpManager), margin);

        // makerPosId = perpManager.openMakerPosition(
        //     perpId,
        //     IPerpManager.OpenMakerPositionParams({
        //         margin: margin,
        //         liquidity: liquidity,
        //         tickLower: tickLower,
        //         tickUpper: tickUpper,
        //         maxAmt0In: type(uint128).max,
        //         maxAmt1In: type(uint128).max,
        //         timeout: 1
        //     })
        // );

        // makerPos = perpManager.getMakerPosition(perpId, makerPosId);

        // console2.log("tickLower", makerPos.tickLower);
        // console2.log("tickUpper", makerPos.tickUpper);
        // console2.log("liquidity", makerPos.liquidity);
        // console2.log("perps borrowed", makerPos.perpsBorrowed);
        // console2.log("usd borrowed", makerPos.usdBorrowed);

        // open a taker position
        uint256 maxNotionalTakerSizeLong = perpManager.maxNotionalTakerSize(perpId, true);
        uint256 maxNotionalTakerSizeShort = perpManager.maxNotionalTakerSize(perpId, false);

        console2.log("maxNotionalTakerSizeLong", maxNotionalTakerSizeLong);
        console2.log("maxNotionalTakerSizeShort", maxNotionalTakerSizeShort);
    }
}