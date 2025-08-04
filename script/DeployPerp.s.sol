// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { PerpHook } from "../src/PerpHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { Perp } from "../src/libraries/Perp.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { Params } from "../src/libraries/Params.sol";

contract DeployPerp is Script {
    using SafeCast for *;

    address public constant PERP_HOOK = 0x0000000000000000000000000000000000000000; // Replace with actual hook address
    address public constant BEACON = 0x0000000000000000000000000000000000000000; // Replace with actual beacon address

    uint160 constant SQRT_50_X96 = 560_227_709_747_861_419_891_227_623_424; // 2 ** 96 * sqrt(50)

    uint24 constant TRADING_FEE = 5000; // 0.5%
    uint128 immutable TRADING_FEE_CREATOR_SPLIT_X96 = (5 * FixedPoint96.Q96 / 100).toUint128(); // 5%
    uint128 immutable TRADING_FEE_INSURANCE_SPLIT_X96 = (10 * FixedPoint96.Q96 / 100).toUint128(); // 10%
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
    uint32 constant INITIAL_CARDINALITY_NEXT = 100;

    function run() public {
        vm.startBroadcast();

        Params.CreatePerpParams memory createPerpParams = Params.CreatePerpParams({
            beacon: BEACON,
            tradingFee: TRADING_FEE,
            tradingFeeCreatorSplitX96: TRADING_FEE_CREATOR_SPLIT_X96,
            tradingFeeInsuranceSplitX96: TRADING_FEE_INSURANCE_SPLIT_X96,
            minMargin: MIN_MARGIN,
            maxMargin: MAX_MARGIN,
            minOpeningLeverageX96: MIN_OPENING_LEVERAGE_X96,
            maxOpeningLeverageX96: MAX_OPENING_LEVERAGE_X96,
            liquidationLeverageX96: LIQUIDATION_LEVERAGE_X96,
            liquidationFeeX96: LIQUIDATION_FEE_X96,
            liquidationFeeSplitX96: LIQUIDATION_FEE_SPLIT_X96,
            fundingInterval: FUNDING_INTERVAL,
            tickSpacing: TICK_SPACING,
            startingSqrtPriceX96: STARTING_SQRT_PRICE_X96,
            initialCardinalityNext: INITIAL_CARDINALITY_NEXT
        });

        PerpHook perpHook = PerpHook(PERP_HOOK);
        perpHook.createPerp(createPerpParams);

        vm.stopBroadcast();
    }
}
