// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

/// @title ITimeWeightedAvg
/// @notice Interface that must be implemented by beacons used by perps in the PerpManager
interface ITimeWeightedAvg {
    /* FUNCTIONS */

    /// @notice Get the time weighted average
    /// @param secondsAgo The number of seconds to look back when computing the time weighted average
    /// @return timeWeightedAvg The time weighted average
    function timeWeightedAvg(uint32 secondsAgo) external view returns (uint256 timeWeightedAvg);

    /// @notice Increase the number of observations that can be stored to help compute time weighted averages
    /// @param newCap The new cardinality cap
    function increaseCardinalityCap(uint16 newCap) external;
}
