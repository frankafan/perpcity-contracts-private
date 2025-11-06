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

    /// @dev State for modifyLiquidity operation
    struct ModifyLiquidityState {
        bool flippedLower;
        uint128 liquidityGrossAfterLower;
        bool flippedUpper;
        uint128 liquidityGrossAfterUpper;
    }

    /// @dev Parameters for internal swap
    struct SwapParamsInternal {
        int24 tickSpacing;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        uint128 lpFeeOverride;
    }

    /// @dev Swap step state (matching Pool.sol StepComputations)
    struct SwapStepState {
        uint160 sqrtPriceStartX96;
        int24 tickNext;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
        uint256 feeGrowthGlobalX128;
    }

    /// @dev Tracks the state of a pool throughout a swap, and returns these values at the end of the swap
    struct SwapResult {
        // the current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the current liquidity in range
        uint128 liquidity;
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

    /// @dev Count of nonzero deltas - used for flash accounting validation
    uint256 internal _nonzeroDeltaCount;

    /// @dev The currency that has been synced (for settle() to know which currency to settle)
    Currency internal _syncedCurrency;

    /* CORE FUNCTIONS - from PoolManager */

    /// @notice Unlocks the pool manager and executes callback
    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (_unlocked) revert AlreadyUnlocked();

        _unlocked = true;

        // Callback to the caller
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        // Ensure all deltas are settled before locking
        if (_nonzeroDeltaCount != 0) revert CurrencyNotSettled();

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

        // Validate sqrtPriceX96 bounds
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
            revert PriceLimitOutOfBounds(sqrtPriceX96);
        }

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

    /// @notice Sync currency state
    function sync(Currency currency) external {
        if (!_unlocked) revert ManagerLocked();
        _syncedCurrency = currency;
    }

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

    /// @notice Get the balance of an account for a token (ERC6909)
    /// @param owner The address to query the balance of
    /// @param id The token ID (currency address as uint256)
    /// @return The balance of the account
    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        return _balances[owner][id];
    }

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

    /// @notice Derives max liquidity per tick from given tick spacing
    /// @dev Executed when adding liquidity
    /// @param tickSpacing The amount of required tick separation, realized in multiples of `tickSpacing`
    ///     e.g., a tickSpacing of 3 requires ticks to be initialized every 3rd tick i.e., ..., -6, -3, 0, 3, 6, ...
    /// @return result The max liquidity per tick
    function _tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128 result) {
        // Equivalent to:
        // int24 minTick = (TickMath.MIN_TICK / tickSpacing);
        // if (TickMath.MIN_TICK  % tickSpacing != 0) minTick--;
        // int24 maxTick = (TickMath.MAX_TICK / tickSpacing);
        // uint24 numTicks = maxTick - minTick + 1;
        // return type(uint128).max / numTicks;
        int24 MAX_TICK = TickMath.MAX_TICK;
        int24 MIN_TICK = TickMath.MIN_TICK;
        // tick spacing will never be 0 since TickMath.MIN_TICK_SPACING is 1
        assembly ("memory-safe") {
            tickSpacing := signextend(2, tickSpacing)
            let minTick := sub(sdiv(MIN_TICK, tickSpacing), slt(smod(MIN_TICK, tickSpacing), 0))
            let maxTick := sdiv(MAX_TICK, tickSpacing)
            let numTicks := add(sub(maxTick, minTick), 1)
            result := div(sub(shl(128, 1), 1), numTicks)
        }
    }

    /// @dev Clears tick data
    /// @param pool The Pool state struct
    /// @param tick The tick that will be cleared
    function _clearTick(PoolState storage pool, int24 tick) internal {
        delete pool.ticks[tick];
    }

    /// @notice Effect changes to a position in a pool
    /// @dev PoolManager checks that the pool is initialized before calling
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return delta the deltas of the token balances of the pool, from the liquidity change
    /// @return feeDelta the fees generated by the liquidity range (always zero in mock)
    function _modifyLiquidity(
        PoolState storage pool,
        ModifyLiquidityParamsInternal memory params
    ) internal returns (BalanceDelta delta, BalanceDelta feeDelta) {
        int128 liquidityDelta = params.liquidityDelta;
        int24 tickLower = params.tickLower;
        int24 tickUpper = params.tickUpper;
        _checkTicks(tickLower, tickUpper);

        {
            ModifyLiquidityState memory state;

            // if we need to update the ticks, do it
            if (liquidityDelta != 0) {
                (state.flippedLower, state.liquidityGrossAfterLower) = _updateTick(
                    pool,
                    tickLower,
                    liquidityDelta,
                    false
                );
                (state.flippedUpper, state.liquidityGrossAfterUpper) = _updateTick(
                    pool,
                    tickUpper,
                    liquidityDelta,
                    true
                );

                // `>` and `>=` are logically equivalent here but `>=` is cheaper
                if (liquidityDelta >= 0) {
                    uint128 maxLiquidityPerTick = _tickSpacingToMaxLiquidityPerTick(params.tickSpacing);
                    if (state.liquidityGrossAfterLower > maxLiquidityPerTick) {
                        revert TickLiquidityOverflow(tickLower);
                    }
                    if (state.liquidityGrossAfterUpper > maxLiquidityPerTick) {
                        revert TickLiquidityOverflow(tickUpper);
                    }
                }

                if (state.flippedLower) {
                    pool.tickBitmap.flipTick(tickLower, params.tickSpacing);
                }
                if (state.flippedUpper) {
                    pool.tickBitmap.flipTick(tickUpper, params.tickSpacing);
                }
            }

            {
                // SIMPLIFIED: No fee growth tracking in mock
                // In original Pool.sol:
                //   (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
                //       getFeeGrowthInside(self, tickLower, tickUpper);
                //   Position.State storage position = self.positions.get(params.owner, tickLower, tickUpper, params.salt);
                //   (uint256 feesOwed0, uint256 feesOwed1) =
                //       position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

                Position.State storage position = pool.positions.get(params.owner, tickLower, tickUpper, params.salt);

                // Update position liquidity (without fee calculations)
                uint128 liquidityBefore = position.liquidity;
                uint128 liquidityAfter;

                if (liquidityDelta < 0) {
                    liquidityAfter = liquidityBefore - uint128(-liquidityDelta);
                } else {
                    liquidityAfter = liquidityBefore + uint128(liquidityDelta);
                }

                position.liquidity = liquidityAfter;

                // Fees earned from LPing are calculated, and returned (SIMPLIFIED: always zero in mock)
                feeDelta = toBalanceDelta(0, 0);
            }

            // clear any tick data that is no longer needed
            if (liquidityDelta < 0) {
                if (state.flippedLower) {
                    _clearTick(pool, tickLower);
                }
                if (state.flippedUpper) {
                    _clearTick(pool, tickUpper);
                }
            }
        }

        if (liquidityDelta != 0) {
            Slot0 memory _slot0 = pool.slot0;
            int24 tick = _slot0.tick;
            uint160 sqrtPriceX96 = _slot0.sqrtPriceX96;

            if (tick < tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ currency0 (it's becoming more valuable) so user must provide it
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
                delta = toBalanceDelta(
                    SqrtPriceMath
                        .getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta)
                        .toInt128(),
                    SqrtPriceMath
                        .getAmount1Delta(TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, liquidityDelta)
                        .toInt128()
                );

                pool.liquidity = LiquidityMath.addDelta(pool.liquidity, liquidityDelta);
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ currency1 (it's becoming more valuable) so user must provide it
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
        }
    }

    /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// @param pool The Pool state struct
    /// @param tick The tick that will be updated
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa
    /// @return liquidityGrossAfter The total amount of liquidity for all positions that references the tick after the update
    function _updateTick(
        PoolState storage pool,
        int24 tick,
        int128 liquidityDelta,
        bool upper
    ) internal returns (bool flipped, uint128 liquidityGrossAfter) {
        TickInfo storage info = pool.ticks[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        int128 liquidityNetBefore = info.liquidityNet;

        liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            if (tick <= pool.slot0.tick) {
                info.feeGrowthOutside0X128 = pool.feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = pool.feeGrowthGlobal1X128;
            }
        }

        // when the lower (upper) tick is crossed left to right, liquidity must be added (removed)
        // when the lower (upper) tick is crossed right to left, liquidity must be removed (added)
        int128 liquidityNet = upper ? liquidityNetBefore - liquidityDelta : liquidityNetBefore + liquidityDelta;

        info.liquidityGross = liquidityGrossAfter;
        info.liquidityNet = liquidityNet;
    }

    /// @notice Executes a swap against the state (SIMPLIFIED - matches Pool.sol structure but without tick crossing loop)
    /// @dev Structure matches Pool.sol for easier comparison despite simplifications
    /// @param params Swap parameters matching Pool.SwapParams structure
    /// @return swapDelta The balance delta from the swap
    function _swap(PoolState storage pool, SwapParamsInternal memory params) internal returns (BalanceDelta swapDelta) {
        Slot0 memory slot0Start = pool.slot0;
        bool zeroForOne = params.zeroForOne;

        // SIMPLIFIED: No protocol fee tracking
        // In original: protocolFee = zeroForOne ? slot0Start.protocolFee().getZeroForOneFee() : ...

        // the amount remaining to be swapped in/out of the input/output asset. initially set to the amountSpecified
        int256 amountSpecifiedRemaining = params.amountSpecified;
        // the amount swapped out/in of the output/input asset. initially set to 0
        int256 amountCalculated = 0;

        // Initialize result state to current pool state
        SwapResult memory result;
        result.sqrtPriceX96 = slot0Start.sqrtPriceX96;
        result.tick = slot0Start.tick;
        result.liquidity = pool.liquidity;

        // SIMPLIFIED: No fee override, no swapFee calculation
        // In original:
        //   uint24 lpFee = params.lpFeeOverride.isOverride() ? ... : slot0Start.lpFee();
        //   swapFee = protocolFee == 0 ? lpFee : uint16(protocolFee).calculateSwapFee(lpFee);
        //   if (swapFee >= SwapMath.MAX_SWAP_FEE && params.amountSpecified > 0) revert InvalidFeeForExactOut();

        // Price limit validation (matching Pool.sol lines 322-338)
        if (zeroForOne) {
            if (params.sqrtPriceLimitX96 >= slot0Start.sqrtPriceX96) {
                revert PriceLimitAlreadyExceeded(slot0Start.sqrtPriceX96, params.sqrtPriceLimitX96);
            }
            // Swaps can never occur at MIN_TICK, only at MIN_TICK + 1
            if (params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                revert PriceLimitOutOfBounds(params.sqrtPriceLimitX96);
            }
        } else {
            if (params.sqrtPriceLimitX96 <= slot0Start.sqrtPriceX96) {
                revert PriceLimitAlreadyExceeded(slot0Start.sqrtPriceX96, params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                revert PriceLimitOutOfBounds(params.sqrtPriceLimitX96);
            }
        }

        SwapStepState memory step;
        step.feeGrowthGlobalX128 = zeroForOne ? pool.feeGrowthGlobal0X128 : pool.feeGrowthGlobal1X128;

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (!(amountSpecifiedRemaining == 0 || result.sqrtPriceX96 == params.sqrtPriceLimitX96)) {
            step.sqrtPriceStartX96 = result.sqrtPriceX96;

            // SIMPLIFIED: Skip tick bitmap search, use current tick as next tick (no tick crossing)
            // In original:
            //   (step.tickNext, step.initialized) = self.tickBitmap.nextInitializedTickWithinOneWord(...)
            //   if (step.tickNext <= TickMath.MIN_TICK) step.tickNext = TickMath.MIN_TICK;
            //   if (step.tickNext >= TickMath.MAX_TICK) step.tickNext = TickMath.MAX_TICK;
            //   step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // SIMPLIFIED: Use price limit as the target price (no intermediate ticks)
            step.sqrtPriceNextX96 = params.sqrtPriceLimitX96;

            // SIMPLIFIED: Direct calculation instead of SwapMath.computeSwapStep
            // In original:
            //   (result.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) =
            //       SwapMath.computeSwapStep(
            //           result.sqrtPriceX96,
            //           SwapMath.getSqrtPriceTarget(zeroForOne, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
            //           result.liquidity,
            //           amountSpecifiedRemaining,
            //           swapFee
            //       );

            // Direct price and amount calculation without fees
            // if exactOutput
            if (params.amountSpecified > 0) {
                step.amountOut = uint256(amountSpecifiedRemaining);

                // Calculate new price after swap (no fees)
                result.sqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                    result.sqrtPriceX96,
                    result.liquidity,
                    step.amountOut,
                    zeroForOne
                );

                // Calculate input amount
                if (zeroForOne) {
                    step.amountIn = SqrtPriceMath.getAmount0Delta(
                        result.sqrtPriceX96,
                        step.sqrtPriceStartX96,
                        result.liquidity,
                        true
                    );
                } else {
                    step.amountIn = SqrtPriceMath.getAmount1Delta(
                        step.sqrtPriceStartX96,
                        result.sqrtPriceX96,
                        result.liquidity,
                        true
                    );
                }

                step.feeAmount = 0; // SIMPLIFIED: No fees

                unchecked {
                    amountSpecifiedRemaining -= step.amountOut.toInt256();
                }
                amountCalculated -= (step.amountIn + step.feeAmount).toInt256();
            } else {
                // exactInput
                step.amountIn = uint256(-amountSpecifiedRemaining);

                // Calculate new price after swap (no fees)
                result.sqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    result.sqrtPriceX96,
                    result.liquidity,
                    step.amountIn,
                    zeroForOne
                );

                // Calculate output amount
                if (zeroForOne) {
                    step.amountOut = SqrtPriceMath.getAmount1Delta(
                        result.sqrtPriceX96,
                        step.sqrtPriceStartX96,
                        result.liquidity,
                        false
                    );
                } else {
                    step.amountOut = SqrtPriceMath.getAmount0Delta(
                        step.sqrtPriceStartX96,
                        result.sqrtPriceX96,
                        result.liquidity,
                        false
                    );
                }

                step.feeAmount = 0; // SIMPLIFIED: No fees

                unchecked {
                    amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                }
                amountCalculated += step.amountOut.toInt256();
            }

            // SIMPLIFIED: No protocol fee split
            // In original:
            //   if (protocolFee > 0) {
            //       uint256 delta = (swapFee == protocolFee) ? step.feeAmount : (step.amountIn + step.feeAmount) * protocolFee / PIPS_DENOMINATOR;
            //       step.feeAmount -= delta;
            //       amountToProtocol += delta;
            //   }

            // SIMPLIFIED: No fee growth update
            // In original:
            //   if (result.liquidity > 0) {
            //       step.feeGrowthGlobalX128 += UnsafeMath.simpleMulDiv(step.feeAmount, FixedPoint128.Q128, result.liquidity);
            //   }

            // SIMPLIFIED: No tick crossing since we consume all remaining amount in one step
            // In original:
            //   if (result.sqrtPriceX96 == step.sqrtPriceNextX96) {
            //       if (step.initialized) {
            //           (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = ...
            //           int128 liquidityNet = Pool.crossTick(self, step.tickNext, feeGrowthGlobal0X128, feeGrowthGlobal1X128);
            //           if (zeroForOne) liquidityNet = -liquidityNet;
            //           result.liquidity = LiquidityMath.addDelta(result.liquidity, liquidityNet);
            //       }
            //       result.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            //   } else if (result.sqrtPriceX96 != step.sqrtPriceStartX96) {
            //       result.tick = TickMath.getTickAtSqrtPrice(result.sqrtPriceX96);
            //   }

            // Update tick based on final price (recompute unless we're on a lower tick boundary and haven't moved)
            if (result.sqrtPriceX96 != step.sqrtPriceStartX96) {
                result.tick = TickMath.getTickAtSqrtPrice(result.sqrtPriceX96);
            }
        }

        // Update pool state (matching Pool.sol lines 439-449)
        pool.slot0.sqrtPriceX96 = result.sqrtPriceX96;
        pool.slot0.tick = result.tick;

        // SIMPLIFIED: Liquidity doesn't change (no tick crossing)
        // In original: if (self.liquidity != result.liquidity) self.liquidity = result.liquidity;

        // SIMPLIFIED: No fee growth update
        // In original:
        //   if (!zeroForOne) { self.feeGrowthGlobal1X128 = step.feeGrowthGlobalX128; }
        //   else { self.feeGrowthGlobal0X128 = step.feeGrowthGlobalX128; }

        // Calculate balance delta (matching Pool.sol lines 451-462)
        unchecked {
            // "if currency1 is specified"
            if (zeroForOne != (params.amountSpecified < 0)) {
                swapDelta = toBalanceDelta(
                    amountCalculated.toInt128(),
                    (params.amountSpecified - amountSpecifiedRemaining).toInt128()
                );
            } else {
                swapDelta = toBalanceDelta(
                    (params.amountSpecified - amountSpecifiedRemaining).toInt128(),
                    amountCalculated.toInt128()
                );
            }
        }
    }

    /* HELPER FUNCTIONS */

    /// @dev Settles currency for a recipient
    function _settle(address recipient) internal returns (uint256 paid) {
        Currency currency = _syncedCurrency;

        // If not previously synced, expects native currency to be settled
        if (Currency.unwrap(currency) == address(0)) {
            paid = msg.value;
        } else {
            int256 currentDelta = _currencyDeltas[currency][recipient];

            if (currentDelta < 0) {
                // There's a negative delta (debt), settle it by accounting for a payment
                paid = uint256(-currentDelta);
            } else {
                paid = 0;
            }

            // Reset synced currency
            _syncedCurrency = Currency.wrap(address(0));
        }

        if (paid > 0) {
            _accountDelta(currency, int128(uint128(paid)), recipient);
        }
    }

    /// @dev Accounts a delta for a currency and address
    function _accountDelta(Currency currency, int128 delta, address target) internal {
        if (delta == 0) return;

        int256 previous = _currencyDeltas[currency][target];
        int256 next = previous + delta;
        _currencyDeltas[currency][target] = next;

        // Track nonzero delta count for flash accounting validation
        if (next == 0 && previous != 0) {
            _nonzeroDeltaCount--;
        } else if (next != 0 && previous == 0) {
            _nonzeroDeltaCount++;
        }
    }

    /// @dev Accounts pool balance deltas for both currencies
    function _accountPoolBalanceDelta(PoolKey memory key, BalanceDelta delta, address target) internal {
        _accountDelta(key.currency0, delta.amount0(), target);
        _accountDelta(key.currency1, delta.amount1(), target);
    }
}
