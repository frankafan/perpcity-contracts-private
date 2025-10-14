// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IBeacon} from "../interfaces/beacons/IBeacon.sol";
import {Ownable} from "@solady/src/auth/Ownable.sol";

/// @title BeaconRegistry
/// @notice A registry for beacons
contract BeaconRegistry is Ownable {
    /* STORAGE */

    /// @notice A mapping of beacon addresses to their registration status
    mapping(address beacon => bool registered) public beacons;

    /* EVENTS */

    /// @notice Event emitted when a beacon is registered
    /// @param beacon The address of the registered beacon
    /// @param data The data of the beacon at the time of registration
    event BeaconRegistered(address beacon, uint256 data);

    /// @notice Event emitted when a beacon is unregistered
    /// @param beacon The address of the unregistered beacon
    /// @param data The data of the beacon at the time of unregistration
    event BeaconUnregistered(address beacon, uint256 data);

    /* CONSTRUCTOR */

    /// @notice Instantiates the BeaconRegistry
    /// @param owner The owner of the BeaconRegistry
    constructor(address owner) {
        _initializeOwner(owner);
    }

    /* FUNCTIONS */

    /// @notice Register a beacon
    /// @dev Only the owner can register beacons. They should ensure the beacon is valid before registering it.
    /// @param beacon The address of the beacon to register
    function registerBeacon(address beacon) external onlyOwner {
        beacons[beacon] = true;
        emit BeaconRegistered(beacon, IBeacon(beacon).data());
    }

    /// @notice Unregister a beacon
    /// @dev Only the owner can unregister beacons
    /// @param beacon The address of the beacon to unregister
    function unregisterBeacon(address beacon) external onlyOwner {
        beacons[beacon] = false;
        emit BeaconUnregistered(beacon, IBeacon(beacon).data());
    }
}
