// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {AccountingToken} from "../AccountingToken.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title UniV4Router
/// @notice A library that contains functions to execute actions in the Uniswap PoolManager
library UniV4Router {
    using StateLibrary for IPoolManager;

    /* STRUCTS */

    /// @notice Configuration parameters for creating a pool
    /// @param tickSpacing The tick spacing to create the pool with
    /// @param startingSqrtPriceX96 The starting square root price of the pool scaled by 2^96
    struct CreatePoolConfig {
        int24 tickSpacing;
        uint160 startingSqrtPriceX96;
    }

    /// @notice Configuration parameters for modifying liquidity in a Uniswap pool
    /// @param poolKey The key of the pool to modify liquidity for
    /// @param positionId The position ID to modify liquidity for
    /// @param isAdd Whether to add or remove liquidity
    /// @param tickLower The lower tick of the liquidity range
    /// @param tickUpper The upper tick of the liquidity range
    /// @param liquidityToMove The amount of liquidity to add or remove
    /// @param amount0Limit Max currency0 amt in for add liquidity or min currency0 amt out for remove liquidity
    /// @param amount1Limit Max currency1 amt in for add liquidity or min currency1 amt out for remove liquidity
    struct LiquidityConfig {
        PoolKey poolKey;
        uint256 positionId;
        bool isAdd;
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidityToMove;
        uint128 amount0Limit;
        uint128 amount1Limit;
    }

    /// @notice Configuration parameters for swapping in a Uniswap pool
    /// @param poolKey The key of the pool to swap in
    /// @param isExactIn Whether the specified amount is going in or out of the Uniswap pool
    /// @param zeroForOne Whether the swapper is sending currency0 into the pool for currency1 out or vice versa
    /// @param amountSpecified The amount of the specified currency to swap in or out
    /// @param sqrtPriceLimitX96 The square root price limit of the swap. If the swap reaches this price, it will stop
    /// and only be partially filled. This is scaled by 2^96
    /// @param unspecifiedAmountLimit The minimum amount of currency received out of the pool if isExactIn or the
    /// maximum amount of currency sent in if isExactOut. If the limit is breached, the swap will revert
    struct SwapConfig {
        PoolKey poolKey;
        bool isExactIn;
        bool zeroForOne;
        uint256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        uint128 unspecifiedAmountLimit;
    }

    /// @notice Configuration parameters for donating currency1 in a Uniswap pool
    /// @param poolKey The key of the pool to donate to
    /// @param amount The amount of currency1 to donate
    struct DonateConfig {
        PoolKey poolKey;
        uint256 amount;
    }

    /* CONSTANTS */

    /// @notice The action number that corresponds to creating a pool
    uint8 constant CREATE_POOL = 0x00;
    /// @notice The action number that corresponds to modifying liquidity in a pool
    uint8 constant MODIFY_LIQUIDITY = 0x01;
    /// @notice The action number that corresponds to swapping in a pool
    uint8 constant SWAP = 0x02;
    /// @notice The action number that corresponds to distributing currency1 to LPs in a pool
    uint8 constant DONATE = 0x03;

    /* ERRORS */

    /// @notice Thrown when the amount sent in is greater than the maximum amount specified
    error MaximumAmountExceeded(uint256 maximumAmount, uint256 amountRequested);
    /// @notice Thrown when the amount received is less than the minimum amount specified
    error MinimumAmountInsufficient(uint256 minimumAmount, uint256 amountReceived);

    /* FUNCTIONS */

    /// @notice Unlocks the pool manager, passing on a specified action and encoded params
    /// @dev This function can take an invalid action but will revert when UnlockCallback is called
    /// @param poolManager The pool manager to execute the action on
    /// @param action The action number to execute
    /// @param encodedParams The encoded parameters for the action
    /// @return encodedActionResult The encoded data returned after the action was executed
    function executeAction(IPoolManager poolManager, uint8 action, bytes memory encodedParams)
        internal
        returns (bytes memory encodedActionResult)
    {
        // encode action and encodedParams into bytes that are sent with an unlock call to the pool manager
        // the pool manager will call UnlockCallback and pass this to data to it
        bytes memory unlockData = abi.encode(action, encodedParams);
        return poolManager.unlock(unlockData);
    }

    /// @notice Creates a new pool in Uniswap with the given parameters
    /// @param poolManager The pool manager to create the pool in
    /// @param params The parameters for creating the pool
    /// @return encodedPoolKey The encoded pool key of the newly created pool
    function createPool(IPoolManager poolManager, CreatePoolConfig memory params)
        internal
        returns (bytes memory encodedPoolKey)
    {
        // create two accounting tokens
        // currency0 will always represent perp contracts and currency1 will always represent usd
        address currency0 = address(new AccountingToken());
        address currency1 = address(new AccountingToken());

        // mint accounting tokens to PoolManager and mint ERC6909 tokens to this contract
        AccountingToken(currency0).initialize(poolManager, type(uint120).max);
        AccountingToken(currency1).initialize(poolManager, type(uint120).max);

        // assign smaller address to currency0 and larger address to currency1 to match Uniswap's expected format
        if (currency0 > currency1) (currency0, currency1) = (currency1, currency0);

        // create pool key with a zero fee and no hook address since this contract will use donate() for custom fees
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 0,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(address(0))
        });

        poolManager.initialize(poolKey, params.startingSqrtPriceX96);
        return abi.encode(poolKey);
    }

    /// @notice Modifies liquidity in a Uniswap pool
    /// @dev This function should not be called with a zero liquidityToMove
    /// @param poolManager The pool manager to modify liquidity in
    /// @param params The parameters for modifying liquidity
    /// @return encodedDeltas The encoded deltas of the tokens sent in or out of the pool
    function modifyLiquidity(IPoolManager poolManager, LiquidityConfig memory params)
        internal
        returns (bytes memory encodedDeltas)
    {
        // Uniswap expects positive liquidity when adding and negative when removing
        int256 liquidityChange = params.isAdd ? int256(params.liquidityToMove) : -int256(params.liquidityToMove);

        // create modifyLiquidityParams with the given parameters
        ModifyLiquidityParams memory modifyLiquidityParams = ModifyLiquidityParams({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: liquidityChange,
            salt: bytes32(params.positionId) // using positionId as salt
        });

        // modifyLiquidity call into PoolManager with empty hook data
        (BalanceDelta liquidityDelta,) = poolManager.modifyLiquidity(params.poolKey, modifyLiquidityParams, "");

        // if removing liquidity, collect fees and account them into the overall delta
        if (!params.isAdd) {
            modifyLiquidityParams.liquidityDelta = 0;
            (, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(params.poolKey, modifyLiquidityParams, "");
            liquidityDelta = liquidityDelta + feesAccrued;
        }

        // currency0Delta and currency1Delta should be <= 0 when adding liquidity and >= 0 when removing
        int256 currency0Delta = liquidityDelta.amount0();
        int256 currency1Delta = liquidityDelta.amount1();

        if (params.isAdd) {
            // revert if amount of currency0 or currency1 sent in is greater than the maximum specified
            revertIfExcessiveAmount(currency0Delta, params.amount0Limit);
            revertIfExcessiveAmount(currency1Delta, params.amount1Limit);
        } else {
            // revert if amount of currency0 or currency1 received is less than the minimum specified
            revertIfInsufficientAmount(currency0Delta, params.amount0Limit);
            revertIfInsufficientAmount(currency1Delta, params.amount1Limit);
        }

        // pay or receive currency0 and currency1 amounts so that debt or credit is settled
        clearBalance(poolManager, params.poolKey.currency0, currency0Delta);
        clearBalance(poolManager, params.poolKey.currency1, currency1Delta);

        return abi.encode(currency0Delta, currency1Delta);
    }

    /// @notice Swaps tokens in a Uniswap pool
    /// @param poolManager The pool manager to swap in
    /// @param params The parameters for swapping
    /// @return encodedDeltas The encoded deltas of the tokens sent in or out of the pool
    function swap(IPoolManager poolManager, SwapConfig memory params) internal returns (bytes memory encodedDeltas) {
        // Uniswap expects negative amountSpecified for exactIn and positive for exactOut
        int256 amountSpecified = params.isExactIn ? -int256(params.amountSpecified) : int256(params.amountSpecified);

        // create swapParams with the given parameters
        SwapParams memory swapParams = SwapParams(params.zeroForOne, amountSpecified, params.sqrtPriceLimitX96);

        // swap call into PoolManager with empty hook data
        BalanceDelta swapDelta = poolManager.swap(params.poolKey, swapParams, "");

        // the currency delta moving into the pool should be < 0 and the currency delta moving out should be > 0
        int256 currency0Delta = swapDelta.amount0();
        int256 currency1Delta = swapDelta.amount1();

        if (params.isExactIn) {
            // for exact input, ensure the output amount is not less than the minimum specified
            int256 deltaToCheck = params.zeroForOne ? currency1Delta : currency0Delta;
            revertIfInsufficientAmount(deltaToCheck, params.unspecifiedAmountLimit);
        } else {
            // for exact output, ensure the input amount is not greater than the maximum specified
            int256 deltaToCheck = params.zeroForOne ? currency0Delta : currency1Delta;
            revertIfExcessiveAmount(deltaToCheck, params.unspecifiedAmountLimit);
        }

        // pay or receive currency0 and currency1 amounts so that debt and credit is settled
        clearBalance(poolManager, params.poolKey.currency0, currency0Delta);
        clearBalance(poolManager, params.poolKey.currency1, currency1Delta);

        return abi.encode(currency0Delta, currency1Delta);
    }

    /// @notice Distributes currency1 to LPs in a Uniswap pool
    /// @param poolManager The pool manager to donate to
    /// @param params The parameters for donating
    function donate(IPoolManager poolManager, DonateConfig memory params) internal {
        // donate call into PoolManager with empty hook data and clear the currency1 delta
        BalanceDelta donationDelta = poolManager.donate(params.poolKey, 0, params.amount, "");
        clearBalance(poolManager, params.poolKey.currency1, donationDelta.amount1());
    }

    /// @notice Clears the credit or debt of a currency in the pool manager
    /// @param poolManager The pool manager to clear the balance in
    /// @param currency The currency to clear the balance of
    /// @param delta The delta of the currency to clear
    function clearBalance(IPoolManager poolManager, Currency currency, int256 delta) internal {
        // return early if nothing is owed
        if (delta == 0) return;

        if (delta > 0) {
            // with delta > 0, PoolManager owes this contract delta ERC6909 tokens
            // use up the positive delta by minting the same amount of ERC6909 tokens to this contract
            poolManager.mint(address(this), currency.toId(), uint256(delta));
        } else {
            // with delta < 0, this contract owes |delta| ERC6909 tokens to PoolManager
            // clear the negative delta by burning the same amount of this contract's ERC6909 tokens
            // casting delta is safe due to pool's total supply limit
            poolManager.burn(address(this), currency.toId(), uint256(-delta));
        }
    }

    /// @notice Reverts if the amount received is less than the minimum specified
    /// @param delta The delta of the currency to check
    /// @param min The minimum amount
    function revertIfInsufficientAmount(int256 delta, uint256 min) internal pure {
        if (delta > 0 && uint256(delta) < min) revert MinimumAmountInsufficient(min, uint256(delta));
    }

    /// @notice Reverts if the amount sent in is greater than the maximum specified
    /// @param delta The delta of the currency to check
    /// @param max The maximum amount
    function revertIfExcessiveAmount(int256 delta, uint256 max) internal pure {
        if (delta < 0 && uint256(-delta) > max) revert MaximumAmountExceeded(max, uint256(-delta));
    }

    /// TODO: clean below

    function isTickInitialized(IPoolManager poolManager, PoolId poolId, int24 tick) internal view returns (bool) {
        (uint128 tickLowerLiquidityGrossBefore,,,) = poolManager.getTickInfo(poolId, tick);
        return tickLowerLiquidityGrossBefore > 0;
    }

    /// @notice Returns the next initialized tick contained in the same word (or adjacent word) as the tick that is
    /// either
    /// to the left (less than or equal to) or right (greater than) of the given tick
    /// @param tick The starting tick
    /// @param tickSpacing The spacing between usable ticks
    /// @param lte Whether to search for the next initialized tick to the left (less than or equal to the starting tick)
    /// @return next The next initialized or uninitialized tick up to 256 ticks away from the current tick
    /// @return initialized Whether the next tick is initialized, as the function only searches within up to 256 ticks
    function nextInitializedTickWithinOneWord(
        IPoolManager poolManager,
        PoolId poolId,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        unchecked {
            int24 compressed = compress(tick, tickSpacing);

            if (lte) {
                (int16 wordPos, uint8 bitPos) = position(compressed);
                // all the 1s at or to the right of the current bitPos
                uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
                uint256 masked = poolManager.getTickBitmap(poolId, wordPos) & mask;

                // if there are no initialized ticks to the right of or at the current tick, return rightmost in the
                // word
                initialized = masked != 0;
                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                // start from the word of the next tick, since the current tick state doesn't matter
                (int16 wordPos, uint8 bitPos) = position(++compressed);
                // all the 1s at or to the left of the bitPos
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = poolManager.getTickBitmap(poolId, wordPos) & mask;

                // if there are no initialized ticks to the left of the current tick, return leftmost in the word
                initialized = masked != 0;
                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }

    function compress(int24 tick, int24 tickSpacing) internal pure returns (int24 compressed) {
        // compressed = tick / tickSpacing;
        // if (tick < 0 && tick % tickSpacing != 0) compressed--;
        assembly ("memory-safe") {
            tick := signextend(2, tick)
            tickSpacing := signextend(2, tickSpacing)
            compressed :=
                sub(
                    sdiv(tick, tickSpacing),
                    // if (tick < 0 && tick % tickSpacing != 0) then tick % tickSpacing < 0, vice versa
                    slt(smod(tick, tickSpacing), 0)
                )
        }
    }

    /// @notice Computes the position in the mapping where the initialized bit for a tick lives
    /// @param tick The tick for which to compute the position
    /// @return wordPos The key in the mapping containing the word in which the bit is stored
    /// @return bitPos The bit position in the word where the flag is stored
    function position(int24 tick) internal pure returns (int16 wordPos, uint8 bitPos) {
        assembly ("memory-safe") {
            // signed arithmetic shift right
            wordPos := sar(8, signextend(2, tick))
            bitPos := and(tick, 0xff)
        }
    }
}
