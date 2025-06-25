// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { TestnetBeacon } from "./TestnetBeacon.sol";

contract TestnetBeaconFactory {
    event BeaconCreated(address beacon);

    function createBeacon(address owner) external returns (address) {
        address beacon = address(new TestnetBeacon(owner));
        emit BeaconCreated(beacon);
        return beacon;
    }
}
