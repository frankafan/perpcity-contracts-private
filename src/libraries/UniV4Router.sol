// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {AccountingToken} from "../AccountingToken.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

library UniV4Router {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    error InvalidAction(uint8 action);
    error MaximumAmountExceeded(uint256 maximumAmount, uint256 amountRequested);
    error MinimumAmountInsufficient(uint256 minimumAmount, uint256 amountReceived);

    struct CreatePoolConfig {
        int24 tickSpacing;
        uint160 startingSqrtPriceX96;
    }

    struct LiquidityConfig {
        PoolKey poolKey;
        uint256 positionId;
        bool isAdd; // else isRemove
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidityToMove; // liquidity amount that will be added or removed
        uint128 amount0Limit; // max currency0 amt in for add liquidity or min currency0 amt out for remove liquidity
        uint128 amount1Limit; // max currency1 amt in for add liquidity or min currency1 amt out for remove liquidity
    }

    struct SwapConfig {
        PoolKey poolKey;
        bool isExactIn; // else isExactOut
        bool zeroForOne;
        uint256 amountSpecified; // amount of currency to move in if isExactIn or out if isExactOut
        uint160 sqrtPriceLimitX96;
        uint128 unspecifiedAmountLimit; // min amount out if isExactIn or max amount in if isExactOut
        uint24 fee; // the lp fee that will be set before the swap
    }

    uint8 internal constant CREATE_POOL = 0x00;
    uint8 internal constant MODIFY_LIQUIDITY = 0x01;
    uint8 internal constant SWAP = 0x02;

    function executeAction(
        IPoolManager poolManager,
        uint8 action,
        bytes memory encodedParams
    )
        internal
        returns (bytes memory)
    {
        // encode action and encoded params into bytes that will eventually be passed to UnlockCallback
        bytes memory unlockData = abi.encode(action, encodedParams);
        return poolManager.unlock(unlockData);
    }

    function createPool(
        IPoolManager poolManager,
        CreatePoolConfig memory params
    )
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

        // create pool key with a dynamic fee and this contract as the hook to allow updateDynamicLPFee calls
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(address(this))
        });

        poolManager.initialize(poolKey, params.startingSqrtPriceX96);

        return abi.encode(poolKey);
    }

    // this should not be called with a zero liquidityToMove
    function modifyLiquidity(
        IPoolManager poolManager,
        LiquidityConfig memory params
    )
        internal
        returns (bytes memory encodedDeltas)
    {
        // Uniswap expects positive liquidity when adding and negative when removing
        int256 liquidityChange = params.isAdd ? int256(params.liquidityToMove) : -int256(params.liquidityToMove);

        BalanceDelta feesAccrued;
        if (!params.isAdd) {
            (, feesAccrued) = poolManager.modifyLiquidity(
                params.poolKey,
                ModifyLiquidityParams({
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidityDelta: 0,
                    salt: bytes32(params.positionId) // using positionId as salt
                }),
                "" // no hook data
            );
        }

        // modifyLiquidity call into PoolManager which returns deltas with information on token movement
        (BalanceDelta liquidityDelta,) = poolManager.modifyLiquidity(
            params.poolKey,
            ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: liquidityChange,
                salt: bytes32(params.positionId) // using positionId as salt
            }),
            "" // no hook data
        );

        // if removing liquidity, account the fees accrued into the overall delta
        if (!params.isAdd) liquidityDelta = liquidityDelta + feesAccrued;

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

    function swap(IPoolManager poolManager, SwapConfig memory params) internal returns (bytes memory encodedDeltas) {
        // update the dynamic lp fee before the swap
        // fee in params should only be non-zero for swaps in opening taker positions
        poolManager.updateDynamicLPFee(params.poolKey, params.fee);

        // Uniswap expects negative amountSpecified for exactIn and positive for exactOut
        int256 amountSpecified = params.isExactIn ? -int256(params.amountSpecified) : int256(params.amountSpecified);

        // swap call into PoolManager which returns deltas with information on token movement
        BalanceDelta swapDelta = poolManager.swap(
            params.poolKey,
            SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            }),
            "" // no hook data
        );

        // the currency moving into the pool should be < 0 and the currency moving out should be > 0
        int256 currency0Delta = swapDelta.amount0();
        int256 currency1Delta = swapDelta.amount1();

        // TODO: only charge fee in amount 0 & calculate amount to return here
        uint256 feeAmount = 0;
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

        return abi.encode(currency0Delta, currency1Delta, feeAmount);
    }

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

    function revertIfInsufficientAmount(int256 delta, uint256 min) internal pure {
        if (delta > 0 && uint256(delta) < min) revert MinimumAmountInsufficient(min, uint256(delta));
    }

    function revertIfExcessiveAmount(int256 delta, uint256 max) internal pure {
        if (delta < 0 && uint256(-delta) > max) revert MaximumAmountExceeded(max, uint256(-delta));
    }

    // CLEAN BELOW

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
    )
        internal
        view
        returns (int24 next, bool initialized)
    {
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
