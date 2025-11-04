// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Simplified TickMath for Halmos testing
/// @notice Provides simplified tick <-> sqrt price conversions that avoid complex bit manipulation
/// @dev This is NOT accurate for production use - only for symbolic execution testing
/// @dev Uses linear approximation instead of the complex logarithmic calculations
library TickMathSimplified {
    /// @notice Thrown when the tick passed to #getSqrtPriceAtTick is not between MIN_TICK and MAX_TICK
    error InvalidTick(int24 tick);
    /// @notice Thrown when the price passed to #getTickAtSqrtPrice does not correspond to a price between MIN_TICK and MAX_TICK
    error InvalidSqrtPrice(uint160 sqrtPriceX96);

    /// @dev The minimum tick that may be passed to #getSqrtPriceAtTick computed from log base 1.0001 of 2**-128
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick that may be passed to #getSqrtPriceAtTick computed from log base 1.0001 of 2**128
    int24 internal constant MAX_TICK = 887272;

    /// @dev The minimum tick spacing value drawn from the range of type int16 that is greater than 0
    int24 internal constant MIN_TICK_SPACING = 1;
    /// @dev The maximum tick spacing value drawn from the range of type int16
    int24 internal constant MAX_TICK_SPACING = type(int16).max;

    /// @dev The minimum value that can be returned from #getSqrtPriceAtTick. Equivalent to getSqrtPriceAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtPriceAtTick. Equivalent to getSqrtPriceAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    /// @dev A threshold used for optimized bounds check
    uint160 internal constant MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE =
        1461446703485210103287273052203988822378723970342 - 4295128739 - 1;

    /// @dev sqrt(1) in Q96 format - used as the center point for our approximation
    uint160 internal constant SQRT_PRICE_AT_TICK_0 = 79228162514264337593543950336;

    /// @notice Given a tickSpacing, compute the maximum usable tick
    function maxUsableTick(int24 tickSpacing) internal pure returns (int24) {
        unchecked {
            return (MAX_TICK / tickSpacing) * tickSpacing;
        }
    }

    /// @notice Given a tickSpacing, compute the minimum usable tick
    function minUsableTick(int24 tickSpacing) internal pure returns (int24) {
        unchecked {
            return (MIN_TICK / tickSpacing) * tickSpacing;
        }
    }

    /// @notice Calculates sqrt(1.0001^tick) * 2^96
    /// @dev Simplified version using linear approximation for symbolic execution
    /// @dev This is NOT accurate but avoids path explosion in Halmos
    /// @param tick The input tick for the above formula
    /// @return sqrtPriceX96 A Fixed point Q64.96 number representing the sqrt of the ratio of the two assets (token1/token0)
    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        // Validate tick is in range
        if (tick < MIN_TICK || tick > MAX_TICK) revert InvalidTick(tick);

        unchecked {
            // Use piecewise linear approximation to avoid complex calculations
            // This divides the tick range into segments and approximates within each segment

            if (tick == 0) {
                return SQRT_PRICE_AT_TICK_0;
            } else if (tick > 0) {
                // For positive ticks, price increases
                // Linear interpolation between tick 0 and MAX_TICK
                // At tick 0: SQRT_PRICE_AT_TICK_0
                // At MAX_TICK: MAX_SQRT_PRICE
                uint256 ratio = (uint256(uint24(tick)) * (MAX_SQRT_PRICE - SQRT_PRICE_AT_TICK_0)) / uint24(MAX_TICK);
                sqrtPriceX96 = uint160(SQRT_PRICE_AT_TICK_0 + ratio);
            } else {
                // For negative ticks, price decreases
                // Linear interpolation between MIN_TICK and tick 0
                // At MIN_TICK: MIN_SQRT_PRICE
                // At tick 0: SQRT_PRICE_AT_TICK_0
                uint256 ratio = (uint256(uint24(-tick)) * (SQRT_PRICE_AT_TICK_0 - MIN_SQRT_PRICE)) / uint24(-MIN_TICK);
                sqrtPriceX96 = uint160(SQRT_PRICE_AT_TICK_0 - ratio);
            }
        }
    }

    /// @notice Calculates the greatest tick value such that getSqrtPriceAtTick(tick) <= sqrtPriceX96
    /// @dev Simplified version using linear approximation for symbolic execution
    /// @dev This is NOT accurate but avoids path explosion in Halmos
    /// @param sqrtPriceX96 The sqrt ratio for which to compute the tick as a Q64.96
    /// @return tick The greatest tick for which the sqrt ratio is less than or equal to the input ratio
    function getTickAtSqrtPrice(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        // Validate price is in range
        unchecked {
            if ((sqrtPriceX96 - MIN_SQRT_PRICE) > MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE) {
                revert InvalidSqrtPrice(sqrtPriceX96);
            }
        }

        unchecked {
            // Use inverse of the linear approximation from getSqrtPriceAtTick
            if (sqrtPriceX96 == SQRT_PRICE_AT_TICK_0) {
                return 0;
            } else if (sqrtPriceX96 > SQRT_PRICE_AT_TICK_0) {
                // Positive tick range
                // tick = ((sqrtPriceX96 - SQRT_PRICE_AT_TICK_0) * MAX_TICK) / (MAX_SQRT_PRICE - SQRT_PRICE_AT_TICK_0)
                uint256 priceDelta = sqrtPriceX96 - SQRT_PRICE_AT_TICK_0;
                uint256 priceRange = MAX_SQRT_PRICE - SQRT_PRICE_AT_TICK_0;
                tick = int24(int256((priceDelta * uint24(MAX_TICK)) / priceRange));
            } else {
                // Negative tick range
                // tick = -((SQRT_PRICE_AT_TICK_0 - sqrtPriceX96) * (-MIN_TICK)) / (SQRT_PRICE_AT_TICK_0 - MIN_SQRT_PRICE)
                uint256 priceDelta = SQRT_PRICE_AT_TICK_0 - sqrtPriceX96;
                uint256 priceRange = SQRT_PRICE_AT_TICK_0 - MIN_SQRT_PRICE;
                tick = -int24(int256((priceDelta * uint24(-MIN_TICK)) / priceRange));
            }
        }
    }
}
