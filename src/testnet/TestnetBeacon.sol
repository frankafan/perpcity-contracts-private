// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { IBeacon } from "../interfaces/IBeacon.sol";

contract TestnetBeacon is IBeacon {
    uint256 private data;
    uint256 private timestamp;

    event DataUpdated(uint256 data);

    function getData() public view returns (uint256, uint256) {
        return (data, timestamp);
    }

    function updateData(bytes memory proof, bytes memory publicSignals) external {
        data = abi.decode(publicSignals, (uint256));
        timestamp = block.timestamp;

        emit DataUpdated(data);
    }
}
