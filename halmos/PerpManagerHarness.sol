// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title PerpManagerHarness
/// @notice Test harness for PerpManager to access internal states
contract PerpManagerHarness is PerpManager {
    constructor(IPoolManager poolManager, address usdc) PerpManager(poolManager, usdc, msg.sender) {}

    function getInsurance(PoolId perpId) external view returns (uint128) {
        return states[perpId].insurance;
    }

    function getCumlBadDebtX96(PoolId perpId) external view returns (uint128) {
        return states[perpId].cumlBadDebtX96;
    }

    function getTakerOpenInterest(PoolId perpId) external view returns (uint128) {
        return states[perpId].takerOI;
    }

    function getVault(PoolId perpId) external view returns (address) {
        return configs[perpId].vault;
    }

    function getNextPosId(PoolId perpId) external view returns (uint128) {
        return states[perpId].nextPosId;
    }

    function getPosition(PoolId perpId, uint128 posId) external view returns (IPerpManager.Position memory) {
        return states[perpId].positions[posId];
    }
}
