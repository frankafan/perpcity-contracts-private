// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {UnlockCallback} from "./UnlockCallback.sol";
import {IPerpManager} from "./interfaces/IPerpManager.sol";
import {PerpLogic} from "./libraries/PerpLogic.sol";
import {Quoter} from "./libraries/Quoter.sol";
import {TimeWeightedAvg} from "./libraries/TimeWeightedAvg.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IFees} from "./interfaces/modules/IFees.sol";
import {IMarginRatios} from "./interfaces/modules/IMarginRatios.sol";
import {ILockupPeriod} from "./interfaces/modules/ILockupPeriod.sol";
import {ISqrtPriceImpactLimit} from "./interfaces/modules/ISqrtPriceImpactLimit.sol";
import {Ownable} from "@solady/src/auth/Ownable.sol";

/// @title PerpManager
/// @notice Manages state for all perps
contract PerpManager is IPerpManager, UnlockCallback, Ownable {
    /* IMMUTABLES */

    /// @notice The address of the USDC token
    address public immutable USDC;

    /* STORAGE */

    /// @notice The configuration specified for every perp created
    /// @dev values are not modified after creations
    mapping(PoolId => IPerpManager.PerpConfig) public configs;
    /// @notice The state of every perp created
    /// @dev values are modified on every action
    mapping(PoolId => IPerpManager.PerpState) private states;

    /// @notice A mapping containing registered fee module addresses
    mapping(IFees => bool) public isFeesRegistered;
    /// @notice A mapping containing registered margin ratios module addresses
    mapping(IMarginRatios => bool) public isMarginRatiosRegistered;
    /// @notice A mapping containing registered lockup period module addresses
    mapping(ILockupPeriod => bool) public isLockupPeriodRegistered;
    /// @notice A mapping containing registered sqrt price impact limit module addresses
    mapping(ISqrtPriceImpactLimit => bool) public isSqrtPriceImpactLimitRegistered;

    /* CONSTRUCTOR */

    /// @notice Instantiates the PerpManager
    /// @dev This inherits UnlockCallback so it can accept callbacks from Uniswap PoolManager
    /// @param poolManager The address of the pool manager
    /// @param usdc The address of the USDC token
    constructor(IPoolManager poolManager, address usdc, address owner) UnlockCallback(poolManager) {
        USDC = usdc;
        _initializeOwner(owner);
    }

    /* PERP FUNCTIONS */

    /// @notice Creates a new perp
    /// @param params The parameters for creating the perp
    /// @return perpId The ID of the new perp
    function createPerp(CreatePerpParams calldata params) external returns (PoolId perpId) {
        if (!isFeesRegistered[params.fees]) revert FeesNotRegistered();
        if (!isMarginRatiosRegistered[params.marginRatios]) revert MarginRatiosNotRegistered();
        if (!isLockupPeriodRegistered[params.lockupPeriod]) revert LockupPeriodNotRegistered();
        if (!isSqrtPriceImpactLimitRegistered[params.sqrtPriceImpactLimit]) revert SqrtPriceImpactLimitNotRegistered();

        perpId = PerpLogic.createPerp(configs, states, POOL_MANAGER, USDC, params);
    }

    /// @notice Opens a maker position
    /// @param perpId The ID of the perp to open the position in
    /// @param params The parameters for opening the position
    /// @return posId The ID of the new maker position
    function openMakerPos(PoolId perpId, OpenMakerPositionParams calldata params) external returns (uint128 posId) {
        // TODO: fix break when POOL_MANAGER & USDC moved into constants
        (posId,) = PerpLogic.openPos(configs[perpId], states[perpId], POOL_MANAGER, USDC, abi.encode(params), true, false);
    }

    /// @notice Opens a taker position
    /// @param perpId The ID of the perp to open the position in
    /// @param params The parameters for opening the position
    /// @return posId The ID of the new taker position
    function openTakerPos(PoolId perpId, OpenTakerPositionParams calldata params) external returns (uint128 posId) {
        // TODO: fix break when POOL_MANAGER & USDC moved into constants
        (posId,) = PerpLogic.openPos(configs[perpId], states[perpId], POOL_MANAGER, USDC, abi.encode(params), false, false);
    }

    /// @notice Adds margin to an open position
    /// @param perpId The ID of the perp to add margin to
    /// @param params The parameters for adding margin
    function addMargin(PoolId perpId, AddMarginParams calldata params) external {
        PerpLogic.addMargin(configs[perpId], states[perpId], POOL_MANAGER, USDC, params);
    }

    /// @notice Closes an open position
    /// @param perpId The ID of the perp to close the position in
    /// @param params The parameters for closing the position
    /// @return posId The ID of the taker position created if the position closed was a maker. Otherwise, 0
    function closePosition(PoolId perpId, ClosePositionParams calldata params) external returns (uint128 posId) {
        return PerpLogic.closePosition(configs[perpId], states[perpId], POOL_MANAGER, USDC, params, false);
    }

    /// @notice Increases the cardinality cap for a perp
    /// @param perpId The ID of the perp to increase the cardinality cap for
    /// @param cardinalityCap The new cardinality cap
    function increaseCardinalityCap(PoolId perpId, uint16 cardinalityCap) external {
        TimeWeightedAvg.increaseCardinalityCap(states[perpId].twAvgState, cardinalityCap);
    }

    /* MODULE FUNCTIONS */

    /// @notice Registers a fees module
    /// @param feesModule The fees module to register
    function registerFeesModule(IFees feesModule) external onlyOwner {
        if (isFeesRegistered[feesModule]) revert ModuleAlreadyRegistered();
        isFeesRegistered[feesModule] = true;
        emit FeesModuleRegistered(feesModule);
    }

    /// @notice Registers a margin ratios module
    /// @param marginRatiosModule The margin ratios module to register
    function registerMarginRatiosModule(IMarginRatios marginRatiosModule) external onlyOwner {
        if (isMarginRatiosRegistered[marginRatiosModule]) revert ModuleAlreadyRegistered();
        isMarginRatiosRegistered[marginRatiosModule] = true;
        emit MarginRatiosModuleRegistered(marginRatiosModule);
    }

    /// @notice Registers a lockup period module
    /// @param lockupPeriodModule The lockup period module to register
    function registerLockupPeriodModule(ILockupPeriod lockupPeriodModule) external onlyOwner {
        if (isLockupPeriodRegistered[lockupPeriodModule]) revert ModuleAlreadyRegistered();
        isLockupPeriodRegistered[lockupPeriodModule] = true;
        emit LockupPeriodModuleRegistered(lockupPeriodModule);
    }

    /// @notice Registers a sqrt price impact limit module
    /// @param sqrtPriceImpactLimitModule The sqrt price impact limit module to register
    function registerSqrtPriceImpactLimitModule(ISqrtPriceImpactLimit sqrtPriceImpactLimitModule) external onlyOwner {
        if (isSqrtPriceImpactLimitRegistered[sqrtPriceImpactLimitModule]) revert ModuleAlreadyRegistered();
        isSqrtPriceImpactLimitRegistered[sqrtPriceImpactLimitModule] = true;
        emit SqrtPriceImpactLimitModuleRegistered(sqrtPriceImpactLimitModule);
    }

    /* VIEW FUNCTIONS */

    /// @notice Returns the time-weighted average sqrt price of a perp, scaled by 2^96
    /// @param perpId The ID of the perp to get the time-weighted average sqrt price of
    /// @param lookbackWindow The lookback window in seconds to calculate the time-weighted average over
    /// @return twAvg The time-weighted average sqrt price
    function timeWeightedAvgSqrtPriceX96(PoolId perpId, uint32 lookbackWindow) external view returns (uint256 twAvg) {
        (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(POOL_MANAGER, perpId);
        return TimeWeightedAvg.timeWeightedAvg(
            states[perpId].twAvgState, lookbackWindow, SafeCastLib.toUint32(block.timestamp), sqrtPrice
        );
    }

    /// @notice Returns the position details for a given position ID
    /// @param perpId The ID of the perp to get the position for
    /// @param posId The ID of the position to get
    /// @return pos The position's details
    function position(PoolId perpId, uint128 posId) external view returns (IPerpManager.Position memory pos) {
        return states[perpId].positions[posId];
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
        try PerpLogic.openPos(configs[perpId], states[perpId], POOL_MANAGER, USDC, abi.encode(params), true, true) {}
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
        try PerpLogic.openPos(configs[perpId], states[perpId], POOL_MANAGER, USDC, abi.encode(params), false, true) {}
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

        try PerpLogic.closePosition(configs[perpId], states[perpId], POOL_MANAGER, USDC, params, true) {}
        catch (bytes memory reason) {
            (success, pnl, funding, netMargin, wasLiquidated) = Quoter.parseClose(reason);
        }
    }
}
