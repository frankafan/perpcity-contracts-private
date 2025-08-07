// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

library Fees {
    struct FeeInfo {
        uint24 tradingFee;
        uint128 tradingFeeCreatorSplitX96;
        uint256 tradingFeeInsuranceSplitX96;
        uint128 liquidationFeeX96;
        uint128 liquidationFeeSplitX96;
    }
}
