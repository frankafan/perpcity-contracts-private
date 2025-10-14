// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IEZKLHalo2Verifier} from "../../interfaces/beacons/IEZKLHalo2Verifier.sol";
import {IVerifierWrapper} from "../../interfaces/beacons/IVerifierWrapper.sol";
import {UINT_Q96} from "../../libraries/Constants.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";

/// @title EZKLHalo2VerifierWrapper
/// @notice Wrapper for an EZKL Halo2 verifier with 1 public signal
contract EZKLHalo2VerifierWrapper is IVerifierWrapper {
    /* CONSTANTS */

    /// @notice The factor values in EZKL Halo2 verifier public signals are scaled by
    /// @dev Equal to 2^13
    uint256 public constant EZKL_SCALE_FACTOR = 8192;

    /* IMMUTABLES */

    /// @notice The verifier to check proofs and public signals against
    IEZKLHalo2Verifier public immutable VERIFIER;

    /* CONSTRUCTOR */

    /// @notice Instantiates the wrapper given an EZKL Halo2 verifier
    /// @param ezklHalo2Verifier The EZKL Halo2 verifier address to store
    constructor(IEZKLHalo2Verifier ezklHalo2Verifier) {
        VERIFIER = ezklHalo2Verifier;
    }

    /* FUNCTIONS */

    /// @inheritdoc IVerifierWrapper
    function verifier() external view returns (address verifierAddress) {
        return address(VERIFIER);
    }

    /// @inheritdoc IVerifierWrapper
    /// @dev Outputs data scaled by 2^96
    function verify(bytes calldata encodedProof, bytes calldata encodedPublicSignals)
        external
        view
        returns (bool success, uint256 data)
    {
        // decode proof and publicSignals
        bytes memory proof = abi.decode(encodedProof, (bytes));
        uint256[] memory publicSignals = abi.decode(encodedPublicSignals, (uint256[]));

        // wrap verify call in a try-catch since EZKL Halo2 verifier may revert
        try VERIFIER.verifyProof(proof, publicSignals) returns (bool isValid) {
            // if verifyProof does not revert, success is assigned verifier's return value
            success = isValid;
        } catch {
            // if revert, success is false
            success = false;
        }

        // extract first public signal and change scale from EZKL_SCALE_FACTOR to 2^96
        data = FixedPointMathLib.fullMulDiv(publicSignals[0], UINT_Q96, EZKL_SCALE_FACTOR);
    }
}
