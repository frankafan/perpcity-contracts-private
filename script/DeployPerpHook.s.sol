// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { PerpHook } from "../src/PerpHook.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract DeployPerpHook is Script {
    address public constant POOLMANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(POOLMANAGER);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(PerpHook).creationCode, constructorArgs);

        vm.startBroadcast();

        PerpHook perpHook = new PerpHook{ salt: salt }(IPoolManager(POOLMANAGER));
        require(address(perpHook) == hookAddress, "PerpHookScript: hook address mismatch");

        console2.log("PerpHook: ", address(perpHook));

        vm.stopBroadcast();
    }
}
