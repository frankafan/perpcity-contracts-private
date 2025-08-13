// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IPerpManager} from "../interfaces/IPerpManager.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

library UniswapV4Utility {
    using StateLibrary for IPoolManager;
    using SafeCastLib for uint256;
    using SafeTransferLib for address;

    error InsufficientOutputAmount(uint256 amountOut, uint256 minAmountOut);
    error ExcessiveInputAmount(uint256 amountIn, uint256 maxAmountIn);
    error SwapReverted();

    bytes constant MINT_LIQ_POS_ACTIONS = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
    bytes constant BURN_LIQ_POS_ACTIONS = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
    bytes constant SWAP_EXACT_IN_COMMANDS = abi.encodePacked(uint8(Commands.V4_SWAP));
    bytes constant SWAP_EXACT_IN_ACTIONS =
        abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
    bytes constant SWAP_EXACT_OUT_COMMANDS = abi.encodePacked(uint8(Commands.V4_SWAP));
    bytes constant SWAP_EXACT_OUT_ACTIONS =
        abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.TAKE_ALL), uint8(Actions.SETTLE_ALL));

    function approveRouterAndPositionManager(
        IPerpManager.ExternalContracts calldata c,
        address currency0,
        address currency1
    )
        internal
    {
        address router = address(c.router);
        address positionManager = address(c.posm);

        currency0.permit2Approve(router, type(uint160).max, type(uint48).max);
        currency1.permit2Approve(router, type(uint160).max, type(uint48).max);
        currency0.permit2Approve(positionManager, type(uint160).max, type(uint48).max);
        currency1.permit2Approve(positionManager, type(uint160).max, type(uint48).max);
    }

    function mintLiqPos(
        IPositionManager positionManager,
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 timeout
    )
        internal
        returns (uint128 tokenId, uint256 amount0In, uint256 amount1In)
    {
        // Prepare parameters for each action
        bytes[] memory params = new bytes[](2);
        params[0] =
            abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, address(this), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        // Get token ID for the position about to be minted
        tokenId = positionManager.nextTokenId().toUint128();

        // Get balances of currencies before mint, used to calculate amount0In & amount1In
        uint256 amount0BalanceBefore = poolKey.currency0.balanceOfSelf();
        uint256 amount1BalanceBefore = poolKey.currency1.balanceOfSelf();

        // Execute the mint
        uint256 deadline = block.timestamp + timeout;
        positionManager.modifyLiquidities{value: 0}(abi.encode(MINT_LIQ_POS_ACTIONS, params), deadline);

        // Get balances of currencies after mint
        uint256 amount0BalanceAfter = poolKey.currency0.balanceOfSelf();
        uint256 amount1BalanceAfter = poolKey.currency1.balanceOfSelf();

        // Calculate the input amounts
        amount0In = amount0BalanceBefore - amount0BalanceAfter;
        amount1In = amount1BalanceBefore - amount1BalanceAfter;

        // Verify the input amounts are at most the maximum allowed
        if (amount0In > amount0Max) revert ExcessiveInputAmount(amount0In, amount0Max);
        if (amount1In > amount1Max) revert ExcessiveInputAmount(amount1In, amount1Max);
    }

    function burnLiqPos(
        IPositionManager positionManager,
        PoolKey memory poolKey,
        uint128 tokenId,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 timeout
    )
        internal
        returns (uint256 amount0Out, uint256 amount1Out)
    {
        // Prepare parameters for each action
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        // Get balances of currencies before burn, used to calculate amount0Out & amount1Out
        uint256 amount0BalanceBefore = poolKey.currency0.balanceOfSelf();
        uint256 amount1BalanceBefore = poolKey.currency1.balanceOfSelf();

        // Execute the burn
        uint256 deadline = block.timestamp + timeout;
        positionManager.modifyLiquidities(abi.encode(BURN_LIQ_POS_ACTIONS, params), deadline);

        // Get balances of currencies after burn
        uint256 amount0BalanceAfter = poolKey.currency0.balanceOfSelf();
        uint256 amount1BalanceAfter = poolKey.currency1.balanceOfSelf();

        // Calculate the output amounts
        amount0Out = amount0BalanceAfter - amount0BalanceBefore;
        amount1Out = amount1BalanceAfter - amount1BalanceBefore;

        // Verify the output amounts are at least the minimum required
        if (amount0Out < amount0Min) revert InsufficientOutputAmount(amount0Out, amount0Min);
        if (amount1Out < amount1Min) revert InsufficientOutputAmount(amount1Out, amount1Min);
    }

    function swapExactIn(
        IUniversalRouter router,
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint24 fee,
        uint256 timeout
    )
        internal
        returns (uint256 amountOut, bool reverted)
    {
        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: abi.encode(fee)
            })
        );

        // Get input and output currencies based on swap direction
        Currency inputCurrency = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        Currency outputCurrency = zeroForOne ? poolKey.currency1 : poolKey.currency0;

        // Encode settle and take parameters
        params[1] = abi.encode(inputCurrency, amountIn);
        params[2] = abi.encode(outputCurrency, minAmountOut);

        // Combine actions and params into inputs
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(SWAP_EXACT_IN_ACTIONS, params);

        // Get balance of output currency before swap, used to calculate amountOut
        uint256 outputCurrencyBalanceBefore = outputCurrency.balanceOfSelf();

        // Calculate the deadline
        uint256 deadline = block.timestamp + timeout;

        // try to execute the swap, if it reverts, return 0 and set reverted to true
        try router.execute(SWAP_EXACT_IN_COMMANDS, inputs, deadline) {}
        catch {
            return (0, true);
        }

        // Calculate and verify the output amount
        uint256 outputCurrencyBalanceAfter = outputCurrency.balanceOfSelf();
        amountOut = outputCurrencyBalanceAfter - outputCurrencyBalanceBefore;
        if (amountOut < minAmountOut) revert InsufficientOutputAmount(amountOut, minAmountOut);
    }

    function swapExactOut(
        IUniversalRouter router,
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 amountOut,
        uint128 maxAmountIn,
        uint24 fee,
        uint256 timeout
    )
        internal
        returns (uint256 amountIn, bool reverted)
    {
        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountOut: amountOut,
                amountInMaximum: maxAmountIn,
                hookData: abi.encode(fee)
            })
        );

        // Get input and output currencies based on swap direction
        Currency inputCurrency = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        Currency outputCurrency = zeroForOne ? poolKey.currency1 : poolKey.currency0;

        // Encode settle and take parameters
        params[1] = abi.encode(outputCurrency, amountOut);
        params[2] = abi.encode(inputCurrency, maxAmountIn);

        // Combine actions and params into inputs
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(SWAP_EXACT_OUT_ACTIONS, params);

        // Get balance of output currency before swap, used to calculate amountOut
        uint256 inputCurrencyBalanceBefore = inputCurrency.balanceOfSelf();

        // Calculate the deadline
        uint256 deadline = block.timestamp + timeout;

        // try to execute the swap, if it reverts, return 0 and set reverted to true
        try router.execute(SWAP_EXACT_OUT_COMMANDS, inputs, deadline) {}
        catch {
            return (0, true);
        }

        // Verify and return the output amount
        uint256 inputCurrencyBalanceAfter = inputCurrency.balanceOfSelf();
        amountIn = inputCurrencyBalanceBefore - inputCurrencyBalanceAfter;
        if (amountIn > maxAmountIn) revert ExcessiveInputAmount(amountIn, maxAmountIn);
    }

    // use this instead of getSlot0 for currentTick since it may be inaccurate in some cases
    function getSqrtPriceX96AndTick(IPoolManager poolManager, PoolId poolId) internal view returns (uint160, int24) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        return (sqrtPriceX96, currentTick);
    }

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
