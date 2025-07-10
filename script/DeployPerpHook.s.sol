// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { PerpHook } from "../src/PerpHook.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import { ExternalContracts } from "../src/libraries/ExternalContracts.sol";
import { IUniversalRouter } from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { IPermit2 } from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployPerpHook is Script {
    address public constant POOLMANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address public constant ROUTER = 0x492E6456D9528771018DeB9E87ef7750EF184104;
    address public constant POSITION_MANAGER = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant USDC = 0xC1a5D4E99BB224713dd179eA9CA2Fa6600706210;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public {
        vm.startBroadcast();

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        // Create the ExternalContracts struct
        ExternalContracts.Contracts memory contracts = ExternalContracts.Contracts({
            poolManager: IPoolManager(POOLMANAGER),
            router: IUniversalRouter(ROUTER),
            positionManager: IPositionManager(POSITION_MANAGER),
            permit2: IPermit2(PERMIT2),
            usdc: IERC20(USDC)
        });

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(contracts);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(PerpHook).creationCode, constructorArgs);

        PerpHook perpHook = new PerpHook{ salt: salt }(contracts);
        require(address(perpHook) == hookAddress, "PerpHookScript: hook address mismatch");

        console2.log("PerpHook: ", address(perpHook));

        vm.stopBroadcast();
    }
}
