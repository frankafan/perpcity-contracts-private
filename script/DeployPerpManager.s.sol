// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {PerpManager} from "../src/PerpManager.sol";

import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script, console2} from "forge-std/Script.sol";

contract DeployPerpManager is Script {
    using SafeTransferLib for address;

    // replace addresses as needed
    address public constant POOLMANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address public constant ROUTER = 0x492E6456D9528771018DeB9E87ef7750EF184104;
    address public constant POSITION_MANAGER = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address public constant USDC = 0xC1a5D4E99BB224713dd179eA9CA2Fa6600706210;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address public constant CREATION_FEE_RECIPIENT = 0x0000000000000000000000000000000000000000;

    uint256 public constant CREATION_FEE = 1_000_000; // 1 USDC

    function run() public {
        vm.startBroadcast();

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        // Create the ExternalContracts struct
        IPerpManager.ExternalContracts memory contracts = IPerpManager.ExternalContracts({
            poolManager: IPoolManager(POOLMANAGER),
            router: IUniversalRouter(ROUTER),
            posm: IPositionManager(POSITION_MANAGER),
            usdc: USDC
        });

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(contracts, CREATION_FEE, CREATION_FEE_RECIPIENT);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(PerpManager).creationCode, constructorArgs);

        PerpManager perpManager = new PerpManager{salt: salt}(contracts, CREATION_FEE, CREATION_FEE_RECIPIENT);
        require(address(perpManager) == hookAddress, "hook address mismatch");

        console2.log("PerpManager: ", address(perpManager));

        vm.stopBroadcast();
    }
}
