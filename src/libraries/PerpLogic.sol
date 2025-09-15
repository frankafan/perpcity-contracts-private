// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpVault} from "../PerpVault.sol";
import {IPerpManager} from "../interfaces/IPerpManager.sol";
import {ITimeWeightedAvg} from "../interfaces/ITimeWeightedAvg.sol";
import "./Constants.sol";
import {Funding} from "./Funding.sol";
import {LivePositionDetailsReverter} from "./LivePositionDetailsReverter.sol";
import {MoreSignedMath} from "./MoreSignedMath.sol";
import {Tick} from "./Tick.sol";
import {TimeWeightedAvg} from "./TimeWeightedAvg.sol";
import {TradingFee} from "./TradingFee.sol";
import {UniV4Router} from "./UniV4Router.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {console2} from "forge-std/console2.sol";

library PerpLogic {
    using UniV4Router for IPoolManager;
    using TimeWeightedAvg for TimeWeightedAvg.State;
    using FixedPointMathLib for *;
    using StateLibrary for IPoolManager;
    using SafeCastLib for *;
    using MoreSignedMath for int256;
    using PerpLogic for *;
    using TradingFee for IPerpManager.Perp;
    using Tick for mapping(int24 => Tick.GrowthInfo);
    using SafeTransferLib for address;

    function createPerp(
        mapping(PoolId => IPerpManager.Perp) storage perps,
        IPoolManager poolManager,
        address usdc,
        IPerpManager.CreatePerpParams calldata params
    )
        external
        returns (PoolId perpId)
    {
        bytes memory encodedConfig = abi.encode(
            UniV4Router.CreatePoolConfig({tickSpacing: TICK_SPACING, startingSqrtPriceX96: params.startingSqrtPriceX96})
        );

        bytes memory encodedPoolKey = poolManager.executeAction(UniV4Router.CREATE_POOL, encodedConfig);
        PoolKey memory key = abi.decode(encodedPoolKey, (PoolKey));
        perpId = key.toId();

        IPerpManager.Perp storage perp = perps[perpId];

        perp.vault = address(new PerpVault(address(this), usdc));
        perp.creationTimestamp = uint32(block.timestamp);
        perp.makerLockupPeriod = MAKER_LOCKUP_PERIOD;
        perp.beacon = params.beacon;
        perp.twapWindow = TWAP_WINDOW;
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
        perp.tradingFeeConfig = TradingFee.Config({
            baseFeeX96: 1,
            startFeeX96: START_FEE,
            targetFeeX96: TARGET_FEE,
            decay: DECAY,
            volatilityScalerX96: VOLATILITY_SCALER,
            maxFeeMultiplierX96: MAX_FEE_MULTIPLIER
        });
        perp.key = key;

        perp.twapState.initialize(uint32(block.timestamp));
        perp.twapState.grow(INITIAL_CARDINALITY_NEXT);

        emit IPerpManager.PerpCreated(perpId, params.beacon, params.startingSqrtPriceX96);
    }

    function openPosition(
        IPerpManager.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        bytes memory encodedParams,
        bool isMaker
    )
        external
        returns (uint128 posId)
    {
        PoolId perpId = perp.key.toId();
        (uint160 sqrtPriceX96, int24 startingTick,,) = poolManager.getSlot0(perpId);

        updateTwPremiums(perp, sqrtPriceX96);

        posId = perp.nextPosId;
        perp.nextPosId++;

        IPerpManager.Position memory pos;

        uint256 specifiedMargin;

        if (isMaker) {
            IPerpManager.OpenMakerPositionParams memory params =
                abi.decode(encodedParams, (IPerpManager.OpenMakerPositionParams));

            if (params.liquidity == 0) revert IPerpManager.InvalidLiquidity(params.liquidity);

            specifiedMargin = params.margin;
            pos.margin = specifiedMargin;

            Tick.FundingGrowthRangeInfo memory fundingGrowthRangeInfo = perp.tickGrowthInfo.getAllFundingGrowth(
                params.tickLower, params.tickUpper, startingTick, perp.twPremiumX96, perp.twPremiumDivBySqrtPriceX96
            );

            pos.makerDetails = IPerpManager.MakerDetails({
                entryTimestamp: uint32(block.timestamp),
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidity: params.liquidity,
                entryTwPremiumGrowthInsideX96: fundingGrowthRangeInfo.twPremiumGrowthInsideX96,
                entryTwPremiumDivBySqrtPriceGrowthInsideX96: fundingGrowthRangeInfo.twPremiumDivBySqrtPriceGrowthInsideX96,
                entryTwPremiumGrowthBelowX96: fundingGrowthRangeInfo.twPremiumGrowthBelowX96
            });

            if (!poolManager.isTickInitialized(perpId, params.tickLower)) {
                perp.tickGrowthInfo.initialize(
                    params.tickLower, startingTick, perp.twPremiumX96, perp.twPremiumDivBySqrtPriceX96
                );
            }
            if (!poolManager.isTickInitialized(perpId, params.tickUpper)) {
                perp.tickGrowthInfo.initialize(
                    params.tickUpper, startingTick, perp.twPremiumX96, perp.twPremiumDivBySqrtPriceX96
                );
            }

            bytes memory encodedConfig = abi.encode(
                UniV4Router.LiquidityConfig({
                    poolKey: perp.key,
                    positionId: posId,
                    isAdd: true,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidityToMove: params.liquidity,
                    amount0Limit: params.maxAmt0In,
                    amount1Limit: params.maxAmt1In
                })
            );

            bytes memory encodedDeltas = poolManager.executeAction(UniV4Router.MODIFY_LIQUIDITY, encodedConfig);

            (pos.perpDelta, pos.usdDelta) = abi.decode(encodedDeltas, (int256, int256));

            console2.log("pos.perpDelta", pos.perpDelta);
            console2.log("pos.usdDelta", pos.usdDelta);

            uint256 notionalValue = liquidityNotional(pos.perpDelta, pos.usdDelta, sqrtPriceX96);

            console2.log("notionalValue", notionalValue);
            console2.log("pos.margin", pos.margin);

            uint256 marginRatio = pos.margin.fullMulDiv(SCALE_1E6, notionalValue);

            console2.log("marginRatio 3", marginRatio);

            if (marginRatio < perp.minMakerOpeningMarginRatio) revert("margin ratio is too low");
            if (marginRatio > perp.maxMakerOpeningMarginRatio) revert("margin ratio is too high");
        } else {
            IPerpManager.OpenTakerPositionParams memory params =
                abi.decode(encodedParams, (IPerpManager.OpenTakerPositionParams));

            specifiedMargin = params.margin;

            // clean up and maybe combine into one muldiv
            uint256 notionalValue = specifiedMargin.mulDiv(params.levX96, UINT_Q96);

            uint256 creatorFeeAmount = notionalValue.mulDiv(perp.creatorFee, SCALE_1E6);
            usdc.safeTransferFrom(perp.vault, perp.creator, creatorFeeAmount);

            uint256 insuranceFeeAmount = notionalValue.mulDiv(perp.insuranceFee, SCALE_1E6);

            pos.margin = specifiedMargin - creatorFeeAmount - insuranceFeeAmount;
            notionalValue = pos.margin.mulDiv(params.levX96, UINT_Q96);

            uint256 marginRatio = pos.margin.fullMulDiv(SCALE_1E6, notionalValue);

            if (marginRatio < perp.minTakerOpeningMarginRatio) revert("margin ratio is too low");
            if (marginRatio > perp.maxTakerOpeningMarginRatio) revert("margin ratio is too high");

            // determine whether or not to charge fee based on hookData passed in
            uint24 fee = perp.calculateTradingFee(poolManager);

            bytes memory encodedConfig = abi.encode(
                UniV4Router.SwapConfig({
                    poolKey: perp.key,
                    isExactIn: params.isLong,
                    zeroForOne: !params.isLong,
                    amountSpecified: notionalValue,
                    sqrtPriceLimitX96: getSqrtPriceLimitX96(perp, sqrtPriceX96, params.isLong),
                    unspecifiedAmountLimit: params.unspecifiedAmountLimit,
                    fee: fee
                })
            );

            bytes memory encodedDeltas = poolManager.executeAction(UniV4Router.SWAP, encodedConfig);

            (pos.perpDelta, pos.usdDelta) = abi.decode(encodedDeltas, (int256, int256));

            int24 endingTick;
            (sqrtPriceX96, endingTick,,) = poolManager.getSlot0(perpId);

            perp.tickGrowthInfo.crossTicks(
                poolManager,
                perpId,
                startingTick,
                perp.key.tickSpacing,
                !params.isLong,
                endingTick,
                perp.twPremiumX96,
                perp.twPremiumDivBySqrtPriceX96
            );
        }

        pos.holder = msg.sender;
        pos.entryTwPremiumX96 = perp.twPremiumX96;

        if (pos.margin < perp.minOpeningMargin) revert IPerpManager.InvalidMargin(pos.margin);

        updatePremiumPerSecond(perp, sqrtPriceX96);

        perp.twapState.write(block.timestamp.toUint32(), sqrtPriceX96);

        perp.positions[posId] = pos;

        usdc.safeTransferFrom(msg.sender, perp.vault, specifiedMargin);

        emit IPerpManager.PositionOpened(perpId, posId, isMaker, pos.margin, sqrtPriceX96);
    }

    function addMargin(
        IPerpManager.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        IPerpManager.AddMarginParams calldata params
    )
        external
    {
        address holder = perp.positions[params.posId].holder;
        uint256 margin = params.margin;

        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(perp.key.toId());

        // update funding accounting
        updateTwPremiums(perp, sqrtPriceX96);
        updatePremiumPerSecond(perp, sqrtPriceX96);

        // update mark twap
        perp.twapState.write(block.timestamp.toUint32(), sqrtPriceX96);

        // validate caller is holder and that margin is nonzero
        if (msg.sender != holder) revert IPerpManager.InvalidCaller(msg.sender, holder);
        if (margin == 0) revert IPerpManager.InvalidMargin(margin);

        // TODO: add margin ratio check

        // transfer margin from sender to vault
        usdc.safeTransferFrom(msg.sender, perp.vault, margin);

        // update maker position state
        perp.positions[params.posId].margin += margin;

        emit IPerpManager.MarginAdded(perp.key.toId(), params.posId, perp.positions[params.posId].margin);
    }

    function closePosition(
        IPerpManager.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        IPerpManager.ClosePositionParams calldata params,
        bool revertChanges
    )
        external
        returns (uint128 posId)
    {
        PoolId perpId = perp.key.toId();
        IPerpManager.Position memory pos = perp.positions[params.posId];

        if (pos.holder == address(0)) revert IPerpManager.InvalidClose(msg.sender, address(0), false);

        (uint160 sqrtPriceX96, int24 startingTick,,) = poolManager.getSlot0(perpId);
        updateTwPremiums(perp, sqrtPriceX96);


        bool isLiquidation;
        if (pos.makerDetails.liquidity > 0) {
            IPerpManager.MakerDetails memory makerDetails = pos.makerDetails;

            bytes memory encodedConfig = abi.encode(
                UniV4Router.LiquidityConfig({
                    poolKey: perp.key,
                    positionId: params.posId,
                    isAdd: false,
                    tickLower: makerDetails.tickLower,
                    tickUpper: makerDetails.tickUpper,
                    liquidityToMove: makerDetails.liquidity,
                    amount0Limit: params.minAmt0Out,
                    amount1Limit: params.minAmt1Out
                })
            );

            bytes memory encodedDeltas = poolManager.executeAction(UniV4Router.MODIFY_LIQUIDITY, encodedConfig);

            (int256 perpDelta, int256 usdDelta) = abi.decode(encodedDeltas, (int256, int256));

            int256 pnl = usdDelta + pos.usdDelta;

            int256 takerPerpDelta = perpDelta + pos.perpDelta;

            int256 funding = makerFunding(perp, pos, startingTick);

            uint256 notional = liquidityNotional(takerPerpDelta, usdDelta, sqrtPriceX96);

            (uint256 effectiveMargin, bool isLiquidation) =
                calcEffectiveMargin(perp, usdc, pos.margin, pnl, funding, notional, true, pos.holder);

            if (revertChanges) LivePositionDetailsReverter.revertLivePositionDetails(pnl, funding, effectiveMargin, isLiquidation, sqrtPriceX96);

            if (
                !revertChanges && !isLiquidation
                    && block.timestamp <= makerDetails.entryTimestamp + perp.makerLockupPeriod
            ) {
                revert IPerpManager.MakerPositionLocked(
                    block.timestamp, makerDetails.entryTimestamp + perp.makerLockupPeriod
                );
            }

            // clear tick mapping to mimick uniswap pool ticks cleared
            if (!poolManager.isTickInitialized(perpId, makerDetails.tickLower)) {
                perp.tickGrowthInfo.clear(makerDetails.tickLower);
            }
            if (!poolManager.isTickInitialized(perpId, makerDetails.tickUpper)) {
                perp.tickGrowthInfo.clear(makerDetails.tickUpper);
            }

            if (takerPerpDelta != 0) {
                posId = perp.nextPosId;
                perp.nextPosId++;

                IPerpManager.Position memory newPos;

                newPos.holder = pos.holder;
                newPos.perpDelta = takerPerpDelta;
                newPos.usdDelta = 0;
                newPos.margin = effectiveMargin;
                newPos.entryTwPremiumX96 = perp.twPremiumX96;

                perp.positions[posId] = newPos;

                // emit IPerpManager.TakerPositionOpened(perpId, takerPosId, perp.takerPositions[takerPosId], sqrtPriceX96);
            } else {
                usdc.safeTransferFrom(perp.vault, pos.holder, effectiveMargin);
            }
        } else {
            bool isLong = pos.perpDelta > 0;

            bytes memory encodedConfig = abi.encode(
                UniV4Router.SwapConfig({
                    poolKey: perp.key,
                    isExactIn: isLong,
                    zeroForOne: isLong,
                    amountSpecified: isLong ? uint256(pos.perpDelta) : uint256(-pos.perpDelta),
                    sqrtPriceLimitX96: getSqrtPriceLimitX96(perp, sqrtPriceX96, !isLong),
                    unspecifiedAmountLimit: isLong ? params.minAmt1Out : params.maxAmt1In,
                    fee: 0
                })
            );

            bytes memory encodedDeltas = poolManager.executeAction(UniV4Router.SWAP, encodedConfig);

            (int256 perpDelta, int256 usdDelta) = abi.decode(encodedDeltas, (int256, int256));

            int256 pnl = usdDelta + pos.usdDelta;

            int24 endingTick;
            (sqrtPriceX96, endingTick,,) = poolManager.getSlot0(perpId);

            perp.tickGrowthInfo.crossTicks(
                poolManager,
                perpId,
                startingTick,
                perp.key.tickSpacing,
                isLong,
                endingTick,
                perp.twPremiumX96,
                perp.twPremiumDivBySqrtPriceX96
            );

            // update mark twap
            perp.twapState.write(block.timestamp.toUint32(), sqrtPriceX96);

            int256 twPremiumGrowthX96 = perp.twPremiumX96 - pos.entryTwPremiumX96;
            int256 funding = twPremiumGrowthX96.mulDivSigned(pos.perpDelta, UINT_Q96);

            uint256 notional = usdDelta < 0 ? uint256(-usdDelta) : uint256(usdDelta);

            (uint256 effectiveMargin, bool isLiquidation) =
                calcEffectiveMargin(perp, usdc, pos.margin, pnl, funding, notional, true, pos.holder);

            if (revertChanges) LivePositionDetailsReverter.revertLivePositionDetails(pnl, funding, effectiveMargin, isLiquidation, sqrtPriceX96);

            usdc.safeTransferFrom(perp.vault, pos.holder, effectiveMargin);
        }

        updatePremiumPerSecond(perp, sqrtPriceX96);

        // update mark twap
        perp.twapState.write(block.timestamp.toUint32(), sqrtPriceX96);

        emit IPerpManager.PositionClosed(perpId, params.posId, isLiquidation, sqrtPriceX96);
        delete perp.positions[params.posId];
    }

    function makerFunding(
        IPerpManager.Perp storage perp,
        IPerpManager.Position memory pos,
        int24 currentTick
    )
        internal
        view
        returns (int256)
    {
        return Funding.calcPendingFundingPaymentWithLiquidityCoefficient(
            pos.perpDelta,
            pos.entryTwPremiumX96,
            Funding.Growth({
                twPremiumX96: perp.twPremiumX96,
                twPremiumDivBySqrtPriceX96: perp.twPremiumDivBySqrtPriceX96
            }),
            Funding.calcLiquidityCoefficientInFundingPaymentByOrder(
                pos.makerDetails.liquidity,
                pos.makerDetails.tickLower,
                pos.makerDetails.tickUpper,
                perp.tickGrowthInfo.getAllFundingGrowth(
                    pos.makerDetails.tickLower,
                    pos.makerDetails.tickUpper,
                    currentTick,
                    perp.twPremiumX96,
                    perp.twPremiumDivBySqrtPriceX96
                ),
                pos.makerDetails.entryTwPremiumGrowthInsideX96,
                pos.makerDetails.entryTwPremiumDivBySqrtPriceGrowthInsideX96,
                pos.makerDetails.entryTwPremiumGrowthBelowX96
            )
        );
    }

    function calcEffectiveMargin(
        IPerpManager.Perp storage perp,
        address usdc,
        uint256 margin,
        int256 pnl,
        int256 funding,
        uint256 notional,
        bool isMaker,
        address holder
    )
        internal
        returns (uint256 effectiveMargin, bool isLiquidation)
    {
        int256 netMargin = int256(margin) + pnl - funding;

        uint256 liquidationFeeAmt = notional.mulDiv(perp.liquidationFee, SCALE_1E6);

        if (netMargin <= 0) {
            return (0, true);
        } else if (uint256(netMargin) <= liquidationFeeAmt) {
            effectiveMargin = 0;
            liquidationFeeAmt = uint256(netMargin);
        } else {
            uint256 marginRatioWithFee = (uint256(netMargin) - liquidationFeeAmt).mulDiv(SCALE_1E6, notional);
            uint256 liquidationMarginRatio =
                isMaker ? perp.makerLiquidationMarginRatio : perp.takerLiquidationMarginRatio;
            if (marginRatioWithFee <= liquidationMarginRatio) {
                effectiveMargin = uint256(netMargin) - liquidationFeeAmt;
                liquidationFeeAmt = liquidationFeeAmt;
            } else {
                effectiveMargin = uint256(netMargin);
                liquidationFeeAmt = 0;
            }
        }

        isLiquidation = effectiveMargin == 0;
        if (!isLiquidation && msg.sender != holder) revert IPerpManager.InvalidClose(msg.sender, holder, false);
        if (isLiquidation) usdc.safeTransferFrom(perp.vault, msg.sender, liquidationFeeAmt);
    }

    function liquidityNotional(
        int256 perpDelta,
        int256 usdDelta,
        uint160 sqrtPriceX96
    )
        internal
        pure
        returns (uint256 notional)
    {
        uint256 perps = perpDelta.abs();
        uint256 usd = usdDelta.abs();

        console2.log("perps", perps);
        console2.log("usd", usd);
        console2.log("sqrtPriceX96", sqrtPriceX96);

        // convert currency0Amount (perp contracts) to its value in currency1 (usd)
        uint256 perpsNotional = sqrtPriceX96.fullMulDiv(perps * sqrtPriceX96, UINT_Q192);

        // currency1Amount is already in USD, so its notional value is its amount
        notional = perpsNotional + usd;
    }

    function updateTwPremiums(IPerpManager.Perp storage perp, uint160 sqrtPriceX96) internal {
        int256 timeSinceLastUpdate = int256(block.timestamp - perp.lastTwPremiumsUpdate);

        perp.twPremiumX96 += perp.premiumPerSecondX96 * timeSinceLastUpdate;

        perp.twPremiumDivBySqrtPriceX96 +=
            perp.premiumPerSecondX96.fullMulDivSigned(timeSinceLastUpdate * INT_Q96, sqrtPriceX96);

        perp.lastTwPremiumsUpdate = uint32(block.timestamp);
    }

    // expects updateTwPremiums() to have been called before to account for time during old premiumPerSecondX96
    function updatePremiumPerSecond(IPerpManager.Perp storage perp, uint160 sqrtPriceX96) internal {
        uint256 twaSqrtMarkX96 = getTimeWeightedAvg(perp, perp.twapWindow, sqrtPriceX96);
        uint256 twaIndexX96 = ITimeWeightedAvg(perp.beacon).getTimeWeightedAvg(perp.twapWindow);

        uint256 twaMarkX192 = twaSqrtMarkX96 * twaSqrtMarkX96;
        uint256 twaIndexX192 = twaIndexX96 * UINT_Q96;

        perp.premiumPerSecondX96 = ((int256(twaMarkX192) - int256(twaIndexX192)) / INT_Q96 / int256(uint256(FUNDING_INTERVAL)));
    }

    // time weight avg sqrt price x96
    function getTimeWeightedAvg(
        IPerpManager.Perp storage perp,
        uint32 twapSecondsAgo,
        uint160 sqrtPriceX96
    )
        internal
        view
        returns (uint256 twapPrice)
    {
        uint32 oldestObservationTimestamp = perp.twapState.getOldestObservationTimestamp();
        uint32 timeSinceLastObservation = (block.timestamp - oldestObservationTimestamp).toUint32();
        if (twapSecondsAgo > timeSinceLastObservation) twapSecondsAgo = timeSinceLastObservation;

        if (twapSecondsAgo == 0) return sqrtPriceX96;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSecondsAgo;
        secondsAgos[1] = 0;
        uint216[] memory sqrtPriceX96Cumulatives =
            perp.twapState.observe(block.timestamp.toUint32(), secondsAgos, sqrtPriceX96);
        uint216 sqrtPriceX96CumulativesDelta = sqrtPriceX96Cumulatives[1] - sqrtPriceX96Cumulatives[0];
        return (sqrtPriceX96CumulativesDelta / uint216(twapSecondsAgo));
    }

    function getSqrtPriceLimitX96(
        IPerpManager.Perp storage perp,
        uint160 sqrtPriceX96,
        bool isBuy
    )
        internal
        view
        returns (uint160 sqrtPriceLimitX96)
    {
        uint256 twaSqrtPriceX96 = getTimeWeightedAvg(perp, TWAP_WINDOW, sqrtPriceX96);
        uint256 multiplier = isBuy ? SQRT_PRICE_UPPER_MULTI_X96 : SQRT_PRICE_LOWER_MULTI_X96;

        sqrtPriceLimitX96 = twaSqrtPriceX96.fullMulDiv(multiplier, UINT_Q96).toUint160();

        if (sqrtPriceLimitX96 > TickMath.MAX_SQRT_PRICE) sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE;
        if (sqrtPriceLimitX96 < TickMath.MIN_SQRT_PRICE) sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE;
    }
}
