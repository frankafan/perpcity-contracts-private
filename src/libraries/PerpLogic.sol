// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {AccountingToken} from "../AccountingToken.sol";
import {PerpVault} from "../PerpVault.sol";
import {IPerpManager} from "../interfaces/IPerpManager.sol";
import {ITWAPBeacon} from "../interfaces/ITWAPBeacon.sol";
import {MAX_CARDINALITY} from "../utils/Constants.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {MoreSignedMath} from "./MoreSignedMath.sol";
import {TickTWAP} from "./TickTWAP.sol";
import {UniswapV4Utility} from "./UniswapV4Utility.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

library PerpLogic {
    using TickTWAP for TickTWAP.Observation[MAX_CARDINALITY];
    using FixedPointMathLib for *;
    using SafeCastLib for *;
    using MoreSignedMath for int256;
    using PerpLogic for uint160;

    function createPerp(
        mapping(PoolId => IPerpManager.Perp) storage perps,
        IPerpManager.ExternalContracts calldata c,
        IPerpManager.CreatePerpParams calldata params
    )
        external
        returns (PoolId perpId)
    {
        validateParams(params);

        PoolKey memory key = createUniswapPool(params.tickSpacing, params.startingSqrtPriceX96, c);
        perpId = key.toId();

        // create a vault that will hold all usdc for the perp
        PerpVault vault = new PerpVault(address(this), c.usdc);

        // cast timestamp to 32 bits
        uint32 currentTimestamp = block.timestamp.toUint32();

        // initialize perp state
        IPerpManager.Perp storage perp = perps[perpId];

        perp.vault = address(vault);
        perp.creationTimestamp = currentTimestamp;
        perp.makerLockupPeriod = params.makerLockupPeriod;
        perp.beacon = params.beacon;
        perp.fundingInterval = params.fundingInterval;
        perp.twapWindow = params.twapWindow;
        perp.creator = msg.sender;
        perp.tradingFeeCreatorSplitX96 = params.tradingFeeCreatorSplitX96;
        perp.tradingFeeInsuranceSplitX96 = params.tradingFeeInsuranceSplitX96;
        perp.nextMakerPosId = 1; // maker IDs start at 1
        perp.nextTakerPosId = 1; // taker IDs start at 1
        perp.priceImpactBandX96 = params.priceImpactBandX96;
        perp.maxOpeningLevX96 = params.maxOpeningLevX96;
        perp.liquidationLevX96 = params.liquidationLevX96;
        perp.liquidationFeeX96 = params.liquidationFeeX96;
        perp.liquidatorFeeSplitX96 = params.liquidatorFeeSplitX96;
        perp.marketDeathThresholdX96 = params.marketDeathThresholdX96;
        perp.tradingFeeConfig = params.tradingFeeConfig;
        perp.key = key;

        // initialize twap helpers, cardinalityNext will be set to 1 at first
        (perp.twapState.cardinality, perp.twapState.cardinalityNext) =
            perp.twapState.observations.initialize(currentTimestamp);

        // grow cardinalityNext to the desired initial CardinalityNext
        perp.twapState.cardinalityNext =
            perp.twapState.observations.grow(perp.twapState.cardinalityNext, params.initialCardinalityNext);

        emit IPerpManager.PerpCreated(perpId, params.beacon, params.startingSqrtPriceX96);
    }

    function validateParams(IPerpManager.CreatePerpParams calldata params) internal pure {
        if (params.startingSqrtPriceX96 == 0) {
            revert IPerpManager.InvalidStartingSqrtPriceX96(params.startingSqrtPriceX96);
        }

        if (params.beacon == address(0)) revert IPerpManager.InvalidBeaconAddress(params.beacon);

        if (params.maxOpeningLevX96 == 0) revert IPerpManager.InvalidMaxOpeningLev(params.maxOpeningLevX96);

        if (params.tradingFeeInsuranceSplitX96 + params.tradingFeeCreatorSplitX96 > FixedPoint96.UINT_Q96) {
            revert IPerpManager.InvalidTradingFeeSplits(
                params.tradingFeeInsuranceSplitX96, params.tradingFeeCreatorSplitX96
            );
        }

        if (params.liquidationLevX96 <= params.maxOpeningLevX96) {
            revert IPerpManager.InvalidLiquidationLev(params.liquidationLevX96, params.maxOpeningLevX96);
        }

        if (params.liquidationFeeX96 > FixedPoint96.UINT_Q96) {
            revert IPerpManager.InvalidLiquidationFee(params.liquidationFeeX96);
        }

        if (params.liquidatorFeeSplitX96 > FixedPoint96.UINT_Q96) {
            revert IPerpManager.InvalidLiquidatorFeeSplit(params.liquidatorFeeSplitX96);
        }

        if (params.fundingInterval == 0) revert IPerpManager.InvalidFundingInterval(params.fundingInterval);

        if (params.priceImpactBandX96 > FixedPoint96.UINT_Q96) {
            revert IPerpManager.InvalidPriceImpactBand(params.priceImpactBandX96);
        }

        if (params.priceImpactBandX96 == 0) revert IPerpManager.InvalidPriceImpactBand(params.priceImpactBandX96);

        if (params.marketDeathThresholdX96 >= FixedPoint96.UINT_Q96) {
            revert IPerpManager.InvalidMarketDeathThreshold(params.marketDeathThresholdX96);
        }

        if (params.tradingFeeConfig.decay == 0) revert IPerpManager.InvalidTradingFeeConfig(params.tradingFeeConfig);

        if (params.tradingFeeConfig.maxFeeMultiplierX96 < FixedPoint96.UINT_Q96) {
            revert IPerpManager.InvalidTradingFeeConfig(params.tradingFeeConfig);
        }

        // maxFee = maxFeeMultiplier * startFee; maxFee can't be more than 100%
        if (
            params.tradingFeeConfig.maxFeeMultiplierX96.mulDiv(
                params.tradingFeeConfig.startFeeX96, FixedPoint96.UINT_Q96
            ) > FixedPoint96.UINT_Q96
        ) revert IPerpManager.InvalidTradingFeeConfig(params.tradingFeeConfig);

        // maxFee = maxFeeMultiplier * targetFee when (targetFee > startFee); maxFee can't be more than 100%
        if (
            params.tradingFeeConfig.maxFeeMultiplierX96.mulDiv(
                params.tradingFeeConfig.targetFeeX96, FixedPoint96.UINT_Q96
            ) > FixedPoint96.UINT_Q96
        ) revert IPerpManager.InvalidTradingFeeConfig(params.tradingFeeConfig);
    }

    function createUniswapPool(
        int24 tickSpacing,
        uint160 startingSqrtPriceX96,
        IPerpManager.ExternalContracts calldata c
    )
        internal
        returns (PoolKey memory poolKey)
    {
        // create two accounting tokens for the perp
        address currency0 = address(new AccountingToken(type(uint128).max));
        address currency1 = address(new AccountingToken(type(uint128).max));

        // approve the router and position manager to transfer accounting tokens from this address
        UniswapV4Utility.approveRouterAndPositionManager(c, currency0, currency1);

        // assign the smaller token address to currency0 and the larger token address to currency1
        // such that currency0 can always represent usd and currency1 can always represent perp contracts
        if (currency0 > currency1) (currency0, currency1) = (currency1, currency0);

        // create the pool key with a zero fee since we use custom fee logic
        poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 0,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });

        // initialize the pool in Uniswap's PoolManager
        c.poolManager.initialize(poolKey, startingSqrtPriceX96);
    }

    function updateTwPremiums(IPerpManager.Perp storage perp, uint160 sqrtPriceX96) internal {
        int256 timeSinceLastUpdate = (block.timestamp - perp.lastTwPremiumsUpdate).toInt256();

        perp.twPremiumX96 += perp.premiumPerSecondX96 * timeSinceLastUpdate;

        perp.twPremiumDivBySqrtPriceX96 +=
            perp.premiumPerSecondX96.fullMulDivSigned(timeSinceLastUpdate * FixedPoint96.INT_Q96, sqrtPriceX96);

        perp.lastTwPremiumsUpdate = block.timestamp.toUint32();
    }

    // expects updateTwPremiums() to have been called before to account for time during old premiumPerSecondX96
    function updatePremiumPerSecond(IPerpManager.Perp storage perp, uint160 sqrtPriceX96) internal {
        uint32 oldestObservationTimestamp =
            perp.twapState.observations.getOldestObservationTimestamp(perp.twapState.index, perp.twapState.cardinality);
        uint32 twapSecondsAgo = (block.timestamp - oldestObservationTimestamp).toUint32();
        twapSecondsAgo = twapSecondsAgo > perp.twapWindow ? perp.twapWindow : twapSecondsAgo;

        uint256 markTwapX96 = getTWAP(perp, twapSecondsAgo, TickMath.getTickAtSqrtPrice(sqrtPriceX96));
        uint256 indexTwapX96 = ITWAPBeacon(perp.beacon).getTWAP(twapSecondsAgo);

        perp.premiumPerSecondX96 = ((int256(markTwapX96) - int256(indexTwapX96)) / perp.fundingInterval.toInt256());
    }

    function getTWAP(
        IPerpManager.Perp storage perp,
        uint32 twapSecondsAgo,
        int24 currentTick
    )
        internal
        view
        returns (uint256 twapPrice)
    {
        if (twapSecondsAgo == 0) return TickMath.getSqrtPriceAtTick(currentTick).toPriceX96();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSecondsAgo;
        secondsAgos[1] = 0;
        int56[] memory tickCumulatives = perp.twapState.observations.observe(
            block.timestamp.toUint32(), secondsAgos, currentTick, perp.twapState.index, perp.twapState.cardinality
        );
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        return TickMath.getSqrtPriceAtTick(int24(tickCumulativesDelta / int56(uint56(twapSecondsAgo)))).toPriceX96();
    }

    function increaseCardinalityNext(
        IPerpManager.Perp storage perp,
        uint32 cardinalityNext
    )
        internal
        returns (uint32 cardinalityNextOld, uint32 cardinalityNextNew)
    {
        cardinalityNextOld = perp.twapState.cardinalityNext;
        cardinalityNextNew = perp.twapState.observations.grow(cardinalityNextOld, cardinalityNext);
        perp.twapState.cardinalityNext = cardinalityNextNew;
    }

    function toPriceX96(uint256 sqrtPriceX96) internal pure returns (uint256) {
        return sqrtPriceX96.fullMulDiv(sqrtPriceX96, FixedPoint96.UINT_Q96);
    }
}
