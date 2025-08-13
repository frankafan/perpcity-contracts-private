// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IPerpManager} from "../interfaces/IPerpManager.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {MakerActions} from "./MakerActions.sol";
import {TakerActions} from "./TakerActions.sol";
import {FixedPointMathLib} from "@solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib} from "@solady/src/utils/SafeTransferLib.sol";

library MarketDeath {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;
    using MakerActions for IPerpManager.Perp;
    using TakerActions for IPerpManager.Perp;
    using SafeCastLib for uint256;

    function marketHealthX96(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts calldata c
    )
        public
        view
        returns (uint256)
    {
        if (perp.totalMargin == 0) return FixedPoint96.UINT_Q96; // Market has no capital

        uint256 vaultBalance = c.usdc.balanceOf(perp.vault);
        if (perp.badDebt >= vaultBalance) return 0; // Market is completely insolvent

        return (vaultBalance - perp.badDebt).mulDiv(FixedPoint96.UINT_Q96, perp.totalMargin);
    }

    function marketDeath(IPerpManager.Perp storage perp, IPerpManager.ExternalContracts calldata c) external {
        uint256 currentMarketHealthX96 = marketHealthX96(perp, c);
        if (currentMarketHealthX96 > perp.marketDeathThresholdX96) {
            revert IPerpManager.MarketNotKillable(currentMarketHealthX96, perp.marketDeathThresholdX96);
        }

        // close taker positions without payouts until
        // market health >= 1 (market is fully solvent) or all taker positions are closed
        currentMarketHealthX96 = closeTakerPositions(perp, c, false);

        if (currentMarketHealthX96 >= FixedPoint96.UINT_Q96) {
            // market is solvent and there are still taker positions open
            // close remaining taker positions with payouts
            closeTakerPositions(perp, c, true);

            // close all maker positions with payouts
            closeMakerPositions(perp, c, true);
        } else {
            // market health still < 1, even after closing all taker positions
            // close maker positions without payouts until >= 1 or all maker positions are closed
            currentMarketHealthX96 = closeMakerPositions(perp, c, false);

            if (currentMarketHealthX96 >= FixedPoint96.UINT_Q96) {
                // market is solvent and there are still maker positions open
                // close remaining maker positions with payouts
                closeMakerPositions(perp, c, true);
            }
        }

        emit IPerpManager.MarketKilled(perp.key.toId());
    }

    // if performPayouts is false, closes taker positions until market health >= 1 or all taker positions are closed
    // starts with the newest taker position and moves towards the oldest
    // if performPayouts is true, all taker positions will be closed
    function closeTakerPositions(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts calldata c,
        bool withPayouts
    )
        internal
        returns (uint256 newMarketHealthX96)
    {
        uint128 currentPosId = perp.nextTakerPosId - 1;

        // params are minimized / maximized where possible to ensure no reverts
        IPerpManager.ClosePositionParams memory params = IPerpManager.ClosePositionParams({
            posId: currentPosId,
            minAmt0Out: 0,
            minAmt1Out: 0,
            maxAmt1In: type(uint128).max,
            timeout: type(uint32).max
        });

        // Loop through taker positions, starting with the newest
        while (currentPosId > 0) {
            // checking if position is open at this ID
            if (perp.takerPositions[currentPosId].holder != address(0)) {
                if (!withPayouts) {
                    // force close position without paying holder
                    perp.closeTakerPosition(c, params, false, true);
                    // while not paying out, check if market health >= 1 to stop
                    newMarketHealthX96 = marketHealthX96(perp, c);
                    if (newMarketHealthX96 >= FixedPoint96.UINT_Q96) break;
                } else {
                    // force close position with payout
                    perp.closeTakerPosition(c, params, false, false);
                }
            }
            currentPosId--;
            params.posId = currentPosId;
        }
    }

    function closeMakerPositions(
        IPerpManager.Perp storage perp,
        IPerpManager.ExternalContracts calldata c,
        bool withPayouts
    )
        internal
        returns (uint256 newMarketHealthX96)
    {
        uint128 currentPosId = c.posm.nextTokenId().toUint128() - 1;

        // params are minimized / maximized where possible to ensure no reverts
        IPerpManager.ClosePositionParams memory params = IPerpManager.ClosePositionParams({
            posId: currentPosId,
            minAmt0Out: 0,
            minAmt1Out: 0,
            maxAmt1In: type(uint128).max,
            timeout: type(uint32).max
        });

        // Loop through maker positions, starting with the newest
        while (currentPosId > 0) {
            // checking if position is open at this ID
            if (perp.makerPositions[currentPosId].holder != address(0)) {
                if (!withPayouts) {
                    // force close position without paying holder
                    perp.closeMakerPosition(c, params, false, true);
                    // while not paying out, check if market health >= 1 to stop
                    newMarketHealthX96 = marketHealthX96(perp, c);
                    if (newMarketHealthX96 >= FixedPoint96.UINT_Q96) break;
                } else {
                    // force close position with payout
                    perp.closeMakerPosition(c, params, false, false);
                }
            }
            currentPosId--;
            params.posId = currentPosId;
        }
    }
}
