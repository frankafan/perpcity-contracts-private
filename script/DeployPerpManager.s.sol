// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeployPerpManager
/// @notice Deploys the PerpManager contract as a Uniswap V4 hook
contract DeployPerpManager is Script {
    /// @notice The address of the PoolManager contract
    IPoolManager public constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    /// @notice The address of the USDC contract
    address public constant USDC = 0xC1a5D4E99BB224713dd179eA9CA2Fa6600706210;
    /// @notice The address of the owner
    address public constant OWNER = 0x0000000000000000000000000000000000000000;

    /// @notice Deploys PerpManager
    function run() public {
        vm.startBroadcast();

        PerpManager perpManager = new PerpManager(POOL_MANAGER, USDC, OWNER);
        console2.log("PerpManager: ", address(perpManager));

        vm.stopBroadcast();
    }
}
