// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SignedMath } from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library MoreSignedMath {
    function mulDiv(int256 a, int256 b, uint256 denominator) internal pure returns (int256 result) {
        uint256 unsignedA = SignedMath.abs(a);
        uint256 unsignedB = SignedMath.abs(b);
        bool negative = ((a < 0 && b > 0) || (a > 0 && b < 0)) ? true : false;

        uint256 unsignedResult = Math.mulDiv(unsignedA, unsignedB, denominator);

        result = negative ? -SafeCast.toInt256(unsignedResult) : SafeCast.toInt256(unsignedResult);

        return result;
    }
}
