// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";

// The maximum usable length of the observations array is 2^16 - 1 so that max iterations in binary search is 16
uint256 constant MAX_CARDINALITY_CAP = 65_535;

/// @title TimeWeightedAvg
/// @notice Provides utility to track a value and calculate time weighted averages on it
/// @dev Instances of the value at a given timestamp are stored in an observations array. This array is initialized with
/// a cap of usable slots at 1. Anyone can pay the SSTOREs needed to increase this cap. Observations are overwritten
/// when the cap of usable slots is reached.
library TimeWeightedAvg {
    using SafeCastLib for uint256;

    /* STRUCTS */

    /// @notice State that must be stored by contracts using this library
    /// @param index The index of the most recent observation
    /// @param cardinality The number of usable slots in the observations array
    /// @param cardinalityCap The max size cardinality can be increased to.
    /// cardinalityCap itself can also be increased up to MAX_CARDINALITY_CAP
    /// @param observations The array of observations
    struct State {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityCap;
        Observation[MAX_CARDINALITY_CAP] observations;
    }

    /// @notice Observation stored each time the value being tracked changes
    /// @param timestamp The timestamp of the observation
    /// @param cumulativeVal The value accumulator, i.e. value * time elapsed since the first observation
    /// @param initialized Whether the observation is initialized
    struct Observation {
        uint32 timestamp;
        uint216 cumulativeVal;
        bool initialized;
    }

    /* FUNCTIONS */

    /// @notice Initialize the observations array by writing the first slot
    /// @dev This should only be called once for the lifecycle of State
    /// @param state The caller's time weighted average helper data and observation history
    /// @param blockTimestamp The time of initialization, via block.timestamp truncated to uint32
    function initialize(State storage state, uint32 blockTimestamp) internal {
        state.observations[0] = Observation({timestamp: blockTimestamp, cumulativeVal: 0, initialized: true});
        state.cardinality = state.cardinalityCap = 1;
    }

    /// @notice Allows cardinality to be increased to `newCap` when cardinality reaches old capacity
    /// @param state The caller's time weighted average helper data and observation history
    /// @param newCap The proposed new cardinality cap
    function increaseCardinalityCap(State storage state, uint16 newCap) internal {
        // no-op if the passed newCap value isn't greater than the current newCap value
        if (newCap <= state.cardinalityCap) return;

        // store non-zero values in each slot to prevent fresh SSTOREs when they are first used
        // these observations will not be in calculations since they are not initialized
        for (uint16 i = state.cardinalityCap; i < newCap; i++) {
            state.observations[i].timestamp = 1;
        }
        state.cardinalityCap = newCap;
    }

    /// @notice Calculates a new observation given the most recent observation
    /// @param recentObservation The most recent observation stored
    /// @param blockTimestamp The timestamp of the new observation. This must be at or after recentObservation.timestamp
    /// @param currentVal The value at the time of the new observation
    /// @return newObservation The new observation to be stored
    function calcObservation(Observation memory recentObservation, uint32 blockTimestamp, uint256 currentVal)
        private
        pure
        returns (Observation memory newObservation)
    {
        uint32 timePassed = blockTimestamp - recentObservation.timestamp;
        return Observation({
            timestamp: blockTimestamp,
            cumulativeVal: (recentObservation.cumulativeVal + currentVal * timePassed).toUint216(),
            initialized: true
        });
    }

    /// @notice Writes an observation to the array
    /// @dev Writes at most once per block
    /// @param state The caller's time weighted average helper data and observation history
    /// @param blockTimestamp The timestamp of the new observation
    /// @param currentVal The value at the time of the new observation
    function write(State storage state, uint32 blockTimestamp, uint256 currentVal) internal {
        uint16 cardinality = state.cardinality;
        uint16 cardinalityCap = state.cardinalityCap;
        Observation memory recentObservation = state.observations[state.index];

        // early return if we've already written an observation this block
        if (recentObservation.timestamp == blockTimestamp) return;

        // if cardinality is below the cap, we can bump cardinality to cardinalityCap
        // index has to be at the end of the array's usable slots to maintain ordering
        if (cardinalityCap > cardinality && state.index == (cardinality - 1)) state.cardinality = cardinalityCap;

        // wrap index around to the beginning of the observations array if cardinality is at capacity
        state.index = (state.index + 1) % state.cardinality;
        // use the most recent observation to calculate the next observation and store it at the new index
        state.observations[state.index] = calcObservation(recentObservation, blockTimestamp, currentVal);
    }

    /// @notice Fetches the observations beforeOrAt & atOrAfter a target such that target is in [beforeOrAt, atOrAfter]
    /// @dev The results could be the same when cardinality = 1. The target must be older than the most recent
    /// observation and newer (or the same age as) the oldest observation
    /// @param state The caller's time weighted average helper data and observation history
    /// @param oldestObservationIndex The index of the oldest observation
    /// @param targetTimestamp The timestamp to bracket beforeOrAt & atOrAfter around
    /// @return beforeOrAt The observation recorded before, or at, the target
    /// @return atOrAfter The observation recorded at, or after, the target
    function binarySearch(State storage state, uint16 oldestObservationIndex, uint32 targetTimestamp)
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        uint256 cardinality = state.cardinality;
        Observation[MAX_CARDINALITY_CAP] storage observations = state.observations;

        uint256 l = oldestObservationIndex;
        // if l is 0, then the most recent observation written to is the current index
        // otherwise, we need to account for wrapping
        uint256 r = l == 0 ? state.index : l + cardinality - 1;
        uint256 i;

        while (true) {
            // calculate middle observation index
            i = (l + r) / 2;

            // the actual index requires i % cardinality to wrap around if needed
            beforeOrAt = observations[i % cardinality];
            // set atOrAfter to the observation index after beforeOrAt
            atOrAfter = observations[(i + 1) % cardinality];

            if (beforeOrAt.timestamp <= targetTimestamp) {
                // if beforeOrAt <= targetTimestamp <= atOrAfter, we've found the answer
                if (targetTimestamp <= atOrAfter.timestamp) break;
                // else, beforeOrAt <= targetTimestamp but targetTimestamp > atOrAfter, so we need to search higher
                l = i + 1;
            } else {
                // beforeOrAt > targetTimestamp, so we need to search lower
                r = i - 1;
            }
        }
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a given target timestamp
    /// @dev the oldest observation will be returned if target is before or at the oldest observation.
    /// targetTimestamp must be older (or the same age as) block.timestamp
    /// @param state The caller's time weighted average helper data and observation history
    /// @param targetTimestamp The timestamp to bracket beforeOrAt & atOrAfter around
    /// @param currentVal The current value
    /// @return beforeOrAt The observation which occurred at, or before, the given timestamp
    /// @return atOrAfter The observation which occurred at, or after, the given timestamp
    function surrounding(State storage state, uint32 targetTimestamp, uint256 currentVal)
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        Observation[MAX_CARDINALITY_CAP] storage observations = state.observations;

        // if the target is before the oldest observation, we use the oldest observation's timestamp as the target
        uint16 oldestObservationIndex = (state.index + 1) % state.cardinality;
        Observation memory oldest = observations[oldestObservationIndex];
        // after a cardinality bump, oldest slot (slot to write to next) may be uninitialized, so use slot 0 instead
        if (!oldest.initialized) oldest = observations[oldestObservationIndex = 0];
        // use oldest observation as answer if target is before or at the oldest observation
        if (targetTimestamp <= oldest.timestamp) return (oldest, oldest);

        Observation memory newest = state.observations[state.index];

        // if the most recent observation's timestamp is the target, we know mostRecent = beforeOrAt = atOrAfter
        if (targetTimestamp == newest.timestamp) return (newest, newest);
        // if target timestamp is after the most recent observation, we know beforeOrAt = most recent observation
        // and atOrAfter must be calculated based on the current value and time passed since most recent observation
        if (targetTimestamp > newest.timestamp) return (newest, calcObservation(newest, targetTimestamp, currentVal));

        // if we've reached this point, we have to binary search
        return binarySearch(state, oldestObservationIndex, targetTimestamp);
    }

    /// @notice Returns the cumulative value at any timestamp from the oldest observation to block.timestamp.
    /// If called with a timestamp falling between two observations, returns the counterfactual cumulativeVal
    /// at exactly the timestamp between the two observations
    /// @dev It a target timestamp older than the oldest observation is given, the oldest observation is used.
    /// This funciton expects target timestamps equal to or older than block.timestamp
    /// @param state The caller's time weighted average helper data and observation history
    /// @param blockTimestamp The current block timestamp
    /// @param targetTimestamp The timestamp of returned `cumulativeVal`
    /// @param currentVal The current value
    /// @return cumulativeVal The cumulative value at the target timestamp
    function cumulativeValAtTimestamp(
        State storage state,
        uint32 blockTimestamp,
        uint32 targetTimestamp,
        uint256 currentVal
    ) internal view returns (uint216 cumulativeVal) {
        if (targetTimestamp == blockTimestamp) {
            Observation memory newest = state.observations[state.index];
            if (newest.timestamp != blockTimestamp) newest = calcObservation(newest, blockTimestamp, currentVal);
            return newest.cumulativeVal;
        }

        (Observation memory beforeOrAt, Observation memory atOrAfter) = surrounding(state, targetTimestamp, currentVal);

        // early return if one of the observations has a timestamp equal to the target
        if (targetTimestamp == beforeOrAt.timestamp) {
            return (beforeOrAt.cumulativeVal);
        } else if (targetTimestamp == atOrAfter.timestamp) {
            return (atOrAfter.cumulativeVal);
        }
        // otherwise, the target is in between the two observations
        else {
            uint216 totalSpan = atOrAfter.timestamp - beforeOrAt.timestamp; // time between beforeOrAt and atOrAfter
            uint216 spanToTarget = targetTimestamp - beforeOrAt.timestamp; // time between beforeOrAt and target
            uint216 cvDelta = atOrAfter.cumulativeVal - beforeOrAt.cumulativeVal; // Δ cumVal: beforeOrAt to atOrAfter

            // calculate the delta in cumulativeVal from beforeOrAt to target and add it to beforeOrAt's cumulativeVal
            return beforeOrAt.cumulativeVal + (cvDelta * spanToTarget / totalSpan);
        }
    }

    /// @notice Returns the time weighted average of tracked value given a lookback window
    /// @dev If the lookback window is 0, the current value is returned. If the lookback window points to a timestamp
    /// older than the oldest observation, then the window is capped to the time since the oldest observation.
    /// @param state The caller's time weighted average helper data and observation history
    /// @param lookbackWindow The time window to calculate the average over
    /// @param blockTimestamp The current block timestamp truncated to uint32
    /// @param currentVal The current value
    /// @return twAvg The calculated time weighted average
    function timeWeightedAvg(State storage state, uint32 lookbackWindow, uint32 blockTimestamp, uint256 currentVal)
        internal
        view
        returns (uint256 twAvg)
    {
        if (lookbackWindow == 0) return currentVal;

        uint32 targetTimestamp = blockTimestamp - lookbackWindow;
        uint256 cumulativeValStart = cumulativeValAtTimestamp(state, blockTimestamp, targetTimestamp, currentVal);
        uint256 cumulativeValEnd = cumulativeValAtTimestamp(state, blockTimestamp, blockTimestamp, currentVal);

        uint256 delta = cumulativeValEnd - cumulativeValStart;
        // if cumVal hasn't changed, return the current value; else, calculate and return the average over the window
        return delta == 0 ? currentVal : delta / lookbackWindow;
    }
}
