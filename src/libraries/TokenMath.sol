// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

library TokenMath {
    uint256 internal constant DECIMALS_6_TO_18_FACTOR = 1e12;

    function scale6To18(uint256 amount) internal pure returns (uint256) {
        return amount * DECIMALS_6_TO_18_FACTOR;
    }

    function scale18To6(uint256 amount) internal pure returns (uint256) {
        return amount / DECIMALS_6_TO_18_FACTOR;
    }
}
