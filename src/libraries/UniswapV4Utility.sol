// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "v4-periphery/src/interfaces/IPositionManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { IUniversalRouter } from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import { Commands } from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import { IV4Router } from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IPermit2 } from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";

library UniswapV4Utility {
    function _approveTokenWithPermit2(
        address permit2,
        address approvedAddress,
        address token,
        uint160 amount,
        uint48 expiration
    )
        internal
    {
        IERC20(token).approve(permit2, type(uint256).max);
        IPermit2(permit2).approve(token, approvedAddress, amount, expiration);
    }

    function _swapExactInputSingle(
        IUniversalRouter router,
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint24 fee
    )
        internal
        returns (uint128 amountOut)
    {
        // Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

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
        inputs[0] = abi.encode(actions, params);

        // Get balance of output currency before swap, used to calculate amountOut
        uint256 outputCurrencyBalanceBefore = outputCurrency.balanceOfSelf();

        // Execute the swap
        uint256 deadline = block.timestamp + 20;
        router.execute(commands, inputs, deadline);

        // Verify and return the output amount
        uint256 outputCurrencyBalanceAfter = outputCurrency.balanceOfSelf();
        amountOut = SafeCast.toUint128(outputCurrencyBalanceAfter - outputCurrencyBalanceBefore);
    }

    function _swapExactOutputSingle(
        IUniversalRouter router,
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 amountOut,
        uint128 maxAmountIn,
        uint24 fee
    )
        internal
        returns (uint128 amountIn)
    {
        // Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.TAKE_ALL), uint8(Actions.SETTLE_ALL));

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
        inputs[0] = abi.encode(actions, params);

        // Get balance of output currency before swap, used to calculate amountOut
        uint256 inputCurrencyBalanceBefore = inputCurrency.balanceOfSelf();

        // Execute the swap
        uint256 deadline = block.timestamp + 20;
        router.execute(commands, inputs, deadline);

        // Verify and return the output amount
        uint256 inputCurrencyBalanceAfter = inputCurrency.balanceOfSelf();
        amountIn = SafeCast.toUint128(inputCurrencyBalanceBefore - inputCurrencyBalanceAfter);
    }

    function _mintLiquidityPosition(
        PoolKey memory poolKey,
        IPositionManager positionManager,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max
    )
        internal
        returns (uint256 tokenId, uint256 amount0In, uint256 amount1In)
    {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2); // new bytes[](3) for ETH liquidity positions

        params[0] =
            abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, address(this), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        tokenId = positionManager.nextTokenId();

        uint256 amount0BalanceBefore = poolKey.currency0.balanceOfSelf();
        uint256 amount1BalanceBefore = poolKey.currency1.balanceOfSelf();

        uint256 deadline = block.timestamp + 20;
        positionManager.modifyLiquidities{ value: 0 }(abi.encode(actions, params), deadline);

        uint256 amount0BalanceAfter = poolKey.currency0.balanceOfSelf();
        uint256 amount1BalanceAfter = poolKey.currency1.balanceOfSelf();

        amount0In = amount0BalanceBefore - amount0BalanceAfter;
        amount1In = amount1BalanceBefore - amount1BalanceAfter;
    }

    function _burnLiquidityPosition(
        PoolKey memory poolKey,
        IPositionManager positionManager,
        uint256 tokenId
    )
        internal
        returns (uint256 amount0Out, uint256 amount1Out)
    {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        uint256 amount0BalanceBefore = poolKey.currency0.balanceOfSelf();
        uint256 amount1BalanceBefore = poolKey.currency1.balanceOfSelf();

        uint256 deadline = block.timestamp + 20;
        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);

        uint256 amount0BalanceAfter = poolKey.currency0.balanceOfSelf();
        uint256 amount1BalanceAfter = poolKey.currency1.balanceOfSelf();

        amount0Out = amount0BalanceAfter - amount0BalanceBefore;
        amount1Out = amount1BalanceAfter - amount1BalanceBefore;
    }
}
