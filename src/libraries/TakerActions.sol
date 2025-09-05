// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IPerpManager} from "../interfaces/IPerpManager.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {MoreSignedMath} from "./MoreSignedMath.sol";
import {SharedPositionLogic} from "./SharedPositionLogic.sol";
import {UniswapV4Utility} from "./UniswapV4Utility.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LivePositionDetailsReverter} from "./LivePositionDetailsReverter.sol";
import {PerpLogic} from "./PerpLogic.sol";

library TakerActions {
    using SafeCastLib for *;
    using FixedPointMathLib for *;
    using UniswapV4Utility for IUniversalRouter;
    using SafeTransferLib for address;
    using StateLibrary for IPoolManager;
    using MoreSignedMath for int256;
    using SharedPositionLogic for IPerpManager.Perp;
    using PerpLogic for uint160;

    function openTakerPosition(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts calldata c,
        IPerpManager.OpenTakerPositionParams calldata params
    )
        external
        returns (uint128 takerPosId)
    {
        if (params.margin == 0) revert IPerpManager.InvalidMargin(params.margin);
        uint256 lev = params.levX96;
        uint128 maxLev = perp.maxOpeningLevX96;
        if (lev == 0 || lev > maxLev) revert IPerpManager.InvalidLevX96(lev, maxLev);

        PoolKey memory key = perp.key;
        PoolId perpId = key.toId();

        uint256 size;
        uint128 value = params.margin.mulDiv(params.levX96, FixedPoint96.UINT_Q96).toUint128();

        bool reverted;
        if (params.isLong) {
            // if long, swap usd in for perps out; buying perps
            (size, reverted) = c.router.swapExactIn(key, false, value, params.minAmt0Out, true, params.timeout);
            if (reverted) revert UniswapV4Utility.SwapReverted();
        } else {
            // if short, swap perps in for usd out; borrowing then selling perps
            (size, reverted) = c.router.swapExactOut(key, true, value, params.maxAmt0In, true, params.timeout);
            if (reverted) revert UniswapV4Utility.SwapReverted();
        }

        // revert if price impact was too high
        perp.checkPriceImpact(c);

        takerPosId = perp.nextTakerPosId;
        perp.nextTakerPosId++;

        perp.takerPositions[takerPosId] = IPerpManager.TakerPos({
            holder: msg.sender,
            isLong: params.isLong,
            size: size.toUint128(),
            margin: params.margin,
            entryValue: value,
            entryTwPremiumX96: perp.twPremiumX96
        });

        // Transfer margin from the user to the contract
        c.usdc.safeTransferFrom(msg.sender, perp.vault, params.margin);

        (uint160 sqrtPriceX96,,,) = c.poolManager.getSlot0(perpId);
        emit IPerpManager.TakerPositionOpened(perpId, takerPosId, perp.takerPositions[takerPosId], sqrtPriceX96);
    }

    function addTakerMargin(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts calldata c,
        IPerpManager.AddMarginParams calldata params
    )
        external
    {
        address holder = perp.takerPositions[params.posId].holder;
        uint128 margin = params.margin;

        perp.addMargin(c, holder, margin);

        // update taker position state
        perp.takerPositions[params.posId].margin += margin;

        emit IPerpManager.TakerMarginAdded(perp.key.toId(), params.posId, margin);
    }

    function closeTakerPosition(
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

        IPerpManager.TakerPos memory takerPos = perp.takerPositions[params.posId];

        if (takerPos.holder == address(0)) {
            if (revertChanges) {
                (uint160 sqrtPriceX96,,,) = c.poolManager.getSlot0(perpId);
                uint256 newPriceX96 = sqrtPriceX96.toPriceX96();
                LivePositionDetailsReverter.revertLivePositionDetails(0, 0, 0, false, newPriceX96);
            } else {
                revert IPerpManager.InvalidClose(msg.sender, address(0), false);
            }
        }

        uint256 notional;
        int256 pnl;

        bool reverted;
        if (takerPos.isLong) {
            // sell perps for usd (swap in perps, get out usd)
            uint128 perpsIn = takerPos.size;
            (notional, reverted) = c.router.swapExactIn(key, true, perpsIn, params.minAmt1Out, false, params.timeout);
            if (reverted) revert UniswapV4Utility.SwapReverted();
            // usd received minus entry cost
            pnl = int256(notional) - int256(uint256(takerPos.entryValue));
        } else {
            // buy back perps for usd (swap in usd, get out perps)
            uint128 perpsOut = takerPos.size;
            (notional, reverted) = c.router.swapExactOut(key, false, perpsOut, params.maxAmt1In, false, params.timeout);
            if (reverted) revert UniswapV4Utility.SwapReverted();
            // entry loan value minus usd used to buy back and pay debt
            pnl = int256(uint256(takerPos.entryValue)) - int256(notional);
        }

        int256 twPremiumGrowthX96 = perp.twPremiumX96 - takerPos.entryTwPremiumX96;
        int256 funding = twPremiumGrowthX96.mulDivSigned(takerPos.size.toInt256(), FixedPoint96.UINT_Q96);
        if (!takerPos.isLong) funding = -funding;

        bool wasLiquidation =
            perp.closePosition(c, takerPos.holder, takerPos.margin, pnl, funding, notional, revertChanges, doNotPayout);

        (uint160 sqrtPriceX96,,,) = c.poolManager.getSlot0(perpId);
        emit IPerpManager.TakerPositionClosed(perpId, params.posId, wasLiquidation, takerPos, sqrtPriceX96);
        delete perp.takerPositions[params.posId];
    }
}
