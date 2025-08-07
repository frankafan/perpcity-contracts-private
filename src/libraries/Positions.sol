// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

library Positions {
    struct MakerInfo {
        address holder;
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceLowerX96;
        uint160 sqrtPriceUpperX96;
        uint128 margin;
        uint128 liquidity;
        uint128 perpsBorrowed;
        uint128 usdBorrowed;
        int128 entryTwPremiumX96;
        int128 entryTwPremiumDivBySqrtPriceX96;
        uint256 entryTimestamp;
    }

    struct TakerInfo {
        address holder;
        bool isLong;
        uint128 size;
        uint128 margin;
        uint128 entryValue;
        int128 entryTwPremiumX96;
    }
}
