// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";

library MoreSignedMath {
    function mulDivSigned(int256 a, int256 b, uint256 denominator) internal pure returns (int256 result) {
        uint256 unsignedA = FixedPointMathLib.abs(a);
        uint256 unsignedB = FixedPointMathLib.abs(b);
        bool negative = ((a < 0 && b > 0) || (a > 0 && b < 0)) ? true : false;

        uint256 unsignedResult = FixedPointMathLib.mulDiv(unsignedA, unsignedB, denominator);

        result = negative ? -SafeCastLib.toInt256(unsignedResult) : SafeCastLib.toInt256(unsignedResult);

        return result;
    }
}
