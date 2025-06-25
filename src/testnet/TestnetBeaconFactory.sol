// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { TestnetBeacon } from "./TestnetBeacon.sol";

event BeaconCreated(address beacon);

contract TestnetBeaconFactory {
    function createBeacon(address owner) external returns (address) {
        TestnetBeacon beacon = new TestnetBeacon(owner);
        emit BeaconCreated(address(beacon));
        return address(beacon);
    }
}
