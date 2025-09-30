// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {OwnableBeacon} from "./OwnableBeacon.sol";

contract OwnableFactory {
    event BeaconCreated(address beacon);

    function createBeacon(
        address owner,
        uint256 initialPriceX96,
        uint32 initialCardinalityNext
    )
        external
        returns (address)
    {
        address beacon = address(new OwnableBeacon(owner, initialPriceX96, initialCardinalityNext));
        emit BeaconCreated(beacon);
        return beacon;
    }
}
