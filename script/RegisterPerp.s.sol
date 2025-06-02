// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { PerpRegistry } from "../src/PerpRegistry.sol";

contract RegisterPerp is Script {
    address public constant OWNER = 0xCe5300d186999d014b0F4802a0ef6F97c4381196;
    address public constant REGISTRY = 0x37c1387b55214324B63452931B44109EA5F7c8a4;
    address public constant PERP = 0x569af394601aab1ef01622Fa27aeF15367220785;

    function run() public {
        vm.startBroadcast(OWNER);

        PerpRegistry(REGISTRY).registerPerp(PERP);

        vm.stopBroadcast();
    }
}
