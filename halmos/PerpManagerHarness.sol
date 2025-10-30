// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PerpLogic} from "../src/libraries/PerpLogic.sol";
import {Quoter} from "../src/libraries/Quoter.sol";

/// @title PerpManagerHarness
/// @notice Test harness for PerpManager to access internal states
contract PerpManagerHarness is PerpManager {
    constructor(IPoolManager poolManager, address usdc) PerpManager(poolManager, usdc, msg.sender) {}

    function getInsurance(PoolId perpId) external view returns (uint128) {
        return states[perpId].insurance;
    }

    // XXX: optional because configs is public
    function getVault(PoolId perpId) external view returns (address) {
        return configs[perpId].vault;
    }

    function getNextPosId(PoolId perpId) external view returns (uint128) {
        return states[perpId].nextPosId;
    }

    function getPosition(PoolId perpId, uint128 posId) external view returns (IPerpManager.Position memory) {
        return states[perpId].positions[posId];
    }

    function getNetMargin(PoolId perpId, uint128 posId) external returns (bool success, uint256 netMargin) {
        // Create close params with minimal restrictions to avoid reverts
        ClosePositionParams memory params = ClosePositionParams({
            posId: posId,
            minAmt0Out: 0,
            minAmt1Out: 0,
            maxAmt1In: type(uint128).max
        });

        // First, quote the close by calling with revertChanges=true
        // This will revert with Quoter.CloseQuote containing the netMargin
        try PerpLogic.closePosition(configs[perpId], states[perpId], POOL_MANAGER, USDC, params, true) {
            // Should always revert when revertChanges=true
            return (false, 0);
        } catch (bytes memory reason) {
            // Parse the revert reason to extract netMargin and other values
            int256 pnl;
            int256 funding;
            bool wasLiquidated;

            // TODO: try to just read net margin from the perp directly before and after actually closing the position
            // TODO: use the emitted event from new position to get the margin - use getRecordedLogs
            (success, pnl, funding, netMargin, wasLiquidated) = Quoter.parseClose(reason);

            if (!success) {
                return (false, 0);
            }
        }

        return (success, netMargin);
    }
}
