// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IPerpManager} from "../interfaces/IPerpManager.sol";
import {MAX_CARDINALITY} from "../utils/Constants.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {LivePositionDetailsReverter} from "./LivePositionDetailsReverter.sol";
import {PerpLogic} from "./PerpLogic.sol";
import {TickTWAP} from "./TickTWAP.sol";
import {TokenMath} from "./TokenMath.sol";
import {UniswapV4Utility} from "./UniswapV4Utility.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";

library SharedPositionLogic {
    using SafeCastLib for uint256;
    using FixedPointMathLib for uint256;
    using TokenMath for *;
    using SafeTransferLib for address;
    using PerpLogic for *;
    using UniswapV4Utility for *;
    using TickTWAP for TickTWAP.Observation[MAX_CARDINALITY];

    function addMargin(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts calldata c,
        address holder,
        uint128 margin
    )
        internal
    {
        (uint160 sqrtPriceX96, int24 currentTick) = c.poolManager.getSqrtPriceX96AndTick(perp.key.toId());

        // update funding accounting
        perp.updateTwPremiums(sqrtPriceX96);
        perp.updatePremiumPerSecond(sqrtPriceX96);

        // update mark twap
        (perp.twapState.index, perp.twapState.cardinality) = perp.twapState.observations.write(
            perp.twapState.index,
            block.timestamp.toUint32(),
            currentTick,
            perp.twapState.cardinality,
            perp.twapState.cardinalityNext
        );

        // validate caller is holder and that margin is nonzero
        if (msg.sender != holder) revert IPerpManager.InvalidCaller(msg.sender, holder);
        if (margin == 0) revert IPerpManager.InvalidMargin(margin);

        perp.totalMargin += margin;

        // transfer margin from sender to vault
        c.usdc.safeTransferFrom(msg.sender, perp.vault, margin);
    }

    function closePosition(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts calldata c,
        address holder,
        uint256 scaledMargin,
        int256 pnl,
        int256 funding,
        uint256 notional,
        bool revertChanges,
        bool doNotPayout
    )
        internal
        returns (bool wasLiquidation)
    {
        uint256 effectiveMargin;
        uint256 liquidationFeeAmt;

        (wasLiquidation, effectiveMargin, liquidationFeeAmt) =
            isLiquidatable(perp, scaledMargin, pnl, funding, notional);

        if (revertChanges) {
            LivePositionDetailsReverter.revertLivePositionDetails(pnl, funding, effectiveMargin, wasLiquidation);
        } else if (wasLiquidation) {
            // send remaining margin to position holder
            if (!doNotPayout) c.usdc.safeTransferFrom(perp.vault, holder, effectiveMargin.scale18To6());
            // send part of liquidation fee to liquidator; the rest is kept as insurance
            c.usdc.safeTransferFrom(perp.vault, msg.sender, liquidationFeeAmt.scale18To6());
        } else if (holder == msg.sender) {
            // If not liquidated and caller is the owner, return effective margin
            if (!doNotPayout) c.usdc.safeTransferFrom(perp.vault, holder, effectiveMargin.scale18To6());
            // revert if price impact was too high
            checkPriceImpact(perp, c);
        } else if (doNotPayout) {
            // if not liquidation and caller not holder but force closing, return
            return wasLiquidation;
        } else {
            // Otherwise, caller is not position holder and position is not liquidatable
            revert IPerpManager.InvalidClose(msg.sender, holder, false);
        }
    }

    // expects values scaled to 18 decimals
    function isLiquidatable(
        IPerpManager.Perp storage perp,
        uint256 scaledEntryMargin,
        int256 pnl,
        int256 funding,
        uint256 notional
    )
        internal
        returns (bool liquidatable, uint256 effectiveMargin, uint256 liquidationFeeAmt)
    {
        int256 netMargin = scaledEntryMargin.toInt256() + pnl - funding;

        liquidationFeeAmt = notional.mulDiv(perp.liquidationFeeX96, FixedPoint96.UINT_Q96);

        if (netMargin <= 0) {
            liquidatable = true;
            effectiveMargin = 0;
            liquidationFeeAmt = 0;
            perp.badDebt += uint128(uint256(-netMargin).scale18To6());
        } else if (uint256(netMargin) <= liquidationFeeAmt) {
            liquidatable = true;
            effectiveMargin = 0;
            liquidationFeeAmt = uint256(netMargin);
        } else {
            effectiveMargin = uint256(netMargin);
            uint256 netMarginWithFee = effectiveMargin - liquidationFeeAmt;

            uint256 levX96 = notional.mulDiv(FixedPoint96.UINT_Q96, netMarginWithFee);
            liquidatable = levX96 >= perp.liquidationLevX96;

            if (liquidatable) effectiveMargin = netMarginWithFee;
        }
    }

    function checkPriceImpact(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts calldata c
    )
        internal
        view
    {
        (uint160 sqrtPriceX96, int24 currentTick) = c.poolManager.getSqrtPriceX96AndTick(perp.key.toId());

        // get mark twap, and calculate price band around it
        uint256 markTwapX96 = perp.getTWAP(perp.twapWindow, currentTick);

        uint256 priceImpactBandLowerX96 = FixedPoint96.UINT_Q96 - perp.priceImpactBandX96;
        uint256 priceImpactBandUpperX96 = FixedPoint96.UINT_Q96 + perp.priceImpactBandX96;

        uint256 minPriceX96 = markTwapX96.mulDiv(priceImpactBandLowerX96, FixedPoint96.UINT_Q96);
        uint256 maxPriceX96 = markTwapX96.mulDiv(priceImpactBandUpperX96, FixedPoint96.UINT_Q96);

        // ensure new price is within price band
        uint256 priceX96 = sqrtPriceX96.toPriceX96();
        if (priceX96 < minPriceX96 || priceX96 > maxPriceX96) {
            revert IPerpManager.PriceImpactTooHigh(priceX96, minPriceX96, maxPriceX96);
        }
    }
}
