// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {TestnetUSDC} from "../src/testnet/TestnetUSDC.sol";
import {Script, console2} from "forge-std/Script.sol";

contract DeployTestnetUSDC is Script {
    TestnetUSDC public usdc;

    function run() public {
        vm.startBroadcast();

        usdc = new TestnetUSDC();

        console2.log("TestnetUSDC: ", address(usdc));

        vm.stopBroadcast();
    }
}
