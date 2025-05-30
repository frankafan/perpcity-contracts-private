// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { PerpRegistry } from "../src/PerpRegistry.sol";

contract DeployRegistry is Script {
    PerpRegistry public registry;

    address public constant OWNER = 0xCe5300d186999d014b0F4802a0ef6F97c4381196;

    function run() public {
        vm.startBroadcast();

        registry = new PerpRegistry(OWNER);

        console2.log("PerpRegistry: ", address(registry));

        vm.stopBroadcast();
    }
}
