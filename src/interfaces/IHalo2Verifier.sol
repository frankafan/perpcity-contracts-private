// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

interface IHalo2Verifier {
    function verifyProof(bytes memory proof, uint256[] memory publicSignals) external view returns (bool);
}
