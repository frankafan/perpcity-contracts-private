// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { PerpHook } from "../src/PerpHook.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TestnetUSDC } from "../src/testnet/TestnetUSDC.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Perp } from "../src/libraries/Perp.sol";
import { Params } from "../src/libraries/Params.sol";

contract OpenMakerPosition is Script {
    using StateLibrary for IPoolManager;

    address public constant MAKER = 0xCe5300d186999d014b0F4802a0ef6F97c4381196;
    address public constant USDC = 0x0000000000000000000000000000000000000000;
    address public constant PERP = 0x569af394601aab1ef01622Fa27aeF15367220785;
    PoolId public immutable POOL_ID = PoolId.wrap(bytes32(0));
    address public constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    int24 constant TICK_SPACING = 30;
    uint256 constant MARGIN = 500e6;
    uint160 constant SQRT_PRICE_LOWER_X96 = uint160(1 * FixedPoint96.Q96 / 10);
    uint160 constant SQRT_PRICE_UPPER_X96 = uint160(10 * FixedPoint96.Q96);

    function run() public {
        vm.startBroadcast();

        TestnetUSDC(USDC).mint(MAKER, MARGIN);
        TestnetUSDC(USDC).approve(PERP, MARGIN);

        int24 tickLower = TickMath.getTickAtSqrtPrice(SQRT_PRICE_LOWER_X96); // 2 ** 96 * sqrt(0.01)
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING; // round to the nearest ticks

        int24 tickUpper = TickMath.getTickAtSqrtPrice(SQRT_PRICE_UPPER_X96); // 2 ** 96 * sqrt(100)
        tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING; // round to the nearest tick

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(SQRT_PRICE_LOWER_X96, SQRT_PRICE_UPPER_X96, 200e18);

        Params.OpenMakerPositionParams memory openMakerPositionParams = Params.OpenMakerPositionParams({
            margin: uint128(MARGIN),
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper
        });

        PerpHook(PERP).openMakerPosition(POOL_ID, openMakerPositionParams);

        vm.stopBroadcast();
    }
}
