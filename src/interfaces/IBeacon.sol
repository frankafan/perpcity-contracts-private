// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

interface IBeacon {
    function getData() external view returns (uint256 data);

    function updateData(bytes calldata proof, bytes calldata publicSignals) external;
}
