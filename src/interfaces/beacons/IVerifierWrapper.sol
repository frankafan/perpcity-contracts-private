// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

/// @title IVerifierWrapper
/// @notice Interface that verifier wrappers must implement
interface IVerifierWrapper {
    /* FUNCTIONS */

    /// @notice Get the verifier that this wrapper checks proofs and public signals against
    /// @return verifier The address of the verifier used
    function verifier() external view returns (address verifier);

    /// @notice Verify a proof and public signals pair and extract data from public signals
    /// @param encodedProof The encoded proof
    /// Example: `abi.encode(proof)`
    /// @param encodedPublicSignals The encoded public signals
    /// Example: `abi.encode(publicSignals)`
    /// @return success Whether the proof and public signals pair is valid
    /// @return data The data extracted from `encodedPublicSignals`
    function verify(bytes calldata encodedProof, bytes calldata encodedPublicSignals)
        external
        view
        returns (bool success, uint256 data);
}
