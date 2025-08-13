// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IPerpManager} from "../interfaces/IPerpManager.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {Funding} from "./Funding.sol";
import {PerpLogic} from "./PerpLogic.sol";
import {SharedPositionLogic} from "./SharedPositionLogic.sol";
import {Tick} from "./Tick.sol";
import {TokenMath} from "./TokenMath.sol";
import {UniswapV4Utility} from "./UniswapV4Utility.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

library MakerActions {
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for *;
    using TokenMath for *;
    using UniswapV4Utility for *;
    using SafeCastLib for *;
    using SafeTransferLib for address;
    using Tick for mapping(int24 => Tick.GrowthInfo);
    using LiquidityAmounts for uint160;
    using SharedPositionLogic for IPerpManager.Perp;
    using PerpLogic for uint160;

    function openMakerPosition(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts calldata c,
        IPerpManager.OpenMakerPositionParams calldata params
    )
        external
        returns (uint128 makerPosId)
    {
        if (params.margin == 0) revert IPerpManager.InvalidMargin(params.margin);
        if (params.liquidity == 0) revert IPerpManager.InvalidLiquidity(params.liquidity);
        if (params.tickLower >= params.tickUpper) {
            revert IPerpManager.InvalidTickRange(params.tickLower, params.tickUpper);
        }

        PoolKey memory key = perp.key;
        PoolId perpId = key.toId();

        // scale margin to 18 decimals, and add to total margin
        uint256 scaledMargin = params.margin.scale6To18();
        perp.totalMargin += params.margin;

        // calculate notional value of liquidity at current price
        (uint160 sqrtPriceX96,,,) = c.poolManager.getSlot0(perpId);
        uint256 notional = liquidityNotional(params.liquidity, sqrtPriceX96, params.tickLower, params.tickUpper);

        // check that opening leverage is within bounds
        uint256 levX96 = notional.mulDiv(FixedPoint96.UINT_Q96, scaledMargin);
        if (levX96 > perp.maxOpeningLevX96) revert IPerpManager.InvalidLevX96(levX96, perp.maxOpeningLevX96);

        // mint underlying lp position
        uint256 perpsBorrowed;
        uint256 usdBorrowed;
        (makerPosId, perpsBorrowed, usdBorrowed) = c.posm.mintLiqPos(
            key,
            params.tickLower,
            params.tickUpper,
            params.liquidity,
            params.maxAmt0In,
            params.maxAmt1In,
            params.timeout
        );

        // update maker position state
        perp.makerPositions[makerPosId] = IPerpManager.MakerPos({
            holder: msg.sender,
            margin: params.margin,
            liquidity: params.liquidity,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            perpsBorrowed: perpsBorrowed.toUint128(),
            usdBorrowed: usdBorrowed.toUint128(),
            entryTwPremiumX96: perp.twPremiumX96,
            entryTwPremiumDivBySqrtPriceX96: perp.twPremiumDivBySqrtPriceX96,
            entryTimestamp: block.timestamp.toUint32()
        });

        // transfer margin from sender to vault
        c.usdc.safeTransferFrom(msg.sender, perp.vault, params.margin);

        emit IPerpManager.MakerPositionOpened(perpId, makerPosId, perp.makerPositions[makerPosId], sqrtPriceX96);
    }

    function addMakerMargin(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts calldata c,
        IPerpManager.AddMarginParams calldata params
    )
        external
    {
        address holder = perp.makerPositions[params.posId].holder;
        uint128 margin = params.margin;

        perp.addMargin(c, holder, margin);

        // update maker position state
        perp.makerPositions[params.posId].margin += margin;

        emit IPerpManager.MakerMarginAdded(perp.key.toId(), params.posId, margin);
    }

    function closeMakerPosition(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts calldata c,
        IPerpManager.ClosePositionParams calldata params,
        bool revertChanges, // true if used as a view function, otherwise false
        bool doNotPayout // forces close and does not payout holder, only true in market death
    )
        external
    {
        PoolKey memory key = perp.key;
        PoolId perpId = key.toId();
        IPerpManager.MakerPos memory makerPos = perp.makerPositions[params.posId];

        if (!revertChanges) checkLockup(makerPos.entryTimestamp, perp.makerLockupPeriod);

        uint256 scaledMargin = makerPos.margin.scale6To18();
        perp.totalMargin -= makerPos.margin;

        (uint256 perpsReceived, uint256 usdReceived) =
            c.posm.burnLiqPos(key, params.posId, params.minAmt0Out, params.minAmt1Out, params.timeout);

        int256 pnl = int256(usdReceived) - int256(uint256(makerPos.usdBorrowed));
        int256 excessPerps = int256(perpsReceived) - int256(uint256(makerPos.perpsBorrowed));

        pnl += settleExcess(perp, c, params, excessPerps, makerPos.holder);

        (uint160 sqrtPriceX96, int24 currentTick) = c.poolManager.getSqrtPriceX96AndTick(perpId);

        int256 funding = makerFunding(perp, makerPos, currentTick);

        uint256 notional = liquidityNotional(makerPos.liquidity, sqrtPriceX96, makerPos.tickLower, makerPos.tickUpper);

        bool wasLiquidation =
            perp.closePosition(c, makerPos.holder, scaledMargin, pnl, funding, notional, revertChanges, doNotPayout);

        emit IPerpManager.MakerPositionClosed(perpId, params.posId, wasLiquidation, makerPos, sqrtPriceX96);
        delete perp.makerPositions[params.posId];
    }

    function liquidityNotional(
        uint128 liquidity,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper
    )
        internal
        pure
        returns (uint256 notional)
    {
        // get sqrt price at lower and upper ticks
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // convert liquidity to token amounts at current price
        (uint256 perps, uint256 usd) = sqrtPriceX96.getAmountsForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);

        // convert currency0Amount (perp contracts) to its value in currency1 (usd)
        uint256 perpsNotional = perps.mulDiv(sqrtPriceX96.toPriceX96(), FixedPoint96.UINT_Q96);

        // currency1Amount is already in USD, so its notional value is its amount
        notional = perpsNotional + usd;
    }

    function makerFunding(
        IPerpManager.Perp storage perp,
        IPerpManager.MakerPos memory makerPos,
        int24 currentTick
    )
        internal
        view
        returns (int256)
    {
        return Funding.calcPendingFundingPaymentWithLiquidityCoefficient(
            makerPos.perpsBorrowed.toInt256(),
            makerPos.entryTwPremiumX96,
            Funding.Growth({
                twPremiumX96: perp.twPremiumX96,
                twPremiumDivBySqrtPriceX96: perp.twPremiumDivBySqrtPriceX96
            }),
            Funding.calcLiquidityCoefficientInFundingPaymentByOrder(
                makerPos.liquidity,
                makerPos.tickLower,
                makerPos.tickUpper,
                perp.tickGrowthInfo.getAllFundingGrowth(
                    makerPos.tickLower,
                    makerPos.tickUpper,
                    currentTick,
                    perp.twPremiumX96,
                    perp.twPremiumDivBySqrtPriceX96
                )
            )
        );
    }

    function checkLockup(uint32 entryTimestamp, uint32 lockupPeriod) internal view {
        // ensure lockupPeriod has passed since entryTimestamp
        if (block.timestamp <= entryTimestamp + lockupPeriod) {
            revert IPerpManager.MakerPositionLocked(block.timestamp, entryTimestamp + lockupPeriod);
        }
    }

    function settleExcess(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts calldata c,
        IPerpManager.ClosePositionParams calldata params,
        int256 excessPerps,
        address holder
    )
        internal
        returns (int256 pnlChange)
    {
        PoolKey memory key = perp.key;

        uint128 absExcessPerps = excessPerps.abs().toUint128();

        bool reverted;
        bool isExcessLong = excessPerps > 0; // the directional exposure that the excess perps is causing

        if (isExcessLong) {
            // must sell excess perp contracts to close long exposure
            uint256 usdOut;
            (usdOut, reverted) = c.router.swapExactIn(key, true, absExcessPerps, params.minAmt1Out, 0, params.timeout);

            // if swap was successful, update pnlChange with profit from selling
            if (!reverted) pnlChange = int256(usdOut);
        } else if (excessPerps != 0) {
            // if excessPerps != 0, there is a short exposure to close
            // must buy perps to pay back debt / close short exposure
            uint256 usdIn;
            (usdIn, reverted) = c.router.swapExactOut(key, false, absExcessPerps, params.maxAmt1In, 0, params.timeout);

            // if swap was successful, update pnlChange with cost of buying
            if (!reverted) pnlChange = -int256(usdIn);
        }

        // if the swap reverted, there was no liquidity to swap against while settling excess
        // so, we need to store a taker position with the corresponding excess exposure
        if (reverted) {
            (uint160 sqrtPriceX96,,,) = c.poolManager.getSlot0(key.toId());

            // notional = size * price
            uint256 notional = absExcessPerps.mulDiv(sqrtPriceX96.toPriceX96(), FixedPoint96.UINT_Q96);
            // margin = notional / maxOpeningLev; the min margin to open a max leverage position
            uint256 margin = notional.mulDiv(FixedPoint96.UINT_Q96, perp.maxOpeningLevX96).scale18To6();

            // it costs the holder margin amount to open this position
            pnlChange = -int256(margin.scale6To18());
            // add margin to total margin
            perp.totalMargin += margin.toUint128();

            // store taker position
            uint128 takerPosId = perp.nextTakerPosId;
            perp.takerPositions[takerPosId] = IPerpManager.TakerPos({
                holder: holder,
                isLong: isExcessLong,
                size: absExcessPerps,
                margin: margin.toUint128(),
                entryValue: 0, // entryValue is 0, so that pnl represents the correct profit/loss from settling excess
                entryTwPremiumX96: perp.twPremiumX96
            });
            perp.nextTakerPosId++;

            emit IPerpManager.TakerPositionOpened(
                perp.key.toId(), takerPosId, perp.takerPositions[takerPosId], sqrtPriceX96
            );
        }
    }
}
