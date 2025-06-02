// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

interface IVerifier {
    function verify(bytes memory proof, bytes memory publicSignals) external view returns (bool);
}
