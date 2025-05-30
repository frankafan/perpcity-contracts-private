// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Tick } from "./Tick.sol";
import { PerpMath } from "./PerpMath.sol";
import { PerpSafeCast } from "./PerpSafeCast.sol";
import { PerpFixedPoint96 } from "./PerpFixedPoint96.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import { SignedMath } from "@openzeppelin/contracts/utils/math/SignedMath.sol";

library Funding {
    using PerpSafeCast for uint256;
    using PerpSafeCast for uint128;
    using SignedMath for int256;

    //
    // STRUCT
    //

    /// @dev tw: time-weighted
    /// @param twPremiumX96 overflow inspection (as twPremiumX96 > twPremiumDivBySqrtPriceX96):
    //         max = 2 ^ (255 - 96) = 2 ^ 159 = 7.307508187E47
    //         assume premium = 10000, time = 10 year = 60 * 60 * 24 * 365 * 10 -> twPremium = 3.1536E12
    struct Growth {
        int256 twPremiumX96;
        int256 twPremiumDivBySqrtPriceX96;
    }

    //
    // CONSTANT
    //

    /// @dev block-based funding is calculated as: premium * timeFraction / 1 day, for 1 day as the default period
    int256 internal constant _DEFAULT_FUNDING_PERIOD = 1 days;

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
        int256 balanceCoefficientInFundingPayment = PerpMath.mulDiv(
            baseBalance, fundingGrowthGlobal.twPremiumX96 - twPremiumGrowthGlobalX96, uint256(PerpFixedPoint96._IQ96)
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
        int256 fundingBelowX96 = baseAmountBelow.toInt256() * (fundingGrowthRangeInfo.twPremiumGrowthBelowX96);
        // funding inside the range =
        // liquidity * (ΔtwPremiumDivBySqrtPriceGrowthInsideX96 - ΔtwPremiumGrowthInsideX96 / sqrtPriceAtUpperTick)
        int256 fundingInsideX96 = liquidity.toInt256()
        // ΔtwPremiumDivBySqrtPriceGrowthInsideX96
        * (
            fundingGrowthRangeInfo.twPremiumDivBySqrtPriceGrowthInsideX96
                - PerpMath.mulDiv(
                    fundingGrowthRangeInfo.twPremiumGrowthInsideX96, PerpFixedPoint96._IQ96, sqrtPriceX96AtUpperTick
                )
        );
        return (fundingBelowX96 + fundingInsideX96) / PerpFixedPoint96._IQ96;
    }
}
