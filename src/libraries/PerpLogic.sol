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
        perp.nextMakerPosId = 1; // maker IDs start at 1
        perp.nextTakerPosId = 1; // taker IDs start at 1
        perp.priceImpactBand = PRICE_IMPACT_BAND;
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

    function openMakerPosition(
        IPerpManager.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        IPerpManager.OpenMakerPositionParams calldata params
    )
        external
        returns (uint128 makerPosId)
    {
        if (params.liquidity == 0) revert IPerpManager.InvalidLiquidity(params.liquidity);

        PoolId perpId = perp.key.toId();

        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(perpId);

        updateTwPremiums(perp, sqrtPriceX96);

        bool tickLowerInitializedBefore = poolManager.isTickInitialized(perpId, params.tickLower);
        bool tickUpperInitializedBefore = poolManager.isTickInitialized(perpId, params.tickUpper);

        makerPosId = perp.nextMakerPosId;
        perp.nextMakerPosId++;

        bytes memory encodedConfig = abi.encode(
            UniV4Router.LiquidityConfig({
                poolKey: perp.key,
                positionId: makerPosId,
                isAdd: true,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityToMove: params.liquidity,
                amount0Limit: params.maxAmt0In,
                amount1Limit: params.maxAmt1In
            })
        );

        bytes memory encodedDeltas = poolManager.executeAction(UniV4Router.MODIFY_LIQUIDITY, encodedConfig);

        (int256 perpDelta, int256 usdDelta) = abi.decode(encodedDeltas, (int256, int256));

        uint256 notional = liquidityNotional(perpDelta, usdDelta, sqrtPriceX96);
        validateOpeningMarginAndMarginRatio(perp, params.margin, notional, true);

        updatePremiumPerSecond(perp, sqrtPriceX96);

        if (!tickLowerInitializedBefore) {
            perp.tickGrowthInfo.initialize(
                params.tickLower, currentTick, perp.twPremiumX96, perp.twPremiumDivBySqrtPriceX96
            );
        }
        if (!tickUpperInitializedBefore) {
            perp.tickGrowthInfo.initialize(
                params.tickUpper, currentTick, perp.twPremiumX96, perp.twPremiumDivBySqrtPriceX96
            );
        }

        // update mark twap
        perp.twapState.write(block.timestamp.toUint32(), sqrtPriceX96);

        Tick.FundingGrowthRangeInfo memory fundingGrowthRangeInfo = perp.tickGrowthInfo.getAllFundingGrowth(
            params.tickLower, params.tickUpper, currentTick, perp.twPremiumX96, perp.twPremiumDivBySqrtPriceX96
        );

        // update maker position state
        perp.makerPositions[makerPosId] = IPerpManager.MakerPos({
            holder: msg.sender,
            entryTimestamp: block.timestamp.toUint32(),
            margin: params.margin,
            liquidity: params.liquidity,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            perpDelta: perpDelta,
            usdDelta: usdDelta,
            entryTwPremiumX96: perp.twPremiumX96,
            entryTwPremiumGrowthInsideX96: fundingGrowthRangeInfo.twPremiumGrowthInsideX96,
            entryTwPremiumDivBySqrtPriceGrowthInsideX96: fundingGrowthRangeInfo.twPremiumDivBySqrtPriceGrowthInsideX96,
            entryTwPremiumGrowthBelowX96: fundingGrowthRangeInfo.twPremiumGrowthBelowX96
        });

        // transfer margin from sender to vault
        usdc.safeTransferFrom(msg.sender, perp.vault, params.margin);

        emit IPerpManager.MakerPositionOpened(perpId, makerPosId, perp.makerPositions[makerPosId], sqrtPriceX96);
    }

    function validateOpeningMarginAndMarginRatio(
        IPerpManager.Perp storage perp,
        uint128 margin,
        uint256 notional,
        bool isMaker
    )
        internal
        view
    {
        if (margin < perp.minOpeningMargin) revert IPerpManager.InvalidMargin(margin);

        uint256 marginRatio = margin.fullMulDiv(SCALE_1E6, notional);

        if (isMaker) {
            if (marginRatio < perp.minMakerOpeningMarginRatio) revert("margin ratio is too low");
            if (marginRatio > perp.maxMakerOpeningMarginRatio) revert("margin ratio is too high");
        } else {
            if (marginRatio < perp.minTakerOpeningMarginRatio) revert("margin ratio is too low");
            if (marginRatio > perp.maxTakerOpeningMarginRatio) revert("margin ratio is too high");
        }
    }

    function addMakerMargin(
        IPerpManager.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        IPerpManager.AddMarginParams calldata params
    )
        external
    {
        address holder = perp.makerPositions[params.posId].holder;
        uint128 margin = params.margin;

        addMargin(perp, poolManager, usdc, holder, margin);

        // update maker position state
        perp.makerPositions[params.posId].margin += margin;

        emit IPerpManager.MakerMarginAdded(perp.key.toId(), params.posId, margin);
    }

    function closeMakerPosition(
        IPerpManager.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        IPerpManager.ClosePositionParams calldata params,
        bool revertChanges // true if used as a view function, otherwise false
    )
        external
        returns (uint128 takerPosId)
    {
        PoolId perpId = perp.key.toId();
        IPerpManager.MakerPos memory makerPos = perp.makerPositions[params.posId];

        // if (makerPos.holder == address(0)) {
        //     if (revertChanges) {
        //         (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(perpId);
        //         uint256 newPriceX96 = sqrtPriceX96.toPriceX96();
        //         LivePositionDetailsReverter.revertLivePositionDetails(0, 0, 0, false, newPriceX96);
        //     } else {
        //         revert IPerpManager.InvalidClose(msg.sender, address(0), false);
        //     }
        // }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(perpId);
        updateTwPremiums(perp, sqrtPriceX96);

        bytes memory encodedConfig = abi.encode(
            UniV4Router.LiquidityConfig({
                poolKey: perp.key,
                positionId: params.posId,
                isAdd: false,
                tickLower: makerPos.tickLower,
                tickUpper: makerPos.tickUpper,
                liquidityToMove: makerPos.liquidity,
                amount0Limit: params.minAmt0Out,
                amount1Limit: params.minAmt1Out
            })
        );

        bytes memory encodedDeltas = poolManager.executeAction(UniV4Router.MODIFY_LIQUIDITY, encodedConfig);

        (int256 perpDelta, int256 usdDelta) = abi.decode(encodedDeltas, (int256, int256));

        int24 currentTick;
        (sqrtPriceX96, currentTick,,) = poolManager.getSlot0(perpId);

        // update funding accounting
        updatePremiumPerSecond(perp, sqrtPriceX96);

        // update mark twap
        perp.twapState.write(block.timestamp.toUint32(), sqrtPriceX96);

        int256 pnl = usdDelta + makerPos.usdDelta;

        int256 takerPerpDelta = perpDelta + makerPos.perpDelta;

        (sqrtPriceX96, currentTick,,) = poolManager.getSlot0(perpId);

        int256 funding = makerFunding(perp, makerPos, currentTick);

        uint256 notional = liquidityNotional(takerPerpDelta, usdDelta, sqrtPriceX96);

        (uint256 effectiveMargin, bool isLiquidation) =
            calcEffectiveMargin(perp, usdc, makerPos.margin, pnl, funding, notional, true, makerPos.holder);

        if (!revertChanges && !isLiquidation) {
            if (block.timestamp <= makerPos.entryTimestamp + perp.makerLockupPeriod) {
                revert IPerpManager.MakerPositionLocked(
                    block.timestamp, makerPos.entryTimestamp + perp.makerLockupPeriod
                );
            }
        }

        int24 tickLower = makerPos.tickLower;
        int24 tickUpper = makerPos.tickUpper;

        bool isTickLowerInitializedAfter = poolManager.isTickInitialized(perpId, tickLower);
        bool isTickUpperInitializedAfter = poolManager.isTickInitialized(perpId, tickUpper);

        // clear tick mapping to mimick uniswap pool ticks cleared
        if (!isTickLowerInitializedAfter) perp.tickGrowthInfo.clear(tickLower);
        if (!isTickUpperInitializedAfter) perp.tickGrowthInfo.clear(tickUpper);

        // emit IPerpManager.MakerPositionClosed(perpId, params.posId, wasLiquidation, makerPos, sqrtPriceX96);
        delete perp.makerPositions[params.posId];

        if (takerPerpDelta != 0) {
            takerPosId = perp.nextTakerPosId;
            perp.nextTakerPosId++;

            perp.takerPositions[takerPosId] = IPerpManager.TakerPos({
                holder: makerPos.holder,
                isLong: takerPerpDelta > 0,
                perpDelta: takerPerpDelta,
                usdDelta: 0,
                margin: effectiveMargin.toUint128(),
                entryTwPremiumX96: perp.twPremiumX96
            });

            // emit IPerpManager.TakerPositionOpened(perpId, takerPosId, perp.takerPositions[takerPosId], sqrtPriceX96);
        } else {
            usdc.safeTransferFrom(perp.vault, makerPos.holder, effectiveMargin);
        }
    }

    function openTakerPosition(
        IPerpManager.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        IPerpManager.OpenTakerPositionParams calldata params
    )
        external
        returns (uint128 takerPosId)
    {
        // clean up and maybe combine into one muldiv
        uint256 notional = params.margin.mulDiv(params.levX96, UINT_Q96);

        uint256 creatorFeeAmount = notional.mulDiv(perp.creatorFee, SCALE_1E6);
        usdc.safeTransferFrom(perp.vault, perp.creator, creatorFeeAmount);
        uint256 insuranceFeeAmount = notional.mulDiv(perp.insuranceFee, SCALE_1E6);

        uint256 margin = params.margin - creatorFeeAmount - insuranceFeeAmount;
        notional = margin.mulDiv(params.levX96, UINT_Q96);
        validateOpeningMarginAndMarginRatio(perp, params.margin, notional, false);

        PoolId perpId = perp.key.toId();

        (uint160 sqrtPriceX96, int24 startingTick,,) = poolManager.getSlot0(perpId);
        updateTwPremiums(perp, sqrtPriceX96);

        // determine whether or not to charge fee based on hookData passed in
        uint24 fee = perp.calculateTradingFee(poolManager);

        uint160 sqrtPriceLimitX96 = params.isLong ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1; // fix use for band

        bytes memory encodedConfig = abi.encode(
            UniV4Router.SwapConfig({
                poolKey: perp.key,
                isExactIn: params.isLong,
                zeroForOne: !params.isLong,
                amountSpecified: notional,
                sqrtPriceLimitX96: sqrtPriceLimitX96, // fix use for band
                unspecifiedAmountLimit: params.unspecifiedAmountLimit,
                fee: fee
            })
        );

        bytes memory encodedDeltas = poolManager.executeAction(UniV4Router.SWAP, encodedConfig);

        (int256 perpDelta, int256 usdDelta) = abi.decode(encodedDeltas, (int256, int256));

        // revert if price impact was too high
        // perp.checkPriceImpact(c);

        takerPosId = perp.nextTakerPosId;
        perp.nextTakerPosId++;

        (uint160 sqrtPriceX96After, int24 endingTick,,) = poolManager.getSlot0(perpId);
        updatePremiumPerSecond(perp, sqrtPriceX96After);

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

        // update mark twap
        perp.twapState.write(block.timestamp.toUint32(), sqrtPriceX96After);

        perp.takerPositions[takerPosId] = IPerpManager.TakerPos({
            holder: msg.sender,
            isLong: params.isLong,
            perpDelta: perpDelta,
            usdDelta: usdDelta,
            margin: margin.toUint128(),
            entryTwPremiumX96: perp.twPremiumX96
        });

        // Transfer margin from the user to the contract
        usdc.safeTransferFrom(msg.sender, perp.vault, params.margin);

        emit IPerpManager.TakerPositionOpened(perpId, takerPosId, perp.takerPositions[takerPosId], sqrtPriceX96After);
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
        // return Funding.calcPendingFundingPaymentWithLiquidityCoefficient(
        //     makerPos.perpsBorrowed.toInt256(),
        //     makerPos.entryTwPremiumX96,
        //     Funding.Growth({
        //         twPremiumX96: perp.twPremiumX96,
        //         twPremiumDivBySqrtPriceX96: perp.twPremiumDivBySqrtPriceX96
        //     }),
        //     Funding.calcLiquidityCoefficientInFundingPaymentByOrder(
        //         makerPos.liquidity,
        //         makerPos.tickLower,
        //         makerPos.tickUpper,
        //         perp.tickGrowthInfo.getAllFundingGrowth(
        //             makerPos.tickLower,
        //             makerPos.tickUpper,
        //             currentTick,
        //             perp.twPremiumX96,
        //             perp.twPremiumDivBySqrtPriceX96
        //         ),
        //         makerPos.entryTwPremiumGrowthInsideX96,
        //         makerPos.entryTwPremiumDivBySqrtPriceGrowthInsideX96,
        //         makerPos.entryTwPremiumGrowthBelowX96
        //     )
        // );
        return 0;
    }

    function addTakerMargin(
        IPerpManager.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        IPerpManager.AddMarginParams calldata params
    )
        external
    {
        address holder = perp.takerPositions[params.posId].holder;
        uint128 margin = params.margin;

        addMargin(perp, poolManager, usdc, holder, margin);

        // update taker position state
        perp.takerPositions[params.posId].margin += margin;

        emit IPerpManager.TakerMarginAdded(perp.key.toId(), params.posId, margin);
    }

    function closeTakerPosition(
        IPerpManager.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        IPerpManager.ClosePositionParams calldata params,
        bool revertChanges // true if used as a view function, otherwise false
    )
        external
    {
        PoolId perpId = perp.key.toId();
        IPerpManager.TakerPos memory takerPos = perp.takerPositions[params.posId];

        // if (takerPos.holder == address(0)) {
        //     if (revertChanges) {
        //         (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(perpId);
        //         uint256 newPriceX96 = sqrtPriceX96.toPriceX96();
        //         LivePositionDetailsReverter.revertLivePositionDetails(0, 0, 0, false, newPriceX96);
        //     } else {
        //         revert IPerpManager.InvalidClose(msg.sender, address(0), false);
        //     }
        // }

        (uint160 sqrtPriceX96, int24 startingTick,,) = poolManager.getSlot0(perpId);
        updateTwPremiums(perp, sqrtPriceX96);

        uint160 sqrtPriceLimitX96 = takerPos.isLong ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1; // fix use for band

        bytes memory encodedConfig = abi.encode(
            UniV4Router.SwapConfig({
                poolKey: perp.key,
                isExactIn: takerPos.isLong,
                zeroForOne: takerPos.isLong,
                amountSpecified: takerPos.isLong ? uint256(takerPos.perpDelta) : uint256(-takerPos.perpDelta),
                sqrtPriceLimitX96: sqrtPriceLimitX96,
                unspecifiedAmountLimit: takerPos.isLong ? params.minAmt1Out : params.maxAmt1In,
                fee: 0
            })
        );

        bytes memory encodedDeltas = poolManager.executeAction(UniV4Router.SWAP, encodedConfig);

        (int256 perpDelta, int256 usdDelta) = abi.decode(encodedDeltas, (int256, int256));

        int256 pnl = usdDelta + takerPos.usdDelta;

        (uint160 sqrtPriceX96After, int24 endingTick,,) = poolManager.getSlot0(perpId);
        updatePremiumPerSecond(perp, sqrtPriceX96After);

        perp.tickGrowthInfo.crossTicks(
            poolManager,
            perpId,
            startingTick,
            perp.key.tickSpacing,
            takerPos.isLong,
            endingTick,
            perp.twPremiumX96,
            perp.twPremiumDivBySqrtPriceX96
        );

        // update mark twap
        perp.twapState.write(block.timestamp.toUint32(), sqrtPriceX96After);

        int256 twPremiumGrowthX96 = perp.twPremiumX96 - takerPos.entryTwPremiumX96;
        int256 size = takerPos.perpDelta >= 0 ? takerPos.perpDelta : -takerPos.perpDelta;
        int256 funding = twPremiumGrowthX96.mulDivSigned(size, UINT_Q96);
        if (!takerPos.isLong) funding = -funding;

        uint256 notional = usdDelta < 0 ? uint256(-usdDelta) : uint256(usdDelta);

        (uint256 effectiveMargin, bool isLiquidation) =
            calcEffectiveMargin(perp, usdc, takerPos.margin, pnl, funding, notional, true, takerPos.holder);

        usdc.safeTransferFrom(perp.vault, takerPos.holder, effectiveMargin);

        (sqrtPriceX96,,,) = poolManager.getSlot0(perpId);
        emit IPerpManager.TakerPositionClosed(perpId, params.posId, isLiquidation, takerPos, sqrtPriceX96);
        delete perp.takerPositions[params.posId];
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
        uint256 perpsBorrowed = (perpDelta < 0) ? uint256(-perpDelta) : uint256(perpDelta);
        uint256 usdBorrowed = (usdDelta < 0) ? uint256(-usdDelta) : uint256(usdDelta);

        // convert currency0Amount (perp contracts) to its value in currency1 (usd)
        uint256 perpsNotional = perpsBorrowed.mulDiv(sqrtPriceX96.toPriceX96(), UINT_Q96);

        // currency1Amount is already in USD, so its notional value is its amount
        notional = perpsNotional + usdBorrowed;
    }

    function addMargin(
        IPerpManager.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        address holder,
        uint128 margin
    )
        internal
    {
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(perp.key.toId());

        // update funding accounting
        updateTwPremiums(perp, sqrtPriceX96);
        updatePremiumPerSecond(perp, sqrtPriceX96);

        // update mark twap
        perp.twapState.write(block.timestamp.toUint32(), sqrtPriceX96);

        // validate caller is holder and that margin is nonzero
        if (msg.sender != holder) revert IPerpManager.InvalidCaller(msg.sender, holder);
        if (margin == 0) revert IPerpManager.InvalidMargin(margin);

        // transfer margin from sender to vault
        usdc.safeTransferFrom(msg.sender, perp.vault, margin);
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
        uint256 markTwapX96 = getTimeWeightedAvg(perp, perp.twapWindow, sqrtPriceX96);
        uint256 indexTwapX96 = ITimeWeightedAvg(perp.beacon).getTimeWeightedAvg(perp.twapWindow);

        perp.premiumPerSecondX96 = ((int256(markTwapX96) - int256(indexTwapX96)) / int256(uint256(FUNDING_INTERVAL)));
    }

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

        if (twapSecondsAgo == 0) return sqrtPriceX96.toPriceX96();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSecondsAgo;
        secondsAgos[1] = 0;
        uint216[] memory tickCumulatives = perp.twapState.observe(block.timestamp.toUint32(), secondsAgos, sqrtPriceX96);
        uint216 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        return (tickCumulativesDelta / uint216(twapSecondsAgo)).toPriceX96();
    }

    function increaseCardinalityNext(IPerpManager.Perp storage perp, uint32 cardinalityNext) internal {
        perp.twapState.grow(cardinalityNext);
    }

    function toPriceX96(uint256 sqrtPriceX96) internal pure returns (uint256) {
        return sqrtPriceX96.fullMulDiv(sqrtPriceX96, UINT_Q96);
    }
}
