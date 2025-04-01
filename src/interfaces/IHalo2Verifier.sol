// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

interface IHalo2Verifier {
    function verifyProof(bytes memory proof, uint256[] memory publicSignals) external view returns (bool);
}
