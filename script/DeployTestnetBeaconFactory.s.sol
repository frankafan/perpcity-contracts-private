// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { TestnetBeaconFactory } from "../src/testnet/TestnetBeaconFactory.sol";

contract DeployTestnetBeaconFactory is Script {
    TestnetBeaconFactory public factory;

    function run() public {
        vm.startBroadcast();

        factory = new TestnetBeaconFactory();

        console2.log("TestnetBeaconFactory: ", address(factory));

        vm.stopBroadcast();
    }
}
