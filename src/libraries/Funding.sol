// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {INT_Q96, UINT_Q96} from "./Constants.sol";
import {SignedMath} from "./SignedMath.sol";
import {Tick} from "./Tick.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

/// TODO: add comments
library Funding {
    using SafeCastLib for *;
    using SignedMath for *;

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
    ) internal pure returns (int256) {
        int256 balanceCoefficientInFundingPayment =
            SignedMath.mulDivSigned(baseBalance, fundingGrowthGlobal.twPremiumX96 - twPremiumGrowthGlobalX96, UINT_Q96);

        return liquidityCoefficientInFundingPayment + balanceCoefficientInFundingPayment;
    }

    /// @dev the funding payment of an order/liquidity is composed of
    ///      1. funding accrued inside the range 2. funding accrued below the range
    ///      there is no funding when the price goes above the range, as liquidity is all swapped into quoteToken
    /// @return liquidityCoefficientInFundingPayment the funding payment of an order/liquidity
    function calcLiquidityCoefficientInFundingPaymentByOrder(
        uint128 liquidity,
        int24 lowerTick,
        int24 upperTick,
        Tick.FundingGrowthRangeInfo memory fundingGrowthRangeInfo,
        int256 lastTwPremiumGrowthInsideX96,
        int256 lastTwPremiumDivBySqrtPriceGrowthInsideX96,
        int256 lastTwPremiumGrowthBelowX96
    ) internal pure returns (int256) {
        uint160 sqrtPriceX96AtUpperTick = TickMath.getSqrtPriceAtTick(upperTick);

        // base amount below the range
        uint256 baseAmountBelow = LiquidityAmounts.getAmount0ForLiquidity(
            TickMath.getSqrtPriceAtTick(lowerTick), sqrtPriceX96AtUpperTick, liquidity
        );

        // funding below the range
        int256 fundingBelow = baseAmountBelow.toInt256().fullMulDivSigned(
            fundingGrowthRangeInfo.twPremiumGrowthBelowX96 - lastTwPremiumGrowthBelowX96, UINT_Q96
        );

        // funding inside the range =
        // liquidity * (ΔtwPremiumDivBySqrtPriceGrowthInsideX96 - ΔtwPremiumGrowthInsideX96 / sqrtPriceAtUpperTick)
        int256 fundingInside = liquidity.toInt256().fullMulDivSigned(
            fundingGrowthRangeInfo.twPremiumDivBySqrtPriceGrowthInsideX96 - lastTwPremiumDivBySqrtPriceGrowthInsideX96
                - SignedMath.fullMulDivSigned(
                    (fundingGrowthRangeInfo.twPremiumGrowthInsideX96 - lastTwPremiumGrowthInsideX96),
                    INT_Q96,
                    sqrtPriceX96AtUpperTick
                ),
            UINT_Q96
        );

        return fundingBelow + fundingInside;
    }
}
