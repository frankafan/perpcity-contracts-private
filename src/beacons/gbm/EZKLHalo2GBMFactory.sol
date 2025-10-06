// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IEZKLHalo2Verifier} from "../../interfaces/beacons/IEZKLHalo2Verifier.sol";
import {EZKLHalo2VerifierWrapper} from "./EZKLHalo2VerifierWrapper.sol";
import {GBMBeacon} from "./GBMBeacon.sol";

/// @title EZKLHalo2GBMFactory
/// @notice A helper factory for deploying GBM beacons using EZKL Halo2 verifiers
contract EZKLHalo2GBMFactory {
    /* CONSTANTS */

    /// @notice The initial index for the GBM beacon
    /// @dev Equal to 100 * 2^96
    uint256 public constant INITIAL_INDEX_X96 = 7922816251426433759354395033600;

    /* EVENTS */

    /// @notice Event emitted when a beacon is created
    /// @param beacon The address of the created beacon
    event BeaconCreated(address beacon);

    /* FUNCTIONS */

    /// @notice Create a GBM beacon using an EZKL Halo2 verifier
    /// @dev Uses `verifier` to create a EZKLHalo2VerifierWrapper and pass it to the beacon constructor
    /// @param verifier The EZKL Halo2 verifier to use
    /// @param owner The owner of the beacon
    /// @param initialCardinalityCap The initial cardinality cap set for the beacon's time weighted average
    /// @param thresholdX96 The beacon's threshold used in binary classification of data in public signals
    /// Must be 0-1 scaled by 2^96. Example: 0.5 is represented as 39614081257132168796771975168 (0.5 * 2^96)
    /// @param sigmaBase The beacon's base volatility scaled by 1e18. Example 0.001 is represented as 0.001e18
    /// It is used to calculate SIGMA_UP_EXP_WAD and SIGMA_DOWN_EXP_WAD
    /// @param positiveRate The beacon's positive rate. Must be 0-1 scaled by 1e18. Values < 0.5 cause a downward bias,
    /// and values > 0.5 cause an upward bias
    /// @return beacon The address of the created beacon
    function createBeacon(
        IEZKLHalo2Verifier verifier,
        address owner,
        uint16 initialCardinalityCap,
        uint256 thresholdX96,
        uint256 sigmaBase,
        uint256 positiveRate
    ) external returns (address beacon) {
        beacon = address(
            new GBMBeacon(
                new EZKLHalo2VerifierWrapper(verifier),
                owner,
                INITIAL_INDEX_X96,
                initialCardinalityCap,
                thresholdX96,
                sigmaBase,
                positiveRate
            )
        );
        emit BeaconCreated(beacon);
    }
}
