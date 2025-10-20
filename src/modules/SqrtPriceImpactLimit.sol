// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {ISqrtPriceImpactLimit} from "../interfaces/modules/ISqrtPriceImpactLimit.sol";
import {IPerpManager} from "../interfaces/IPerpManager.sol";

contract SqrtPriceImpactLimit is ISqrtPriceImpactLimit {
    uint256 constant SQRT_PRICE_LOWER_MULTI_X96 = 75162434512514379355924140471; // sqrt(1 - 0.1) * 2^96
    uint256 constant SQRT_PRICE_UPPER_MULTI_X96 = 83095197869223157896060286991; // sqrt(1 + 0.1) * 2^96

    function sqrtPriceImpactLimitX96(IPerpManager.PerpConfig calldata perp, bool zeroForOne) external pure returns (uint256) {
        return zeroForOne ? SQRT_PRICE_LOWER_MULTI_X96 : SQRT_PRICE_UPPER_MULTI_X96;
    }
}