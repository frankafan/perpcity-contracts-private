// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {UnsafeMath} from "@uniswap/v4-core/src/libraries/UnsafeMath.sol";

/// @notice Simplified PoolManager mock for Halmos testing
/// @dev Barebones implementation focusing on core logic with minimal complexity
/// @dev All pool logic is inlined to reduce symbolic execution overhead
contract PoolManagerMockSimplified {
    using PoolIdLibrary for PoolKey;
    using SafeCast for *;

    // Structs

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
    struct PoolState {
        Slot0 slot0;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        uint128 liquidity;
        mapping(int24 => TickInfo) ticks;
        mapping(int16 => uint256) tickBitmap;
    }

    /// @dev Parameters for internal modifyLiquidity
    struct ModifyLiquidityParamsInternal {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
        int24 tickSpacing;
        bytes32 salt;
    }

    /// @dev Parameters for internal swap
    struct SwapParamsInternal {
        int24 tickSpacing;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        uint128 lpFeeOverride;
    }

    // Events
    event Initialize(
        PoolId indexed id,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96,
        int24 tick
    );
    event ModifyLiquidity(
        PoolId indexed id,
        address indexed sender,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 salt
    );
    event Swap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );
    event Donate(PoolId indexed id, address indexed sender, uint256 amount0, uint256 amount1);
    event Transfer(address indexed caller, address indexed from, address indexed to, uint256 id, uint256 amount);

    // State

    /// @dev Lock state - true when unlocked, false when locked
    bool internal _unlocked;

    /// @dev Pool states
    mapping(PoolId => PoolState) internal _poolStates;

    /// @dev ERC6909-style token balances: owner => tokenId => balance
    mapping(address => mapping(uint256 => uint256)) internal _tokenBalances;

    /// @dev Currency deltas for current unlock session: currency => address => delta
    mapping(Currency => mapping(address => int256)) internal _deltas;

    // Lock mechanism

    /// @notice Unlocks the pool manager and executes callback
    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!_unlocked, "Already unlocked");
        _unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        _unlocked = false;
    }

    // Pool operations

    /// @notice Initialize a new pool
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        PoolId id = key.toId();
        uint24 lpFee = key.fee;

        PoolState storage self = _poolStates[id];
        require(self.slot0.sqrtPriceX96 == 0, "Already initialized");

        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        self.slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick, protocolFee: lpFee, lpFee: 0});

        emit Initialize(
            id,
            key.currency0,
            key.currency1,
            key.fee,
            key.tickSpacing,
            address(key.hooks),
            sqrtPriceX96,
            tick
        );
    }

    /// @notice Modify liquidity in a pool
    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes calldata
    ) external returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        require(_unlocked, "Manager locked");
        PoolId id = key.toId();
        PoolState storage self = _poolStates[id];
        _checkPoolInitialized(self);

        ModifyLiquidityParamsInternal memory paramsInternal = ModifyLiquidityParamsInternal({
            owner: msg.sender,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: int128(params.liquidityDelta),
            tickSpacing: key.tickSpacing,
            salt: params.salt
        });

        int128 liquidityDelta = paramsInternal.liquidityDelta;
        int24 tickLower = paramsInternal.tickLower;
        int24 tickUpper = paramsInternal.tickUpper;

        // Update tick info
        _updateTick(self, tickLower, liquidityDelta, false);
        _updateTick(self, tickUpper, liquidityDelta, true);

        BalanceDelta fees = toBalanceDelta(0, 0);

        // Calculate deltas based on current tick position
        BalanceDelta principalDelta;
        if (liquidityDelta != 0) {
            int24 tick = self.slot0.tick;
            uint160 sqrtPriceX96 = self.slot0.sqrtPriceX96;

            if (tick < tickLower) {
                principalDelta = toBalanceDelta(
                    SqrtPriceMath
                        .getAmount0Delta(
                            TickMath.getSqrtPriceAtTick(tickLower),
                            TickMath.getSqrtPriceAtTick(tickUpper),
                            liquidityDelta
                        )
                        .toInt128(),
                    0
                );
            } else if (tick < tickUpper) {
                principalDelta = toBalanceDelta(
                    SqrtPriceMath
                        .getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta)
                        .toInt128(),
                    SqrtPriceMath
                        .getAmount1Delta(TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, liquidityDelta)
                        .toInt128()
                );
                self.liquidity = LiquidityMath.addDelta(self.liquidity, liquidityDelta);
            } else {
                principalDelta = toBalanceDelta(
                    0,
                    SqrtPriceMath
                        .getAmount1Delta(
                            TickMath.getSqrtPriceAtTick(tickLower),
                            TickMath.getSqrtPriceAtTick(tickUpper),
                            liquidityDelta
                        )
                        .toInt128()
                );
            }
        } else {
            principalDelta = toBalanceDelta(0, 0);
        }

        callerDelta = principalDelta + fees;
        feesAccrued = fees;
        _accountDeltas(key, callerDelta, msg.sender);
        emit ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);
    }

    /// @notice Execute a swap in a pool
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (BalanceDelta delta) {
        require(_unlocked, "Manager locked");
        PoolId id = key.toId();
        PoolState storage pool = _poolStates[id];
        _checkPoolInitialized(pool);

        SwapParamsInternal memory paramsInternal = SwapParamsInternal({
            tickSpacing: key.tickSpacing,
            zeroForOne: params.zeroForOne,
            amountSpecified: params.amountSpecified,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            lpFeeOverride: 0
        });

        require(paramsInternal.amountSpecified != 0, "Amount cannot be zero");

        bool zeroForOne = paramsInternal.zeroForOne;
        bool exactInput = paramsInternal.amountSpecified < 0;
        uint160 sqrtPriceX96 = pool.slot0.sqrtPriceX96;
        uint128 liquidity = pool.liquidity;

        // Simplified swap (no iteration through ticks)
        uint160 sqrtPriceX96Next;
        uint256 amountIn;
        uint256 amountOut;

        if (exactInput) {
            // Exact input swap
            uint256 amountSpecifiedAbs = uint256(-paramsInternal.amountSpecified);
            sqrtPriceX96Next = zeroForOne
                ? SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountSpecifiedAbs, zeroForOne)
                : SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountSpecifiedAbs, zeroForOne);

            amountIn = amountSpecifiedAbs;

            if (zeroForOne) {
                amountOut = SqrtPriceMath.getAmount1Delta(sqrtPriceX96Next, sqrtPriceX96, liquidity, false);
            } else {
                amountOut = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceX96Next, liquidity, false);
            }
        } else {
            // Exact output swap
            uint256 amountSpecifiedAbs = uint256(paramsInternal.amountSpecified);
            sqrtPriceX96Next = zeroForOne
                ? SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtPriceX96, liquidity, amountSpecifiedAbs, zeroForOne)
                : SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtPriceX96, liquidity, amountSpecifiedAbs, zeroForOne);

            amountOut = amountSpecifiedAbs;

            if (zeroForOne) {
                amountIn = SqrtPriceMath.getAmount0Delta(sqrtPriceX96Next, sqrtPriceX96, liquidity, true);
            } else {
                amountIn = SqrtPriceMath.getAmount1Delta(sqrtPriceX96, sqrtPriceX96Next, liquidity, true);
            }
        }

        // Calculate deltas
        int128 amount0Delta;
        int128 amount1Delta;
        if (zeroForOne) {
            amount0Delta = int128(int256(amountIn));
            amount1Delta = -int128(int256(amountOut));
        } else {
            amount0Delta = -int128(int256(amountOut));
            amount1Delta = int128(int256(amountIn));
        }

        delta = toBalanceDelta(amount0Delta, amount1Delta);

        // Update pool state
        pool.slot0.sqrtPriceX96 = sqrtPriceX96Next;
        pool.slot0.tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96Next);

        _accountDeltas(key, delta, msg.sender);
        emit Swap(
            id,
            msg.sender,
            delta.amount0(),
            delta.amount1(),
            pool.slot0.sqrtPriceX96,
            pool.liquidity,
            pool.slot0.tick,
            0
        );
    }

    /// @notice Donate tokens to a pool
    function donate(
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) external returns (BalanceDelta delta) {
        require(_unlocked, "Manager locked");
        PoolId id = key.toId();
        PoolState storage pool = _poolStates[id];
        _checkPoolInitialized(pool);

        uint128 liquidity = pool.liquidity;
        require(liquidity > 0, "No liquidity to receive fees");

        // Update fee growth
        unchecked {
            if (amount0 > 0) {
                pool.feeGrowthGlobal0X128 += UnsafeMath.simpleMulDiv(amount0, FixedPoint128.Q128, liquidity);
            }
            if (amount1 > 0) {
                pool.feeGrowthGlobal1X128 += UnsafeMath.simpleMulDiv(amount1, FixedPoint128.Q128, liquidity);
            }
        }

        delta = toBalanceDelta(-int128(uint128(amount0)), -int128(uint128(amount1)));
        _accountDeltas(key, delta, msg.sender);
        emit Donate(id, msg.sender, amount0, amount1);
    }

    // Token operations (ERC6909-like)

    /// @notice Mint tokens (settle negative delta)
    function mint(address to, uint256 id, uint256 amount) external {
        require(_unlocked, "Manager locked");
        _accountDelta(Currency.wrap(address(uint160(id))), -int128(uint128(amount)), msg.sender);
        _tokenBalances[to][id] += amount;
        emit Transfer(msg.sender, address(0), to, id, amount);
    }

    /// @notice Burn tokens (settle positive delta)
    function burn(address from, uint256 id, uint256 amount) external {
        require(_unlocked, "Manager locked");
        _accountDelta(Currency.wrap(address(uint160(id))), int128(uint128(amount)), msg.sender);
        _tokenBalances[from][id] -= amount;
        emit Transfer(msg.sender, from, address(0), id, amount);
    }

    /// @notice Settle with native currency
    function settle() external payable returns (uint256 paid) {
        require(_unlocked, "Manager locked");
        paid = msg.value;
        if (paid > 0) _accountDelta(Currency.wrap(address(0)), int128(uint128(paid)), msg.sender);
    }

    /// @notice Sync currency state (no-op for mock)
    function sync(Currency) external {
        // No-op for simplified mock
    }

    // View functions

    /// @notice Get current price and tick for a pool
    function getSlot0(
        PoolId id
    ) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) {
        Slot0 memory slot0 = _poolStates[id].slot0;
        return (slot0.sqrtPriceX96, slot0.tick, slot0.protocolFee, slot0.lpFee);
    }

    /// @notice Get tick information for a pool
    function getTickInfo(
        PoolId id,
        int24 tick
    )
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128
        )
    {
        TickInfo memory info = _poolStates[id].ticks[tick];
        return (info.liquidityGross, info.liquidityNet, info.feeGrowthOutside0X128, info.feeGrowthOutside1X128);
    }

    /// @notice Get tick bitmap for a pool
    function getTickBitmap(PoolId id, int16 word) external view returns (uint256) {
        return _poolStates[id].tickBitmap[word];
    }

    // Internal pool logic (was in PoolMock)

    /// @dev Check that a pool has been initialized
    function _checkPoolInitialized(PoolState storage self) private view {
        require(self.slot0.sqrtPriceX96 != 0, "Pool not initialized");
    }

    /// @dev Helper to update tick info
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick
    function _updateTick(PoolState storage self, int24 tick, int128 liquidityDelta, bool upper) private {
        TickInfo storage info = self.ticks[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        int128 liquidityNetBefore = info.liquidityNet;

        uint128 liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);

        if (liquidityGrossBefore == 0) {
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            if (tick <= self.slot0.tick) {
                info.feeGrowthOutside0X128 = self.feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = self.feeGrowthGlobal1X128;
            }
        }

        // when the lower (upper) tick is crossed left to right, liquidity must be added (removed)
        // when the lower (upper) tick is crossed right to left, liquidity must be removed (added)
        int128 liquidityNet = upper ? liquidityNetBefore - liquidityDelta : liquidityNetBefore + liquidityDelta;

        // Update liquidityGross and liquidityNet
        info.liquidityGross = liquidityGrossAfter;
        info.liquidityNet = liquidityNet;
    }

    // Internal helpers

    /// @dev Account a single currency delta
    function _accountDelta(Currency currency, int128 delta, address target) internal {
        if (delta != 0) _deltas[currency][target] += delta;
    }

    /// @dev Account deltas for both currencies in a pool
    function _accountDeltas(PoolKey memory key, BalanceDelta delta, address target) internal {
        _accountDelta(key.currency0, delta.amount0(), target);
        _accountDelta(key.currency1, delta.amount1(), target);
    }
}
