// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

interface ITimeWeightedAvg {
    function getTimeWeightedAvg(uint32 secondsAgo) external view returns (uint256);
}
