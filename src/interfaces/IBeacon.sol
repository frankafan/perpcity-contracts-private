// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

interface IBeacon {
    function getData() external returns (uint256 data, uint256 timestamp);

    function updateData(bytes calldata proof, bytes calldata publicSignals) external;
}
