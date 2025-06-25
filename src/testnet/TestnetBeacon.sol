// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { IBeacon } from "../interfaces/IBeacon.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract TestnetBeacon is IBeacon, Ownable {
    uint256 private data;
    uint256 private timestamp;

    event DataUpdated(uint256 data);

    constructor(address owner) Ownable(owner) { }

    function getData() public view returns (uint256, uint256) {
        return (data, timestamp);
    }

    function updateData(bytes memory proof, bytes memory publicSignals) external onlyOwner {
        data = abi.decode(publicSignals, (uint256));
        timestamp = block.timestamp;

        emit DataUpdated(data);
    }
}
