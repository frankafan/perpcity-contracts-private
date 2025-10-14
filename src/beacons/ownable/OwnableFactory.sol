// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {OwnableBeacon} from "./OwnableBeacon.sol";

/// @title OwnableFactory
/// @notice A helper factory for deploying OwnableBeacons
contract OwnableFactory {
    /* EVENTS */

    /// @notice Event emitted when a beacon is created
    /// @param beacon The address of the created beacon
    event BeaconCreated(address beacon);

    /* FUNCTIONS */

    /// @notice Create an OwnableBeacon
    /// @param owner The owner of the beacon
    /// @param initialIndexX96 The initial data of the beacon scaled by 2^96
    /// @param initialCardinalityCap The initial cardinality cap set for the beacon's time weighted average
    /// @return beacon The address of the created beacon
    function createBeacon(address owner, uint256 initialIndexX96, uint16 initialCardinalityCap)
        external
        returns (address beacon)
    {
        beacon = address(new OwnableBeacon(owner, initialIndexX96, initialCardinalityCap));
        emit BeaconCreated(beacon);
    }
}
