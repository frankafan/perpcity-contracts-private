// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PoolManagerBytecode} from "./PoolManagerBytecode.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Test} from "forge-std/Test.sol";

contract DeployPoolManager is PoolManagerBytecode, Test {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    function deployPoolManager() public returns (IPoolManager) {
        vm.etch(address(POOL_MANAGER), POOL_MANAGER_BYTECODE);
        return POOL_MANAGER;
    }
}
