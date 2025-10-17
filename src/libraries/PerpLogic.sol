// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpVault} from "../PerpVault.sol";
import {IPerpManager as Mgr} from "../interfaces/IPerpManager.sol";
import {IBeacon} from "../interfaces/beacons/IBeacon.sol";
import "./Constants.sol";
import {Funding} from "./Funding.sol";
import {Quoter} from "./Quoter.sol";
import {SignedMath} from "./SignedMath.sol";
import {TimeWeightedAvg} from "./TimeWeightedAvg.sol";
import {TradingFee} from "./TradingFee.sol";
import {UniV4Router as Router} from "./UniV4Router.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title PerpLogic
/// @notice Library for the logic of the perp manager
library PerpLogic {
    using Router for IPoolManager;
    using TimeWeightedAvg for TimeWeightedAvg.State;
    using FixedPointMathLib for *;
    using StateLibrary for IPoolManager;
    using SafeCastLib for *;
    using SignedMath for int256;
    using TradingFee for Mgr.Perp;
    using SafeTransferLib for address;
    using Funding for *;

    /* FUNCTIONS */

    /// @notice Creates a new perp and stores it in the passed mapping
    /// @param perps The mapping of perps to their state
    /// @param poolManager The pool manager to create a corresponding Uniswap pool in
    /// @param usdc The address of the USDC token
    /// @param params The parameters for creating the perp
    /// @return perpId The ID of the newly created perp
    function createPerp(
        mapping(PoolId => Mgr.Perp) storage perps,
        IPoolManager poolManager,
        address usdc,
        Mgr.CreatePerpParams calldata params
    ) external returns (PoolId perpId) {
        // prepare params for creating a pool in Uniswap
        Router.CreatePoolConfig memory config = Router.CreatePoolConfig(TICK_SPACING, params.startingSqrtPriceX96);

        // execute the create pool action using an encoded config, obtaining an encoded key for the newly created pool
        bytes memory encodedPoolKey = poolManager.executeAction(Router.CREATE_POOL, abi.encode(config));

        // decode the key and obtain the Uniswap poolId to use as the perpId
        PoolKey memory key = abi.decode(encodedPoolKey, (PoolKey));
        perpId = key.toId();

        // initialize the perp's state
        Mgr.Perp storage perp = perps[perpId];

        // TODO: replace with module addresses that serve perp manager information when needed
        perp.vault = address(new PerpVault(address(this), usdc));
        perp.creationTimestamp = uint32(block.timestamp);
        perp.makerLockupPeriod = MAKER_LOCKUP_PERIOD;
        perp.beacon = params.beacon;
        perp.twAvgWindow = TW_AVG_WINDOW;
        perp.creator = msg.sender;
        perp.creatorFee = CREATOR_FEE;
        perp.insuranceFee = INSURANCE_FEE;
        perp.nextPosId = 1; // position IDs start at 1
        perp.sqrtPriceLowerMultiX96 = SQRT_PRICE_LOWER_MULTI_X96;
        perp.sqrtPriceUpperMultiX96 = SQRT_PRICE_UPPER_MULTI_X96;
        perp.minOpeningMargin = MIN_OPENING_MARGIN;
        perp.minMakerOpeningMarginRatio = MIN_MAKER_OPENING_MARGIN_RATIO;
        perp.maxMakerOpeningMarginRatio = MAX_MAKER_OPENING_MARGIN_RATIO;
        perp.makerLiquidationMarginRatio = MAKER_LIQUIDATION_MARGIN_RATIO;
        perp.minTakerOpeningMarginRatio = MIN_TAKER_OPENING_MARGIN_RATIO;
        perp.maxTakerOpeningMarginRatio = MAX_TAKER_OPENING_MARGIN_RATIO;
        perp.takerLiquidationMarginRatio = TAKER_LIQUIDATION_MARGIN_RATIO;
        perp.liquidationFee = LIQUIDATION_FEE;
        perp.liquidatorFeeSplit = LIQUIDATOR_FEE_SPLIT;
        perp.key = key;

        // initialize the perp's time weighted average state and increase the cardinality cap to its starting value
        perp.twAvgState.initialize(uint32(block.timestamp));
        perp.twAvgState.increaseCardinalityCap(INITIAL_CARDINALITY_CAP);

        uint256 indexPriceX96 = IBeacon(params.beacon).data();
        emit Mgr.PerpCreated(perpId, params.beacon, params.startingSqrtPriceX96, indexPriceX96);
    }

    /// @notice Opens a new maker or taker position in a perp
    /// @dev The struct encoded into `encodedParams` should correspond to the type of position being opened (`isMaker`)
    /// @param perp The perp to open the position in
    /// @param poolManager The Uniswap pool manager to call swapping and liquidity modification actions on
    /// @param usdc The address of the USDC token
    /// @param encodedParams The encoded parameters for opening the position (an encoded maker or taker params struct)
    /// @param isMaker Whether the position is a maker position. If false, the position is a taker position
    /// @param revertChanges Whether to revert the changes (and thus not change state)
    /// @return posId The ID of the opened position
    /// @return pos The details of the opened position
    function openPosition(
        Mgr.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        bytes calldata encodedParams,
        bool isMaker,
        bool revertChanges
    ) external returns (uint128 posId, Mgr.Position memory pos) {
        PoolId perpId = perp.key.toId();
        (uint160 sqrtPriceX96, int24 startTick,,) = poolManager.getSlot0(perpId);

        // update cumulative funding trackers based on funding per second at last update and seconds passed since then
        perp.fundingState.updateCumlFunding(sqrtPriceX96);

        posId = perp.nextPosId;
        perp.nextPosId++;

        // set known position details; cumlFundingX96 & adlGrowth will not change for the remainder of this function
        pos.holder = msg.sender;
        pos.entryCumlFundingX96 = perp.fundingState.cumlFundingX96;
        pos.entryBadDebtGrowth = perp.badDebtGrowth;

        // we need to know how to decode `encodedParams`, which is based on if a maker or taker position is being opened
        if (isMaker) {
            Mgr.OpenMakerPositionParams memory params = abi.decode(encodedParams, (Mgr.OpenMakerPositionParams));

            if (params.liquidity == 0) revert Mgr.InvalidLiquidity(params.liquidity);

            pos.margin = params.margin;

            int24 tickLower = params.tickLower;
            int24 tickUpper = params.tickUpper;

            // check if ticks defining the maker's range are initialized in Uniswap before the liquidity is added
            // if not, initialize them in our funding state using startTick as the current tick
            if (!poolManager.isTickInitialized(perpId, tickLower)) perp.fundingState.initTick(tickLower, startTick);
            if (!poolManager.isTickInitialized(perpId, tickUpper)) perp.fundingState.initTick(tickUpper, startTick);

            // obtain cumulative funding values in certain ranges at entry time, used to calculate funding owed at close
            (int256 cumlFundingBelowX96, int256 cumlFundingWithinX96, int256 cumlFundingDivSqrtPWithinX96) =
                perp.fundingState.cumlFundingRanges(tickLower, tickUpper, startTick);

            // use provided and calculated values to assign maker-specific details
            pos.makerDetails = Mgr.MakerDetails({
                unlockTimestamp: uint32(block.timestamp) + perp.makerLockupPeriod, // TODO: query module
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: params.liquidity,
                entryCumlFundingBelowX96: cumlFundingBelowX96,
                entryCumlFundingWithinX96: cumlFundingWithinX96,
                entryCumlFundingDivSqrtPWithinX96: cumlFundingDivSqrtPWithinX96
            });

            // prepare a config specifying adding liquidity to perp's Uniswap pool in the defined tick range
            Router.LiquidityConfig memory config = Router.LiquidityConfig({
                poolKey: perp.key,
                positionId: posId, // positionId is used as salt (also specified at close to identify position)
                isAdd: true,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityToMove: params.liquidity,
                amount0Limit: params.maxAmt0In,
                amount1Limit: params.maxAmt1In
            });

            // execute the modify liquidity action using an encoded config & obtain encoded deltas of the tokens moved
            // decode deltas and assign them to the position. They will be negative (or zero) since tokens are sent in
            bytes memory encodedDeltas = poolManager.executeAction(Router.MODIFY_LIQUIDITY, abi.encode(config));
            (pos.entryPerpDelta, pos.entryUsdDelta) = abi.decode(encodedDeltas, (int256, int256));

            // it's okay if one delta is zero (e.g. a maker specifies a range above or below current tick) but not both
            if (pos.entryPerpDelta == 0 && pos.entryUsdDelta == 0) revert Mgr.ZeroDeltaPosition();

            // notional value = (perp amount * price) + usd amount
            uint256 priceX96 = sqrtPriceX96.fullMulDiv(sqrtPriceX96, UINT_Q96);
            uint256 notional = pos.entryPerpDelta.abs().fullMulDiv(priceX96, UINT_Q96) + pos.entryUsdDelta.abs();

            // TODO: replace with module call to get min and max margin ratios
            validateMarginRatio(perp, pos.margin, notional, true);

            if (!revertChanges) usdc.safeTransferFrom(msg.sender, perp.vault, pos.margin);
        } else {
            Mgr.OpenTakerPositionParams memory params = abi.decode(encodedParams, (Mgr.OpenTakerPositionParams));

            // notional value before fees = margin * leverage
            uint256 notional = params.margin.mulDiv(params.levX96, UINT_Q96);

            // TODO: replace with module call to get fees
            // calculate fees as percentages of notional value
            uint256 creatorFeeAmt = notional.mulDiv(perp.creatorFee, SCALE_1E6); // creatorFee * notional
            uint256 insuranceFeeAmt = notional.mulDiv(perp.insuranceFee, SCALE_1E6); // insuranceFee * notional
            uint256 lpFee = perp.calculateTradingFee(poolManager);
            uint256 lpFeeAmt = notional.mulDiv(lpFee, SCALE_1E6); // lpFee * notional

            // insurance funds already in vault; just increase increment allowance for covering bad debt
            perp.insurance += insuranceFeeAmt.toUint128();

            // update the position's margin to account for fees paid
            pos.margin = params.margin - creatorFeeAmt - insuranceFeeAmt - lpFeeAmt;
            // update notional value based on lower margin after fees (new margin * leverage)
            notional = pos.margin.mulDiv(params.levX96, UINT_Q96);

            // TODO: replace with module call to get min and max margin ratios
            validateMarginRatio(perp, pos.margin, notional, false);

            // prepare a config specifying a swap of:
            // if long, exact amount of usd (currency1) in for at least unspecifiedAmountLimit perps (currency0) out
            // if short, at most unspecifiedAmountLimit perps (currency0) in for an exact amount of usd (currency1) out
            // for both cases, amountSpecified is the notional value of the position in usd (currency1) &
            // unspecifiedAmountLimit is the max perps sent in (for shorts) or min usd received out (for longs)
            Router.SwapConfig memory config = Router.SwapConfig({
                poolKey: perp.key,
                isExactIn: params.isLong,
                zeroForOne: !params.isLong,
                amountSpecified: notional,
                // calculate the sqrt price at which the swap will stop and only be partially filled
                sqrtPriceLimitX96: sqrtPriceLimitX96(perp, sqrtPriceX96, !params.isLong, false),
                unspecifiedAmountLimit: params.unspecifiedAmountLimit
            });

            // execute the swap action using an encoded config & obtain encoded deltas of the tokens moved. Then, decode
            // deltas and assign them to the position. If long, perpDelta > 0 & usdDelta < 0 since perps were sent in &
            // usd was received out. If short, perpDelta < 0 & usdDelta > 0 since perps were sent in & usd received out.
            bytes memory encodedDeltas = poolManager.executeAction(Router.SWAP, abi.encode(config));
            (pos.entryPerpDelta, pos.entryUsdDelta) = abi.decode(encodedDeltas, (int256, int256));

            // either delta being zero means tokens may have been received out for free (or sent in with no output)
            if (pos.entryPerpDelta == 0 || pos.entryUsdDelta == 0) revert Mgr.ZeroDeltaPosition();

            // the pool of taker OI to absorb ADL is larger, so increment tracker to represent this
            perp.takerOpenInterest += pos.entryPerpDelta.abs().toUint128();

            int24 endTick;
            (sqrtPriceX96, endTick,,) = poolManager.getSlot0(perpId);

            // after price has moved, replicate crossing the ticks that were crossed in Uniswap in our tick mapping
            // if long, we move upward from startTick to endTick. If short, we move downward from startTick to endTick
            perp.fundingState.crossTicks(poolManager, perpId, startTick, endTick, perp.key.tickSpacing, !params.isLong);

            // after the swap has landed the current tick into some LP range, distribute the calculated LP fee to LPs in
            // this range. Consideration: ranges passed during the middle of the swap are not rewarded
            poolManager.executeAction(Router.DONATE, abi.encode(Router.DonateConfig(perp.key, lpFeeAmt)));

            // use params.margin instead of pos.margin since this includes the fees paid
            if (!revertChanges) usdc.safeTransferFrom(msg.sender, perp.vault, params.margin);
            if (!revertChanges) usdc.safeTransferFrom(perp.vault, perp.creator, creatorFeeAmt);
        }

        // disallow low margin amts that may cause potential rounding issues, else store pos in perp positions mapping
        if (pos.margin < perp.minOpeningMargin) revert Mgr.InvalidMargin(pos.margin);
        perp.positions[posId] = pos;

        // write a twAvg observation (time has passed since last update & sqrtPriceX96 has changed if taker pos opened)
        perp.twAvgState.write(uint32(block.timestamp), sqrtPriceX96);

        // fundingPerSec updated after price change & new twAvg observation to capture latest twAvgMark & twAvgIndex
        int256 fundingPerSecX96 = perp.updateFundingPerSecond(uint32(block.timestamp), sqrtPriceX96);

        // if quoting, we revert with final deltas. This should be caught by a try-catch and the reason can be parsed
        if (revertChanges) revert Quoter.OpenQuote(pos.entryPerpDelta, pos.entryUsdDelta);

        emit Mgr.PositionOpened(perpId, posId, pos, sqrtPriceX96, fundingPerSecX96);
    }

    /// @notice Adds margin to an open position
    /// @param perp The perp to add margin to
    /// @param poolManager The pool manager to use
    /// @param usdc The USDC token address
    /// @param params The parameters for adding margin
    function addMargin(
        Mgr.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        Mgr.AddMarginParams calldata params
    ) external {
        Mgr.Position storage pos = perp.positions[params.posId];

        if (msg.sender != pos.holder) revert Mgr.InvalidCaller(msg.sender, pos.holder);
        if (params.amtToAdd == 0) revert Mgr.InvalidMargin(params.amtToAdd);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(perp.key.toId());

        pos.margin += params.amtToAdd;

        // if taker, notional value = (perp amount * price)
        uint256 priceX96 = sqrtPriceX96.fullMulDiv(sqrtPriceX96, UINT_Q96);
        uint256 notional = pos.entryPerpDelta.abs().fullMulDiv(priceX96, UINT_Q96);
        // if maker, we need to add value of usd held
        if (pos.makerDetails.liquidity > 0) notional += pos.entryUsdDelta.abs();

        // TODO: replace with module call to get min and max margin ratios
        validateMarginRatio(perp, pos.margin, notional, true);

        // mark unchanged, but time passed — update cumuls, write a twAvg obs, & refresh funding rate w/ latest twAvgs
        perp.fundingState.updateCumlFunding(sqrtPriceX96);
        perp.twAvgState.write(uint32(block.timestamp), sqrtPriceX96);
        perp.updateFundingPerSecond(uint32(block.timestamp), sqrtPriceX96);

        usdc.safeTransferFrom(msg.sender, perp.vault, params.amtToAdd);
        emit Mgr.MarginAdded(perp.key.toId(), params.posId, pos.margin);
    }

    /// @notice Closes an open maker or taker position
    /// @param perp The perp to close the position in
    /// @param poolManager The pool manager to use for swapping and liquidity modification actions
    /// @param usdc The USDC token address
    /// @param params The parameters for closing the position
    /// @param revertChanges Whether to revert the changes (and thus not change state)
    /// @return posId The ID of the taker position created if this was a maker position or partial close. Otherwise, 0
    function closePosition(
        Mgr.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        Mgr.ClosePositionParams calldata params,
        bool revertChanges
    ) external returns (uint128 posId) {
        PoolId perpId = perp.key.toId();
        Mgr.Position memory pos = perp.positions[params.posId];

        // revert closing a non-existent (or already closed) position
        if (pos.holder == address(0)) revert Mgr.InvalidClose(msg.sender, address(0), false);

        (uint160 sqrtPriceX96, int24 startTick,,) = poolManager.getSlot0(perpId);

        // update cumulative funding trackers based on funding per second at last update and seconds passed since then
        perp.fundingState.updateCumlFunding(sqrtPriceX96);

        bytes memory encodedDeltas; // this will be filled in with either a modify liquidity action or swap action
        bool isMaker = pos.makerDetails.liquidity > 0; // takers don't use Position.MakerDetails, so == 0 if taker

        if (isMaker) {
            Mgr.MakerDetails memory makerPos = pos.makerDetails;
            // if reverting changes for a quote, we ignore the lock up period check
            if (!revertChanges && block.timestamp < makerPos.unlockTimestamp) revert Mgr.PositionLocked();

            // prepare config for removing exact amount of liquidity provided at entry with same position specifics
            Router.LiquidityConfig memory config = Router.LiquidityConfig({
                poolKey: perp.key,
                positionId: params.posId, // salt is same posId used on entry
                isAdd: false,
                tickLower: makerPos.tickLower,
                tickUpper: makerPos.tickUpper,
                liquidityToMove: makerPos.liquidity,
                amount0Limit: params.minAmt0Out,
                amount1Limit: params.minAmt1Out
            });

            // execute using encoded config & fill in encodedDeltas with token movements
            encodedDeltas = poolManager.executeAction(Router.MODIFY_LIQUIDITY, abi.encode(config));

            // clear ticks that were also cleared in corresponding Uniswap pool (they would no longer be initialized)
            if (!poolManager.isTickInitialized(perpId, makerPos.tickLower)) perp.fundingState.clear(makerPos.tickLower);
            if (!poolManager.isTickInitialized(perpId, makerPos.tickUpper)) perp.fundingState.clear(makerPos.tickUpper);
        } else {
            // if entryPerpDelta > 0, perps were taken from the pool on entry & held on (long)
            // if entryPerpDelta < 0, perps were borrowed and sent into the pool on entry & a debt was held (short)
            bool isLong = pos.entryPerpDelta > 0;

            // prepare config for swapping the exact amount of perps held into the pool for usd out (longs) or for
            // swapping in however much usd is needed to get out the amount of perps making up debt owed (shorts)
            Router.SwapConfig memory config = Router.SwapConfig({
                poolKey: perp.key,
                isExactIn: isLong, // currency0 (perps) is always the specified one here
                zeroForOne: isLong, // 0 (perps) in for 1 (usd) out (longs) / 1 (perps) in for 0 (usd) out (shorts)
                amountSpecified: pos.entryPerpDelta.abs(),
                // TODO: test for the risk where price limit stops liquidations from fully going through
                // position will be partially closed if sqrtPriceLimit is hit during the swap
                sqrtPriceLimitX96: sqrtPriceLimitX96(perp, sqrtPriceX96, isLong, true),
                unspecifiedAmountLimit: isLong ? params.minAmt1Out : params.maxAmt1In
            });

            // execute using encoded config & fill in encodedDeltas with token movements
            encodedDeltas = poolManager.executeAction(Router.SWAP, abi.encode(config));

            // this position will no absorb future bad debt costs through ADL (even if it creates bad debt in this tx)
            perp.takerOpenInterest -= pos.entryPerpDelta.abs().toUint128();

            // cross the same ticks the corresponding Uniswap pool did during the swap
            int24 endTick;
            (sqrtPriceX96, endTick,,) = poolManager.getSlot0(perpId);
            perp.fundingState.crossTicks(poolManager, perpId, startTick, endTick, perp.key.tickSpacing, isLong);
        }

        // makers: both deltas >= 0 since tokens were taken out. taker longs: perpDelta < 0 & usdDelta > 0 since perps
        // sent in & usd received out. taker shorts: perpDelta > 0 & usdDelta < 0 since perps taken out & usd sent in
        (int256 exitPerpDelta, int256 exitUsdDelta) = abi.decode(encodedDeltas, (int256, int256));

        // for takers, notional = value of perps sent in / out (equivalent to value of usd exchanged)
        uint256 notional = exitUsdDelta.abs();
        // makers don't exchange one token for another, so exitUsdDelta just represents the value of usd received. The
        // value of perps received needs to be seperately accounted for (perp amount * price)
        uint256 priceX96 = sqrtPriceX96.fullMulDiv(sqrtPriceX96, UINT_Q96);
        if (isMaker) notional += exitPerpDelta.abs().fullMulDiv(priceX96, UINT_Q96);

        // netDelta = amount left over after liquidity modifications / swaps for user (if < 0, this amount is owed)
        int256 netUsdDelta = pos.entryUsdDelta + exitUsdDelta;
        int256 netPerpDelta = pos.entryPerpDelta + exitPerpDelta;

        // the amount paid due to funding accrued since entry; if > 0, holder pays amt; if < 0, amt paid to holder
        int256 funding = perp.fundingState.funding(pos, startTick);

        // (perp.badDebtGrowth - pos.entryBadDebtGrowth) = amount of bad debt per position size created since entry
        // adl payment = (bad debt per position size * position size); lowest possible payment is 0
        uint256 adlFee = (perp.badDebtGrowth - pos.entryBadDebtGrowth).mulDiv(pos.entryPerpDelta.abs(), SCALE_1E6);

        // settle outstanding usd balance from pool actions, funding accrued since entry and adl payment for bad debt
        int256 netMargin = int256(pos.margin) + netUsdDelta - funding - int256(adlFee);

        // we calculate what the liquidation fee would be if this position were to be liquidated since it contributes to
        // the margin ratio calculation (liquidation fee amt = notional * liquidation fee percentage)
        uint256 liquidationFeeAmt = notional.mulDiv(perp.liquidationFee, SCALE_1E6);

        bool isLiquidation;
        if (netMargin <= 0) {
            // if position didn't have enough margin to cover all costs this is an insolvent liquidation, and bad debt
            // is created. someone else is expecting to be paid what this position owes, but this pos can't pay for it
            uint256 badDebt = netMargin.abs();

            if (perp.insurance >= badDebt) {
                // if there is enough insurance to cover the bad debt, use it and decrement available insurance
                perp.insurance -= badDebt.toUint128();
            } else {
                // otherwise, use as much insurance as available
                badDebt -= perp.insurance;
                perp.insurance = 0;

                // TODO: risk that total taker margin < bad debt, then use makers
                // remaining bad debt is paid for by all other open taker positions. this is represented by incrementing
                // badDebtGrowth by the bad debt created per open position size. When takers close, they have to pay the
                // amount this tracker grew since entry per position size owned
                perp.badDebtGrowth += badDebt / perp.takerOpenInterest;
            }

            // TODO: incentivize ADL liquidations
            // this was a liquidation; there is nothing left to provide liquidator as reward; holder gets nothing back
            (isLiquidation, liquidationFeeAmt, netMargin) = (true, 0, 0);
        } else if (uint256(netMargin) <= liquidationFeeAmt) {
            // if the position has enough margin to cover all costs but the liquidation fee, it is a solvent liquidation
            // the liquidator gets whatever margin is left as reward; the holder gets nothing back
            (isLiquidation, liquidationFeeAmt, netMargin) = (true, uint256(netMargin), 0);
        } else {
            // if the position has enough margin to cover all costs and the liquidation fee, we check if the margin
            // ratio of the position (including the liquidation fee) is below the liquidation margin ratio
            uint256 marginRatioAfterLiqFee = (uint256(netMargin) - liquidationFeeAmt).mulDiv(SCALE_1E6, notional);
            uint256 liqMarginRatio = isMaker ? perp.makerLiquidationMarginRatio : perp.takerLiquidationMarginRatio;

            // if it is, it's a solvent liquidation; liquidator gets full fee as reward; holder gets the remainder back
            // otherwise, this isn't a liquidation, just a normal close - there is no liquidation fee
            isLiquidation = marginRatioAfterLiqFee <= liqMarginRatio;
            if (!isLiquidation) liquidationFeeAmt = 0;
            else netMargin -= int256(liquidationFeeAmt);
        }

        if (!revertChanges) {
            // don't allow an closing someone else's position if this isn't a liquidation
            if (!isLiquidation && msg.sender != pos.holder) revert Mgr.InvalidClose(msg.sender, pos.holder, false);
            // if this was a liquidation, transfer the liquidation fee to the liquidator
            if (isLiquidation) usdc.safeTransferFrom(perp.vault, msg.sender, liquidationFeeAmt);
        }

        // time passed and mark may have changed, so write a twAvg observation and update funding rate
        perp.twAvgState.write(uint32(block.timestamp), sqrtPriceX96);
        int256 fundingPerSecX96 = perp.updateFundingPerSecond(uint32(block.timestamp), sqrtPriceX96);

        // TODO: test cases where there is a liquidation (insolvent & solvent) and a partial close such that there's no
        // margin left to open this new position with
        // if there is left over perp directional exposure (a maker closed at a different price than they opened at or a
        // partial close occured due to sqrtPriceLimit being hit), we create a new taker position to cover it
        if (netPerpDelta != 0) {
            posId = perp.nextPosId;
            perp.nextPosId++;

            Mgr.Position memory newPos;

            newPos.holder = pos.holder;
            // new taker position uses leftover margin from closed position
            newPos.margin = uint256(netMargin);
            // netPerpDelta is the remaining perp exposure:
            // if > 0, this is long exposure and they hold perps to swap into the pool for usd out
            // if < 0, this is short exposure and a perp debt; holder must swap in usd to get out perps to repay it
            newPos.entryPerpDelta = netPerpDelta;
            // netPerpDelta was accounted into netMargin, so there is no left over usd balance to settle
            newPos.entryUsdDelta = 0;
            // this taker position is subject to funding and ADL (accounted through badDebtGrowth) like any other
            newPos.entryCumlFundingX96 = perp.fundingState.cumlFundingX96;
            newPos.entryBadDebtGrowth = perp.badDebtGrowth;

            perp.positions[posId] = newPos;
            perp.takerOpenInterest += netPerpDelta.abs().toUint128();

            emit Mgr.PositionOpened(perpId, posId, newPos, sqrtPriceX96, fundingPerSecX96);
        } else {
            // if no left over perp exposure, holder gets the remaining margin back (no new position needed)
            if (!revertChanges) usdc.safeTransferFrom(perp.vault, pos.holder, uint256(netMargin));
        }

        // TODO: if maker, also quote resulting taker close
        // if quote, revert with closed pos details
        if (revertChanges) revert Quoter.CloseQuote(netUsdDelta, funding, uint256(netMargin), isLiquidation);

        emit Mgr.PositionClosed(perpId, params.posId, pos, netUsdDelta, isLiquidation, sqrtPriceX96, fundingPerSecX96);
        delete perp.positions[params.posId];
    }

    /// @notice Validates a margin ratio is within a perp's allowed range
    /// @dev Used in openPosition and addMargin
    /// @param perp The perp to validate the margin ratio for
    /// @param margin The margin used to calculate the margin ratio to check
    /// @param notional The notional value used to calculate the margin ratio to check
    /// @param isMaker Whether the position is a maker. If false, it's a taker
    function validateMarginRatio(Mgr.Perp storage perp, uint256 margin, uint256 notional, bool isMaker) internal view {
        // margin ratio = margin / notional
        uint256 marginRatio = margin.fullMulDiv(SCALE_1E6, notional);

        // TODO: query a module to get min and max
        uint256 min = isMaker ? perp.minMakerOpeningMarginRatio : perp.minTakerOpeningMarginRatio;
        uint256 max = isMaker ? perp.maxMakerOpeningMarginRatio : perp.maxTakerOpeningMarginRatio;

        if (marginRatio < min || marginRatio > max) revert Mgr.InvalidMarginRatio(marginRatio, min, max);
    }

    /// @notice Calculates the sqrt price limit for a swap using maximum allowed deviation from mark twap
    /// @dev Used in openPosition and closePosition swaps
    /// @param perp The perp to calculate the sqrt price limit for
    /// @param sqrtPriceX96 The current sqrt price of the perp
    /// @param zeroForOne Whether currency0 is being swapped in for currency1 (if false, currency1 in for currency0 out)
    /// @param isQuoting Whether this is a quote (and thus we should use the max price limit)
    /// @return limit The sqrt price limit for the swap
    function sqrtPriceLimitX96(Mgr.Perp storage perp, uint160 sqrtPriceX96, bool zeroForOne, bool isQuoting)
        internal
        view
        returns (uint160 limit)
    {
        // get the time-weighted average sqrt price of the perp
        uint256 twAvgSqrtPX96 = perp.twAvgState.timeWeightedAvg(TW_AVG_WINDOW, uint32(block.timestamp), sqrtPriceX96);
        // TODO: replace with module call to get multipliers
        // the sqrt factor used on twAvgSqrtPX96 to get a sqrt price limit is based on swap direction
        // e.g. on a long, 10% higher than current twAvgPrice would have a multiplier of sqrt(1.1) * 2^96
        uint256 multiplierX96 = zeroForOne ? SQRT_PRICE_LOWER_MULTI_X96 : SQRT_PRICE_UPPER_MULTI_X96;

        // sqrtPriceLimit = twAvgSqrtPrice * multiplier; e.g. when price is 100$ and there is a 10% allowed upward
        // movement, sqrtPriceLimit = sqrt(1.1) * sqrt(100) = sqrt(110)
        limit = twAvgSqrtPX96.fullMulDiv(multiplierX96, UINT_Q96).toUint160();

        // if the computed sqrt price limit lies outside the min or max bounds of a Uniswap pool, restrict it
        // if this is used for a quote, we override the limit to allow a full swap
        if (limit > TickMath.MAX_SQRT_PRICE || (isQuoting && !zeroForOne)) limit = TickMath.MAX_SQRT_PRICE - 1;
        if (limit < TickMath.MIN_SQRT_PRICE || (isQuoting && zeroForOne)) limit = TickMath.MIN_SQRT_PRICE + 1;
    }
}
