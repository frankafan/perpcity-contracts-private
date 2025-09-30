// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {IBeacon} from "../../interfaces/IBeacon.sol";
import {ITimeWeightedAvg} from "../../interfaces/ITimeWeightedAvg.sol";

import {IVerifierWrapper} from "../../interfaces/IVerifierWrapper.sol";
import {UINT_Q96} from "../../libraries/Constants.sol";
import {TimeWeightedAvg} from "../../libraries/TimeWeightedAvg.sol";
import {Ownable} from "@solady/src/auth/Ownable.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";

contract GBMBeacon is IBeacon, ITimeWeightedAvg, Ownable {
    using FixedPointMathLib for *;
    using SafeCastLib for *;
    using TimeWeightedAvg for TimeWeightedAvg.State;

    uint256 internal constant WAD = 1e18;

    // GBM Parameters
    uint256 public immutable thresholdX96; // Threshold for binary classification (scaled by 2^96)
    int256 public immutable sigmaUp; // Base volatility (scaled by 1e18)
    int256 public immutable sigmaDown; // Fixed positive rate (scaled by 1e18)

    uint256 public immutable creationTimestamp;
    TimeWeightedAvg.State public twapState;

    IVerifierWrapper public immutable VERIFIER_WRAPPER;

    mapping(bytes => bool) public usedProofs;
    mapping(bytes => bool) public usedPublicSignals;

    uint256 private indexX96;

    constructor(
        IVerifierWrapper verifierWrapper,
        address owner,
        uint256 initialIndexX96,
        uint32 initialCardinalityNext,
        uint256 _thresholdX96,
        uint256 sigmaBase, // scaled by 1e18
        uint256 positiveRate // scaled by 1e18
    ) {
        VERIFIER_WRAPPER = verifierWrapper;

        _initializeOwner(owner);
        indexX96 = initialIndexX96;
        creationTimestamp = block.timestamp;

        // initialize twap state
        twapState.initialize(block.timestamp.toUint32());
        twapState.grow(initialCardinalityNext);
        twapState.write(block.timestamp.toUint32(), initialIndexX96.toUint216());

        // initialize threshold, sigmaUp, and sigmaDown
        thresholdX96 = _thresholdX96;
        sigmaDown = -sigmaBase.toInt256();

        if (positiveRate > 0 && positiveRate < WAD) {
            sigmaUp = sigmaBase.fullMulDiv(WAD - positiveRate, positiveRate).toInt256();
        } else {
            sigmaUp = sigmaBase.toInt256();
        }
    }

    function updateData(bytes calldata proof, bytes calldata publicSignals) external onlyOwner {
        if (usedProofs[proof] && usedPublicSignals[publicSignals]) revert ProofAndPublicSignalsAlreadyUsed();

        (bool success, uint256 measurementX96) = VERIFIER_WRAPPER.verify(proof, publicSignals);
        if (!success) revert VerificationFailed();

        int256 factorWAD = measurementX96 > thresholdX96 ? sigmaUp.expWad() : sigmaDown.expWad();

        indexX96 = indexX96.fullMulDiv(factorWAD.toUint256(), WAD);

        usedProofs[proof] = true;
        usedPublicSignals[publicSignals] = true;

        twapState.write(block.timestamp.toUint32(), indexX96.toUint216());

        emit DataUpdated(indexX96);
    }

    function getData() external view returns (uint256) {
        return indexX96;
    }

    function getTimeWeightedAvg(uint32 twapSecondsAgo) external view returns (uint256 twapPriceX96) {
        uint32 timeSinceLastObservation = (block.timestamp - twapState.getOldestObservationTimestamp()).toUint32();
        if (twapSecondsAgo > timeSinceLastObservation) twapSecondsAgo = timeSinceLastObservation;

        if (twapSecondsAgo == 0) return indexX96;

        uint32 timeSinceCreation = (block.timestamp - creationTimestamp).toUint32();
        if (timeSinceCreation < twapSecondsAgo) twapSecondsAgo = timeSinceCreation;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSecondsAgo;
        secondsAgos[1] = 0;
        uint216[] memory priceCumulatives =
            twapState.observe(block.timestamp.toUint32(), secondsAgos, indexX96.toUint216());
        return (priceCumulatives[1] - priceCumulatives[0]) / twapSecondsAgo;
    }
}
