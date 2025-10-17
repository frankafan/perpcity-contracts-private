// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {UnlockCallback} from "./UnlockCallback.sol";
import {IPerpManager} from "./interfaces/IPerpManager.sol";
import {PerpLogic} from "./libraries/PerpLogic.sol";
import {Quoter} from "./libraries/Quoter.sol";
import {TimeWeightedAvg} from "./libraries/TimeWeightedAvg.sol";
import {TradingFee} from "./libraries/TradingFee.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

/// @title PerpManager
/// @notice Manages state for all perps
contract PerpManager is IPerpManager, UnlockCallback {
    /* IMMUTABLES */

    /// @notice The address of the USDC token
    address public immutable USDC;

    /* STORAGE */

    /// @notice Mapping to store state of all perps
    mapping(PoolId => IPerpManager.Perp) internal perps;

    /* CONSTRUCTOR */

    /// @notice Instantiates the PerpManager
    /// @dev This inherits UnlockCallback so it can accept callbacks from Uniswap PoolManager
    /// @param poolManager The address of the pool manager
    /// @param usdc The address of the USDC token
    constructor(IPoolManager poolManager, address usdc) UnlockCallback(poolManager) {
        USDC = usdc;
    }

    /* FUNCTIONS */

    /// @notice Creates a new perp
    /// @param params The parameters for creating the perp
    /// @return perpId The ID of the new perp
    function createPerp(CreatePerpParams calldata params) external returns (PoolId perpId) {
        perpId = PerpLogic.createPerp(perps, POOL_MANAGER, USDC, params);
    }

    /// @notice Opens a maker position
    /// @param perpId The ID of the perp to open the position in
    /// @param params The parameters for opening the position
    /// @return makerPosId The ID of the new maker position
    function openMakerPosition(PoolId perpId, OpenMakerPositionParams calldata params)
        external
        returns (uint128 makerPosId)
    {
        (makerPosId,) = PerpLogic.openPosition(perps[perpId], POOL_MANAGER, USDC, abi.encode(params), true, false);
    }

    /// @notice Opens a taker position
    /// @param perpId The ID of the perp to open the position in
    /// @param params The parameters for opening the position
    /// @return takerPosId The ID of the new taker position
    function openTakerPosition(PoolId perpId, OpenTakerPositionParams calldata params)
        external
        returns (uint128 takerPosId)
    {
        (takerPosId,) = PerpLogic.openPosition(perps[perpId], POOL_MANAGER, USDC, abi.encode(params), false, false);
    }

    /// @notice Adds margin to an open position
    /// @param perpId The ID of the perp to add margin to
    /// @param params The parameters for adding margin
    function addMargin(PoolId perpId, AddMarginParams calldata params) external {
        PerpLogic.addMargin(perps[perpId], POOL_MANAGER, USDC, params);
    }

    /// @notice Closes an open position
    /// @param perpId The ID of the perp to close the position in
    /// @param params The parameters for closing the position
    /// @return posId The ID of the taker position created if the position closed was a maker. Otherwise, 0
    function closePosition(PoolId perpId, ClosePositionParams calldata params) external returns (uint128 posId) {
        return PerpLogic.closePosition(perps[perpId], POOL_MANAGER, USDC, params, false);
    }

    /// @notice Increases the cardinality cap for a perp
    /// @param perpId The ID of the perp to increase the cardinality cap for
    /// @param cardinalityCap The new cardinality cap
    function increaseCardinalityCap(PoolId perpId, uint16 cardinalityCap) external {
        TimeWeightedAvg.increaseCardinalityCap(perps[perpId].twAvgState, cardinalityCap);
    }

    /* VIEW FUNCTIONS */

    /// @notice Returns the tick spacing for a perp
    /// @param perpId The ID of the perp to get the tick spacing for
    /// @return tickSpacing The tick spacing for the perp
    function tickSpacing(PoolId perpId) external view returns (int24) {
        return perps[perpId].key.tickSpacing;
    }

    /// @notice Returns the current sqrt price of a perp scaled by 2^96
    /// @param perpId The ID of the perp to get the sqrt price of
    /// @return sqrtPrice The current sqrt price
    function sqrtPriceX96(PoolId perpId) external view returns (uint160 sqrtPrice) {
        (sqrtPrice,,,) = StateLibrary.getSlot0(POOL_MANAGER, perpId);
    }

    /// @notice Returns the fees for a perp
    /// @param perpId The ID of the perp to get the fees for
    /// @return cFee The creator fee percentage scaled by 1e6
    /// @return insFee The insurance fee percentage scaled by 1e6
    /// @return lpFee The lp fee percentage scaled by 1e6
    /// @return liqFee The liquidation fee percentage scaled by 1e6
    function fees(PoolId perpId) external view returns (uint24 cFee, uint24 insFee, uint24 lpFee, uint24 liqFee) {
        cFee = perps[perpId].creatorFee;
        insFee = perps[perpId].insuranceFee;
        lpFee = TradingFee.calculateTradingFee(perps[perpId], POOL_MANAGER);
        liqFee = perps[perpId].liquidationFee;
    }

    /// @notice Returns the trading bounds for a perp
    /// @param perpId The ID of the perp to get the trading bounds for
    /// @return minOpeningMargin The minimum opening margin
    /// @return minMakerMarginRatio The minimum maker margin ratio
    /// @return maxMakerMarginRatio The maximum maker margin ratio
    /// @return makerLiquidationMarginRatio The maker liquidation margin ratio
    /// @return minTakerMarginRatio The minimum taker margin ratio
    /// @return maxTakerMarginRatio The maximum taker margin ratio
    /// @return takerLiquidationMarginRatio The taker liquidation margin ratio
    function tradingBounds(PoolId perpId)
        external
        view
        returns (
            uint24 minOpeningMargin,
            uint24 minMakerMarginRatio,
            uint24 maxMakerMarginRatio,
            uint24 makerLiquidationMarginRatio,
            uint24 minTakerMarginRatio,
            uint24 maxTakerMarginRatio,
            uint24 takerLiquidationMarginRatio
        )
    {
        minOpeningMargin = perps[perpId].minOpeningMargin;
        minMakerMarginRatio = perps[perpId].minMakerOpeningMarginRatio;
        maxMakerMarginRatio = perps[perpId].maxMakerOpeningMarginRatio;
        makerLiquidationMarginRatio = perps[perpId].makerLiquidationMarginRatio;
        minTakerMarginRatio = perps[perpId].minTakerOpeningMarginRatio;
        maxTakerMarginRatio = perps[perpId].maxTakerOpeningMarginRatio;
        takerLiquidationMarginRatio = perps[perpId].takerLiquidationMarginRatio;
    }

    /// @notice Estimates the liquidity for a certain amount of token1 (usd) provided within a tick range
    /// @param tickA One tick boundry defining the range
    /// @param tickB The other tick boundry defining the range
    /// @param amount1 The amount of token1 (usd) to estimate liquidity for
    /// @return liq The resulting liquidity calculated
    function estimateLiquidityForUsd(int24 tickA, int24 tickB, uint256 amount1) external pure returns (uint128 liq) {
        return LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickA), TickMath.getSqrtPriceAtTick(tickB), amount1
        );
    }

    /// @notice Returns the time-weighted average sqrt price of a perp, scaled by 2^96
    /// @param perpId The ID of the perp to get the time-weighted average sqrt price of
    /// @param lookbackWindow The lookback window in seconds to calculate the time-weighted average over
    /// @return twAvg The time-weighted average sqrt price
    function timeWeightedAvgSqrtPriceX96(PoolId perpId, uint32 lookbackWindow) external view returns (uint256 twAvg) {
        (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(POOL_MANAGER, perpId);
        return TimeWeightedAvg.timeWeightedAvg(
            perps[perpId].twAvgState, lookbackWindow, SafeCastLib.toUint32(block.timestamp), sqrtPrice
        );
    }

    /// @notice Returns the position details for a given position ID
    /// @param perpId The ID of the perp to get the position for
    /// @param posId The ID of the position to get
    /// @return pos The position's details
    function position(PoolId perpId, uint128 posId) external view returns (IPerpManager.Position memory pos) {
        return perps[perpId].positions[posId];
    }

    /// @notice Quotes the opening of a maker position without changing state
    /// @param perpId The ID of the perp to simulate opening the position in
    /// @param params The parameters for opening the position
    /// @return success Whether the transaction would have been successful
    /// @return perpDelta The movement of perp contracts if the transaction was successful
    /// @return usdDelta The movement of usd if the transaction was successful
    function quoteOpenMakerPosition(PoolId perpId, OpenMakerPositionParams calldata params)
        external
        returns (bool success, int256 perpDelta, int256 usdDelta)
    {
        try PerpLogic.openPosition(perps[perpId], POOL_MANAGER, USDC, abi.encode(params), true, true) {}
        catch (bytes memory reason) {
            (success, perpDelta, usdDelta) = Quoter.parseOpen(reason);
        }
    }

    /// @notice Quotes the opening of a taker position without changing state
    /// @param perpId The ID of the perp to simulate opening the position in
    /// @param params The parameters for opening the position
    /// @return success Whether the transaction would have been successful
    /// @return perpDelta The movement of perp contracts if the transaction was successful
    /// @return usdDelta The movement of usd if the transaction was successful
    function quoteOpenTakerPosition(PoolId perpId, OpenTakerPositionParams calldata params)
        external
        returns (bool success, int256 perpDelta, int256 usdDelta)
    {
        try PerpLogic.openPosition(perps[perpId], POOL_MANAGER, USDC, abi.encode(params), false, true) {}
        catch (bytes memory reason) {
            (success, perpDelta, usdDelta) = Quoter.parseOpen(reason);
        }
    }

    // TODO: if closing maker, we only quote for maker close but want to quote for resulting taker close as well
    /// @notice Quotes the closing of a position without changing state
    /// @param perpId The ID of the perp to simulate closing the position in
    /// @param posId The ID of the position to close
    /// @return success Whether the transaction would have been successful
    /// @return pnl The pnl of the position at close
    /// @return funding The funding payment of the position at close
    /// @return netMargin The margin of the position after pnl, funding, and fees
    /// @return wasLiquidated Whether the position was liquidated by the close call
    function quoteClosePosition(PoolId perpId, uint128 posId)
        external
        returns (bool success, int256 pnl, int256 funding, uint256 netMargin, bool wasLiquidated)
    {
        // params are minimized / maximized where possible to ensure no reverts
        ClosePositionParams memory params = ClosePositionParams(posId, 0, 0, type(uint128).max);

        try PerpLogic.closePosition(perps[perpId], POOL_MANAGER, USDC, params, true) {}
        catch (bytes memory reason) {
            (success, pnl, funding, netMargin, wasLiquidated) = Quoter.parseClose(reason);
        }
    }
}
