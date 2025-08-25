// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IPerpManager} from "./interfaces/IPerpManager.sol";
import {Hook} from "./libraries/Hook.sol";
import {LivePositionDetailsReverter} from "./libraries/LivePositionDetailsReverter.sol";
import {MakerActions} from "./libraries/MakerActions.sol";
import {MarketDeath} from "./libraries/MarketDeath.sol";
import {PerpLogic} from "./libraries/PerpLogic.sol";
import {TakerActions} from "./libraries/TakerActions.sol";

import {TickTWAP} from "./libraries/TickTWAP.sol";
import {UniswapV4Utility} from "./libraries/UniswapV4Utility.sol";
import {MAX_CARDINALITY} from "./utils/Constants.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

// manages state for all perps and contains hooks for uniswap pools
contract PerpManager is IPerpManager, BaseHook {
    using PerpLogic for mapping(PoolId => IPerpManager.Perp);
    using PerpLogic for IPerpManager.Perp;
    using MakerActions for IPerpManager.Perp;
    using TakerActions for IPerpManager.Perp;
    using Hook for IPerpManager.Perp;
    using StateLibrary for IPoolManager;
    using SafeTransferLib for address;
    using LivePositionDetailsReverter for bytes;
    using UniswapV4Utility for IPoolManager;
    using MarketDeath for IPerpManager.Perp;
    using SafeCastLib for *;
    using TickTWAP for TickTWAP.Observation[MAX_CARDINALITY];

    IPerpManager.ExternalContracts public c;

    uint256 public immutable CREATION_FEE_AMT;
    address public immutable CREATION_FEE_RECIPIENT;

    mapping(PoolId => IPerpManager.Perp) public perps;

    constructor(
        ExternalContracts memory _c,
        uint256 _creationFee,
        address _creationFeeRecipient
    )
        BaseHook(_c.poolManager)
    {
        c = _c;
        CREATION_FEE_AMT = _creationFee;
        CREATION_FEE_RECIPIENT = _creationFeeRecipient;
    }

    // ------------
    // PERP ACTIONS
    // ------------

    function createPerp(CreatePerpParams calldata params) external returns (PoolId perpId) {
        perpId = perps.createPerp(c, params);
        // transfer creation fee from sender to creation fee recipient
        c.usdc.safeTransferFrom(msg.sender, CREATION_FEE_RECIPIENT, CREATION_FEE_AMT);
    }

    function openMakerPosition(
        PoolId perpId,
        OpenMakerPositionParams calldata params
    )
        external
        returns (uint128 makerPosId)
    {
        return perps[perpId].openMakerPosition(c, params); // in MakerActions library
    }

    function addMakerMargin(PoolId perpId, AddMarginParams calldata params) external {
        perps[perpId].addMakerMargin(c, params); // in MakerActions library
    }

    function closeMakerPosition(PoolId perpId, ClosePositionParams calldata params) external {
        perps[perpId].closeMakerPosition(c, params, false, false); // in MakerActions library
    }

    function openTakerPosition(
        PoolId perpId,
        OpenTakerPositionParams calldata params
    )
        external
        returns (uint128 takerPosId)
    {
        return perps[perpId].openTakerPosition(c, params); // in TakerActions library
    }

    function addTakerMargin(PoolId perpId, AddMarginParams calldata params) external {
        perps[perpId].addTakerMargin(c, params); // in TakerActions library
    }

    function closeTakerPosition(PoolId perpId, ClosePositionParams calldata params) external {
        perps[perpId].closeTakerPosition(c, params, false, false); // in TakerActions library
    }

    function marketDeath(PoolId perpId) external {
        perps[perpId].marketDeath(c);
    }

    // -------------
    // TWAP ACTIONS
    // -------------

    function increaseCardinalityNext(PoolId perpId, uint32 cardinalityNext) external {
        perps[perpId].increaseCardinalityNext(cardinalityNext);
    }

    // ----
    // VIEW / READ
    // ----

    function getTWAP(PoolId perpId) external view returns (uint256) {
        uint32 oldestObservationTimestamp = perps[perpId].twapState.observations.getOldestObservationTimestamp(
            perps[perpId].twapState.index, perps[perpId].twapState.cardinality
        );
        uint32 twapSecondsAgo = (block.timestamp - oldestObservationTimestamp).toUint32();
        uint32 twapWindow = perps[perpId].twapWindow;
        twapSecondsAgo = twapSecondsAgo > twapWindow ? twapWindow : twapSecondsAgo;

        (, int24 currentTick) = c.poolManager.getSqrtPriceX96AndTick(perpId);
        return perps[perpId].getTWAP(twapSecondsAgo, currentTick);
    }

    function getMakerPosition(PoolId perpId, uint128 makerPosId) external view returns (IPerpManager.MakerPos memory) {
        return perps[perpId].makerPositions[makerPosId];
    }

    function getTakerPosition(PoolId perpId, uint128 takerPosId) external view returns (IPerpManager.TakerPos memory) {
        return perps[perpId].takerPositions[takerPosId];
    }

    // isn't view since it calls a non-view function that reverts with live position details
    function liveMakerDetails(
        PoolId perpId,
        uint128 makerPosId
    )
        external
        returns (int256 pnl, int256 fundingPayment, int256 effectiveMargin, bool isLiquidatable)
    {
        // params are minimized / maximized where possible to ensure no reverts
        ClosePositionParams memory params = ClosePositionParams({
            posId: makerPosId,
            minAmt0Out: 0,
            minAmt1Out: 0,
            maxAmt1In: type(uint128).max,
            timeout: type(uint32).max
        });

        // pass revert == true into close so we can parse live position details from the reason
        try perps[perpId].closeMakerPosition(c, params, true, false) {}
        catch (bytes memory reason) {
            (pnl, fundingPayment, effectiveMargin, isLiquidatable) = reason.parseLivePositionDetails();
        }
    }

    // isn't view since it calls a non-view function that reverts with live position details
    function liveTakerDetails(
        PoolId perpId,
        uint128 takerPosId
    )
        external
        returns (int256 pnl, int256 fundingPayment, int256 effectiveMargin, bool isLiquidatable)
    {
        // params are minimized / maximized where possible to ensure no reverts
        ClosePositionParams memory params = ClosePositionParams({
            posId: takerPosId,
            minAmt0Out: 0,
            minAmt1Out: 0,
            maxAmt1In: type(uint128).max,
            timeout: type(uint32).max
        });

        // pass revert == true into close so we can parse live position details from the reason
        try perps[perpId].closeTakerPosition(c, params, true, false) {}
        catch (bytes memory reason) {
            (pnl, fundingPayment, effectiveMargin, isLiquidatable) = reason.parseLivePositionDetails();
        }
    }

    function marketHealthX96(PoolId perpId) external view returns (uint256) {
        return perps[perpId].marketHealthX96(c);
    }

    // -----
    // HOOKS
    // -----

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata // hookData
    )
        internal
        override
        returns (bytes4)
    {
        return perps[key.toId()].beforeAddLiquidity(c, sender, key, params);
    }

    function _afterAddLiquidity(
        address, // sender
        PoolKey calldata key,
        ModifyLiquidityParams calldata, // params
        BalanceDelta, // delta
        BalanceDelta, // feesAccrued
        bytes calldata // hookData
    )
        internal
        override
        returns (bytes4, BalanceDelta)
    {
        return perps[key.toId()].afterAddLiquidity(c, key);
    }

    function _beforeRemoveLiquidity(
        address, // sender
        PoolKey calldata key,
        ModifyLiquidityParams calldata, // params
        bytes calldata // hookData
    )
        internal
        override
        returns (bytes4)
    {
        return perps[key.toId()].beforeRemoveLiquidity(c, key);
    }

    function _afterRemoveLiquidity(
        address, // sender
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta, // delta
        BalanceDelta, // feesAccrued
        bytes calldata // hookData
    )
        internal
        override
        returns (bytes4, BalanceDelta)
    {
        return perps[key.toId()].afterRemoveLiquidity(c, key, params);
    }

    // only set non-zero fee if the swap is for opening a position
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    )
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return perps[key.toId()].beforeSwap(c, sender, key, params, hookData);
    }

    function _afterSwap(
        address, // sender
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta, // delta
        bytes calldata // hookData
    )
        internal
        override
        returns (bytes4, int128)
    {
        return perps[key.toId()].afterSwap(c, key, params);
    }

    function _beforeDonate(
        address sender,
        PoolKey calldata, // key
        uint256, // amount0
        uint256, // amount1
        bytes calldata // hookData
    )
        internal
        view
        override
        returns (bytes4)
    {
        return Hook.beforeDonate(c, sender);
    }
}
