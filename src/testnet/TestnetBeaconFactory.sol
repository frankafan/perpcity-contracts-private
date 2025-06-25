// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { TestnetBeacon } from "./TestnetBeacon.sol";

contract TestnetBeaconFactory {
    function createBeacon(address owner) external returns (address) {
        return address(new TestnetBeacon(owner));
    }
}
