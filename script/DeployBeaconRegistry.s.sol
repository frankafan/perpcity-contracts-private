// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {BeaconRegistry} from "../src/BeaconRegistry.sol";
import {Script, console2} from "forge-std/Script.sol";

contract DeployBeaconRegistry is Script {
    BeaconRegistry public registry;

    address public constant OWNER = 0xCe5300d186999d014b0F4802a0ef6F97c4381196; // replace with owner address

    function run() public {
        vm.startBroadcast();

        registry = new BeaconRegistry(OWNER);

        console2.log("BeaconRegistry: ", address(registry));

        vm.stopBroadcast();
    }
}
