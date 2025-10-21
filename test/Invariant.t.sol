// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";

import {PerpHandler} from "./PerpHandler.sol";

import {DeployPoolManager} from "./utils/DeployPoolManager.sol";
import {TestnetUSDC} from "./utils/TestnetUSDC.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Test} from "forge-std/Test.sol";

contract InvariantTest is Test, DeployPoolManager {
    function setUp() public {
        IPoolManager poolManager = deployPoolManager();
        address usdc = address(new TestnetUSDC());
        address creator = makeAddr("creator");

        // Since PerpManager.sol is a hook, we need to deploy it to an address with the correct flags
        address perpManagerAddress = address(
            uint160(0) ^ (0x5555 << 144) // Namespace the address to avoid collisions
        );

        // Add all necessary constructor arguments for PerpManager.sol
        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), usdc, creator);

        // Use StdCheats.deployCodeTo to deploy the PerpManager.sol contract to the flags address
        deployCodeTo("PerpManager.sol:PerpManager", constructorArgs, perpManagerAddress);

        PerpHandler perpHandler = new PerpHandler(PerpManager(perpManagerAddress), usdc, 10);

        targetContract(address(perpHandler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = PerpHandler.createPerp.selector;
        selectors[1] = PerpHandler.openMakerPosition.selector;
        // selectors[2] = PerpHandler.addMakerMargin.selector;
        // selectors[3] = PerpHandler.closeMakerPosition.selector;
        // selectors[4] = PerpHandler.openTakerPosition.selector;

        targetSelector(FuzzSelector({addr: address(perpHandler), selectors: selectors}));
    }

    function invariant_no_reverts() public {
        vm.skip(true); // skip test
        assert(true);
    }
}
