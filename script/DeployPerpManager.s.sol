// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Script, console2} from "forge-std/Script.sol";

contract DeployPerpManager is Script {
    IPoolManager public immutable POOL_MANAGER = IPoolManager(vm.envAddress("POOL_MANAGER"));
    address public immutable USDC = vm.envAddress("USDC");
    address public immutable OWNER = vm.envAddress("OWNER");

    function run() public {
        vm.startBroadcast();

        PerpManager perpManager = new PerpManager(POOL_MANAGER, USDC, OWNER);
        console2.log("PerpManager: ", address(perpManager));

        vm.stopBroadcast();
    }
}
