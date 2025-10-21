// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPerpManager} from "../interfaces/IPerpManager.sol";
import {ISqrtPriceImpactLimit} from "../interfaces/modules/ISqrtPriceImpactLimit.sol";

/// @title SqrtPriceImpactLimit
/// @notice A basic implementation of a sqrt price impact limit module
contract SqrtPriceImpactLimit is ISqrtPriceImpactLimit {
    /* CONSTANTS */

    /// @notice The lower bound of the sqrt price impact limit, equivalent to sqrt(90%) * 2^96
    uint256 constant SQRT_PRICE_LOWER_MULTI_X96 = 75162434512514379355924140471;
    /// @notice The upper bound of the sqrt price impact limit, equivalent to sqrt(110%) * 2^96
    uint256 constant SQRT_PRICE_UPPER_MULTI_X96 = 83095197869223157896060286991;

    /* FUNCTIONS */

    /// @inheritdoc ISqrtPriceImpactLimit
    function sqrtPriceImpactLimit(IPerpManager.PerpConfig calldata, bool zfo) external pure returns (uint256) {
        return zfo ? SQRT_PRICE_LOWER_MULTI_X96 : SQRT_PRICE_UPPER_MULTI_X96;
    }
}
