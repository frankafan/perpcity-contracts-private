// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPerpManager as Mgr} from "../interfaces/IPerpManager.sol";
import {ITimeWeightedAvg} from "../interfaces/ITimeWeightedAvg.sol";
import {FUNDING_INTERVAL, INT_Q96, TWAVG_WINDOW, UINT_Q96} from "./Constants.sol";
import {SignedMath} from "./SignedMath.sol";
import {TimeWeightedAvg} from "./TimeWeightedAvg.sol";
import {UniV4Router} from "./UniV4Router.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

// This library's logic was largely inspired by Perp V2

/// @title Funding
/// @notice Library for calculating funding
library Funding {
    using SafeCastLib for *;
    using SignedMath for *;
    using FixedPointMathLib for *;
    using UniV4Router for IPoolManager;
    using TimeWeightedAvg for TimeWeightedAvg.State;

    /* STRUCTS */

    /// @notice State that must be stored by contracts using this library
    /// @param lastCumlFundingUpdate The timestamp of the last update to cumlFundingX96 & cumlFundingDivSqrtPX96
    /// @param fundingPerSecondX96 The funding owed per position size per second, scaled by 2^96. If positive, it means
    /// that longs pay shorts. If negative, it means that shorts pay longs
    /// @param cumlFundingX96 Cumulative funding per position size since market creation. i.e. This is the amount that a
    /// size 1 perp long position would pay in funding if opened at market creation. Σ(fundingPerSecondX96 * Δt)
    /// @param cumlFundingDivSqrtPX96 Cumulative funding divided by sqrt mark price since market creation. It is similar
    /// to cumlFundingX96 but divided by sqrt price at the time of update. Σ(fundingPerSecondX96 * Δt / sqrtPriceX96)
    /// @param ticks A mapping of ticks which mimicks the perp's corresponding Uniswap pool's ticks but instead holds
    /// information that helps calculate cumulative funding between certain tick ranges
    struct State {
        uint32 lastCumlFundingUpdate;
        int256 fundingPerSecondX96;
        int256 cumlFundingX96;
        int256 cumlFundingDivSqrtPX96;
        mapping(int24 => TickInfo) ticks;
    }

    /// @notice Information about a tick that helps calculate cumulative funding between certain tick ranges
    /// @dev We assume all cumulative funding updates before a tick was initialized happened below it. For example,
    /// if tick 0 was initialized when global state.cumlFundingX96 was 100, then we assume cumlFundingX96 grew
    // from 0 to 100 below tick 0.
    /// @param cumlFundingOppX96 Cumulative funding if only updates on the opposite side of a tick were counted. For
    /// example, if this is tick 0 and the current tick is 100, then it represents cumulative funding below tick 0. If
    /// current tick was -100, then it represents cumulative funding above tick 0. Cumulative funding on the same side
    /// as the current tick can be calculated with state.cumlFundingX96 - cumlFundingOppX96
    /// @param cumlFundingDivSqrtPOppX96 Cumulative funding divided by sqrt price if only updates on the opposite side
    /// of a tick were counted. For example, if this is tick 0 and the current tick is 100, then it represents
    /// cumlFundingDivSqrtP below tick 0. If current tick was -100, then it represents cumlFundingDivSqrtP above tick 0.
    /// cumlFundingDivSqrtP on the same side as the current tick can be calculated with
    /// state.cumlFundingDivSqrtPX96 - cumlFundingDivSqrtPOppX96
    struct TickInfo {
        int256 cumlFundingOppX96;
        int256 cumlFundingDivSqrtPOppX96;
    }

    /* FUNCTIONS */

    /// @notice Updates the cumulative funding and cumulative funding divided by sqrt price values to account for
    /// funding accrued since the last update
    /// @dev This should be called before prices change and before updateFundingPerSecond() is called because funding
    /// per second was some value since the last update and that value should be used for the time passed since then
    /// @param fundingState The calling contract's funding state
    /// @param sqrtPriceX96 The current sqrt price
    function updateCumlFunding(State storage fundingState, uint160 sqrtPriceX96) internal {
        int256 timeSinceLastUpdate = (block.timestamp - fundingState.lastCumlFundingUpdate).toInt256();
        fundingState.lastCumlFundingUpdate = block.timestamp.toUint32();

        // funding accrued is funding per second * number of seconds passed
        int256 fundingAccruedX96 = fundingState.fundingPerSecondX96 * timeSinceLastUpdate;
        fundingState.cumlFundingX96 += fundingAccruedX96;

        // cumlFundingDivSqrtPX96 update = funding accrued / √markPrice
        fundingState.cumlFundingDivSqrtPX96 += fundingAccruedX96.fullMulDivSigned(INT_Q96, sqrtPriceX96);
    }

    /// @notice Updates the funding per second value to account for new twAvgMarkX96 and twAvgIndexX96
    /// @dev This should be called after prices change and after updateCumlFunding() is called
    /// @param perpState The perp state to access twAvg and funding states from
    /// @param beacon The perp's beacon address
    /// @param sqrtPriceX96 The current sqrt price
    /// @return premiumPerSecondX96 The new funding per second value
    function updateFundingPerSecond(Mgr.PerpState storage perpState, address beacon, uint160 sqrtPriceX96)
        internal
        returns (int256 premiumPerSecondX96)
    {
        // get time weighted average of sqrt mark price & square it to get mark TWAP
        uint256 twAvgSqrtMarkX96 = perpState.twAvg.timeWeightedAvg(TWAVG_WINDOW, uint32(block.timestamp), sqrtPriceX96);
        uint256 twAvgMarkX96 = twAvgSqrtMarkX96.fullMulDiv(twAvgSqrtMarkX96, UINT_Q96);

        // call beacon to get index TWAP
        uint256 twAvgIndexX96 = ITimeWeightedAvg(beacon).timeWeightedAvg(TWAVG_WINDOW);

        // the amount paid (or received) due to funding per interval is (mark TWAP - index TWAP)
        // if positive (mark > index), longs pay shorts to incentivize downwards price movement towards index
        // if negative (mark < index), shorts pay longs to incentivize upwards price movement towards index
        int256 fundingPerIntervalX96 = twAvgMarkX96.toInt256() - twAvgIndexX96.toInt256();

        // funding per second is (funding per interval / seconds in an interval)
        premiumPerSecondX96 = fundingPerIntervalX96 / FUNDING_INTERVAL;
        perpState.funding.fundingPerSecondX96 = premiumPerSecondX96;
    }

    /// @notice Initializes a specified tick in State.ticks
    /// @dev Call this when a maker position is opened (non-zero liquidity) and the ticks defining the range have not
    /// been initialized yet. We assume all cumulative funding updates before a tick was initialized happened below it.
    /// @param state The calling contract's funding state
    /// @param tick The tick to initialize
    /// @param currentTick The perp's current tick
    function initTick(State storage state, int24 tick, int24 currentTick) internal {
        // If tick is less than or equal to the current tick, we set its values to the global cumulative funding values
        // to match the assumption that all cumulative funding updates happened below a newly initialized tick.
        if (tick <= currentTick) {
            state.ticks[tick].cumlFundingOppX96 = state.cumlFundingX96;
            state.ticks[tick].cumlFundingDivSqrtPOppX96 = state.cumlFundingDivSqrtPX96;
        }
        // otherwise, the tick's values are kept zeroed to represent 0 growth above the tick
    }

    /// @notice Crosses a tick in State.ticks and updates its values to keep track of cumulative funding opposite to it
    /// @param state The calling contract's funding state
    /// @param tickCrossed The tick to cross
    function crossTick(State storage state, int24 tickCrossed) internal {
        TickInfo storage tick = state.ticks[tickCrossed];

        // Each value is updated as: current cumulative - stored cumulative outside
        // This flip recalculates the tick’s cumulative funding by subtracting growth that occurred
        // on the side just crossed into, so the stored value continues to represent cumulative funding
        // on the opposite side (which has now switched).
        tick.cumlFundingOppX96 = state.cumlFundingX96 - tick.cumlFundingOppX96;
        tick.cumlFundingDivSqrtPOppX96 = state.cumlFundingDivSqrtPX96 - tick.cumlFundingDivSqrtPOppX96;
    }

    /// @notice Crosses all initialized ticks from a starting tick to an ending tick
    /// @dev Call this when sqrt price moves. Starting tick is assumed to already have been crossed, so it wont be
    /// crossed again. Ending tick will be crossed
    /// @param state The calling contract's funding state
    /// @param poolManager The pool manager
    /// @param poolId The pool id
    /// @param startingTick The starting tick
    /// @param endingTick The ending tick
    function crossTicks(
        State storage state,
        IPoolManager poolManager,
        PoolId poolId,
        int24 startingTick,
        int24 endingTick,
        int24 tickSpacing,
        bool zeroForOne
    ) internal {
        // TODO: tests for errors here
        // nextInitializedTickWithinOneWord returns ticks less than OR EQUAL to tick passed in, so we decrement to
        // move past starting tick if going downward to avoid duplicate crossing
        int24 tick = zeroForOne ? startingTick - 1 : startingTick;
        bool isInitialized;

        while (true) {
            (tick, isInitialized) = poolManager.nextInitializedTickWithinOneWord(poolId, tick, tickSpacing, zeroForOne);

            if (zeroForOne ? tick < endingTick : tick > endingTick) {
                // we've passed the ending tick, so we break
                break;
            } else {
                // else we haven't passed the ending tick yet, so we cross the tick
                if (isInitialized) crossTick(state, tick);
                // if going downward, we decrement to move past the tick so we don't cross it again
                if (zeroForOne) tick--;
            }
        }
    }

    /// @notice Clears a tick in State.ticks
    /// @dev Call this when a maker position is closed (zero liquidity) and the ticks defining the range are not
    /// used by any other maker positions
    /// @param state The calling contract's funding state
    /// @param tick The tick to clear
    function clear(State storage state, int24 tick) internal {
        delete state.ticks[tick];
    }

    /// @notice Calculates cumulative funding between particular ranges
    /// @param state The calling contract's funding state
    /// @param lowerTick The lower tick of the range
    /// @param upperTick The upper tick of the range
    /// @param currentTick The perp's current tick
    /// @return cumlFundingBelowX96 Cumulative funding if updates were only counted below the lower tick
    /// @return cumlFundingWithinX96 Cumulative funding if updates were only counted within the range
    /// @return cumlFundingDivSqrtPWithinX96 Cuml funding / sqrt price if updates were only counted within the range
    function cumlFundingRanges(State storage state, int24 lowerTick, int24 upperTick, int24 currentTick)
        internal
        view
        returns (int256 cumlFundingBelowX96, int256 cumlFundingWithinX96, int256 cumlFundingDivSqrtPWithinX96)
    {
        TickInfo storage tickLower = state.ticks[lowerTick];
        TickInfo storage tickUpper = state.ticks[upperTick];

        int256 cumlFundingDivSqrtPBelowLowerX96; // cumlFundingDivSqrtPX96 below lower tick
        int256 cumlFundingBelowUpperX96; // cumlFundingX96 below upper tick
        int256 cumlFundingDivSqrtPBelowUpperX96; // cumlFundingDivSqrtPX96 below upper tick

        if (currentTick >= lowerTick) {
            // if current tick above lowertick, then stored values represent cumulative funding below it
            cumlFundingBelowX96 = tickLower.cumlFundingOppX96;
            cumlFundingDivSqrtPBelowLowerX96 = tickLower.cumlFundingDivSqrtPOppX96;
        } else {
            // otherwise, we derive cumulative funding on the same side of the lower tick by taking the current global
            // cumulative and subtracting updates that happened above it
            cumlFundingBelowX96 = state.cumlFundingX96 - tickLower.cumlFundingOppX96;
            cumlFundingDivSqrtPBelowLowerX96 = state.cumlFundingDivSqrtPX96 - tickLower.cumlFundingDivSqrtPOppX96;
        }

        if (currentTick >= upperTick) {
            // if current tick above upper tick, then stored values represent cumulative funding below it
            cumlFundingBelowUpperX96 = tickUpper.cumlFundingOppX96;
            cumlFundingDivSqrtPBelowUpperX96 = tickUpper.cumlFundingDivSqrtPOppX96;
        } else {
            // otherwise, we derive cumulative funding on the same side of the upper tick by taking the current global
            // cumulative and subtracting updates that happened above it
            cumlFundingBelowUpperX96 = state.cumlFundingX96 - tickUpper.cumlFundingOppX96;
            cumlFundingDivSqrtPBelowUpperX96 = state.cumlFundingDivSqrtPX96 - tickUpper.cumlFundingDivSqrtPOppX96;
        }

        // TODO: test for >= & <= errors at range edges
        // we can take cumulative funding below the upper tick and subtract the cumulative funding below the lower tick
        // to get the cumulative funding only within the range
        cumlFundingWithinX96 = cumlFundingBelowUpperX96 - cumlFundingBelowX96;
        cumlFundingDivSqrtPWithinX96 = cumlFundingDivSqrtPBelowUpperX96 - cumlFundingDivSqrtPBelowLowerX96;
    }

    /// @notice Calculates the funding component for a maker’s remaining inventory, as if their held perps contributed
    /// to position size. Makers aren’t directionally exposed until trades move their balance beyond the initial
    /// inventory (e.g., if starting with 10 perps: 10 → 11 perps = short, or 10 → 9 perps = long, but 10 = no size).
    /// @dev No funding is accrued from a maker's inventory when the price is above the maker's range since their
    /// entire holdings are converted to usd (must hold usd to serve downward price moves)
    /// @param state The calling contract's funding state
    /// @param makerPos Details specific to the maker position
    /// @param currentTick The perp's current tick
    /// @return funding The funding component for the maker position
    function makerInventoryFunding(State storage state, Mgr.MakerDetails memory makerPos, int24 currentTick)
        internal
        view
        returns (int256)
    {
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(makerPos.tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(makerPos.tickUpper);

        (int256 cumlFundingBelowX96, int256 cumlFundingWithinX96, int256 cumlFundingDivSqrtPWithinX96) =
            cumlFundingRanges(state, makerPos.tickLower, makerPos.tickUpper, currentTick);

        // Calculating funding below the maker's range:
        // get the amount of perps held by the maker when price is below the maker's range. Recall that makers sell off
        // usd and buy perps for downward price moves, so they hold their max perp amount when price is below the range
        uint256 perpAmtBelow = LiquidityAmounts.getAmount0ForLiquidity(sqrtLowerX96, sqrtUpperX96, makerPos.liquidity);

        // calculate funding accrued per perp held while price was below the range since entry and multiply by the
        // number of perps held by this position when price is below range
        int256 deltaCumlFundingBelowX96 = cumlFundingBelowX96 - makerPos.entryCumlFundingBelowX96;
        int256 fundingBelow = perpAmtBelow.toInt256().fullMulDivSigned(deltaCumlFundingBelowX96, UINT_Q96);

        // Calculating funding within the maker's range:
        // recall that liquidity * (1 / √mark — 1 / √upper) is the amount of perp contracts held by the maker when
        // price = mark. We must multiply this by the funding accrued per perp since entry (delta cumulatives) to get
        // the funding owed while price was within the range: liquidity * funding * (1 / √mark — 1 / √upper). This
        // can be represented as liquidity * (funding / √mark — funding / √upper)

        // Ignoring liquidity, first part of the second term (funding / √mark) is just ΔcumlFundingDivSqrtPWithinX96
        int256 fundingDivSqrtMarkX96 = cumlFundingDivSqrtPWithinX96 - makerPos.entryCumlFundingDivSqrtPWithinX96;

        // For the second term, since sqrt upper is constant, we can take ΔcumlFundingWithinX96 and divide by sqrt upper
        int256 deltaCumlFundingWithinX96 = cumlFundingWithinX96 - makerPos.entryCumlFundingWithinX96;
        int256 fundingDivSqrtUpperX96 = deltaCumlFundingWithinX96.fullMulDivSigned(INT_Q96, sqrtUpperX96);

        // (1 / √mark — 1 / √upper)
        int256 rangeComponentX96 = fundingDivSqrtMarkX96 - fundingDivSqrtUpperX96;

        // liquidity * (1 / √mark — 1 / √upper)
        int256 fundingWithin = makerPos.liquidity.toInt256().fullMulDivSigned(rangeComponentX96, UINT_Q96);

        return fundingBelow + fundingWithin;
    }

    /// @notice Calculates the funding payment of an open maker or taker position
    /// @dev This should be called after updateCumlFunding() sto account for the time passed since the last update. If
    /// `payment` is positive, then that amount is paid by the holder. If negative, that amount is sent to the holder.
    /// @param state The calling contract's funding state
    /// @param pos The position to calculate funding for
    /// @param currentTick The perp's current tick
    /// @return payment The funding payment of the position
    function payment(State storage state, Mgr.Position memory pos, int24 currentTick) internal view returns (int256) {
        // the base funding payment is the position size * funding accrued per perp since entry. Perp delta is negative
        // if short, so payment's signage is corrected. Maker perp delta will always be <=0 since perps are sent in
        int256 funding = pos.entryPerpDelta.fullMulDivSigned(state.cumlFundingX96 - pos.entryCumlFundingX96, UINT_Q96);
        // if maker, we calculate funding using the amount of perps sent / received over time as position size
        // i.e. (funding for a maker's remaining inventory over time - funding for starting inventory (payment is <= 0))
        if (pos.makerDetails.liquidity > 0) funding += makerInventoryFunding(state, pos.makerDetails, currentTick);
        return funding;
    }
}
