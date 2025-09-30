// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

interface IBeacon {
    function getData() external view returns (uint256 data);

    function updateData(bytes calldata proof, bytes calldata publicSignals) external;

    event DataUpdated(uint256 data);

    error ProofAndPublicSignalsAlreadyUsed();
    error VerificationFailed();
}
