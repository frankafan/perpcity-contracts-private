// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPerpManager} from "../interfaces/IPerpManager.sol";

import {INT_Q96, UINT_Q96} from "./Constants.sol";
import {PerpLogic} from "./PerpLogic.sol";
import {SignedMath} from "./SignedMath.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// TODO: add comments & turn into a module
// a library with a function to calculate a dynamic fee based on liquidity and volatility
// as liquidity grows, the fee decays from startFee, approaching targetFee asymptotically
// at any point, high volatility will increase the fee, up to maxFeeMultiplier * baseFee
library TradingFee {
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for *;
    using SafeCastLib for *;

    using PerpLogic for *;
    using SignedMath for int256;
    // using TickTWAP for TickTWAP.Observation[MAX_CARDINALITY];

    // uint24 constant START_FEE = 0.01e6; // 1%
    uint24 constant START_FEE = 0;
    uint24 constant TARGET_FEE = 0.0001e6; // 0.01%
    uint24 constant DECAY = 15000000;
    uint24 constant VOLATILITY_SCALER = 0.2e6; // 0.2
    uint24 constant MAX_FEE_MULTIPLIER = 2e6; // 200%

    // struct Config {
    //     uint128 baseFeeX96; // current percent fee if volatility is zero (e.g. 0.05 = 5%)
    //     uint128 startFeeX96; // percent fee when liquidity is zero and volatility is zero (e.g. 0.05 = 5%)
    //     uint128 targetFeeX96; // percent fee the curve approaches as liquidity is added and volatility is zero
    //     uint128 decay; // controls decay rate from startFee to targetFee as liquidity grows; higher value = slower)
    //     uint128 volatilityScalerX96; // scales volatility's impact on fee (e.g. 0 = no impact, 0.05 = higher impact)
    //     uint128 maxFeeMultiplierX96; // determines max percent fee when volatility is high (e.g. 1.5 = 150% of base)
    // }

    // updates the portion of the overall fee function that is based on liquidity (baseFeeX96)
    // function updateBaseFeeX96(IPerpManager.Perp storage perp, IPoolManager poolManager) internal {

    //     // calculate the weighted liquidity through dividing by the decay constant
    //     uint128 liquidity = poolManager.getLiquidity(perp.key.toId());
    //     uint256 weightedLiqX96 = liquidity.mulDiv(UINT_Q96, DECAY);

    //     // baseFee = targetFee + (startFee - targetFee) / (weightedLiq + 1)
    //     int256 targetFeeX96 = TARGET_FEE.toInt256();
    //     perp.baseFeeX96 = (
    //         targetFeeX96
    //             + (START_FEE.toInt256() - targetFeeX96).mulDivSigned(INT_Q96, weightedLiqX96 + UINT_Q96)
    //     ).toUint256().toUint128();
    // }

    // uses the current baseFee to calculate the current tradingFee based on volatility's impact
    // function calculateTradingFeeX96(
    //     IPerpManager.Perp storage perp,
    //     IPoolManager poolManager
    // )
    //     internal
    //     view
    //     returns (uint128)
    // {
    //     Config memory config = perp.tradingFeeConfig;

    //     (uint256 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(perp.key.toId());

    //     // get mark and markTwap, used to calculate volatility
    //     uint256 markX96 = sqrtPriceX96.toPriceX96();

    //     uint32 oldestObservationTimestamp = perp.twapState.observations.getOldestObservationTimestamp(
    //         perp.twapState.index, perp.twapState.cardinality
    //     );
    //     uint32 twapSecondsAgo = (block.timestamp - oldestObservationTimestamp).toUint32();
    //     uint32 twapWindow = perp.twapWindow;
    //     twapSecondsAgo = twapSecondsAgo > twapWindow ? twapWindow : twapSecondsAgo;

    //     uint256 markTwapX96 = perp.getTWAP(twapSecondsAgo, currentTick);

    //     // sqrtVolatility = |(mark / markTwap) - 1|
    //     uint256 sqrtVolatilityX96 =
    //         (int256(markX96.fullMulDiv(UINT_Q96, markTwapX96 + 1)) - INT_Q96).abs();
    //     // volatility = sqrtVolatility ^ 2
    //     uint256 volatilityX96 = sqrtVolatilityX96.fullMulDiv(sqrtVolatilityX96, UINT_Q96);
    //     // volatilityFee = volatilityScaler * volatility
    //     // this is just the portion of the fee that is based on volatility; it is not the entire fee
    //     uint256 volatilityFeeX96 = config.volatilityScalerX96.fullMulDiv(volatilityX96, UINT_Q96);

    //     // maxFee = maxFeeMultiplier * baseFee
    //     uint256 maxFeeX96 = config.maxFeeMultiplierX96.fullMulDiv(config.baseFeeX96, UINT_Q96);

    //     // tradingFee = min(baseFee + volatilityFee, maxFee)
    //     return FixedPointMathLib.min(config.baseFeeX96 + volatilityFeeX96, maxFeeX96).toUint128();
    // }

    function calculateTradingFee(IPerpManager.Perp storage perp, IPoolManager poolManager)
        internal
        view
        returns (uint24)
    {
        return START_FEE;
    }
}
