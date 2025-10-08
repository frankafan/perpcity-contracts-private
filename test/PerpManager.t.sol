// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";

import {OwnableBeacon} from "../src/beacons/ownable/OwnableBeacon.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {IBeacon} from "../src/interfaces/beacons/IBeacon.sol";

import {UINT_Q96} from "../src/libraries/Constants.sol";
import {PerpLogic} from "../src/libraries/PerpLogic.sol";
import {TradingFee} from "../src/libraries/TradingFee.sol";

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

    address public usdc;

    PerpManager public perpManager;

    address public actor = makeAddr("actor");

    function setUp() public {
        IPoolManager poolManager = deployPoolManager();

        usdc = address(new TestnetUSDC());

        // // Since PerpManager.sol is a hook, we need to deploy it to an address with the correct flags
        // address flags = address(
        //     uint160(0) ^ (0x5555 << 144) // Namespace the address to avoid collisions
        // );

        // // Add all necessary constructor arguments for PerpManager.sol
        // bytes memory constructorArgs = abi.encode(poolManager, usdc);

        // // Use StdCheats.deployCodeTo to deploy the PerpManager.sol contract to the flags address
        // deployCodeTo("PerpManager.sol:PerpManager", constructorArgs, flags);

        // perpManager = PerpManager(flags);

        perpManager = new PerpManager(poolManager, usdc);
    }

    function test_informal() public {
        // deploy a beacon
        IBeacon beacon = new OwnableBeacon(actor, 50 * UINT_Q96, 100);

        // deploy a perp
        PoolId perpId = perpManager.createPerp(
            IPerpManager.CreatePerpParams({
                startingSqrtPriceX96: 560227709747861399187319382275, // sqrt(50)
                beacon: address(beacon)
            })
        );

        // open a maker position
        vm.startPrank(actor);

        uint160 sqrtPriceLowerX96 = uint160(FixedPointMathLib.mulSqrt(45, UINT_Q96 * UINT_Q96));
        uint160 sqrtPriceUpperX96 = uint160(FixedPointMathLib.mulSqrt(55, UINT_Q96 * UINT_Q96));

        int24 tickSpacing = perpManager.tickSpacing(perpId);

        int24 tickLower = TickMath.getTickAtSqrtPrice(sqrtPriceLowerX96);
        tickLower = (tickLower / tickSpacing) * tickSpacing;
        int24 tickUpper = TickMath.getTickAtSqrtPrice(sqrtPriceUpperX96);
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;

        uint256 makerMargin = 100e6;

        uint128 liquidity = perpManager.estimateLiquidityForAmount1(tickLower, tickUpper, makerMargin);

        deal(usdc, actor, makerMargin);
        usdc.safeApprove(address(perpManager), makerMargin);
        uint128 makerPosId = perpManager.openMakerPosition(
            perpId,
            IPerpManager.OpenMakerPositionParams({
                margin: makerMargin,
                liquidity: liquidity,
                tickLower: tickLower,
                tickUpper: tickUpper,
                maxAmt0In: type(uint128).max,
                maxAmt1In: type(uint128).max
            })
        );

        console2.log("maker position opened with posId ", makerPosId);
        console2.log();

        uint256 takerMargin = 20e6;

        // open taker long
        deal(usdc, actor, takerMargin);
        usdc.safeApprove(address(perpManager), takerMargin);

        uint128 takerPos1Id = perpManager.openTakerPosition(
            perpId,
            IPerpManager.OpenTakerPositionParams({
                isLong: true,
                margin: takerMargin,
                levX96: 2 * UINT_Q96,
                unspecifiedAmountLimit: 0
            })
        );

        IPerpManager.Position memory takerPos1 = perpManager.getPosition(perpId, takerPos1Id);

        console2.log("taker position opened with posId ", takerPos1Id);
        console2.log("margin %6e", takerPos1.margin);
        console2.log("perpDelta %6e", takerPos1.perpDelta);
        console2.log("usdDelta %6e", takerPos1.usdDelta);
        console2.log();

        // // open taker short
        // deal(usdc, actor, takerMargin);
        // usdc.safeApprove(address(perpManager), takerMargin);

        // uint128 takerPos2Id = perpManager.openTakerPosition(
        //     perpId,
        //     IPerpManager.OpenTakerPositionParams({
        //         isLong: false,
        //         margin: takerMargin,
        //         levX96: 2 * UINT_Q96,
        //         unspecifiedAmountLimit: type(uint128).max
        //     })
        // );

        // skip(1 hours);

        // int256 pnl;
        // int256 fundingPayment;
        // int256 effectiveMargin;
        // bool isLiquidatable;
        // uint256 newPriceX96;

        // (pnl, fundingPayment, effectiveMargin, isLiquidatable, newPriceX96) = perpManager.livePositionDetails(perpId, makerPosId);
        // console2.log("makerPosId", makerPosId);
        // console2.log("pnl", pnl);
        // console2.log("fundingPayment", fundingPayment);
        // console2.log("effectiveMargin", effectiveMargin);
        // console2.log("isLiquidatable", isLiquidatable);
        // console2.log("newPriceX96", newPriceX96);
        // console2.log();

        // (pnl, fundingPayment, effectiveMargin, isLiquidatable, newPriceX96) = perpManager.livePositionDetails(perpId, takerPos1Id);
        // console2.log("takerPos1Id", takerPos1Id);
        // console2.log("pnl", pnl);
        // console2.log("fundingPayment", fundingPayment);
        // console2.log("effectiveMargin", effectiveMargin);
        // console2.log("isLiquidatable", isLiquidatable);
        // console2.log("newPriceX96", newPriceX96);
        // console2.log();

        // (pnl, fundingPayment, effectiveMargin, isLiquidatable, newPriceX96) = perpManager.livePositionDetails(perpId, takerPos2Id);
        // console2.log("takerPos2Id", takerPos2Id);
        // console2.log("pnl", pnl);
        // console2.log("fundingPayment", fundingPayment);
        // console2.log("effectiveMargin", effectiveMargin);
        // console2.log("isLiquidatable", isLiquidatable);
        // console2.log("newPriceX96", newPriceX96);
    }
}
