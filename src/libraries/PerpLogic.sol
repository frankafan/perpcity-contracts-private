// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpVault} from "../PerpVault.sol";

import {IPerpManager as Mgr} from "../interfaces/IPerpManager.sol";
import {ITimeWeightedAvg} from "../interfaces/ITimeWeightedAvg.sol";
import {IBeacon} from "../interfaces/beacons/IBeacon.sol";
import "./Constants.sol";
import {Funding} from "./Funding.sol";
import {QuoteReverter} from "./QuoteReverter.sol";
import {SignedMath} from "./SignedMath.sol";
import {Tick} from "./Tick.sol";
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
    using Tick for mapping(int24 => Tick.GrowthInfo);
    using SafeTransferLib for address;

    /* FUNCTIONS */

    /// @notice Creates a new perp
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
        // prepare the params for creating a pool in Uniswap
        Router.CreatePoolConfig memory config = Router.CreatePoolConfig(TICK_SPACING, params.startingSqrtPriceX96);

        // execute the create pool action using an encoded config
        bytes memory encodedPoolKey = poolManager.executeAction(Router.CREATE_POOL, abi.encode(config));

        // decode the key and obtain the Uniswap poolId to use as the perpId
        PoolKey memory key = abi.decode(encodedPoolKey, (PoolKey));
        perpId = key.toId();

        // initialize the perp's state
        Mgr.Perp storage perp = perps[perpId];

        // TODO: clean up and reorder as needed
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
        perp.key = key;

        // initialize the perp's time weighted average state and increase the cardinality cap to its starting value
        perp.twapState.initialize(uint32(block.timestamp));
        perp.twapState.increaseCardinalityCap(INITIAL_CARDINALITY_CAP);

        uint256 indexPriceX96 = IBeacon(params.beacon).data();
        emit Mgr.PerpCreated(perpId, params.beacon, params.startingSqrtPriceX96, indexPriceX96);
    }

    /// @notice Opens a new maker or taker position in a perp
    /// @param perp The perp to open the position in
    /// @param poolManager The Uniswap pool manager to call swapping and liquidity modification actions on
    /// @param usdc The address of the USDC token
    /// @param encodedParams The encoded parameters for opening the position
    /// @param isMaker Whether the position is a maker position. If false, the position is a taker position
    /// @param revertChanges Whether to revert the changes (and thus not change state)
    /// @return posId The ID of the opened position
    /// @return pos The details of the opened position
    /// @return creatorFee The amount paid due to the creator fee
    /// @return insFee The amount paid due to the insurance fee
    /// @return lpFee The amount paid due to the lp fee
    function openPosition(
        Mgr.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        bytes memory encodedParams,
        bool isMaker,
        bool revertChanges
    ) external returns (uint128 posId, Mgr.Position memory pos, uint256 creatorFee, uint256 insFee, uint256 lpFee) {
        PoolId perpId = perp.key.toId();
        (uint160 sqrtPriceX96, int24 startingTick,,) = poolManager.getSlot0(perpId);

        // use the existing premium per second and sqrt price before they change to update funding accumulators to
        // account for the time passed since the last update
        updateTwPremiums(perp, sqrtPriceX96);

        // store the ID of the position about to be opened and increment the next position ID
        posId = perp.nextPosId;
        perp.nextPosId++;

        if (isMaker) {
            // Use the maker params struct to decode the parameters
            Mgr.OpenMakerPositionParams memory params = abi.decode(encodedParams, (Mgr.OpenMakerPositionParams));

            // Don't allow zero liquidity to be specified
            if (params.liquidity == 0) revert Mgr.InvalidLiquidity(params.liquidity);

            pos.margin = params.margin;

            Tick.FundingGrowthRangeInfo memory fundingGrowthRangeInfo = perp.tickGrowthInfo.getAllFundingGrowth(
                params.tickLower, params.tickUpper, startingTick, perp.twPremiumX96, perp.twPremiumDivBySqrtPriceX96
            );

            int256 e = fundingGrowthRangeInfo.twPremiumDivBySqrtPriceGrowthInsideX96;
            pos.makerDetails = Mgr.MakerDetails({
                entryTimestamp: uint32(block.timestamp),
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidity: params.liquidity,
                entryTwPremiumGrowthInsideX96: fundingGrowthRangeInfo.twPremiumGrowthInsideX96,
                entryTwPremiumDivBySqrtPriceGrowthInsideX96: e,
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
                Router.LiquidityConfig({
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

            bytes memory encodedDeltas = poolManager.executeAction(Router.MODIFY_LIQUIDITY, encodedConfig);

            (pos.perpDelta, pos.usdDelta) = abi.decode(encodedDeltas, (int256, int256));

            uint256 notionalValue = liquidityNotional(pos.perpDelta, pos.usdDelta, sqrtPriceX96);

            uint256 marginRatio = pos.margin.fullMulDiv(SCALE_1E6, notionalValue);

            if (marginRatio < perp.minMakerOpeningMarginRatio) revert("margin ratio is too low");
            if (marginRatio > perp.maxMakerOpeningMarginRatio) revert("margin ratio is too high");
        } else {
            Mgr.OpenTakerPositionParams memory params = abi.decode(encodedParams, (Mgr.OpenTakerPositionParams));

            uint256 notionalValue = params.margin.mulDiv(params.levX96, UINT_Q96);

            creatorFee = notionalValue.mulDiv(perp.creatorFee, SCALE_1E6);
            insFee = notionalValue.mulDiv(perp.insuranceFee, SCALE_1E6);
            lpFee = notionalValue.mulDiv(perp.calculateTradingFee(poolManager), SCALE_1E6);

            pos.margin = params.margin - creatorFee - insFee - lpFee;
            notionalValue = pos.margin.mulDiv(params.levX96, UINT_Q96);

            uint256 marginRatio = pos.margin.fullMulDiv(SCALE_1E6, notionalValue);

            if (marginRatio < perp.minTakerOpeningMarginRatio) revert("margin ratio is too low");
            if (marginRatio > perp.maxTakerOpeningMarginRatio) revert("margin ratio is too high");

            bytes memory encodedConfig = abi.encode(
                Router.SwapConfig({
                    poolKey: perp.key,
                    isExactIn: params.isLong,
                    zeroForOne: !params.isLong,
                    amountSpecified: notionalValue,
                    sqrtPriceLimitX96: getSqrtPriceLimitX96(perp, sqrtPriceX96, params.isLong),
                    unspecifiedAmountLimit: params.unspecifiedAmountLimit
                })
            );

            bytes memory encodedDeltas = poolManager.executeAction(Router.SWAP, encodedConfig);

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

            poolManager.executeAction(
                Router.DONATE, abi.encode(Router.DonateConfig({poolKey: perp.key, amount: lpFee}))
            );
        }

        if (pos.perpDelta == 0 && pos.usdDelta == 0) revert Mgr.ZeroSizePosition(pos.perpDelta, pos.usdDelta);

        pos.holder = msg.sender;
        pos.entryTwPremiumX96 = perp.twPremiumX96;

        if (pos.margin < perp.minOpeningMargin) revert Mgr.InvalidMargin(pos.margin);

        perp.twapState.write(block.timestamp.toUint32(), sqrtPriceX96);

        int256 fundingPremiumPerSecX96 = updatePremiumPerSecond(perp, sqrtPriceX96);

        perp.positions[posId] = pos;

        if (revertChanges) {
            revert QuoteReverter.RevertOpenQuote(
                QuoteReverter.OpenQuote(pos.perpDelta, pos.usdDelta, creatorFee, insFee, lpFee)
            );
        }

        usdc.safeTransferFrom(msg.sender, perp.vault, pos.margin + creatorFee + insFee + lpFee);
        usdc.safeTransferFrom(perp.vault, perp.creator, creatorFee);

        emit Mgr.PositionOpened(
            perpId, posId, pos.holder, isMaker, pos.perpDelta, sqrtPriceX96, fundingPremiumPerSecX96
        );
    }

    function addMargin(
        Mgr.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        Mgr.AddMarginParams calldata params
    ) external {
        address holder = perp.positions[params.posId].holder;
        uint256 margin = params.margin;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(perp.key.toId());

        // update funding accounting
        updateTwPremiums(perp, sqrtPriceX96);
        updatePremiumPerSecond(perp, sqrtPriceX96);

        // update mark twap
        perp.twapState.write(block.timestamp.toUint32(), sqrtPriceX96);

        // validate caller is holder and that margin is nonzero
        if (msg.sender != holder) revert Mgr.InvalidCaller(msg.sender, holder);
        if (margin == 0) revert Mgr.InvalidMargin(margin);

        // TODO: add margin ratio check

        // transfer margin from sender to vault
        usdc.safeTransferFrom(msg.sender, perp.vault, margin);

        // update maker position state
        perp.positions[params.posId].margin += margin;

        emit Mgr.MarginAdded(perp.key.toId(), params.posId, perp.positions[params.posId].margin);
    }

    function closePosition(
        Mgr.Perp storage perp,
        IPoolManager poolManager,
        address usdc,
        Mgr.ClosePositionParams calldata params,
        bool revertChanges
    ) external returns (uint128 posId) {
        PoolId perpId = perp.key.toId();
        Mgr.Position memory pos = perp.positions[params.posId];

        if (pos.holder == address(0)) revert Mgr.InvalidClose(msg.sender, address(0), false);

        (uint160 sqrtPriceX96, int24 startingTick,,) = poolManager.getSlot0(perpId);
        updateTwPremiums(perp, sqrtPriceX96);

        bool isLiquidation;
        bool isMaker = pos.makerDetails.liquidity > 0;
        int256 pnl;
        if (isMaker) {
            Mgr.MakerDetails memory makerDetails = pos.makerDetails;

            bytes memory encodedConfig = abi.encode(
                Router.LiquidityConfig({
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

            bytes memory encodedDeltas = poolManager.executeAction(Router.MODIFY_LIQUIDITY, encodedConfig);

            (int256 perpDelta, int256 usdDelta) = abi.decode(encodedDeltas, (int256, int256));

            pnl = usdDelta + pos.usdDelta;

            int256 takerPerpDelta = perpDelta + pos.perpDelta;

            int256 funding = makerFunding(perp, pos, startingTick);

            uint256 notional = liquidityNotional(takerPerpDelta, usdDelta, sqrtPriceX96);

            uint256 effectiveMargin;
            (effectiveMargin, isLiquidation) =
                calcEffectiveMargin(perp, usdc, pos.margin, pnl, funding, notional, true, pos.holder);

            if (revertChanges) {
                revert QuoteReverter.RevertCloseQuote(
                    QuoteReverter.CloseQuote(pnl, funding, effectiveMargin, isLiquidation)
                );
            }

            if (
                !revertChanges && !isLiquidation
                    && block.timestamp <= makerDetails.entryTimestamp + perp.makerLockupPeriod
            ) revert Mgr.MakerPositionLocked(block.timestamp, makerDetails.entryTimestamp + perp.makerLockupPeriod);

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

                Mgr.Position memory newPos;

                newPos.holder = pos.holder;
                newPos.perpDelta = takerPerpDelta;
                newPos.usdDelta = 0;
                newPos.margin = effectiveMargin;
                newPos.entryTwPremiumX96 = perp.twPremiumX96;

                perp.positions[posId] = newPos;

                // emit Mgr.TakerPositionOpened(perpId, takerPosId, perp.takerPositions[takerPosId], sqrtPriceX96);
            } else {
                usdc.safeTransferFrom(perp.vault, pos.holder, effectiveMargin);
            }
        } else {
            bool isLong = pos.perpDelta > 0;

            bytes memory encodedConfig = abi.encode(
                Router.SwapConfig({
                    poolKey: perp.key,
                    isExactIn: isLong,
                    zeroForOne: isLong,
                    amountSpecified: isLong ? uint256(pos.perpDelta) : uint256(-pos.perpDelta),
                    sqrtPriceLimitX96: getSqrtPriceLimitX96(perp, sqrtPriceX96, !isLong),
                    unspecifiedAmountLimit: isLong ? params.minAmt1Out : params.maxAmt1In
                })
            );

            bytes memory encodedDeltas = poolManager.executeAction(Router.SWAP, encodedConfig);

            (, int256 usdDelta) = abi.decode(encodedDeltas, (int256, int256));

            pnl = usdDelta + pos.usdDelta;

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

            uint256 effectiveMargin;
            (effectiveMargin, isLiquidation) =
                calcEffectiveMargin(perp, usdc, pos.margin, pnl, funding, notional, true, pos.holder);

            if (revertChanges) {
                revert QuoteReverter.RevertCloseQuote(
                    QuoteReverter.CloseQuote(pnl, funding, effectiveMargin, isLiquidation)
                );
            }

            usdc.safeTransferFrom(perp.vault, pos.holder, effectiveMargin);
        }

        int256 fundingPremiumPerSecX96 = updatePremiumPerSecond(perp, sqrtPriceX96);

        // update mark twap
        perp.twapState.write(block.timestamp.toUint32(), sqrtPriceX96);

        emit Mgr.PositionClosed(
            perpId,
            params.posId,
            pos.holder,
            isMaker,
            pos.perpDelta,
            pnl,
            isLiquidation,
            sqrtPriceX96,
            fundingPremiumPerSecX96
        );
        delete perp.positions[params.posId];
    }

    function makerFunding(Mgr.Perp storage perp, Mgr.Position memory pos, int24 currentTick)
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
        Mgr.Perp storage perp,
        address usdc,
        uint256 margin,
        int256 pnl,
        int256 funding,
        uint256 notional,
        bool isMaker,
        address holder
    ) internal returns (uint256 effectiveMargin, bool isLiquidation) {
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
        if (!isLiquidation && msg.sender != holder) revert Mgr.InvalidClose(msg.sender, holder, false);
        if (isLiquidation) usdc.safeTransferFrom(perp.vault, msg.sender, liquidationFeeAmt);
    }

    function liquidityNotional(int256 perpDelta, int256 usdDelta, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 notional)
    {
        uint256 perps = perpDelta.abs();
        uint256 usd = usdDelta.abs();

        // convert currency0Amount (perp contracts) to its value in currency1 (usd)
        uint256 perpsNotional = sqrtPriceX96.fullMulDiv(perps * sqrtPriceX96, UINT_Q192);

        // currency1Amount is already in USD, so its notional value is its amount
        notional = perpsNotional + usd;
    }

    function updateTwPremiums(Mgr.Perp storage perp, uint160 sqrtPriceX96) internal {
        int256 timeSinceLastUpdate = int256(block.timestamp - perp.lastTwPremiumsUpdate);

        perp.twPremiumX96 += perp.premiumPerSecondX96 * timeSinceLastUpdate;

        perp.twPremiumDivBySqrtPriceX96 +=
            perp.premiumPerSecondX96.fullMulDivSigned(timeSinceLastUpdate * INT_Q96, sqrtPriceX96);

        perp.lastTwPremiumsUpdate = uint32(block.timestamp);
    }

    // expects updateTwPremiums() to have been called before to account for time during old premiumPerSecondX96
    function updatePremiumPerSecond(Mgr.Perp storage perp, uint160 sqrtPriceX96)
        internal
        returns (int256 premiumPerSecondX96)
    {
        uint256 twaSqrtMarkX96 =
            perp.twapState.timeWeightedAvg(perp.twapWindow, block.timestamp.toUint32(), sqrtPriceX96);
        uint256 twaIndexX96 = ITimeWeightedAvg(perp.beacon).timeWeightedAvg(perp.twapWindow);

        uint256 twaMarkX192 = twaSqrtMarkX96 * twaSqrtMarkX96;
        uint256 twaIndexX192 = twaIndexX96 * UINT_Q96;

        premiumPerSecondX96 =
            ((int256(twaMarkX192) - int256(twaIndexX192)) / INT_Q96 / int256(uint256(FUNDING_INTERVAL)));
        perp.premiumPerSecondX96 = premiumPerSecondX96;
    }

    function getSqrtPriceLimitX96(Mgr.Perp storage perp, uint160 sqrtPriceX96, bool isBuy)
        internal
        view
        returns (uint160 sqrtPriceLimitX96)
    {
        uint256 twaSqrtPriceX96 = perp.twapState.timeWeightedAvg(TWAP_WINDOW, block.timestamp.toUint32(), sqrtPriceX96);
        uint256 multiplier = isBuy ? SQRT_PRICE_UPPER_MULTI_X96 : SQRT_PRICE_LOWER_MULTI_X96;

        sqrtPriceLimitX96 = twaSqrtPriceX96.fullMulDiv(multiplier, UINT_Q96).toUint160();

        if (sqrtPriceLimitX96 > TickMath.MAX_SQRT_PRICE) sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE;
        if (sqrtPriceLimitX96 < TickMath.MIN_SQRT_PRICE) sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE;
    }
}
