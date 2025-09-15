// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";

import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {Script, console2} from "forge-std/Script.sol";

contract DeployPerpManager is Script {
    using SafeTransferLib for address;

    // replace addresses as needed
    address public constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address public constant USDC = 0xC1a5D4E99BB224713dd179eA9CA2Fa6600706210;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public {
        vm.startBroadcast();

        uint160 flags = 0;

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), USDC);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(PerpManager).creationCode, constructorArgs);

        PerpManager perpManager = new PerpManager{salt: salt}(IPoolManager(POOL_MANAGER), USDC);
        require(address(perpManager) == hookAddress, "hook address mismatch");

        console2.log("PerpManager: ", address(perpManager));

        vm.stopBroadcast();
    }
}
