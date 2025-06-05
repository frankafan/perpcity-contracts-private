// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

/// @title FixedPoint192
/// @notice A library for handling binary fixed point numbers, see https://en.wikipedia.org/wiki/Q_(number_format)
library FixedPoint192 {
    uint256 internal constant UINT_Q192 = 0x1000000000000000000000000000000000000000000000000;
}
