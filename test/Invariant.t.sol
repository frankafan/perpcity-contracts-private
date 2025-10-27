// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";
import {PerpHandler} from "./PerpHandler.sol";
import {DeployPoolManager} from "./utils/DeployPoolManager.sol";
import {TestnetUSDC} from "./utils/TestnetUSDC.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Test} from "forge-std/Test.sol";

contract InvariantTest is Test, DeployPoolManager {
    function setUp() public {
        IPoolManager poolManager = deployPoolManager();
        address usdc = address(new TestnetUSDC());
        address owner = makeAddr("owner");

        PerpManager perpManager = new PerpManager(poolManager, usdc, owner);
        PerpHandler perpHandler = new PerpHandler(perpManager, usdc, 10);

        targetContract(address(perpHandler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = PerpHandler.createPerp.selector;
        selectors[1] = PerpHandler.openMakerPosition.selector;
        selectors[2] = PerpHandler.addMakerMargin.selector;
        selectors[3] = PerpHandler.closeMakerPosition.selector;
        selectors[4] = PerpHandler.openTakerPosition.selector;
        selectors[5] = PerpHandler.addTakerMargin.selector;
        selectors[6] = PerpHandler.closeTakerPosition.selector;

        targetSelector(FuzzSelector({addr: address(perpHandler), selectors: selectors}));
    }

    function invariant_no_reverts() public {
        vm.skip(true); // skip test
    }
}
