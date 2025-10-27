// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";
import {IBeacon} from "../src/interfaces/beacons/IBeacon.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

contract PerpHandler is Test {
    PerpManager public immutable PERP_MANAGER;
    address public immutable USDC;
    address public immutable LIQUIDATOR = makeAddr("liquidator");

    PoolId[] public perps;
    IBeacon[] public beacons;
    address[] public actors;

    mapping(PoolId => uint128[]) public makerPositions;
    mapping(PoolId => uint128[]) public takerPositions;

    constructor(PerpManager perpManager, address usdc, uint256 actorCount) {
        require(actorCount > 0, "at least one actor required");

        PERP_MANAGER = perpManager;
        USDC = usdc;

        for (uint256 i = 0; i < actorCount; i++) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
            console2.log("Actor: ", actors[i]);
        }
        console2.log();
    }

    /* PERP FUNCTIONS */

    function createPerp() public {}

    function openMakerPosition() public {}

    function addMakerMargin() public {}

    function closeMakerPosition() public {}

    function openTakerPosition() public {}

    function addTakerMargin() public {}

    function closeTakerPosition() public {}

    function increaseCardinalityNext_Perp() public {}

    /* BEACON ACTIONS */

    function updateData() public {}

    function increaseCardinalityNext_Beacon() public {}

    /* UTILITY FUNCTIONS */

    // this is a workaround via ir caching block.timestamp
    function time() external view returns (uint256) {
        return block.timestamp;
    }
}
