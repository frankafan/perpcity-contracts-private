// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { TestnetUSDC } from "../src/testnet/TestnetUSDC.sol";

contract DeployTestnetUSDC is Script {
    TestnetUSDC public usdc;

    function run() public {
        vm.startBroadcast();

        usdc = new TestnetUSDC();

        console2.log("TestnetUSDC: ", address(usdc));

        vm.stopBroadcast();
    }
}
