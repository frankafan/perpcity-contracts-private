// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Simplified Pool mock for Halmos testing
/// @dev Replaces the heavy Pool.State library to reduce symbolic execution complexity
library PoolMock {
    /// @dev Slot0 contains the current price and tick
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
    }

    /// @dev Tick info for a specific tick
    struct TickInfo {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    /// @dev Simplified pool state
    struct State {
        Slot0 slot0;
        uint128 liquidity;
        mapping(int24 => TickInfo) ticks;
        mapping(int16 => uint256) tickBitmap;
    }

    /// @dev Parameters for modifyLiquidity
    struct ModifyLiquidityParams {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
        int24 tickSpacing;
        bytes32 salt;
    }

    /// @dev Parameters for swap
    struct SwapParams {
        int24 tickSpacing;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        uint128 lpFeeOverride;
    }

    /// @notice Initialize a pool
    function initialize(State storage self, uint160 sqrtPriceX96, uint24 protocolFee) internal returns (int24 tick) {
        require(self.slot0.sqrtPriceX96 == 0, "Already initialized");

        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        self.slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick, protocolFee: protocolFee, lpFee: 0});
    }

    /// @notice Modify liquidity in the pool
    function modifyLiquidity(
        State storage self,
        ModifyLiquidityParams memory params
    ) internal returns (BalanceDelta delta, BalanceDelta feesAccrued) {
        // Simplified: return approximate deltas
        int128 amount0Delta = int128(params.liquidityDelta / 2);
        int128 amount1Delta = int128(params.liquidityDelta / 2);

        delta = toBalanceDelta(amount0Delta, amount1Delta);
        feesAccrued = toBalanceDelta(0, 0);

        // Update liquidity
        if (params.liquidityDelta > 0) {
            self.liquidity += uint128(params.liquidityDelta);
        } else if (params.liquidityDelta < 0) {
            self.liquidity -= uint128(-params.liquidityDelta);
        }

        // Update tick info
        _updateTick(self, params.tickLower, params.liquidityDelta);
        _updateTick(self, params.tickUpper, params.liquidityDelta);
    }

    /// @notice Execute a swap
    function swap(
        State storage self,
        SwapParams memory params
    ) internal returns (BalanceDelta delta, uint160, uint24, uint128) {
        require(params.amountSpecified != 0, "Amount cannot be zero");

        // Simplified: calculate approximate swap delta
        int128 amount0Delta;
        int128 amount1Delta;

        if (params.zeroForOne) {
            amount0Delta = int128(params.amountSpecified);
            amount1Delta = -int128(params.amountSpecified); // Simplified 1:1 swap
        } else {
            amount0Delta = -int128(params.amountSpecified);
            amount1Delta = int128(params.amountSpecified);
        }

        delta = toBalanceDelta(amount0Delta, amount1Delta);

        // Update pool state (simplified price impact)
        if (params.zeroForOne) {
            self.slot0.tick -= 1; // Price moves down
        } else {
            self.slot0.tick += 1; // Price moves up
        }
        self.slot0.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(self.slot0.tick);

        return (delta, self.slot0.sqrtPriceX96, 0, self.liquidity);
    }

    /// @notice Donate to the pool
    function donate(State storage, uint256 amount0, uint256 amount1) internal pure returns (BalanceDelta delta) {
        // Simplified: donations are just added as deltas
        delta = toBalanceDelta(-int128(uint128(amount0)), -int128(uint128(amount1)));
    }

    /// @dev Helper to update tick info
    function _updateTick(State storage self, int24 tick, int128 liquidityDelta) private {
        TickInfo storage info = self.ticks[tick];

        if (liquidityDelta > 0) {
            info.liquidityGross += uint128(liquidityDelta);
            info.liquidityNet += liquidityDelta;
        } else if (liquidityDelta < 0) {
            info.liquidityGross -= uint128(-liquidityDelta);
            info.liquidityNet += liquidityDelta; // Note: adding negative delta
        }
    }
}
