// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IEZKLHalo2Verifier} from "../../interfaces/IEZKLHalo2Verifier.sol";
import {IVerifierWrapper} from "../../interfaces/IVerifierWrapper.sol";

import {UINT_Q96} from "../../libraries/Constants.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";

contract EZKLHalo2VerifierWrapper is IVerifierWrapper {
    uint256 private constant EZKL_SCALE_FACTOR = 8192; // 2^13

    IEZKLHalo2Verifier private immutable VERIFIER;

    constructor(IEZKLHalo2Verifier verifier) {
        VERIFIER = verifier;
    }

    // outputs data scaled by 2^96
    function verify(
        bytes calldata encodedProof,
        bytes calldata encodedPublicSignals
    )
        external
        view
        returns (bool success, uint256 data)
    {
        // decode proof
        bytes memory proof = abi.decode(encodedProof, (bytes));
        // decode publicSignals
        uint256[] memory publicSignals = abi.decode(encodedPublicSignals, (uint256[]));

        // try to verify the proof
        try VERIFIER.verifyProof(proof, publicSignals) returns (bool isValid) {
            // if verifyProof does not revert, success is assigned verifier's return value
            success = isValid;
        } catch {
            // if revert, success is false
            success = false;
        }

        data = FixedPointMathLib.fullMulDiv(publicSignals[0], UINT_Q96, EZKL_SCALE_FACTOR);
    }
}
