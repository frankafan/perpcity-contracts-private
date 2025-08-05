// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { TestnetBeacon } from "./TestnetBeacon.sol";

contract TestnetBeaconFactory {
    event BeaconCreated(address beacon);

    function createBeacon(
        address owner,
        uint256 initialData,
        uint32 initialCardinalityNext
    )
        external
        returns (address)
    {
        address beacon = address(new TestnetBeacon(owner, initialData, initialCardinalityNext));
        emit BeaconCreated(beacon);
        return beacon;
    }
}
