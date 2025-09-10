// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

interface IVerifier {
    function verify(bytes calldata proof, bytes calldata publicSignals) external view returns (bool);
}
