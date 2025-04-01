// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

interface IBeacon {
    function getData() external returns (uint256 data);

    function getDataTimestamp() external view returns (uint256 dataTimestamp);

    function getFee() external view returns (uint256 fee);

    function getVault() external view returns (address vault);
}
