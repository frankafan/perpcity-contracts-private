// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeployPerpManager
/// @notice Deploys the PerpManager contract as a Uniswap V4 hook
contract DeployPerpManager is Script {
    /// @notice The address of the PoolManager contract
    address public constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    /// @notice The address of the USDC contract
    address public constant USDC = 0xC1a5D4E99BB224713dd179eA9CA2Fa6600706210;
    /// @notice The address of the CREATE2 Deployer contract
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Mines for a valid hook address and deploys the PerpManager contract to it
    function run() public {
        vm.startBroadcast();

        // specify the absence of every hook flag since no hooks are implemented in PerpManager
        uint160 flags = 0;

        // obtain the creation code of the PerpManager contract
        bytes memory creationCode = type(PerpManager).creationCode;

        // prepare encoded constructor arguments to help compute addresses during mining
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), USDC);

        // mine a salt that will produce a fresh hook address with the correct flags
        (address hookAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        // deploy the PerpManager contract to the mined hook address
        PerpManager perpManager = new PerpManager{salt: salt}(IPoolManager(POOL_MANAGER), USDC);
        require(address(perpManager) == hookAddress, "hook address mismatch");
        console2.log("PerpManager: ", address(perpManager));

        vm.stopBroadcast();
    }
}
