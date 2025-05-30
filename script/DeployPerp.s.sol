// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { Perp } from "../src/Perp.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

contract DeployPerp is Script {
    Perp public perp;

    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant POSITION_MANAGER = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address constant ROUTER = 0x492E6456D9528771018DeB9E87ef7750EF184104;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDC = 0x4F4e46307114d7c02C5dee116dd51Bd34faCf39a;
    address constant BEACON = 0xB4BF59f4958e5EDE1A463A3AeB587d4Cc2D8aDF6;
    uint24 constant TRADING_FEE = 10_000;
    uint256 constant MIN_MARGIN = 1e6;
    uint256 constant MAX_MARGIN = type(uint256).max;
    uint256 constant MIN_OPENING_LEVERAGE_X96 = 1 * FixedPoint96.Q96 / 10;
    uint256 constant MAX_OPENING_LEVERAGE_X96 = 10 * FixedPoint96.Q96;
    uint256 constant LIQUIDATION_MARGIN_RATIO_X96 = 15 * FixedPoint96.Q96 / 100; // 0.15
    uint256 constant LIQUIDATION_FEE_X96 = 5 * FixedPoint96.Q96 / 100; // 0.05
    uint256 constant LIQUIDATION_FEE_SPLIT_X96 = 50 * FixedPoint96.Q96 / 100; // 0.50
    int24 constant TICK_SPACING = 30;
    address constant HOOK = 0x93C35f4Cee88C914Ed3916aC6114816A99F1EAA0;
    uint160 constant STARTING_SQRT_PRICE_X96 = 560_227_709_747_861_399_187_319_863_744; // 2 ** 96 * sqrt(50)

    function run() public {
        vm.startBroadcast();

        Perp.UniswapV4Contracts memory uniswapV4Contracts = Perp.UniswapV4Contracts({
            poolManager: POOL_MANAGER,
            router: ROUTER,
            positionManager: POSITION_MANAGER,
            permit2: PERMIT2
        });

        Perp.PerpConfig memory perpConfig = Perp.PerpConfig({
            usdc: USDC,
            beacon: BEACON,
            tradingFee: TRADING_FEE,
            minMargin: MIN_MARGIN,
            maxMargin: MAX_MARGIN,
            minOpeningLeverageX96: MIN_OPENING_LEVERAGE_X96,
            maxOpeningLeverageX96: MAX_OPENING_LEVERAGE_X96,
            liquidationMarginRatioX96: LIQUIDATION_MARGIN_RATIO_X96,
            liquidationFeeX96: LIQUIDATION_FEE_X96,
            liquidationFeeSplitX96: LIQUIDATION_FEE_SPLIT_X96
        });

        Perp.UniswapV4PoolConfig memory uniswapV4PoolConfig = Perp.UniswapV4PoolConfig({
            tickSpacing: TICK_SPACING,
            hook: HOOK,
            startingSqrtPriceX96: STARTING_SQRT_PRICE_X96
        });

        perp = new Perp(uniswapV4Contracts, perpConfig, uniswapV4PoolConfig);

        console2.log("Perp: ", address(perp));

        vm.stopBroadcast();
    }
}
