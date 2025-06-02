// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { TestnetBeacon } from "../src/testnet/TestnetBeacon.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

contract UpdateBeacon is Script {
    address public constant BEACON = 0xB4BF59f4958e5EDE1A463A3AeB587d4Cc2D8aDF6;

    uint256 public constant NEW_PRICE = 46 * FixedPoint96.Q96;

    function run() public {
        vm.startBroadcast();

        TestnetBeacon(BEACON).updateData(bytes(""), bytes(abi.encode(NEW_PRICE)));

        vm.stopBroadcast();
    }
}
