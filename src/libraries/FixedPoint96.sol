// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

/// @title FixedPoint96
/// @notice A library for handling binary fixed point numbers, see https://en.wikipedia.org/wiki/Q_(number_format)
library FixedPoint96 {
    uint256 internal constant UINT_Q96 = 0x1000000000000000000000000;
    int256 internal constant INT_Q96 = 0x1000000000000000000000000;
}
