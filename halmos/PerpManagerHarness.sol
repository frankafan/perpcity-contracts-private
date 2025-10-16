// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title PerpManagerHarness
/// @notice Test harness for PerpManager to access internal states
contract PerpManagerHarness is PerpManager {
    constructor(IPoolManager poolManager, address usdc) PerpManager(poolManager, usdc) {}

    function getInsurance(PoolId perpId) external view returns (uint128) {
        return perps[perpId].insurance;
    }

    function getAdlGrowth(PoolId perpId) external view returns (uint256) {
        return perps[perpId].adlGrowth;
    }

    function getTakerOpenInterest(PoolId perpId) external view returns (uint128) {
        return perps[perpId].takerOpenInterest;
    }

    function getVault(PoolId perpId) external view returns (address) {
        return perps[perpId].vault;
    }

    function getNextPosId(PoolId perpId) external view returns (uint128) {
        return perps[perpId].nextPosId;
    }
}
