// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { TestnetBeacon } from "../src/testnet/TestnetBeacon.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

contract DeployTestnetBeacon is Script {
    TestnetBeacon public beacon;

    uint256 public constant STARTING_PRICE = 50 * FixedPoint96.Q96;
    address public constant OWNER = 0x0000000000000000000000000000000000000000;
    uint256 public constant INITIAL_DATA = 50 * FixedPoint96.Q96;
    uint32 public constant INITIAL_CARDINALITY_NEXT = 100;

    function run() public {
        vm.startBroadcast();

        beacon = new TestnetBeacon(OWNER, INITIAL_DATA, INITIAL_CARDINALITY_NEXT);

        beacon.updateData(bytes(""), bytes(abi.encode(STARTING_PRICE)));

        console2.log("TestnetBeacon: ", address(beacon));

        vm.stopBroadcast();
    }
}
