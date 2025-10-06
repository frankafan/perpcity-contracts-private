// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

/// @title IBeacon
/// @notice Interface for a beacon
interface IBeacon {
    /* EVENTS */

    /// @notice Event emitted when the beacon's data is updated
    /// @param data The new value of the data stored
    event DataUpdated(uint256 data);

    /* ERRORS */

    /// @notice Thrown when the proof and public signals have already been used
    error ProofAndPublicSignalsAlreadyUsed();
    /// @notice Thrown when the proof and public signals are invalid
    error VerificationFailed();

    /* FUNCTIONS */

    /// @notice Get the data stored in the beacon
    /// @return data The data stored
    function data() external view returns (uint256 data);

    /// @notice Update the data stored in the beacon
    /// @dev This should revert on invalid proof and public signals pairs
    /// @param encodedProof The encoded proof of valid data
    /// Example: `abi.encode(proof)`
    /// @param encodedPublicSignals The encoded public signals paired with `encodedProof`
    /// It should contain some data used to update the beacon. Example: `abi.encode(publicSignals)`
    function updateData(bytes calldata encodedProof, bytes calldata encodedPublicSignals) external;
}
