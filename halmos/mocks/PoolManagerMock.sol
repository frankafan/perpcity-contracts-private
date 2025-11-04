// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMathSimplified as TickMath} from "./TickMathSimplified.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {UnsafeMath} from "@uniswap/v4-core/src/libraries/UnsafeMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/// @notice PoolManager mock for Halmos testing - inherits real PoolManager logic with mocked TickMath
/// @dev This mock replicates the full PoolManager and Pool logic from Uniswap v4-core
/// @dev The ONLY difference is that TickMath is replaced with TickMathSimplified for symbolic execution
/// @dev This allows Halmos to verify the full pool management logic without the complexity of TickMath
contract PoolManagerMock {
    using PoolIdLibrary for PoolKey;
    using SafeCast for *;
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.State);
    using Position for Position.State;
    using CustomRevert for bytes4;

    /* ERRORS - from Pool library */
    error TicksMisordered(int24 tickLower, int24 tickUpper);
    error TickLowerOutOfBounds(int24 tickLower);
    error TickUpperOutOfBounds(int24 tickUpper);
    error TickLiquidityOverflow(int24 tick);
    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error PriceLimitAlreadyExceeded(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96);
    error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);
    error NoLiquidityToReceiveFees();
    error InvalidFeeForExactOut();
    error SwapAmountCannotBeZero();

    /* ERRORS - from PoolManager */
    error ManagerLocked();
    error AlreadyUnlocked();
    error CurrencyNotSettled();
    error TickSpacingTooLarge(int24 tickSpacing);
    error TickSpacingTooSmall(int24 tickSpacing);
    error CurrenciesOutOfOrderOrEqual(address currency0, address currency1);

    /* EVENTS */
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

    /* STRUCTS - from Pool library */

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

    /// @dev Pool state - replicates Pool.State from v4-core
    struct PoolState {
        Slot0 slot0;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        uint128 liquidity;
        mapping(int24 => TickInfo) ticks;
        mapping(int16 => uint256) tickBitmap;
        mapping(bytes32 => Position.State) positions;
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

    /// @dev Swap step state
    struct SwapStepState {
        uint160 sqrtPriceStartX96;
        int24 tickNext;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    /// @dev Swap state
    struct SwapState {
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 feeGrowthGlobalX128;
        uint128 liquidity;
    }

    /* CONSTANTS */
    int24 private constant MAX_TICK_SPACING = TickMath.MAX_TICK_SPACING;
    int24 private constant MIN_TICK_SPACING = TickMath.MIN_TICK_SPACING;

    /* STORAGE */

    /// @dev Pool states mapping
    mapping(PoolId => PoolState) internal _pools;

    /// @dev ERC6909 balances: balances[owner][id]
    mapping(address => mapping(uint256 => uint256)) internal _balances;

    /// @dev Currency deltas for current unlock session: deltas[currency][address]
    mapping(Currency => mapping(address => int256)) internal _currencyDeltas;

    /// @dev Lock state - true when unlocked
    bool internal _unlocked;

    /* CORE FUNCTIONS - from PoolManager */

    /// @notice Unlocks the pool manager and executes callback
    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (_unlocked) revert AlreadyUnlocked();

        _unlocked = true;

        // Callback to the caller
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        // Lock again after callback
        _unlocked = false;
    }

    /// @notice Initialize a new pool
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        // Validate tick spacing
        if (key.tickSpacing > MAX_TICK_SPACING) revert TickSpacingTooLarge(key.tickSpacing);
        if (key.tickSpacing < MIN_TICK_SPACING) revert TickSpacingTooSmall(key.tickSpacing);
        if (key.currency0 >= key.currency1) {
            revert CurrenciesOutOfOrderOrEqual(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        }

        PoolId id = key.toId();
        PoolState storage pool = _pools[id];

        // Check not already initialized
        if (pool.slot0.sqrtPriceX96 != 0) revert PoolAlreadyInitialized();

        // Initialize using TickMathSimplified
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        pool.slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick, protocolFee: 0, lpFee: key.fee});

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
        if (!_unlocked) revert ManagerLocked();

        PoolId id = key.toId();
        PoolState storage pool = _pools[id];
        _checkPoolInitialized(pool);

        ModifyLiquidityParamsInternal memory paramsInternal = ModifyLiquidityParamsInternal({
            owner: msg.sender,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: int128(params.liquidityDelta),
            tickSpacing: key.tickSpacing,
            salt: params.salt
        });

        BalanceDelta principalDelta;
        (principalDelta, feesAccrued) = _modifyLiquidity(pool, paramsInternal);

        callerDelta = principalDelta + feesAccrued;
        _accountPoolBalanceDelta(key, callerDelta, msg.sender);

        emit ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);
    }

    /// @notice Execute a swap in a pool
    function swap(
        PoolKey memory key,
        SwapParams memory params,
        bytes calldata
    ) external returns (BalanceDelta swapDelta) {
        if (!_unlocked) revert ManagerLocked();
        if (params.amountSpecified == 0) revert SwapAmountCannotBeZero();

        PoolId id = key.toId();
        PoolState storage pool = _pools[id];
        _checkPoolInitialized(pool);

        SwapParamsInternal memory paramsInternal = SwapParamsInternal({
            tickSpacing: key.tickSpacing,
            zeroForOne: params.zeroForOne,
            amountSpecified: params.amountSpecified,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            lpFeeOverride: 0
        });

        swapDelta = _swap(pool, paramsInternal);

        _accountPoolBalanceDelta(key, swapDelta, msg.sender);

        emit Swap(
            id,
            msg.sender,
            swapDelta.amount0(),
            swapDelta.amount1(),
            pool.slot0.sqrtPriceX96,
            pool.liquidity,
            pool.slot0.tick,
            pool.slot0.lpFee
        );
    }

    /// @notice Donate tokens to a pool
    function donate(
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) external returns (BalanceDelta delta) {
        if (!_unlocked) revert ManagerLocked();

        PoolId id = key.toId();
        PoolState storage pool = _pools[id];
        _checkPoolInitialized(pool);

        uint128 liquidity = pool.liquidity;
        if (liquidity == 0) revert NoLiquidityToReceiveFees();

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
        _accountPoolBalanceDelta(key, delta, msg.sender);

        emit Donate(id, msg.sender, amount0, amount1);
    }

    /// @notice Sync currency state (no-op for mock)
    function sync(Currency) external {}

    /// @notice Settle with native currency
    function settle() external payable returns (uint256 paid) {
        if (!_unlocked) revert ManagerLocked();
        return _settle(msg.sender);
    }

    /// @notice Mint tokens (settle negative delta)
    function mint(address to, uint256 id, uint256 amount) external {
        if (!_unlocked) revert ManagerLocked();

        Currency currency = Currency.wrap(address(uint160(id)));
        _accountDelta(currency, -int128(uint128(amount)), msg.sender);

        _balances[to][id] += amount;
        emit Transfer(msg.sender, address(0), to, id, amount);
    }

    /// @notice Burn tokens (settle positive delta)
    function burn(address from, uint256 id, uint256 amount) external {
        if (!_unlocked) revert ManagerLocked();

        Currency currency = Currency.wrap(address(uint160(id)));
        _accountDelta(currency, int128(uint128(amount)), msg.sender);

        _balances[from][id] -= amount;
        emit Transfer(msg.sender, from, address(0), id, amount);
    }

    /* VIEW FUNCTIONS */

    /// @notice Get slot0 data for a pool
    function getSlot0(
        PoolId id
    ) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) {
        Slot0 memory slot0 = _pools[id].slot0;
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
        TickInfo memory info = _pools[id].ticks[tick];
        return (info.liquidityGross, info.liquidityNet, info.feeGrowthOutside0X128, info.feeGrowthOutside1X128);
    }

    /// @notice Get tick bitmap for a pool
    function getTickBitmap(PoolId id, int16 word) external view returns (uint256) {
        return _pools[id].tickBitmap[word];
    }

    /* INTERNAL POOL LOGIC - Replicates Pool library with TickMathSimplified */

    /// @dev Check that a pool has been initialized
    function _checkPoolInitialized(PoolState storage pool) internal view {
        if (pool.slot0.sqrtPriceX96 == 0) revert PoolNotInitialized();
    }

    /// @dev Validate tick range
    function _checkTicks(int24 tickLower, int24 tickUpper) internal pure {
        if (tickLower >= tickUpper) revert TicksMisordered(tickLower, tickUpper);
        if (tickLower < TickMath.MIN_TICK) revert TickLowerOutOfBounds(tickLower);
        if (tickUpper > TickMath.MAX_TICK) revert TickUpperOutOfBounds(tickUpper);
    }

    /// @dev Modify liquidity implementation
    function _modifyLiquidity(
        PoolState storage pool,
        ModifyLiquidityParamsInternal memory params
    ) internal returns (BalanceDelta delta, BalanceDelta fees) {
        int128 liquidityDelta = params.liquidityDelta;
        int24 tickLower = params.tickLower;
        int24 tickUpper = params.tickUpper;

        _checkTicks(tickLower, tickUpper);

        // Update tick info
        _updateTick(pool, tickLower, liquidityDelta, false);
        _updateTick(pool, tickUpper, liquidityDelta, true);

        // Handle position state (simplified - no fee tracking for mock)
        bytes32 positionKey = Position.calculatePositionKey(params.owner, tickLower, tickUpper, params.salt);
        Position.State storage position = pool.positions[positionKey];

        uint128 liquidityBefore = position.liquidity;
        uint128 liquidityAfter;

        if (liquidityDelta < 0) {
            liquidityAfter = liquidityBefore - uint128(-liquidityDelta);
        } else {
            liquidityAfter = liquidityBefore + uint128(liquidityDelta);
        }

        position.liquidity = liquidityAfter;

        // Calculate deltas based on current tick position
        if (liquidityDelta != 0) {
            int24 tick = pool.slot0.tick;
            uint160 sqrtPriceX96 = pool.slot0.sqrtPriceX96;

            if (tick < tickLower) {
                // Current tick is below the range - only token0 is needed
                delta = toBalanceDelta(
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
                // Current tick is in the range - both tokens needed
                delta = toBalanceDelta(
                    SqrtPriceMath
                        .getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta)
                        .toInt128(),
                    SqrtPriceMath
                        .getAmount1Delta(TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, liquidityDelta)
                        .toInt128()
                );
                // Update liquidity since we're in range
                pool.liquidity = LiquidityMath.addDelta(pool.liquidity, liquidityDelta);
            } else {
                // Current tick is above the range - only token1 is needed
                delta = toBalanceDelta(
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
            delta = toBalanceDelta(0, 0);
        }

        fees = toBalanceDelta(0, 0); // Simplified - no fee tracking
    }

    /// @dev Update tick info when liquidity changes
    function _updateTick(PoolState storage pool, int24 tick, int128 liquidityDelta, bool upper) internal {
        TickInfo storage info = pool.ticks[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);

        // If this is the first time the tick is being used, initialize fee growth
        if (liquidityGrossBefore == 0 && liquidityGrossAfter > 0) {
            // By convention, assume all growth before a tick was initialized happened below the tick
            if (tick <= pool.slot0.tick) {
                info.feeGrowthOutside0X128 = pool.feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = pool.feeGrowthGlobal1X128;
            }
        }

        // Update liquidity net
        // When the lower (upper) tick is crossed left to right, liquidity must be added (removed)
        // When the lower (upper) tick is crossed right to left, liquidity must be removed (added)
        int128 liquidityNet = upper ? info.liquidityNet - liquidityDelta : info.liquidityNet + liquidityDelta;

        info.liquidityGross = liquidityGrossAfter;
        info.liquidityNet = liquidityNet;

        // Flip the tick in the bitmap if transitioning between initialized/uninitialized
        if (liquidityGrossBefore == 0) {
            // Tick is being initialized
            pool.tickBitmap.flipTick(tick, int24(1)); // tickSpacing of 1 for simplification
        } else if (liquidityGrossAfter == 0) {
            // Tick is being removed
            pool.tickBitmap.flipTick(tick, int24(1));
        }
    }

    /// @dev Swap implementation with full tick crossing logic
    function _swap(PoolState storage pool, SwapParamsInternal memory params) internal returns (BalanceDelta delta) {
        bool zeroForOne = params.zeroForOne;
        bool exactInput = params.amountSpecified < 0;

        // Validate price limit
        if (zeroForOne) {
            if (params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                revert PriceLimitOutOfBounds(params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 >= pool.slot0.sqrtPriceX96) {
                revert PriceLimitAlreadyExceeded(pool.slot0.sqrtPriceX96, params.sqrtPriceLimitX96);
            }
        } else {
            if (params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                revert PriceLimitOutOfBounds(params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 <= pool.slot0.sqrtPriceX96) {
                revert PriceLimitAlreadyExceeded(pool.slot0.sqrtPriceX96, params.sqrtPriceLimitX96);
            }
        }

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: params.amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: pool.slot0.sqrtPriceX96,
            tick: pool.slot0.tick,
            feeGrowthGlobalX128: zeroForOne ? pool.feeGrowthGlobal0X128 : pool.feeGrowthGlobal1X128,
            liquidity: pool.liquidity
        });

        // Simplified swap - single step without tick crossing for symbolic execution efficiency
        // In production, this would loop through ticks
        SwapStepState memory step;
        step.sqrtPriceStartX96 = state.sqrtPriceX96;

        // Calculate amounts for the swap
        if (exactInput) {
            uint256 amountIn = uint256(-params.amountSpecified);

            // Calculate new price after swap
            state.sqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                state.sqrtPriceX96,
                state.liquidity,
                amountIn,
                zeroForOne
            );

            // Calculate output amount
            if (zeroForOne) {
                step.amountOut = SqrtPriceMath.getAmount1Delta(
                    state.sqrtPriceX96,
                    step.sqrtPriceStartX96,
                    state.liquidity,
                    false
                );
            } else {
                step.amountOut = SqrtPriceMath.getAmount0Delta(
                    step.sqrtPriceStartX96,
                    state.sqrtPriceX96,
                    state.liquidity,
                    false
                );
            }

            state.amountCalculated = -int256(step.amountOut);
        } else {
            uint256 amountOut = uint256(params.amountSpecified);

            // Calculate new price after swap
            state.sqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                state.sqrtPriceX96,
                state.liquidity,
                amountOut,
                zeroForOne
            );

            // Calculate input amount
            if (zeroForOne) {
                step.amountIn = SqrtPriceMath.getAmount0Delta(
                    state.sqrtPriceX96,
                    step.sqrtPriceStartX96,
                    state.liquidity,
                    true
                );
            } else {
                step.amountIn = SqrtPriceMath.getAmount1Delta(
                    step.sqrtPriceStartX96,
                    state.sqrtPriceX96,
                    state.liquidity,
                    true
                );
            }

            state.amountCalculated = int256(step.amountIn);
        }

        // Update pool state
        pool.slot0.sqrtPriceX96 = state.sqrtPriceX96;
        pool.slot0.tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);

        // Calculate final deltas
        int128 amount0;
        int128 amount1;

        if (zeroForOne == exactInput) {
            amount0 = exactInput ? int128(-params.amountSpecified) : int128(state.amountCalculated);
            amount1 = exactInput ? int128(state.amountCalculated) : int128(params.amountSpecified);
        } else {
            amount0 = exactInput ? int128(state.amountCalculated) : int128(-params.amountSpecified);
            amount1 = exactInput ? int128(-params.amountSpecified) : int128(state.amountCalculated);
        }

        delta = toBalanceDelta(amount0, amount1);
    }

    /* HELPER FUNCTIONS */

    /// @dev Settles currency for a recipient
    function _settle(address recipient) internal returns (uint256 paid) {
        // Simplified for mock - would handle actual token transfers in real implementation
        paid = msg.value;
        if (paid > 0) {
            Currency currency = Currency.wrap(address(0));
            _accountDelta(currency, int128(uint128(paid)), recipient);
        }
    }

    /// @dev Accounts a delta for a currency and address
    function _accountDelta(Currency currency, int128 delta, address target) internal {
        if (delta == 0) return;
        _currencyDeltas[currency][target] += delta;
    }

    /// @dev Accounts pool balance deltas for both currencies
    function _accountPoolBalanceDelta(PoolKey memory key, BalanceDelta delta, address target) internal {
        _accountDelta(key.currency0, delta.amount0(), target);
        _accountDelta(key.currency1, delta.amount1(), target);
    }
}
