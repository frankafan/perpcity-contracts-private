// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {IEZKLHalo2Verifier} from "../../interfaces/IEZKLHalo2Verifier.sol";
import {EZKLHalo2VerifierWrapper} from "./EZKLHalo2VerifierWrapper.sol";
import {GBMBeacon} from "./GBMBeacon.sol";

contract GBMFactory {
    event BeaconCreated(address beacon);

    uint256 public constant INITIAL_INDEX_X96 = 7922816251426433759354395033600; // 100 * 2^96

    // example inputs:
    // initialCardinalityNext = 100
    // thresholdX96 = 39614081257132168796771975168 (0.5 * 2^96)
    // sigmaBase = 0.001e18
    // positiveRate = 0.5e18
    function createBeacon(
        IEZKLHalo2Verifier verifier,
        address owner,
        uint32 initialCardinalityNext,
        uint256 thresholdX96,
        uint256 sigmaBase, // scaled by 1e18
        uint256 positiveRate // scaled by 1e18
    )
        external
        returns (address)
    {
        address beacon = address(
            new GBMBeacon(
                new EZKLHalo2VerifierWrapper(verifier),
                owner,
                INITIAL_INDEX_X96,
                initialCardinalityNext,
                thresholdX96,
                sigmaBase,
                positiveRate
            )
        );
        emit BeaconCreated(beacon);
        return beacon;
    }
}
