// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {TradingFee} from "../src/libraries/TradingFee.sol";
import {TestnetUSDC} from "../src/testnet/TestnetUSDC.sol";
import {PerpHandler} from "./PerpHandler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Test} from "forge-std/Test.sol";

contract InvariantTest is Test {
    IPoolManager public manager;
    address public usdc;

    function setUp() public {
        bytes memory args = abi.encode(address(0));
        bytes memory bytecode = abi.encodePacked(vm.getCode("PoolManager.sol:PoolManager"), args);
        address poolManager;
        assembly {
            poolManager := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        manager = IPoolManager(poolManager);

        usdc = address(new TestnetUSDC());

        // Since PerpManager.sol is a hook, we need to deploy it to an address with the correct flags
        address flags = address(
            uint160(0) ^ (0x5555 << 144) // Namespace the address to avoid collisions
        );

        // Add all necessary constructor arguments for PerpManager.sol
        bytes memory constructorArgs = abi.encode(manager, usdc);

        // Use StdCheats.deployCodeTo to deploy the PerpManager.sol contract to the flags address
        deployCodeTo("PerpManager.sol:PerpManager", constructorArgs, flags);

        PerpHandler perpHandler = new PerpHandler(PerpManager(flags), usdc, 10);

        targetContract(address(perpHandler));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PerpHandler.createPerp.selector;
        // selectors[1] = PerpHandler.openMakerPosition.selector;
        // selectors[2] = PerpHandler.addMakerMargin.selector;
        // selectors[3] = PerpHandler.closeMakerPosition.selector;
        // selectors[4] = PerpHandler.openTakerPosition.selector;

        targetSelector(FuzzSelector({addr: address(perpHandler), selectors: selectors}));
    }

    function invariant_no_reverts() public {
        assert(true);
    }
}
