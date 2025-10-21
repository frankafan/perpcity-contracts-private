// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {PerpManager} from "../src/PerpManager.sol";

import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {IBeacon} from "../src/interfaces/beacons/IBeacon.sol";

import {OwnableBeacon} from "../src/beacons/ownable/OwnableBeacon.sol";
import "../src/libraries/Constants.sol";
import {PerpLogic} from "../src/libraries/PerpLogic.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolKey} from "@uniswap/v4-core/src/types/PoolId.sol";

import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract PerpHandler is Test {
    using SafeTransferLib for address;
    using FixedPointMathLib for *;
    using StateLibrary for IPoolManager;
    using PerpLogic for *;

    PerpManager public immutable perpManager;
    address public immutable usdc;
    address public liquidator = makeAddr("liquidator");

    PoolId[] public perps;
    IBeacon[] public beacons;
    address[] public actors;

    mapping(PoolId => uint128[]) public makerPositions;
    mapping(PoolId => uint128[]) public takerPositions;

    constructor(PerpManager _perpManager, address _usdc, uint256 _actorCount) {
        require(_actorCount > 0, "at least one actor required");

        perpManager = _perpManager;
        usdc = _usdc;

        for (uint256 i = 0; i < _actorCount; i++) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
        }
    }

    // perp actions

    function createPerp(
        uint256 actorIndex,
        uint256 initialBeaconData,
        uint32 initialCardinalityNext_Beacon,
        uint160 startingSqrtPriceX96,
        uint256 secondsToSkip,
        uint256 makerActorIndex,
        uint128 makerMargin,
        uint128 makerLiquidity,
        int24 makerTickLower,
        bool makerIsTickLowerNegative,
        uint256 makerTickRange,
        uint128 makerLeverageX96,
        uint256 makerSecondsToSkip
    ) public {
        address actor = actors[bound(actorIndex, 0, actors.length - 1)];

        vm.startPrank(actor);

        initialBeaconData = uint256(bound(initialBeaconData, 1 * UINT_Q96, 1000000 * UINT_Q96));

        IBeacon beacon =
            new OwnableBeacon(actor, initialBeaconData, uint16(bound(initialCardinalityNext_Beacon, 1, 100)));
        beacons.push(beacon);

        uint256 startingPriceX96Lower = initialBeaconData.mulDiv(9, 10);
        uint256 startingPriceX96Upper = initialBeaconData.mulDiv(11, 10);

        uint256 minStartingSqrtPriceX96 = startingPriceX96Lower.mulSqrt(UINT_Q96);
        minStartingSqrtPriceX96 = FixedPointMathLib.max(minStartingSqrtPriceX96, TickMath.MIN_SQRT_PRICE);
        minStartingSqrtPriceX96 = FixedPointMathLib.min(minStartingSqrtPriceX96, TickMath.MAX_SQRT_PRICE);

        uint256 maxStartingSqrtPriceX96 = startingPriceX96Upper.mulSqrt(UINT_Q96);
        maxStartingSqrtPriceX96 = FixedPointMathLib.min(maxStartingSqrtPriceX96, TickMath.MAX_SQRT_PRICE);
        maxStartingSqrtPriceX96 = FixedPointMathLib.max(maxStartingSqrtPriceX96, TickMath.MIN_SQRT_PRICE);

        startingSqrtPriceX96 = uint160(bound(startingSqrtPriceX96, minStartingSqrtPriceX96, maxStartingSqrtPriceX96));

        vm.stopPrank();

        skipTime(secondsToSkip);

        // openMakerPosition(makerActorIndex, perps.length - 1, makerMargin, makerLiquidity, makerTickLower, makerIsTickLowerNegative, makerTickRange, makerLeverageX96, makerSecondsToSkip);
    }

    function openMakerPosition(
        uint256 actorIndex,
        uint256 perpIndex,
        uint128 margin,
        int24 tickLower,
        uint256 tickRange,
        uint256 marginRatio,
        uint256 notional,
        uint256 secondsToSkip
    ) public {
        vm.assume(perps.length != 0);

        address actor = actors[bound(actorIndex, 0, actors.length - 1)];
        PoolId perpId = perps[bound(perpIndex, 0, perps.length - 1)];

        vm.startPrank(actor);

        (PoolKey memory key,,,,,,,) = perpManager.configs(perpId);
        int24 tickSpacing = key.tickSpacing;

        int24 MAX_TICK = TickMath.maxUsableTick(tickSpacing);

        tickLower = int24(bound(tickLower, 0, MAX_TICK - tickSpacing));
        tickLower = (tickLower / tickSpacing) * tickSpacing;

        uint256 maxTickRange = uint256(int256(MAX_TICK - tickLower));
        tickRange = uint256(bound(tickRange, uint256(int256(tickSpacing)), maxTickRange));
        int24 tickUpper = tickLower + int24(int256(tickRange));
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;

        notional = bound(notional, 1e6, 1000000e6);

        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, notional);
        vm.assume(liquidity != 0);
        (uint160 sqrtPriceX96,,,) = perpManager.POOL_MANAGER().getSlot0(perpId);
        (uint256 amount0, uint256 amount1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity);
        console2.log("perphandler amount0", amount0);
        console2.log("perphandler amount1", amount1);

        vm.assume(amount0 > 10 || amount1 > 10);

        uint256 priceX96 = sqrtPriceX96.fullMulDiv(sqrtPriceX96, UINT_Q96);
        uint256 perpsNotional = amount0.fullMulDiv(priceX96, UINT_Q96);
        notional = perpsNotional + uint256(amount1);

        // uint256 minMarginRatioAdjusted = FixedPointMathLib.max(minMarginRatio, 1e6.mulDiv(SCALE_1E6, notional));

        // vm.assume(minMarginRatioAdjusted <= maxMarginRatio);

        // marginRatio = bound(marginRatio, minMarginRatioAdjusted, maxMarginRatio);

        margin = uint128(notional.fullMulDiv(marginRatio, SCALE_1E6));

        console2.log("perphandler margin", margin);
        console2.log("perphandler marginRatio", marginRatio);
        console2.log("perphandler notional", notional);

        IPerpManager.OpenMakerPositionParams memory params = IPerpManager.OpenMakerPositionParams({
            margin: margin,
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper,
            maxAmt0In: type(uint128).max,
            maxAmt1In: type(uint128).max
        });

        deal(usdc, actor, margin);
        usdc.safeApprove(address(perpManager), margin);
        uint128 makerPosId = perpManager.openMakerPos(perpId, params);
        makerPositions[perpId].push(makerPosId);

        // IPerpManager.Position memory makerPos = perpManager.getMakerPosition(perpId, makerPosId);
        // // TODO: also make this check in open maker ()
        // vm.assume(makerPos.perpsBorrowed > 0 || makerPos.usdBorrowed > 0);

        vm.stopPrank();

        skipTime(secondsToSkip);
    }

    // function addMakerMargin(uint256 perpIndex, uint256 positionIndex, uint128 margin, uint256 secondsToSkip) public {
    //     vm.assume(perps.length != 0);

    //     PoolId perpId = perps[bound(perpIndex, 0, perps.length - 1)];
    //     vm.assume(makerPositions[perpId].length != 0);

    //     uint128 posId = makerPositions[perpId][bound(positionIndex, 0, makerPositions[perpId].length - 1)];

    //     IPerpManager.MakerPos memory makerPos = perpManager.getMakerPosition(perpId, posId);

    //     address actor = makerPos.holder;

    //     margin = uint128(bound(margin, 1, 1000000e6));

    //     vm.startPrank(actor);

    //     IPerpManager.AddMarginParams memory params = IPerpManager.AddMarginParams({posId: posId, margin: margin});

    //     deal(usdc, actor, margin);
    //     usdc.safeApprove(address(perpManager), margin);
    //     perpManager.addMakerMargin(perpId, params);

    //     vm.stopPrank();

    //     skipTime(secondsToSkip);
    // }

    // function closeMakerPosition(uint256 perpIndex, uint256 positionIndex, uint256 secondsToSkip) public {
    //     vm.assume(perps.length != 0);

    //     PoolId perpId = perps[bound(perpIndex, 0, perps.length - 1)];
    //     vm.assume(makerPositions[perpId].length != 0);

    //     (,, uint32 makerLockupPeriod,,,,,,,,,,,,,,,,,,,,) = perpManager.perps(perpId);

    //     positionIndex = uint256(bound(positionIndex, 0, makerPositions[perpId].length - 1));
    //     uint128 posId = makerPositions[perpId][positionIndex];

    //     IPerpManager.MakerPos memory makerPos = perpManager.getMakerPosition(perpId, posId);

    //     address actor = makerPos.holder;

    //     vm.assume(this.time() >= makerPos.entryTimestamp + makerLockupPeriod);

    //     vm.startPrank(actor);

    //     IPerpManager.ClosePositionParams memory params = IPerpManager.ClosePositionParams({
    //         posId: posId,
    //         minAmt0Out: 0,
    //         minAmt1Out: 0,
    //         maxAmt1In: type(uint128).max,
    //         timeout: 1
    //     });

    //     (,,,,uint256 newPriceX96) = perpManager.liveMakerDetails(perpId, posId);

    //     // vm.assume(newPriceX96 );

    //     perpManager.closeMakerPosition(perpId, params);

    //     // Swap-and-pop to maintain array integrity
    //     uint256 lastIndex = makerPositions[perpId].length - 1;

    //     if (positionIndex != lastIndex) {
    //         // Move the last element to the deleted position
    //         makerPositions[perpId][positionIndex] = makerPositions[perpId][lastIndex];
    //     }

    //     // Remove the last element
    //     makerPositions[perpId].pop();

    //     vm.stopPrank();

    //     skipTime(secondsToSkip);
    // }

    // function openTakerPosition(
    //     uint256 actorIndex,
    //     uint256 perpIndex,
    //     bool isLong,
    //     uint256 notionalValue,
    //     uint128 margin,
    //     uint128 levX96,
    //     uint256 secondsToSkip
    // )
    //     public
    // {
    //     vm.assume(perps.length != 0);

    //     address actor = actors[bound(actorIndex, 0, actors.length - 1)];
    //     PoolId perpId = perps[bound(perpIndex, 0, perps.length - 1)];

    //     (,,,,,,,,,,,,,,,uint128 priceImpactBandX96,uint128 maxOpeningLevX96,,,,,,) = perpManager.perps(perpId);

    //     uint256 maxNotionalTakerValue = perpManager.maxNotionalTakerSize(perpId, isLong);
    //     if (maxNotionalTakerValue == 0) {
    //         isLong = !isLong;
    //         maxNotionalTakerValue = perpManager.maxNotionalTakerSize(perpId, isLong);
    //     }

    //     vm.assume(maxNotionalTakerValue != 0);

    //     (IPoolManager poolManager,,,) = perpManager.c();
    //     (uint160 sqrtPriceX96,int24 currentTick,,) = poolManager.getSlot0(perpId);
    //     uint256 priceX96 = sqrtPriceX96.toPriceX96();
    //     uint256 minNotionalTakerValue = 1 * priceX96 / 1e18 / UINT_Q96;

    //     notionalValue = bound(notionalValue, minNotionalTakerValue + 1, maxNotionalTakerValue - 1);

    //     uint128 levX96For1Margin = uint128(FixedPointMathLib.min(notionalValue / 1e12, maxOpeningLevX96));

    //     levX96 = uint128(bound(levX96, 1 * UINT_Q96 / 2, maxOpeningLevX96));
    //     if (levX96 > levX96For1Margin) {
    //         levX96 = levX96For1Margin;
    //     }

    //     margin = uint128(notionalValue.fullMulDiv(UINT_Q96, levX96));

    //     for (uint256 i = 0; i < makerPositions[perpId].length; i++) {
    //         uint128 makerPosId = makerPositions[perpId][i];
    //         IPerpManager.MakerPos memory makerPos = perpManager.getMakerPosition(perpId, makerPosId);
    //     }

    //     vm.startPrank(actor);

    //     IPerpManager.OpenTakerPositionParams memory params = IPerpManager.OpenTakerPositionParams({
    //         isLong: isLong,
    //         margin: margin,
    //         levX96: levX96,
    //         minAmt0Out: 0,
    //         maxAmt0In: type(uint128).max,
    //         timeout: 1
    //     });

    //     deal(usdc, actor, margin);
    //     usdc.safeApprove(address(perpManager), margin);
    //     uint128 takerPosId = perpManager.openTakerPosition(perpId, params);
    //     takerPositions[perpId].push(takerPosId);

    //     IPerpManager.TakerPos memory takerPos = perpManager.getTakerPosition(perpId, takerPosId);
    //     // TODO: also make this check in open taker ()
    //     vm.assume(takerPos.size > 1);

    //     vm.stopPrank();

    //     skipTime(secondsToSkip);
    // }

    function addTakerMargin() public {}

    function closeTakerPosition() public {}

    function increaseCardinalityNext_Perp() public {}

    // beacon actions

    function updateData() public {}

    function increaseCardinalityNext_Beacon() public {}

    // helpers

    function skipTime(uint256 secondsToSkip) public {
        secondsToSkip = bound(secondsToSkip, 0, 7 days);

        uint256 start = this.time();

        IPerpManager.ClosePositionParams memory params =
            IPerpManager.ClosePositionParams({posId: 0, minAmt0Out: 0, minAmt1Out: 0, maxAmt1In: type(uint128).max});

        vm.startPrank(liquidator);

        while (this.time() < start + secondsToSkip) skip(6 hours);

        // check for liquidations across all perps
        // for (uint256 i = 0; i < perps.length; i++) {
        //     PoolId perpId = perps[i];
        //     // check taker liquidations
        //     if (takerPositions[perpId].length > 0) {
        //         for (uint256 j = takerPositions[perpId].length - 1; j > 0; j--) {
        //             (,,,bool isLiquidatable,) = perpManager.liveTakerDetails(perpId, takerPositions[perpId][j]);
        //             if (isLiquidatable) {
        //                 params.posId = takerPositions[perpId][j];
        //                 perpManager.closeTakerPosition(perpId, params);

        //                 // Swap-and-pop to maintain array integrity
        //                 uint256 lastIndex = takerPositions[perpId].length - 1;

        //                 if (j != lastIndex) {
        //                     // Move the last element to the deleted position
        //                     takerPositions[perpId][j] = takerPositions[perpId][lastIndex];
        //                 }

        //                 // Remove the last element
        //                 takerPositions[perpId].pop();
        //             }
        //         }
        //     }

        //     if (makerPositions[perpId].length > 0) {
        //         for (uint256 j = makerPositions[perpId].length - 1; j > 0; j--) {
        //             (,,,bool isLiquidatable,) = perpManager.liveMakerDetails(perpId, makerPositions[perpId][j]);
        //             if (isLiquidatable) {
        //                 params.posId = makerPositions[perpId][j];
        //                 perpManager.closeMakerPosition(perpId, params);

        //                 // Swap-and-pop to maintain array integrity
        //                 uint256 lastIndex = makerPositions[perpId].length - 1;

        //                 if (j != lastIndex) {
        //                     // Move the last element to the deleted position
        //                     makerPositions[perpId][j] = makerPositions[perpId][lastIndex];
        //                 }

        //                 // Remove the last element
        //                 makerPositions[perpId].pop();
        //             }
        //         }
        //     }
        // }

        vm.stopPrank();
    }

    // this is a workaround via ir caching block.timestamp
    function time() external view returns (uint256) {
        return block.timestamp;
    }
}
