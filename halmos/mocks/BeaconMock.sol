// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {OwnableBeacon} from "../../src/beacons/ownable/OwnableBeacon.sol";

/// @notice Mock Beacon for Halmos Testing
contract BeaconMock is OwnableBeacon {
    constructor(
        address owner,
        uint256 initialIndexX96,
        uint16 initialCardinalityCap
    ) OwnableBeacon(owner, initialIndexX96, initialCardinalityCap) {}
}
