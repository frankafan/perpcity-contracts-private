// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

interface IVerifierWrapper {
    // takes in a bytes proof and a bytes publid signals, given by abi.encode( original publicSignals)
    // outputs a bool of success and the data extracted from publicSignals
    function verify(
        bytes calldata encodedProof,
        bytes calldata encodedPublicSignals
    )
        external
        view
        returns (bool, uint256);
}
