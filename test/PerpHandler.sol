// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {PerpManager} from "../src/PerpManager.sol";
import {IBeacon} from "../src/interfaces/IBeacon.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {FixedPoint96} from "../src/libraries/FixedPoint96.sol";
import {PerpLogic} from "../src/libraries/PerpLogic.sol";
import {TradingFee} from "../src/libraries/TradingFee.sol";
import {TestnetBeacon} from "../src/testnet/TestnetBeacon.sol";
import {MAX_CARDINALITY} from "../src/utils/Constants.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolKey} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract PerpHandler is Test {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;
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
        uint32 initialCardinalityNext_Perp,
        uint32 makerLockupPeriod,
        uint32 fundingInterval,
        int24 tickSpacing,
        uint32 twapWindow,
        uint128 tradingFeeCreatorSplitX96,
        uint128 tradingFeeInsuranceSplitX96,
        uint128 priceImpactBandX96,
        uint128 maxOpeningLevX96,
        uint128 liquidationLevX96,
        uint128 liquidationFeeX96,
        uint128 liquidatorFeeSplitX96,
        uint128 baseFeeX96,
        uint128 startFeeX96,
        uint128 targetFeeX96,
        uint128 decay,
        uint128 volatilityScalerX96,
        uint128 maxFeeMultiplierX96,
        uint256 secondsToSkip,
        uint256 makerActorIndex,
        uint128 makerMargin,
        uint128 makerLiquidity,
        int24 makerTickLower,
        bool makerIsTickLowerNegative,
        uint256 makerTickRange,
        uint128 makerLeverageX96,
        uint256 makerSecondsToSkip
    )
        public
    {
        address actor = actors[bound(actorIndex, 0, actors.length - 1)];

        vm.startPrank(actor);

        initialBeaconData = uint256(bound(initialBeaconData, 0, 1000000000 * FixedPoint96.UINT_Q96));

        IBeacon beacon = new TestnetBeacon(
            actor, initialBeaconData, uint32(bound(initialCardinalityNext_Beacon, 1, MAX_CARDINALITY))
        );
        beacons.push(beacon);

        uint256 startingPriceX96Lower = initialBeaconData.mulDiv(9, 10);
        uint256 startingPriceX96Upper = initialBeaconData.mulDiv(11, 10);

        uint256 minStartingSqrtPriceX96 = startingPriceX96Lower.mulSqrt(FixedPoint96.UINT_Q96);
        minStartingSqrtPriceX96 = FixedPointMathLib.max(minStartingSqrtPriceX96, TickMath.MIN_SQRT_PRICE);
        minStartingSqrtPriceX96 = FixedPointMathLib.min(minStartingSqrtPriceX96, TickMath.MAX_SQRT_PRICE);

        uint256 maxStartingSqrtPriceX96 = startingPriceX96Upper.mulSqrt(FixedPoint96.UINT_Q96);
        maxStartingSqrtPriceX96 = FixedPointMathLib.min(maxStartingSqrtPriceX96, TickMath.MAX_SQRT_PRICE);
        maxStartingSqrtPriceX96 = FixedPointMathLib.max(maxStartingSqrtPriceX96, TickMath.MIN_SQRT_PRICE);
        
        startingSqrtPriceX96 = uint160(bound(startingSqrtPriceX96, minStartingSqrtPriceX96, maxStartingSqrtPriceX96));
        initialCardinalityNext_Perp = uint32(bound(initialCardinalityNext_Perp, 1, MAX_CARDINALITY));
        makerLockupPeriod = uint32(bound(makerLockupPeriod, 0, 7 days));
        fundingInterval = uint32(bound(fundingInterval, 1, type(uint32).max));
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        twapWindow = uint32(bound(twapWindow, 1, type(uint32).max));
        uint128 boundedTradingFeeCreatorSplitX96 = uint128(bound(tradingFeeCreatorSplitX96, 0, FixedPoint96.UINT_Q96));
        tradingFeeCreatorSplitX96 = boundedTradingFeeCreatorSplitX96;
        tradingFeeInsuranceSplitX96 =
            uint128(bound(tradingFeeInsuranceSplitX96, 0, FixedPoint96.UINT_Q96 - boundedTradingFeeCreatorSplitX96));
        priceImpactBandX96 = uint128(bound(priceImpactBandX96, 1 * FixedPoint96.UINT_Q96 / 100, 10 * FixedPoint96.UINT_Q96 / 100));
        maxOpeningLevX96 =
            uint128(bound(maxOpeningLevX96, (1 * FixedPoint96.UINT_Q96) + 1, 100 * FixedPoint96.UINT_Q96));
        liquidationLevX96 = uint128(bound(liquidationLevX96, maxOpeningLevX96 + 1, type(uint128).max));
        liquidationFeeX96 = uint128(bound(liquidationFeeX96, 0, FixedPoint96.UINT_Q96));
        liquidatorFeeSplitX96 = uint128(bound(liquidatorFeeSplitX96, 0, FixedPoint96.UINT_Q96));
        uint128 boundedMaxFeeMultiplierX96 =
            uint128(bound(maxFeeMultiplierX96, FixedPoint96.UINT_Q96, type(uint128).max));
        startFeeX96 = uint128(
            bound(startFeeX96, 0, FixedPoint96.UINT_Q96.mulDiv(FixedPoint96.UINT_Q96, boundedMaxFeeMultiplierX96))
        );
        targetFeeX96 = uint128(
            bound(targetFeeX96, 0, FixedPoint96.UINT_Q96.mulDiv(FixedPoint96.UINT_Q96, boundedMaxFeeMultiplierX96))
        );
        decay = uint128(bound(decay, 1, type(uint128).max));
        volatilityScalerX96 = volatilityScalerX96;
        maxFeeMultiplierX96 = boundedMaxFeeMultiplierX96;

        IPerpManager.CreatePerpParams memory params = IPerpManager.CreatePerpParams({
            startingSqrtPriceX96: startingSqrtPriceX96,
            initialCardinalityNext: initialCardinalityNext_Perp,
            makerLockupPeriod: makerLockupPeriod,
            fundingInterval: fundingInterval,
            beacon: address(beacon),
            tickSpacing: tickSpacing,
            twapWindow: twapWindow,
            tradingFeeCreatorSplitX96: tradingFeeCreatorSplitX96,
            tradingFeeInsuranceSplitX96: tradingFeeInsuranceSplitX96,
            priceImpactBandX96: priceImpactBandX96,
            maxOpeningLevX96: maxOpeningLevX96,
            liquidationLevX96: liquidationLevX96,
            liquidationFeeX96: liquidationFeeX96,
            liquidatorFeeSplitX96: liquidatorFeeSplitX96,
            tradingFeeConfig: TradingFee.Config({
                baseFeeX96: baseFeeX96, // ignored
                startFeeX96: startFeeX96,
                targetFeeX96: targetFeeX96,
                decay: decay,
                volatilityScalerX96: volatilityScalerX96,
                maxFeeMultiplierX96: maxFeeMultiplierX96
            })
        });

        deal(usdc, actor, perpManager.CREATION_FEE_AMT());
        usdc.safeApprove(address(perpManager), perpManager.CREATION_FEE_AMT());
        PoolId perpId = perpManager.createPerp(params);
        perps.push(perpId);

        vm.stopPrank();

        skipTime(secondsToSkip);

        openMakerPosition(makerActorIndex, perps.length - 1, makerMargin, makerLiquidity, makerTickLower, makerIsTickLowerNegative, makerTickRange, makerLeverageX96, makerSecondsToSkip);
    }

    function openMakerPosition(
        uint256 actorIndex,
        uint256 perpIndex,
        uint128 margin,
        uint128 liquidity,
        int24 tickLower,
        bool isTickLowerNegative,
        uint256 tickRange,
        uint128 leverageX96,
        uint256 secondsToSkip
    )
        public
    {
        vm.assume(perps.length != 0);

        address actor = actors[bound(actorIndex, 0, actors.length - 1)];
        PoolId perpId = perps[bound(perpIndex, 0, perps.length - 1)];

        (,,,,,,,,,,,,,,,, uint128 maxOpeningLevX96,,,, PoolKey memory key,,) = perpManager.perps(perpId);

        vm.startPrank(actor);

        int24 tickSpacing = key.tickSpacing;

        int24 MAX_TICK = TickMath.maxUsableTick(tickSpacing);

        tickLower = int24(bound(tickLower, 0, MAX_TICK));
        tickLower = isTickLowerNegative ? -tickLower : tickLower;
        if (tickLower + tickSpacing > MAX_TICK) tickLower -= tickSpacing;

        tickLower = (tickLower / tickSpacing) * tickSpacing;

        uint256 maxTickRange = uint256(int256(MAX_TICK - tickLower));
        tickRange = uint256(bound(tickRange, uint256(int256(tickSpacing)), maxTickRange));
        int24 tickUpper = tickLower + int24(int256(tickRange));
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;

        uint256 maxLiquidityPerTick = type(uint64).max / 1774544 / 10;
        uint256 maxLiquidity = maxLiquidityPerTick * tickRange;
        liquidity = uint128(bound(liquidity, 1, maxLiquidity));

        (IPoolManager poolManager,,,) = perpManager.c();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(perpId);
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );

        uint256 notional = amount0.mulDiv(sqrtPriceX96.toPriceX96(), FixedPoint96.UINT_Q96) + amount1;

        // leverageX96 = uint128(bound(leverageX96, 1 * FixedPoint96.UINT_Q96 / 2, maxOpeningLevX96));
        leverageX96 = uint128(1 * FixedPoint96.UINT_Q96);

        uint256 targetScaledMargin18 = notional.fullMulDiv(FixedPoint96.UINT_Q96, leverageX96);
        margin = uint128(targetScaledMargin18) + 1;

        IPerpManager.OpenMakerPositionParams memory params = IPerpManager.OpenMakerPositionParams({
            margin: margin,
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper,
            maxAmt0In: type(uint128).max,
            maxAmt1In: type(uint128).max,
            timeout: 1
        });

        deal(usdc, actor, margin);
        usdc.safeApprove(address(perpManager), margin);
        uint128 makerPosId = perpManager.openMakerPosition(perpId, params);
        makerPositions[perpId].push(makerPosId);

        IPerpManager.MakerPos memory makerPos = perpManager.getMakerPosition(perpId, makerPosId);
        // TODO: also make this check in open maker ()
        vm.assume(makerPos.perpsBorrowed > 0 || makerPos.usdBorrowed > 0);

        vm.stopPrank();

        skipTime(secondsToSkip);
    }

    function addMakerMargin(uint256 perpIndex, uint256 positionIndex, uint128 margin, uint256 secondsToSkip) public {
        vm.assume(perps.length != 0);

        PoolId perpId = perps[bound(perpIndex, 0, perps.length - 1)];
        vm.assume(makerPositions[perpId].length != 0);

        uint128 posId = makerPositions[perpId][bound(positionIndex, 0, makerPositions[perpId].length - 1)];

        IPerpManager.MakerPos memory makerPos = perpManager.getMakerPosition(perpId, posId);

        address actor = makerPos.holder;

        margin = uint128(bound(margin, 1, 1000000e6));

        vm.startPrank(actor);

        IPerpManager.AddMarginParams memory params = IPerpManager.AddMarginParams({posId: posId, margin: margin});

        deal(usdc, actor, margin);
        usdc.safeApprove(address(perpManager), margin);
        perpManager.addMakerMargin(perpId, params);

        vm.stopPrank();

        skipTime(secondsToSkip);
    }

    function closeMakerPosition(uint256 perpIndex, uint256 positionIndex, uint256 secondsToSkip) public {
        vm.assume(perps.length != 0);

        PoolId perpId = perps[bound(perpIndex, 0, perps.length - 1)];
        vm.assume(makerPositions[perpId].length != 0);

        (,, uint32 makerLockupPeriod,,,,,,,,,,,,,,,,,,,,) = perpManager.perps(perpId);

        positionIndex = uint256(bound(positionIndex, 0, makerPositions[perpId].length - 1));
        uint128 posId = makerPositions[perpId][positionIndex];

        IPerpManager.MakerPos memory makerPos = perpManager.getMakerPosition(perpId, posId);

        address actor = makerPos.holder;

        vm.assume(this.time() >= makerPos.entryTimestamp + makerLockupPeriod);

        vm.startPrank(actor);

        IPerpManager.ClosePositionParams memory params = IPerpManager.ClosePositionParams({
            posId: posId,
            minAmt0Out: 0,
            minAmt1Out: 0,
            maxAmt1In: type(uint128).max,
            timeout: 1
        });

        (,,,,uint256 newPriceX96) = perpManager.liveMakerDetails(perpId, posId);

        // vm.assume(newPriceX96 );

        perpManager.closeMakerPosition(perpId, params);

        // Swap-and-pop to maintain array integrity
        uint256 lastIndex = makerPositions[perpId].length - 1;

        if (positionIndex != lastIndex) {
            // Move the last element to the deleted position
            makerPositions[perpId][positionIndex] = makerPositions[perpId][lastIndex];
        }

        // Remove the last element
        makerPositions[perpId].pop();

        vm.stopPrank();

        skipTime(secondsToSkip);
    }

    function openTakerPosition(
        uint256 actorIndex,
        uint256 perpIndex,
        bool isLong,
        uint256 notionalValue,
        uint128 margin,
        uint128 levX96,
        uint256 secondsToSkip
    )
        public
    {
        vm.assume(perps.length != 0);

        address actor = actors[bound(actorIndex, 0, actors.length - 1)];
        PoolId perpId = perps[bound(perpIndex, 0, perps.length - 1)];

        (,,,,,,,,,,,,,,,uint128 priceImpactBandX96,uint128 maxOpeningLevX96,,,,,,) = perpManager.perps(perpId);

        uint256 maxNotionalTakerValue = perpManager.maxNotionalTakerSize(perpId, isLong);
        if (maxNotionalTakerValue == 0) {
            isLong = !isLong;
            maxNotionalTakerValue = perpManager.maxNotionalTakerSize(perpId, isLong);
        }

        vm.assume(maxNotionalTakerValue != 0);

        (IPoolManager poolManager,,,) = perpManager.c();
        (uint160 sqrtPriceX96,int24 currentTick,,) = poolManager.getSlot0(perpId);
        uint256 priceX96 = sqrtPriceX96.toPriceX96();
        uint256 minNotionalTakerValue = 1 * priceX96 / 1e18 / FixedPoint96.UINT_Q96;

        notionalValue = bound(notionalValue, minNotionalTakerValue + 1, maxNotionalTakerValue - 1);

        uint128 levX96For1Margin = uint128(FixedPointMathLib.min(notionalValue / 1e12, maxOpeningLevX96));

        levX96 = uint128(bound(levX96, 1 * FixedPoint96.UINT_Q96 / 2, maxOpeningLevX96));
        if (levX96 > levX96For1Margin) {
            levX96 = levX96For1Margin;
        }

        margin = uint128(notionalValue.fullMulDiv(FixedPoint96.UINT_Q96, levX96));

        for (uint256 i = 0; i < makerPositions[perpId].length; i++) {
            uint128 makerPosId = makerPositions[perpId][i];
            IPerpManager.MakerPos memory makerPos = perpManager.getMakerPosition(perpId, makerPosId);
        }

        vm.startPrank(actor);

        IPerpManager.OpenTakerPositionParams memory params = IPerpManager.OpenTakerPositionParams({
            isLong: isLong,
            margin: margin,
            levX96: levX96,
            minAmt0Out: 0,
            maxAmt0In: type(uint128).max,
            timeout: 1
        });

        deal(usdc, actor, margin);
        usdc.safeApprove(address(perpManager), margin);
        uint128 takerPosId = perpManager.openTakerPosition(perpId, params);
        takerPositions[perpId].push(takerPosId);

        IPerpManager.TakerPos memory takerPos = perpManager.getTakerPosition(perpId, takerPosId);
        // TODO: also make this check in open taker ()
        vm.assume(takerPos.size > 1);

        vm.stopPrank();

        skipTime(secondsToSkip);
    }

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

        IPerpManager.ClosePositionParams memory params = IPerpManager.ClosePositionParams({
            posId: 0,
            minAmt0Out: 0,
            minAmt1Out: 0,
            maxAmt1In: type(uint128).max,
            timeout: type(uint32).max
        });

        vm.startPrank(liquidator);

        while (this.time() < start + secondsToSkip) {
            skip(6 hours);

            // check for liquidations across all perps
            for (uint256 i = 0; i < perps.length; i++) {
                PoolId perpId = perps[i];
                // check taker liquidations
                if (takerPositions[perpId].length > 0) {
                    for (uint256 j = takerPositions[perpId].length - 1; j > 0; j--) {
                        (,,,bool isLiquidatable,) = perpManager.liveTakerDetails(perpId, takerPositions[perpId][j]);
                        if (isLiquidatable) {
                            params.posId = takerPositions[perpId][j];
                            perpManager.closeTakerPosition(perpId, params);

                            // Swap-and-pop to maintain array integrity
                            uint256 lastIndex = takerPositions[perpId].length - 1;

                            if (j != lastIndex) {
                                // Move the last element to the deleted position
                                takerPositions[perpId][j] = takerPositions[perpId][lastIndex];
                            }

                            // Remove the last element
                            takerPositions[perpId].pop();
                        }
                    }
                }

                if (makerPositions[perpId].length > 0) {
                    for (uint256 j = makerPositions[perpId].length - 1; j > 0; j--) {
                        (,,,bool isLiquidatable,) = perpManager.liveMakerDetails(perpId, makerPositions[perpId][j]);
                        if (isLiquidatable) {
                            params.posId = makerPositions[perpId][j];
                            perpManager.closeMakerPosition(perpId, params);

                            // Swap-and-pop to maintain array integrity
                            uint256 lastIndex = makerPositions[perpId].length - 1;

                            if (j != lastIndex) {
                                // Move the last element to the deleted position
                                makerPositions[perpId][j] = makerPositions[perpId][lastIndex];
                            }

                            // Remove the last element
                            makerPositions[perpId].pop();
                        }
                    }
                }
            }
        }

        vm.stopPrank();
    }

    // this is a workaround via ir caching block.timestamp
    function time() external view returns (uint256) {
        return block.timestamp;
    }
}
