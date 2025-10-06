// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IBeacon} from "../../interfaces/beacons/IBeacon.sol";
import {ITimeWeightedAvg} from "../../interfaces/ITimeWeightedAvg.sol";
import {IVerifierWrapper} from "../../interfaces/beacons/IVerifierWrapper.sol";

import {UINT_Q96} from "../../libraries/Constants.sol";
import {TimeWeightedAvg} from "../../libraries/TimeWeightedAvg.sol";
import {Ownable} from "@solady/src/auth/Ownable.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";

/// @title GBMBeacon
/// @notice A beacon that uses a GBM model to update its data
contract GBMBeacon is IBeacon, ITimeWeightedAvg, Ownable {
    using FixedPointMathLib for *;
    using SafeCastLib for *;
    using TimeWeightedAvg for TimeWeightedAvg.State;

    /* CONSTANTS */

    /// @notice The scale of outputs from expWad()
    uint256 internal constant WAD = 1e18;

    /* IMMUTABLES */

    /// @notice The threshold used in binary classification of data in public signals
    /// @dev This is scaled by 2^96, so 0.5 is 39614081257132168796771975168 (0.5 * 2^96)
    uint256 public immutable THRESHOLD_X96;
    /// @notice e^(upwards volatility) scaled by 1e18
    /// @dev Used as factor to upscale indexX96 when data is above threshold
    uint256 public immutable SIGMA_UP_EXP_WAD;
    /// @notice e^(downwards volatility) scaled by 1e18
    /// @dev Used as factor to downscale indexX96 when data is below threshold
    uint256 public immutable SIGMA_DOWN_EXP_WAD;

    /// @notice The verifier wrapper used to validate proof and public signals pairs & extract data from public signals
    /// @dev The extracted data is expected to be a number from 0-1 scaled by 2^96
    IVerifierWrapper public immutable VERIFIER_WRAPPER;

    /* STORAGE */

    /// @notice The beacon's data
    /// @dev This is scaled by 2^96
    uint256 private indexX96;

    /// @notice The state used to track and calculate a time weighted average of `indexX96`
    TimeWeightedAvg.State public twAvgState;

    /// @notice Mapping to track used proofs
    mapping(bytes => bool) public usedProofs;
    /// @notice Mapping to track used public signals
    mapping(bytes => bool) public usedPublicSignals;

    /* ERRORS */

    /// @notice Thrown when the threshold is outside 0-1 scaled by 2^96
    error InvalidThreshold(uint256 thresholdX96);
    /// @notice Thrown when the positive rate is outside 0-1 scaled by 1e18
    error InvalidPositiveRate(uint256 positiveRate);
    /// @notice Thrown when the measurement is outside 0-1 scaled by 2^96
    error InvalidMeasurement(uint256 measurementX96);

    /* CONSTRUCTOR */

    /// @notice Instantiates the beacon
    /// @param verifierWrapper The verifier wrapper used to validate proof and public signals pairs &
    /// extract data from public signals. The extracted data is expected to be a number from 0-1 scaled by 2^96
    /// @param owner The owner of the beacon
    /// @param initialIndexX96 The initial data of the beacon scaled by 2^96
    /// @param initialCardinalityCap The initial cardinality cap set for the beacon's time weighted average
    /// @param thresholdX96 The beacon's threshold used in binary classification of data in public signals
    /// Must be 0-1 scaled by 2^96. Example: 0.5 is represented as 39614081257132168796771975168 (0.5 * 2^96)
    /// @param sigmaBase The beacon's base volatility scaled by 1e18. Example 0.001 is represented as 0.001e18
    /// It is used to calculate SIGMA_UP_EXP_WAD and SIGMA_DOWN_EXP_WAD
    /// @param positiveRate The beacon's positive rate. Must be 0-1 scaled by 1e18. Values < 0.5 cause a downward bias,
    /// and values > 0.5 cause an upward bias
    constructor(
        IVerifierWrapper verifierWrapper,
        address owner,
        uint256 initialIndexX96,
        uint16 initialCardinalityCap,
        uint256 thresholdX96,
        uint256 sigmaBase,
        uint256 positiveRate
    ) {
        if (thresholdX96 > UINT_Q96) revert InvalidThreshold(thresholdX96);
        if (positiveRate > WAD) revert InvalidPositiveRate(positiveRate);

        THRESHOLD_X96 = thresholdX96;
        // e^(-sigmaBase) scaled by 1e18
        SIGMA_DOWN_EXP_WAD = (-sigmaBase.toInt256()).expWad().toUint256();
        // e^(sigmaBase * (1 - positiveRate) / positiveRate) scaled by 1e18
        SIGMA_UP_EXP_WAD = sigmaBase.fullMulDiv(WAD - positiveRate, positiveRate).toInt256().expWad().toUint256();

        VERIFIER_WRAPPER = verifierWrapper;

        _initializeOwner(owner);
        indexX96 = initialIndexX96;

        // initialize twavg state, grow list to specified cardinality, and write first observation
        twAvgState.initialize(block.timestamp.toUint32());
        twAvgState.increaseCardinalityCap(initialCardinalityCap);
        twAvgState.write(block.timestamp.toUint32(), initialIndexX96);
    }

    /* FUNCTIONS */

    /// @inheritdoc IBeacon
    function data() external view returns (uint256 index) {
        return indexX96;
    }

    /// @inheritdoc IBeacon
    /// @dev only the owner can update data. They still need to provide a valid proof and public signals pair
    function updateData(bytes calldata proof, bytes calldata publicSignals) external onlyOwner {
        if (usedProofs[proof] && usedPublicSignals[publicSignals]) revert ProofAndPublicSignalsAlreadyUsed();

        usedProofs[proof] = true;
        usedPublicSignals[publicSignals] = true;

        // proofs & public signals are verified and measurementX96 is extracted
        (bool success, uint256 measurementX96) = VERIFIER_WRAPPER.verify(proof, publicSignals);
        // if verification fails, revert
        if (!success) revert VerificationFailed();
        // if measurementX96 is outside 0-1 scaled by 2^96, revert
        if (measurementX96 > UINT_Q96) revert InvalidMeasurement(measurementX96);

        // if measurementX96 is above threshold, use SIGMA_UP_EXP_WAD, otherwise use SIGMA_DOWN_EXP_WAD
        uint256 factorWad = measurementX96 > THRESHOLD_X96 ? SIGMA_UP_EXP_WAD : SIGMA_DOWN_EXP_WAD;

        // update indexX96 and write observation to twap state
        indexX96 = indexX96.fullMulDiv(factorWad, WAD);
        twAvgState.write(block.timestamp.toUint32(), indexX96);

        emit DataUpdated(indexX96);
    }

    /// @inheritdoc ITimeWeightedAvg
    function timeWeightedAvg(uint32 secondsAgo) external view returns (uint256 twAvgIndexX96) {
        return twAvgState.timeWeightedAvg(secondsAgo, block.timestamp.toUint32(), indexX96);
    }

    /// @inheritdoc ITimeWeightedAvg
    function increaseCardinalityCap(uint16 newCap) external {
        twAvgState.increaseCardinalityCap(newCap);
    }
}
