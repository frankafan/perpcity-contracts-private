// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";

/// @title SignedMath
/// @notice A library for signed math operations built on top of FixedPointMathLib
library SignedMath {
    /* FUNCTIONS */

    /// @notice Returns `floor(x * y / d)` where `x` and `y` are signed integers and `d` is an unsigned integer
    /// @dev This function uses FixedPointMathLib.mulDiv. This function reverts if `x * y` overflows, or `d` is zero.
    /// @param a The first signed integer
    /// @param b The second signed integer
    /// @param denominator The denominator
    /// @return result The result of the multiplication and division
    function mulDivSigned(int256 a, int256 b, uint256 denominator) internal pure returns (int256 result) {
        // convert the signed integers to unsigned while keeping track of the resulting sign after multiplication
        uint256 unsignedA = FixedPointMathLib.abs(a);
        uint256 unsignedB = FixedPointMathLib.abs(b);
        bool negative = ((a < 0 && b > 0) || (a > 0 && b < 0)) ? true : false;

        // use mulDiv to calculate absolute value of the result, then convert back to a signed integer and add signage
        uint256 unsignedResult = FixedPointMathLib.mulDiv(unsignedA, unsignedB, denominator);
        return negative ? -SafeCastLib.toInt256(unsignedResult) : SafeCastLib.toInt256(unsignedResult);
    }

    /// @notice Returns `floor(x * y / d)` where `x` and `y` are signed integers and `d` is an unsigned integer
    /// @dev This function uses FixedPointMathLib.fullMulDiv. This function reverts if `d` is zero.
    /// @param a The first signed integer
    /// @param b The second signed integer
    /// @param denominator The denominator
    /// @return result The result of the multiplication and division
    function fullMulDivSigned(int256 a, int256 b, uint256 denominator) internal pure returns (int256 result) {
        // convert the signed integers to unsigned while keeping track of the resulting sign after multiplication
        uint256 unsignedA = FixedPointMathLib.abs(a);
        uint256 unsignedB = FixedPointMathLib.abs(b);
        bool negative = ((a < 0 && b > 0) || (a > 0 && b < 0)) ? true : false;

        // use fullMulDiv to calculate absolute value of result, then convert back to a signed integer and add signage
        uint256 unsignedResult = FixedPointMathLib.fullMulDiv(unsignedA, unsignedB, denominator);
        return negative ? -SafeCastLib.toInt256(unsignedResult) : SafeCastLib.toInt256(unsignedResult);
    }
}
