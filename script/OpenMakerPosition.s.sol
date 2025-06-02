// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { Perp } from "../src/Perp.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TestnetUSDC } from "../src/testnet/TestnetUSDC.sol";

contract OpenMakerPosition is Script {
    using StateLibrary for IPoolManager;

    address public constant MAKER = 0xCe5300d186999d014b0F4802a0ef6F97c4381196;
    address public constant PERP = 0x569af394601aab1ef01622Fa27aeF15367220785;
    address public constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    int24 constant TICK_SPACING = 30;
    uint256 constant MARGIN = 500e6;
    uint160 constant SQRT_PRICE_LOWER_X96 = uint160(1 * FixedPoint96.Q96 / 10);
    uint160 constant SQRT_PRICE_UPPER_X96 = uint160(10 * FixedPoint96.Q96);

    function run() public {
        vm.startBroadcast();

        TestnetUSDC(address(Perp(PERP).USDC())).mint(MAKER, MARGIN);
        Perp(PERP).USDC().approve(PERP, MARGIN);

        int24 tickLower = TickMath.getTickAtSqrtPrice(SQRT_PRICE_LOWER_X96); // 2 ** 96 * sqrt(0.01)
        tickLower = (tickLower / TICK_SPACING) * TICK_SPACING; // round to the nearest ticks

        int24 tickUpper = TickMath.getTickAtSqrtPrice(SQRT_PRICE_UPPER_X96); // 2 ** 96 * sqrt(100)
        tickUpper = (tickUpper / TICK_SPACING) * TICK_SPACING; // round to the nearest tick

        // (uint160 sqrtPriceX96, , , ) = IPoolManager(POOL_MANAGER).getSlot0(Perp(PERP).poolId());

        // uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, SQRT_PRICE_UPPER_X96, 5e18, 200e18,
        // 0);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(SQRT_PRICE_LOWER_X96, SQRT_PRICE_UPPER_X96, 200e18);

        Perp(PERP).openMakerPosition(uint128(MARGIN), liquidity, tickLower, tickUpper);

        vm.stopBroadcast();
    }
}
