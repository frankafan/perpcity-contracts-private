// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPerpManager} from "../interfaces/IPerpManager.sol";
import {INT_Q96, UINT_Q96} from "./Constants.sol";
import {FUNDING_INTERVAL} from "./Constants.sol";
import {SignedMath} from "./SignedMath.sol";
import {UniV4Router} from "./UniV4Router.sol";
import {ITimeWeightedAvg} from "../interfaces/ITimeWeightedAvg.sol";
import {TimeWeightedAvg} from "./TimeWeightedAvg.sol";
import {UniV4Router} from "./UniV4Router.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

/// TODO: add comments
library Funding {
    using StateLibrary for IPoolManager;
    using SafeCastLib for *;
    using SignedMath for *;
    using FixedPointMathLib for *;
    using UniV4Router for IPoolManager;
    using TimeWeightedAvg for TimeWeightedAvg.State;

    struct State {
        uint32 lastCumlFundingUpdate;
        int256 fundingPerSecondX96;
        int256 cumlFundingX96;
        int256 cumlScaledFundingX96;
        mapping(int24 => TickInfo) tickInfo;
    }

    // CAN MAYBE ADD GROWTH OPPOSITE TO STRUCT NAME SO VAR NAMES ARE SHORTER

    struct TickInfo {
        int256 cumlFundingOppX96;
        int256 cumlScaledFundingOppX96;
    }

    /// @dev call this function only if (liquidityGrossBefore == 0 && liquidityDelta != 0)
    /// @dev per Uniswap: we assume that all growths before a tick is initialized happen "below" the tick

    function initTick(State storage fundingState, int24 tick, int24 currentTick) internal {
        if (tick <= currentTick) {
            fundingState.tickInfo[tick].cumlFundingOppX96 = fundingState.cumlFundingX96;
            fundingState.tickInfo[tick].cumlScaledFundingOppX96 = fundingState.cumlScaledFundingX96;
        }
    }

    function crossTick(State storage fundingState, int24 tickCrossed) internal {
        TickInfo storage tick = fundingState.tickInfo[tickCrossed];
        tick.cumlFundingOppX96 = fundingState.cumlFundingX96 - tick.cumlFundingOppX96;
        tick.cumlScaledFundingOppX96 = fundingState.cumlScaledFundingX96 - tick.cumlScaledFundingOppX96;
    }

    function clear(State storage fundingState, int24 tick) internal {
        delete fundingState.tickInfo[tick];
    }

    /// all values returned can underflow per feeGrowthOutside specs;
    ///         see https://www.notion.so/32990980ba8b43859f6d2541722a739b

    function getAllFundingGrowth(State storage fundingState, int24 lowerTick, int24 upperTick, int24 currentTick)
        internal
        view
        returns (int256 cumlFundingBelowX96, int256 cumlFundingWithinX96, int256 cumlScaledFundingWithinX96)
    {
        TickInfo storage tickLower = fundingState.tickInfo[lowerTick];
        TickInfo storage tickUpper = fundingState.tickInfo[upperTick];

        int256 cumlScaledFundingBelowLowerX96;
        int256 cumlFundingBelowUpperX96;
        int256 cumlScaledFundingBelowUpperX96;

        if (currentTick >= lowerTick) {
            cumlFundingBelowX96 = tickLower.cumlFundingOppX96;
            cumlScaledFundingBelowLowerX96 = tickLower.cumlScaledFundingOppX96;
        } else {
            cumlFundingBelowX96 = fundingState.cumlFundingX96 - tickLower.cumlFundingOppX96;
            cumlScaledFundingBelowLowerX96 = fundingState.cumlScaledFundingX96 - tickLower.cumlScaledFundingOppX96;
        }

        if (currentTick >= upperTick) {
            cumlFundingBelowUpperX96 = tickUpper.cumlFundingOppX96;
            cumlScaledFundingBelowUpperX96 = tickUpper.cumlScaledFundingOppX96;
        } else {
            cumlFundingBelowUpperX96 = fundingState.cumlFundingX96 - tickUpper.cumlFundingOppX96;
            cumlScaledFundingBelowUpperX96 = fundingState.cumlScaledFundingX96 - tickUpper.cumlScaledFundingOppX96;
        }

        // TODO: test for >= & <= errors at range edges
        cumlFundingWithinX96 = cumlFundingBelowUpperX96 - cumlFundingBelowX96;
        cumlScaledFundingWithinX96 = cumlScaledFundingBelowUpperX96 - cumlScaledFundingBelowLowerX96;
    }

    function crossTicks(
        State storage fundingState,
        IPoolManager poolManager,
        PoolId poolId,
        int24 startingTick,
        int24 endingTick,
        int24 tickSpacing,
        bool zeroForOne
    ) internal {
        int24 tick = startingTick;
        bool isInitialized;

        while (true) {
            (tick, isInitialized) = poolManager.nextInitializedTickWithinOneWord(poolId, tick, tickSpacing, zeroForOne);

            if (zeroForOne ? (tick < endingTick) : (tick > endingTick)) {
                break;
            } else {
                if (isInitialized) crossTick(fundingState, tick);
                if (zeroForOne) tick--;
            }
        }
    }

    /// @dev the funding payment of an order/liquidity is composed of
    ///      1. funding accrued inside the range 2. funding accrued below the range
    ///      there is no funding when the price goes above the range, as liquidity is all swapped into quoteToken
    /// @return liquidityCoefficientInFundingPayment the funding payment of an order/liquidity
    function calcLiquidityCoefficientInFundingPaymentByOrder(
        State storage fundingState,
        IPerpManager.MakerDetails memory makerPos,
        int24 currentTick
    ) internal view returns (int256) {
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(makerPos.tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(makerPos.tickUpper);

        (int256 cumlFundingBelowX96, int256 cumlFundingWithinX96, int256 cumlScaledFundingWithinX96) =
            getAllFundingGrowth(fundingState, makerPos.tickLower, makerPos.tickUpper, currentTick);

        // base amount below the range
        uint256 perpAmtBelow = LiquidityAmounts.getAmount0ForLiquidity(sqrtLowerX96, sqrtUpperX96, makerPos.liquidity);

        // funding below the range

        int256 deltaCumlFundingBelowX96 = cumlFundingBelowX96 - makerPos.entryCumlFundingBelowX96;
        int256 fundingBelow = perpAmtBelow.toInt256().fullMulDivSigned(deltaCumlFundingBelowX96, UINT_Q96);

        // funding inside the range =
        // liquidity * (ΔtwPremiumDivBySqrtPriceGrowthInsideX96 - ΔtwPremiumGrowthInsideX96 / sqrtPriceAtUpperTick)

        // liquidity * (1 / sqrt(Mark) — 1 / sqrt(Upper)) * fundingPerSecond * timepssed

        int256 deltaCumlFundingWithinX96 = cumlFundingWithinX96 - makerPos.entryCumlFundingWithinX96;
        int256 deltaCumlScaledFundingWithinX96 = cumlScaledFundingWithinX96 - makerPos.entryCumlScaledFundingWithinX96;

        int256 secondTerm = deltaCumlFundingWithinX96.fullMulDivSigned(INT_Q96, sqrtUpperX96);
        int256 invSqrtDiffX96 = deltaCumlScaledFundingWithinX96 - secondTerm;

        int256 fundingInside = makerPos.liquidity.toInt256().fullMulDivSigned(invSqrtDiffX96, UINT_Q96);

        return fundingBelow + fundingInside;
    }

    function updateCumlFunding(State storage fundingState, uint160 sqrtPriceX96) internal {
        int256 timeSinceLastUpdate = (block.timestamp - fundingState.lastCumlFundingUpdate).toInt256();
        fundingState.lastCumlFundingUpdate = block.timestamp.toUint32();

        fundingState.cumlFundingX96 += fundingState.fundingPerSecondX96 * timeSinceLastUpdate;
        fundingState.cumlScaledFundingX96 += fundingState.cumlFundingX96.fullMulDivSigned(INT_Q96, sqrtPriceX96);
    }

    // expects updateTwPremiums() to have been called before to account for time during old premiumPerSecondX96
    function updateFundingPerSecond(IPerpManager.Perp storage perp, uint160 sqrtPriceX96)
        internal
        returns (int256 premiumPerSecondX96)
    {
        uint32 twapWindow = perp.twapWindow;

        uint256 twAvgSqrtMarkX96 = perp.twapState.timeWeightedAvg(twapWindow, block.timestamp.toUint32(), sqrtPriceX96);
        uint256 twAvgMarkX96 = twAvgSqrtMarkX96.fullMulDiv(twAvgSqrtMarkX96, UINT_Q96);

        uint256 twAvgIndexX96 = ITimeWeightedAvg(perp.beacon).timeWeightedAvg(twapWindow);

        int256 fundingPerIntervalX96 = twAvgMarkX96.toInt256() - twAvgIndexX96.toInt256();

        premiumPerSecondX96 = fundingPerIntervalX96 / FUNDING_INTERVAL;
        perp.fundingState.fundingPerSecondX96 = premiumPerSecondX96;
    }

    // REMEMBER TO UPDATE CUML FUNDINGS BEFORE CALCULATING FUNDING SO THAT FUNDING FROM MOST REDENT TRADE UP UNTIL NOW IS ACCOUNTED FOR

    function calcFunding(State storage fundingState, IPerpManager.Position memory pos, int24 currentTick)
        internal
        view
        returns (int256 funding)
    {
        funding = pos.perpDelta.fullMulDivSigned(fundingState.cumlFundingX96 - pos.entryCumlFundingX96, UINT_Q96);

        if (pos.makerDetails.liquidity > 0) {
            funding += calcLiquidityCoefficientInFundingPaymentByOrder(fundingState, pos.makerDetails, currentTick);
        }
    }
}
