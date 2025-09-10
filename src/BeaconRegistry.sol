// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IBeacon} from "./interfaces/IBeacon.sol";
import {Ownable} from "@solady/src/auth/Ownable.sol";

contract BeaconRegistry is Ownable {
    mapping(address => bool) public beacons;

    event BeaconRegistered(address beacon, uint256 data);
    event BeaconUnregistered(address beacon, uint256 data);

    constructor(address owner) {
        _initializeOwner(owner);
    }

    function registerBeacon(address beacon) external onlyOwner {
        beacons[beacon] = true;
        uint256 data = IBeacon(beacon).getData();

        emit BeaconRegistered(beacon, data);
    }

    function unregisterBeacon(address beacon) external onlyOwner {
        beacons[beacon] = false;
        uint256 data = IBeacon(beacon).getData();

        emit BeaconUnregistered(beacon, data);
    }
}
