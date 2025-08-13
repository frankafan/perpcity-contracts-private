// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {FixedPoint96} from "./FixedPoint96.sol";
import {MoreSignedMath} from "./MoreSignedMath.sol";
import {Tick} from "./Tick.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

// modified from https://github.com/perpetual-protocol/perp-curie-contract/blob/main/contracts/lib/Funding.sol
library Funding {
    using SafeCastLib for *;

    //
    // STRUCT
    //
    struct Growth {
        int256 twPremiumX96;
        int256 twPremiumDivBySqrtPriceX96;
    }

    //
    // INTERNAL PURE
    //
    function calcPendingFundingPaymentWithLiquidityCoefficient(
        int256 baseBalance,
        int256 twPremiumGrowthGlobalX96,
        Growth memory fundingGrowthGlobal,
        int256 liquidityCoefficientInFundingPayment
    )
        internal
        pure
        returns (int256)
    {
        int256 balanceCoefficientInFundingPayment = MoreSignedMath.mulDivSigned(
            baseBalance, fundingGrowthGlobal.twPremiumX96 - twPremiumGrowthGlobalX96, FixedPoint96.UINT_Q96
        );

        return (liquidityCoefficientInFundingPayment - balanceCoefficientInFundingPayment);
    }

    /// @dev the funding payment of an order/liquidity is composed of
    ///      1. funding accrued inside the range 2. funding accrued below the range
    ///      there is no funding when the price goes above the range, as liquidity is all swapped into quoteToken
    /// @return liquidityCoefficientInFundingPayment the funding payment of an order/liquidity
    function calcLiquidityCoefficientInFundingPaymentByOrder(
        uint128 liquidity,
        int24 lowerTick,
        int24 upperTick,
        Tick.FundingGrowthRangeInfo memory fundingGrowthRangeInfo
    )
        internal
        pure
        returns (int256)
    {
        uint160 sqrtPriceX96AtUpperTick = TickMath.getSqrtPriceAtTick(upperTick);

        // base amount below the range
        uint256 baseAmountBelow = LiquidityAmounts.getAmount0ForLiquidity(
            TickMath.getSqrtPriceAtTick(lowerTick), sqrtPriceX96AtUpperTick, liquidity
        );
        // funding below the range
        int256 fundingBelowX96 = baseAmountBelow.toInt256() * fundingGrowthRangeInfo.twPremiumGrowthBelowX96;
        // funding inside the range =
        // liquidity * (ΔtwPremiumDivBySqrtPriceGrowthInsideX96 - ΔtwPremiumGrowthInsideX96 / sqrtPriceAtUpperTick)
        int256 fundingInsideX96 = liquidity.toInt256()
        // ΔtwPremiumDivBySqrtPriceGrowthInsideX96
        * (
            fundingGrowthRangeInfo.twPremiumDivBySqrtPriceGrowthInsideX96
                - MoreSignedMath.mulDivSigned(
                    fundingGrowthRangeInfo.twPremiumGrowthInsideX96, FixedPoint96.INT_Q96, sqrtPriceX96AtUpperTick
                )
        );
        return (fundingBelowX96 + fundingInsideX96) / FixedPoint96.INT_Q96;
    }
}
