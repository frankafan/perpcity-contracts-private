// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {UniV4Router} from "./UniV4Router.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// TODO: add comments
library Tick {
    using StateLibrary for IPoolManager;
    using Tick for mapping(int24 => Tick.GrowthInfo);

    /// @dev Funding helpers per tick
    struct GrowthInfo {
        int256 twPremiumX96;
        int256 twPremiumDivBySqrtPriceX96;
    }

    struct FundingGrowthRangeInfo {
        int256 twPremiumGrowthInsideX96;
        int256 twPremiumGrowthBelowX96;
        int256 twPremiumDivBySqrtPriceGrowthInsideX96;
    }

    /// @dev call this function only if (liquidityGrossBefore == 0 && liquidityDelta != 0)
    /// @dev per Uniswap: we assume that all growths before a tick is initialized happen "below" the tick
    function initialize(
        mapping(int24 => GrowthInfo) storage self,
        int24 tick,
        int24 currentTick,
        int256 twPremiumX96,
        int256 twPremiumDivBySqrtPriceX96
    ) internal {
        if (tick <= currentTick) {
            GrowthInfo storage growthInfo = self[tick];
            growthInfo.twPremiumX96 = twPremiumX96;
            growthInfo.twPremiumDivBySqrtPriceX96 = twPremiumDivBySqrtPriceX96;
        }
    }

    function cross(
        mapping(int24 => GrowthInfo) storage self,
        int24 tick,
        int256 twPremiumX96,
        int256 twPremiumDivBySqrtPriceX96
    ) internal {
        GrowthInfo storage growthInfo = self[tick];
        growthInfo.twPremiumX96 = twPremiumX96 - growthInfo.twPremiumX96;
        growthInfo.twPremiumDivBySqrtPriceX96 = twPremiumDivBySqrtPriceX96 - growthInfo.twPremiumDivBySqrtPriceX96;
    }

    function clear(mapping(int24 => GrowthInfo) storage self, int24 tick) internal {
        delete self[tick];
    }

    /// @return all values returned can underflow per feeGrowthOutside specs;
    ///         see https://www.notion.so/32990980ba8b43859f6d2541722a739b
    function getAllFundingGrowth(
        mapping(int24 => GrowthInfo) storage self,
        int24 lowerTick,
        int24 upperTick,
        int24 currentTick,
        int256 twPremiumGrowthGlobalX96,
        int256 twPremiumDivBySqrtPriceGrowthGlobalX96
    ) internal view returns (FundingGrowthRangeInfo memory) {
        GrowthInfo storage lowerTickGrowthInfo = self[lowerTick];
        GrowthInfo storage upperTickGrowthInfo = self[upperTick];

        int256 lowerTwPremiumGrowthOutsideX96 = lowerTickGrowthInfo.twPremiumX96;
        int256 upperTwPremiumGrowthOutsideX96 = upperTickGrowthInfo.twPremiumX96;

        FundingGrowthRangeInfo memory fundingGrowthRangeInfo;
        fundingGrowthRangeInfo.twPremiumGrowthBelowX96 = currentTick >= lowerTick
            ? lowerTwPremiumGrowthOutsideX96
            : twPremiumGrowthGlobalX96 - lowerTwPremiumGrowthOutsideX96;
        int256 twPremiumGrowthAboveX96 = currentTick < upperTick
            ? upperTwPremiumGrowthOutsideX96
            : twPremiumGrowthGlobalX96 - upperTwPremiumGrowthOutsideX96;

        int256 lowerTwPremiumDivBySqrtPriceGrowthOutsideX96 = lowerTickGrowthInfo.twPremiumDivBySqrtPriceX96;
        int256 upperTwPremiumDivBySqrtPriceGrowthOutsideX96 = upperTickGrowthInfo.twPremiumDivBySqrtPriceX96;

        int256 twPremiumDivBySqrtPriceGrowthBelowX96 = currentTick >= lowerTick
            ? lowerTwPremiumDivBySqrtPriceGrowthOutsideX96
            : twPremiumDivBySqrtPriceGrowthGlobalX96 - lowerTwPremiumDivBySqrtPriceGrowthOutsideX96;
        int256 twPremiumDivBySqrtPriceGrowthAboveX96 = currentTick < upperTick
            ? upperTwPremiumDivBySqrtPriceGrowthOutsideX96
            : twPremiumDivBySqrtPriceGrowthGlobalX96 - upperTwPremiumDivBySqrtPriceGrowthOutsideX96;

        fundingGrowthRangeInfo.twPremiumGrowthInsideX96 =
            twPremiumGrowthGlobalX96 - fundingGrowthRangeInfo.twPremiumGrowthBelowX96 - twPremiumGrowthAboveX96;
        fundingGrowthRangeInfo.twPremiumDivBySqrtPriceGrowthInsideX96 = twPremiumDivBySqrtPriceGrowthGlobalX96
            - twPremiumDivBySqrtPriceGrowthBelowX96 - twPremiumDivBySqrtPriceGrowthAboveX96;

        return fundingGrowthRangeInfo;
    }

    function crossTicks(
        mapping(int24 => GrowthInfo) storage self,
        IPoolManager poolManager,
        PoolId poolId,
        int24 currentTick,
        int24 tickSpacing,
        bool zeroForOne,
        int24 endingTick,
        int256 twPremiumX96,
        int256 twPremiumDivBySqrtPriceX96
    ) internal {
        bool isInitialized;
        do {
            (currentTick, isInitialized) =
                UniV4Router.nextInitializedTickWithinOneWord(poolManager, poolId, currentTick, tickSpacing, zeroForOne);

            if (isInitialized) self.cross(currentTick, twPremiumX96, twPremiumDivBySqrtPriceX96);

            // if going down, decrement tick so it doesn't get caught by lte in nextInitializedTickWithinOneWord
            if (zeroForOne) currentTick--;

            // stop if we pass the ending tick
        } while (zeroForOne ? (currentTick > endingTick) : (currentTick < endingTick));
    }
}
