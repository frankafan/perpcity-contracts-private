// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { AccountingToken } from "./AccountingToken.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "v4-periphery/src/interfaces/IPositionManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { IUniversalRouter } from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBeacon } from "./interfaces/IBeacon.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { Pool } from "@uniswap/v4-core/src/libraries/Pool.sol";
import { BalanceDelta, toBalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { SwapMath } from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import { BitMath } from "@uniswap/v4-core/src/libraries/BitMath.sol";
import { ProtocolFeeLibrary } from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import { UnsafeMath } from "@uniswap/v4-core/src/libraries/UnsafeMath.sol";
import { FixedPoint128 } from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import { LiquidityMath } from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import { UniswapV4Utility } from "./libraries/UniswapV4Utility.sol";
import { Tick } from "./libraries/Tick.sol";
import { CustomRevert } from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import { Funding } from "./libraries/Funding.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

// TODO: organize import order
// TODO: remove unused imports
// TODO: organize state variable order
// TODO: correct typing for structs, params (for safety), and global variables / constants
//      - uint128 for margin and leverage
//      - uint24 for fee
//      - int24 for tickSpacing
//      - uint128 for margin
//      - uint128 for leverage
// TODO: less arbitrary deadline for ROUTER.execute
// TODO: check for rounding errors due to setting token supply to max uint256
// TODO: see if there's a way to keep poolKey immutable
// TODO: maybe max minAmountOut in _swapExactInputSingle() in a variable in openTakerPosition()
// TODO: reorder structs for packing
// TODO: check for rounding errors
// TODO: check uint218 castings for safety (maybe use uniswap safe casting library)
// TODO: replace math with uniswap math where possible
// TODO: reorder functions
// TODO: use TWAPS for funding (uniswap price oracle, think of solution for index)
// TODO: simplify int256 and uint256 mixing / casting for funding related variables
// TODO: liquidation related functions visibility (external when possible instead of public)
// TODO: open maker positon rounding errors

contract Perp {
    using StateLibrary for IPoolManager;
    using Tick for mapping(int24 => Tick.GrowthInfo);
    using SafeCast for *;
    using ProtocolFeeLibrary for *;
    using LPFeeLibrary for uint24;
    using CustomRevert for bytes4;

    struct UniswapV4Contracts {
        address poolManager;
        address router;
        address positionManager;
        address permit2;
    }

    struct PerpConfig {
        address usdc;
        address beacon;
        uint24 tradingFee;
        uint256 minMargin;
        uint256 maxMargin;
        uint256 minOpeningLeverageX96;
        uint256 maxOpeningLeverageX96;
        uint256 liquidationMarginRatioX96;
        uint256 liquidationFeeX96;
        uint256 liquidationFeeSplitX96;
    }

    struct UniswapV4PoolConfig {
        int24 tickSpacing;
        address hook;
        uint160 startingSqrtPriceX96;
    }

    struct MakerPosition {
        address holder;
        uint128 margin;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceLowerX96;
        uint160 sqrtPriceUpperX96;
        uint256 perpsBorrowed;
        uint256 usdBorrowed;
        int256 entryCumulativeFundingX96;
        int256 entryCumulativeFundingDivBySqrtMarkX96;
    }

    struct TakerPosition {
        address holder;
        bool isLong;
        uint128 size;
        uint256 margin;
        uint256 entryValue;
        int256 entryCumulativeFundingX96;
    }

    IPoolManager private immutable POOL_MANAGER;
    IUniversalRouter private immutable ROUTER;
    IPositionManager private immutable POSITION_MANAGER;

    PoolKey private poolKey;

    IERC20 public immutable USDC;
    IBeacon public immutable BEACON;
    uint24 private immutable TRADING_FEE;
    uint256 public immutable MIN_MARGIN;
    uint256 public immutable MAX_MARGIN;
    uint256 public immutable MIN_OPENING_LEVERAGE_X96;
    uint256 public immutable MAX_OPENING_LEVERAGE_X96;
    uint256 private immutable LIQUIDATION_MARGIN_RATIO_X96;
    uint256 private immutable LIQUIDATION_FEE_X96;
    uint256 private immutable LIQUIDATION_FEE_SPLIT_X96;

    uint256 private nextTakerPosId;
    mapping(uint256 takerPosId => TakerPosition takerPos) public takerPositions;
    mapping(uint256 makerPosId => MakerPosition makerPos) public makerPositions;
    int256 public fundingRateX96;
    int256 private cumulativeFundingX96;
    int256 private cumulativeFundingDivBySqrtMarkX96;
    uint256 private lastFundingUpdate;
    mapping(int24 => Tick.GrowthInfo) private tickGrowthInfo;

    uint256 private constant Q192 = uint256(FixedPoint96.Q96) * uint256(FixedPoint96.Q96);
    uint256 private constant USDC_SCALING_FACTOR = 1e12;

    event TakerPositionOpened(
        uint256 takerPosId, address holder, bool isLong, uint128 size, uint256 markPrice, uint256 indexPrice
    );
    event TakerPositionClosed(uint256 takerPosId, address holder, bool isLong, uint128 size, uint256 markPrice);

    error MarginTooLow(uint256 desiredMargin, uint256 minMargin);
    error MarginTooHigh(uint256 desiredMargin, uint256 maxMargin);
    error LeverageTooLow(uint256 desiredLeverage, uint256 minOpeningLeverage);
    error LeverageTooHigh(uint256 desiredLeverage, uint256 maxOpeningLeverage);
    error InvalidClose(address caller, address positionHolder, bool isLiquidatable);

    constructor(
        UniswapV4Contracts memory uniswapV4Contracts,
        PerpConfig memory perpConfig,
        UniswapV4PoolConfig memory uniswapV4PoolConfig
    ) {
        POOL_MANAGER = IPoolManager(uniswapV4Contracts.poolManager);
        ROUTER = IUniversalRouter(payable(uniswapV4Contracts.router));
        POSITION_MANAGER = IPositionManager(uniswapV4Contracts.positionManager);

        USDC = IERC20(perpConfig.usdc);
        BEACON = IBeacon(perpConfig.beacon);

        TRADING_FEE = perpConfig.tradingFee;
        MIN_MARGIN = perpConfig.minMargin;
        MAX_MARGIN = perpConfig.maxMargin;
        MIN_OPENING_LEVERAGE_X96 = perpConfig.minOpeningLeverageX96;
        MAX_OPENING_LEVERAGE_X96 = perpConfig.maxOpeningLeverageX96;
        LIQUIDATION_MARGIN_RATIO_X96 = perpConfig.liquidationMarginRatioX96;
        LIQUIDATION_FEE_X96 = perpConfig.liquidationFeeX96;
        LIQUIDATION_FEE_SPLIT_X96 = perpConfig.liquidationFeeSplitX96;

        AccountingToken accountingTokenA = new AccountingToken(type(uint256).max);
        AccountingToken accountingTokenB = new AccountingToken(type(uint256).max);

        UniswapV4Utility._approveTokenWithPermit2(
            uniswapV4Contracts.permit2, address(ROUTER), address(accountingTokenA), type(uint160).max, type(uint48).max
        );
        UniswapV4Utility._approveTokenWithPermit2(
            uniswapV4Contracts.permit2, address(ROUTER), address(accountingTokenB), type(uint160).max, type(uint48).max
        );

        UniswapV4Utility._approveTokenWithPermit2(
            uniswapV4Contracts.permit2,
            address(POSITION_MANAGER),
            address(accountingTokenA),
            type(uint160).max,
            type(uint48).max
        );
        UniswapV4Utility._approveTokenWithPermit2(
            uniswapV4Contracts.permit2,
            address(POSITION_MANAGER),
            address(accountingTokenB),
            type(uint160).max,
            type(uint48).max
        );

        AccountingToken perpAccounting = accountingTokenA < accountingTokenB ? accountingTokenA : accountingTokenB;
        AccountingToken usdAccounting = accountingTokenA < accountingTokenB ? accountingTokenB : accountingTokenA;

        poolKey = PoolKey({
            currency0: Currency.wrap(address(perpAccounting)),
            currency1: Currency.wrap(address(usdAccounting)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: uniswapV4PoolConfig.tickSpacing,
            hooks: IHooks(uniswapV4PoolConfig.hook)
        });

        POOL_MANAGER.initialize(poolKey, uniswapV4PoolConfig.startingSqrtPriceX96);
    }

    function openMakerPosition(
        uint128 margin,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper
    )
        external
        returns (uint256 makerPosId)
    {
        if (margin < MIN_MARGIN) revert MarginTooLow(margin, MIN_MARGIN);
        if (margin > MAX_MARGIN) revert MarginTooHigh(margin, MAX_MARGIN);

        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolKey.toId());

        {
            (uint256 amount0, uint256 amount1) =
                LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity);

            uint256 notionalValue =
                amount1 + FullMath.mulDiv(amount0, uint256(sqrtPriceX96) * uint256(sqrtPriceX96), Q192);
            uint256 leverageX96 = FullMath.mulDiv(notionalValue, FixedPoint96.Q96, margin * USDC_SCALING_FACTOR);

            if (leverageX96 < MIN_OPENING_LEVERAGE_X96) revert LeverageTooLow(leverageX96, MIN_OPENING_LEVERAGE_X96);
            if (leverageX96 > MAX_OPENING_LEVERAGE_X96) revert LeverageTooHigh(leverageX96, MAX_OPENING_LEVERAGE_X96);
        }

        (uint128 tickLowerLiquidityGrossBefore,,,) = POOL_MANAGER.getTickInfo(poolKey.toId(), tickLower);
        (uint128 tickUpperLiquidityGrossBefore,,,) = POOL_MANAGER.getTickInfo(poolKey.toId(), tickUpper);

        _updateCumulativeFunding();

        (uint256 tokenId, uint256 perpsBorrowed, uint256 usdBorrowed) = UniswapV4Utility._mintLiquidityPosition(
            poolKey, POSITION_MANAGER, tickLower, tickUpper, liquidity, type(uint128).max, type(uint128).max
        );

        _updateFundingRate();

        (, int24 currentTick,,) = POOL_MANAGER.getSlot0(poolKey.toId());

        if (tickLowerLiquidityGrossBefore == 0) {
            tickGrowthInfo.initialize(
                tickLower,
                currentTick,
                Tick.GrowthInfo({
                    twPremiumX96: cumulativeFundingX96,
                    twPremiumDivBySqrtPriceX96: cumulativeFundingDivBySqrtMarkX96
                })
            );
        }

        if (tickUpperLiquidityGrossBefore == 0) {
            tickGrowthInfo.initialize(
                tickUpper,
                currentTick,
                Tick.GrowthInfo({
                    twPremiumX96: cumulativeFundingX96,
                    twPremiumDivBySqrtPriceX96: cumulativeFundingDivBySqrtMarkX96
                })
            );
        }

        makerPosId = tokenId;
        makerPositions[makerPosId] = MakerPosition({
            holder: msg.sender,
            margin: margin,
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper,
            sqrtPriceLowerX96: sqrtPriceLowerX96,
            sqrtPriceUpperX96: sqrtPriceUpperX96,
            perpsBorrowed: perpsBorrowed,
            usdBorrowed: usdBorrowed,
            entryCumulativeFundingX96: cumulativeFundingX96,
            entryCumulativeFundingDivBySqrtMarkX96: cumulativeFundingDivBySqrtMarkX96
        });

        USDC.transferFrom(msg.sender, address(this), margin);
    }

    function closeMakerPosition(uint256 makerPosId) external {
        _updateCumulativeFunding();

        (uint256 perpsReceived, uint256 usdReceived) =
            UniswapV4Utility._burnLiquidityPosition(poolKey, POSITION_MANAGER, makerPosId);

        MakerPosition memory makerPos = makerPositions[makerPosId];

        int256 pnl = int256(usdReceived) - int256(makerPos.usdBorrowed);
        if (perpsReceived < makerPos.perpsBorrowed) {
            uint128 amountOut = SafeCast.toUint128(makerPos.perpsBorrowed - perpsReceived);
            _simulateSwap(
                Pool.SwapParams({
                    amountSpecified: -int128(amountOut),
                    tickSpacing: poolKey.tickSpacing,
                    zeroForOne: false,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1,
                    lpFeeOverride: 0
                })
            );
            pnl -=
                int128(UniswapV4Utility._swapExactOutputSingle(ROUTER, poolKey, false, amountOut, type(uint128).max, 0));
        } else {
            uint128 amountIn = SafeCast.toUint128(perpsReceived - makerPos.perpsBorrowed);
            _simulateSwap(
                Pool.SwapParams({
                    amountSpecified: int128(amountIn),
                    tickSpacing: poolKey.tickSpacing,
                    zeroForOne: true,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
                    lpFeeOverride: 0
                })
            );
            pnl += int128(UniswapV4Utility._swapExactInputSingle(ROUTER, poolKey, true, amountIn, 0, 0));
        }

        _updateFundingRate();

        {
            (uint128 tickLowerLiquidityGrossAfter,,,) = POOL_MANAGER.getTickInfo(poolKey.toId(), makerPos.tickLower);
            (uint128 tickUpperLiquidityGrossAfter,,,) = POOL_MANAGER.getTickInfo(poolKey.toId(), makerPos.tickUpper);

            if (tickLowerLiquidityGrossAfter == 0) {
                tickGrowthInfo.clear(makerPos.tickLower);
            }

            if (tickUpperLiquidityGrossAfter == 0) {
                tickGrowthInfo.clear(makerPos.tickUpper);
            }
        }

        (uint160 sqrtPriceX96, int24 currentTick,,) = POOL_MANAGER.getSlot0(poolKey.toId());

        int256 funding = Funding.calcPendingFundingPaymentWithLiquidityCoefficient(
            int256(makerPos.perpsBorrowed),
            makerPos.entryCumulativeFundingX96,
            Funding.Growth({
                twPremiumX96: cumulativeFundingX96,
                twPremiumDivBySqrtPriceX96: cumulativeFundingDivBySqrtMarkX96
            }),
            Funding.calcLiquidityCoefficientInFundingPaymentByOrder(
                makerPos.liquidity,
                makerPos.tickLower,
                makerPos.tickUpper,
                tickGrowthInfo.getAllFundingGrowth(
                    makerPos.tickLower,
                    makerPos.tickUpper,
                    currentTick,
                    cumulativeFundingX96,
                    cumulativeFundingDivBySqrtMarkX96
                )
            )
        );

        uint256 effectiveMargin = uint256(int256(uint256(makerPos.margin) * USDC_SCALING_FACTOR) + pnl - funding);
        uint256 liquidationFee = FullMath.mulDiv(effectiveMargin, LIQUIDATION_FEE_X96, FixedPoint96.Q96);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, makerPos.sqrtPriceLowerX96, makerPos.sqrtPriceUpperX96, makerPos.liquidity
        );

        uint256 notionalValue = amount1 + FullMath.mulDiv(amount0, uint256(sqrtPriceX96) * uint256(sqrtPriceX96), Q192);

        if (
            FullMath.mulDiv((effectiveMargin - liquidationFee), FixedPoint96.Q96, notionalValue)
                < LIQUIDATION_MARGIN_RATIO_X96
        ) {
            USDC.transfer(msg.sender, (effectiveMargin - liquidationFee) / USDC_SCALING_FACTOR);
            USDC.transfer(
                msg.sender,
                FullMath.mulDiv(liquidationFee / USDC_SCALING_FACTOR, LIQUIDATION_FEE_SPLIT_X96, FixedPoint96.Q96)
            );
        } else if (makerPos.holder == msg.sender) {
            USDC.transfer(msg.sender, effectiveMargin / USDC_SCALING_FACTOR);
        } else {
            revert InvalidClose(msg.sender, makerPos.holder, false);
        }

        delete makerPositions[makerPosId];
    }

    function openTakerPosition(
        bool isLong,
        uint128 margin,
        uint256 leverageX96
    )
        external
        returns (uint256 takerPosId)
    {
        if (margin < MIN_MARGIN) revert MarginTooLow(margin, MIN_MARGIN);
        if (margin > MAX_MARGIN) revert MarginTooHigh(margin, MAX_MARGIN);
        if (leverageX96 < MIN_OPENING_LEVERAGE_X96) revert LeverageTooLow(leverageX96, MIN_OPENING_LEVERAGE_X96);
        if (leverageX96 > MAX_OPENING_LEVERAGE_X96) revert LeverageTooHigh(leverageX96, MAX_OPENING_LEVERAGE_X96);

        _updateCumulativeFunding();

        uint128 perpsMoved;
        uint128 usdMoved =
            SafeCast.toUint128(FullMath.mulDiv(margin * USDC_SCALING_FACTOR, leverageX96, FixedPoint96.Q96));
        if (isLong) {
            // usd moved in
            _simulateSwap(
                Pool.SwapParams({
                    amountSpecified: int128(usdMoved),
                    tickSpacing: poolKey.tickSpacing,
                    zeroForOne: false,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1,
                    lpFeeOverride: TRADING_FEE
                })
            );
            perpsMoved = UniswapV4Utility._swapExactInputSingle(ROUTER, poolKey, false, usdMoved, 0, TRADING_FEE); // perps
                // moved out
        } else {
            // usd moved out
            _simulateSwap(
                Pool.SwapParams({
                    amountSpecified: -int128(usdMoved),
                    tickSpacing: poolKey.tickSpacing,
                    zeroForOne: true,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
                    lpFeeOverride: 0
                })
            );
            perpsMoved = UniswapV4Utility._swapExactOutputSingle(ROUTER, poolKey, true, usdMoved, type(uint128).max, 0); // perps
                // moved in
        }

        _updateFundingRate();

        takerPosId = nextTakerPosId;
        takerPositions[takerPosId] = TakerPosition({
            holder: msg.sender,
            isLong: isLong,
            size: perpsMoved,
            margin: margin,
            entryValue: usdMoved,
            entryCumulativeFundingX96: cumulativeFundingX96
        });
        nextTakerPosId++;

        USDC.transferFrom(msg.sender, address(this), margin);

        (uint256 indexPrice,) = BEACON.getData();

        emit TakerPositionOpened(takerPosId, msg.sender, isLong, perpsMoved, liveMark(), indexPrice);
    }

    function closeTakerPosition(uint256 takerPosId) external {
        _updateCumulativeFunding();

        TakerPosition memory takerPos = takerPositions[takerPosId];

        uint256 notionalValue;
        int256 pnl;
        if (takerPos.isLong) {
            uint128 amountIn = takerPos.size;
            _simulateSwap(
                Pool.SwapParams({
                    amountSpecified: int128(amountIn),
                    tickSpacing: poolKey.tickSpacing,
                    zeroForOne: true,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
                    lpFeeOverride: 0
                })
            );
            notionalValue = UniswapV4Utility._swapExactInputSingle(ROUTER, poolKey, true, amountIn, 0, 0);
            pnl = (int256(notionalValue) - int256(takerPos.entryValue));
        } else {
            uint128 amountOut = takerPos.size;
            _simulateSwap(
                Pool.SwapParams({
                    amountSpecified: -int128(amountOut),
                    tickSpacing: poolKey.tickSpacing,
                    zeroForOne: false,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1,
                    lpFeeOverride: TRADING_FEE
                })
            );
            notionalValue = UniswapV4Utility._swapExactOutputSingle(
                ROUTER, poolKey, false, amountOut, type(uint128).max, TRADING_FEE
            );
            pnl = (int256(takerPos.entryValue) - int256(notionalValue));
        }

        _updateFundingRate();

        int256 funding = (cumulativeFundingX96 - takerPos.entryCumulativeFundingX96) * SafeCast.toInt256(takerPos.size)
            / SafeCast.toInt256(FixedPoint96.Q96);
        if (!takerPos.isLong) funding = -funding;

        uint256 effectiveMargin = uint256(int256(takerPos.margin * USDC_SCALING_FACTOR) + pnl - funding);
        uint256 liquidationFee = FullMath.mulDiv(effectiveMargin, LIQUIDATION_FEE_X96, FixedPoint96.Q96);

        // check if isliquidatable, then liquidate, else check caller, then close, else revert
        if (
            FullMath.mulDiv((effectiveMargin - liquidationFee), FixedPoint96.Q96, notionalValue)
                < LIQUIDATION_MARGIN_RATIO_X96
        ) {
            USDC.transfer(takerPos.holder, (effectiveMargin - liquidationFee) / USDC_SCALING_FACTOR);
            USDC.transfer(
                msg.sender,
                FullMath.mulDiv(liquidationFee / USDC_SCALING_FACTOR, LIQUIDATION_FEE_SPLIT_X96, FixedPoint96.Q96)
            );
        } else if (takerPos.holder == msg.sender) {
            USDC.transfer(takerPos.holder, effectiveMargin / USDC_SCALING_FACTOR);
        } else {
            revert InvalidClose(msg.sender, takerPos.holder, false);
        }

        emit TakerPositionClosed(takerPosId, takerPos.holder, takerPos.isLong, takerPos.size, liveMark());

        delete takerPositions[takerPosId];
    }

    function _updateCumulativeFunding() internal {
        uint256 timeSinceLastUpdate = block.timestamp - lastFundingUpdate;
        // funding owed per second * time since last update (in seconds)
        cumulativeFundingX96 += fundingRateX96 * int256(timeSinceLastUpdate);

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolKey.toId());
        cumulativeFundingDivBySqrtMarkX96 +=
            fundingRateX96 * int256(timeSinceLastUpdate) * int256(FixedPoint96.Q96) / int256(uint256(sqrtPriceX96));

        lastFundingUpdate = block.timestamp;
    }

    function _updateFundingRate() internal {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolKey.toId());
        uint256 markPriceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);

        (uint256 indexPriceX96,) = BEACON.getData();

        // a notional size 1 long position would pay (markPrice - indexPrice) over the next 1 day
        fundingRateX96 = (int256(markPriceX96) - int256(indexPriceX96)) / 1 days;
    }

    function _simulateSwap(Pool.SwapParams memory params)
        internal
        returns (BalanceDelta swapDelta, uint256 amountToProtocol, uint24 swapFee, Pool.SwapResult memory result)
    {
        (uint160 slot0sqrtPriceX96, int24 slot0tick, uint24 slot0protocolFee, uint24 slot0lpFee) =
            POOL_MANAGER.getSlot0(poolKey.toId());
        bool zeroForOne = params.zeroForOne;

        uint256 protocolFee = zeroForOne ? slot0protocolFee.getZeroForOneFee() : slot0protocolFee.getOneForZeroFee();

        // the amount remaining to be swapped in/out of the input/output asset. initially set to the amountSpecified
        int256 amountSpecifiedRemaining = params.amountSpecified;
        // the amount swapped out/in of the output/input asset. initially set to 0
        int256 amountCalculated = 0;
        // initialize to the current sqrt(price)
        result.sqrtPriceX96 = slot0sqrtPriceX96;
        // initialize to the current tick
        result.tick = slot0tick;
        // initialize to the current liquidity
        result.liquidity = POOL_MANAGER.getLiquidity(poolKey.toId());

        {
            // if the beforeSwap hook returned a valid fee override, use that as the LP fee, otherwise load from storage
            // lpFee, swapFee, and protocolFee are all in pips
            uint24 lpFee =
                params.lpFeeOverride.isOverride() ? params.lpFeeOverride.removeOverrideFlagAndValidate() : slot0lpFee;

            swapFee = protocolFee == 0 ? lpFee : uint16(protocolFee).calculateSwapFee(lpFee);
        }

        // a swap fee totaling MAX_SWAP_FEE (100%) makes exact output swaps impossible since the input is entirely
        // consumed by the fee
        if (swapFee >= SwapMath.MAX_SWAP_FEE) {
            // if exactOutput
            if (params.amountSpecified > 0) {
                Pool.InvalidFeeForExactOut.selector.revertWith();
            }
        }

        // swapFee is the pool's fee in pips (LP fee + protocol fee)
        // when the amount swapped is 0, there is no protocolFee applied and the fee amount paid to the protocol is set
        // to 0
        if (params.amountSpecified == 0) return (BalanceDeltaLibrary.ZERO_DELTA, 0, swapFee, result);

        if (zeroForOne) {
            if (params.sqrtPriceLimitX96 >= slot0sqrtPriceX96) {
                Pool.PriceLimitAlreadyExceeded.selector.revertWith(slot0sqrtPriceX96, params.sqrtPriceLimitX96);
            }
            // Swaps can never occur at MIN_TICK, only at MIN_TICK + 1, except at initialization of a pool
            // Under certain circumstances outlined below, the tick will preemptively reach MIN_TICK without swapping
            // there
            if (params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                Pool.PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        } else {
            if (params.sqrtPriceLimitX96 <= slot0sqrtPriceX96) {
                Pool.PriceLimitAlreadyExceeded.selector.revertWith(slot0sqrtPriceX96, params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                Pool.PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        }

        Pool.StepComputations memory step;

        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = POOL_MANAGER.getFeeGrowthGlobals(poolKey.toId());
        step.feeGrowthGlobalX128 = zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128;

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (!(amountSpecifiedRemaining == 0 || result.sqrtPriceX96 == params.sqrtPriceLimitX96)) {
            step.sqrtPriceStartX96 = result.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                _nextInitializedTickWithinOneWord(POOL_MANAGER, poolKey, result.tick, params.tickSpacing, zeroForOne);

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext <= TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }
            if (step.tickNext >= TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (result.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                result.sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(zeroForOne, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
                result.liquidity,
                amountSpecifiedRemaining,
                swapFee
            );

            // if exactOutput
            if (params.amountSpecified > 0) {
                unchecked {
                    amountSpecifiedRemaining -= step.amountOut.toInt256();
                }
                amountCalculated -= (step.amountIn + step.feeAmount).toInt256();
            } else {
                // safe because we test that amountSpecified > amountIn + feeAmount in SwapMath
                unchecked {
                    amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                }
                amountCalculated += step.amountOut.toInt256();
            }

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            if (protocolFee > 0) {
                unchecked {
                    // step.amountIn does not include the swap fee, as it's already been taken from it,
                    // so add it back to get the total amountIn and use that to calculate the amount of fees owed to the
                    // protocol
                    // cannot overflow due to limits on the size of protocolFee and params.amountSpecified
                    // this rounds down to favor LPs over the protocol
                    uint256 delta = (swapFee == protocolFee)
                        ? step.feeAmount // lp fee is 0, so the entire fee is owed to the protocol instead
                        : (step.amountIn + step.feeAmount) * protocolFee / ProtocolFeeLibrary.PIPS_DENOMINATOR;
                    // subtract it from the total fee and add it to the protocol fee
                    step.feeAmount -= delta;
                    amountToProtocol += delta;
                }
            }

            // update global fee tracker
            if (result.liquidity > 0) {
                unchecked {
                    // FullMath.mulDiv isn't needed as the numerator can't overflow uint256 since tokens have a max
                    // supply of type(uint128).max
                    step.feeGrowthGlobalX128 +=
                        UnsafeMath.simpleMulDiv(step.feeAmount, FixedPoint128.Q128, result.liquidity);
                }
            }

            // Shift tick if we reached the next price, and preemptively decrement for zeroForOne swaps to tickNext - 1.
            // If the swap doesn't continue (if amountRemaining == 0 or sqrtPriceLimit is met), slot0.tick will be 1
            // less
            // than getTickAtSqrtPrice(slot0.sqrtPrice). This doesn't affect swaps, but donation calls should verify
            // both
            // price and tick to reward the correct LPs.
            if (result.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = zeroForOne
                        ? (step.feeGrowthGlobalX128, feeGrowthGlobal1X128)
                        : (feeGrowthGlobal0X128, step.feeGrowthGlobalX128);
                    tickGrowthInfo.cross(
                        step.tickNext,
                        Tick.GrowthInfo({
                            twPremiumX96: cumulativeFundingX96,
                            twPremiumDivBySqrtPriceX96: cumulativeFundingDivBySqrtMarkX96
                        })
                    );
                    (, int128 liquidityNet,,) = POOL_MANAGER.getTickInfo(poolKey.toId(), step.tickNext);
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }

                    result.liquidity = LiquidityMath.addDelta(result.liquidity, liquidityNet);
                }

                unchecked {
                    result.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
                }
            } else if (result.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                result.tick = TickMath.getTickAtSqrtPrice(result.sqrtPriceX96);
            }
        }
    }

    function _simulateSwapView(Pool.SwapParams memory params)
        internal
        view
        returns (BalanceDelta swapDelta, uint256 amountToProtocol, uint24 swapFee, Pool.SwapResult memory result)
    {
        (uint160 slot0sqrtPriceX96, int24 slot0tick, uint24 slot0protocolFee, uint24 slot0lpFee) =
            POOL_MANAGER.getSlot0(poolKey.toId());
        bool zeroForOne = params.zeroForOne;

        uint256 protocolFee = zeroForOne ? slot0protocolFee.getZeroForOneFee() : slot0protocolFee.getOneForZeroFee();

        // the amount remaining to be swapped in/out of the input/output asset. initially set to the amountSpecified
        int256 amountSpecifiedRemaining = params.amountSpecified;
        // the amount swapped out/in of the output/input asset. initially set to 0
        int256 amountCalculated = 0;
        // initialize to the current sqrt(price)
        result.sqrtPriceX96 = slot0sqrtPriceX96;
        // initialize to the current tick
        result.tick = slot0tick;
        // initialize to the current liquidity
        result.liquidity = POOL_MANAGER.getLiquidity(poolKey.toId());

        {
            // if the beforeSwap hook returned a valid fee override, use that as the LP fee, otherwise load from storage
            // lpFee, swapFee, and protocolFee are all in pips
            uint24 lpFee =
                params.lpFeeOverride.isOverride() ? params.lpFeeOverride.removeOverrideFlagAndValidate() : slot0lpFee;

            swapFee = protocolFee == 0 ? lpFee : uint16(protocolFee).calculateSwapFee(lpFee);
        }

        // a swap fee totaling MAX_SWAP_FEE (100%) makes exact output swaps impossible since the input is entirely
        // consumed by the fee
        if (swapFee >= SwapMath.MAX_SWAP_FEE) {
            // if exactOutput
            if (params.amountSpecified > 0) {
                Pool.InvalidFeeForExactOut.selector.revertWith();
            }
        }

        // swapFee is the pool's fee in pips (LP fee + protocol fee)
        // when the amount swapped is 0, there is no protocolFee applied and the fee amount paid to the protocol is set
        // to 0
        if (params.amountSpecified == 0) return (BalanceDeltaLibrary.ZERO_DELTA, 0, swapFee, result);

        if (zeroForOne) {
            if (params.sqrtPriceLimitX96 >= slot0sqrtPriceX96) {
                Pool.PriceLimitAlreadyExceeded.selector.revertWith(slot0sqrtPriceX96, params.sqrtPriceLimitX96);
            }
            // Swaps can never occur at MIN_TICK, only at MIN_TICK + 1, except at initialization of a pool
            // Under certain circumstances outlined below, the tick will preemptively reach MIN_TICK without swapping
            // there
            if (params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                Pool.PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        } else {
            if (params.sqrtPriceLimitX96 <= slot0sqrtPriceX96) {
                Pool.PriceLimitAlreadyExceeded.selector.revertWith(slot0sqrtPriceX96, params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                Pool.PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        }

        Pool.StepComputations memory step;

        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = POOL_MANAGER.getFeeGrowthGlobals(poolKey.toId());
        step.feeGrowthGlobalX128 = zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128;

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (!(amountSpecifiedRemaining == 0 || result.sqrtPriceX96 == params.sqrtPriceLimitX96)) {
            step.sqrtPriceStartX96 = result.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                _nextInitializedTickWithinOneWord(POOL_MANAGER, poolKey, result.tick, params.tickSpacing, zeroForOne);

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext <= TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }
            if (step.tickNext >= TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (result.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                result.sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(zeroForOne, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
                result.liquidity,
                amountSpecifiedRemaining,
                swapFee
            );

            // if exactOutput
            if (params.amountSpecified > 0) {
                unchecked {
                    amountSpecifiedRemaining -= step.amountOut.toInt256();
                }
                amountCalculated -= (step.amountIn + step.feeAmount).toInt256();
            } else {
                // safe because we test that amountSpecified > amountIn + feeAmount in SwapMath
                unchecked {
                    amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                }
                amountCalculated += step.amountOut.toInt256();
            }

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            if (protocolFee > 0) {
                unchecked {
                    // step.amountIn does not include the swap fee, as it's already been taken from it,
                    // so add it back to get the total amountIn and use that to calculate the amount of fees owed to the
                    // protocol
                    // cannot overflow due to limits on the size of protocolFee and params.amountSpecified
                    // this rounds down to favor LPs over the protocol
                    uint256 delta = (swapFee == protocolFee)
                        ? step.feeAmount // lp fee is 0, so the entire fee is owed to the protocol instead
                        : (step.amountIn + step.feeAmount) * protocolFee / ProtocolFeeLibrary.PIPS_DENOMINATOR;
                    // subtract it from the total fee and add it to the protocol fee
                    step.feeAmount -= delta;
                    amountToProtocol += delta;
                }
            }

            // update global fee tracker
            if (result.liquidity > 0) {
                unchecked {
                    // FullMath.mulDiv isn't needed as the numerator can't overflow uint256 since tokens have a max
                    // supply of type(uint128).max
                    step.feeGrowthGlobalX128 +=
                        UnsafeMath.simpleMulDiv(step.feeAmount, FixedPoint128.Q128, result.liquidity);
                }
            }

            // Shift tick if we reached the next price, and preemptively decrement for zeroForOne swaps to tickNext - 1.
            // If the swap doesn't continue (if amountRemaining == 0 or sqrtPriceLimit is met), slot0.tick will be 1
            // less
            // than getTickAtSqrtPrice(slot0.sqrtPrice). This doesn't affect swaps, but donation calls should verify
            // both
            // price and tick to reward the correct LPs.
            if (result.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    (, int128 liquidityNet,,) = POOL_MANAGER.getTickInfo(poolKey.toId(), step.tickNext);
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }

                    result.liquidity = LiquidityMath.addDelta(result.liquidity, liquidityNet);
                }

                unchecked {
                    result.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
                }
            } else if (result.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                result.tick = TickMath.getTickAtSqrtPrice(result.sqrtPriceX96);
            }
        }
    }

    /// @notice Returns the next initialized tick contained in the same word (or adjacent word) as the tick that is
    /// either
    /// to the left (less than or equal to) or right (greater than) of the given tick
    /// @param tick The starting tick
    /// @param tickSpacing The spacing between usable ticks
    /// @param lte Whether to search for the next initialized tick to the left (less than or equal to the starting tick)
    /// @return next The next initialized or uninitialized tick up to 256 ticks away from the current tick
    /// @return initialized Whether the next tick is initialized, as the function only searches within up to 256 ticks
    function _nextInitializedTickWithinOneWord(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        int24 tick,
        int24 tickSpacing,
        bool lte
    )
        internal
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed = _compress(tick, tickSpacing);

            if (lte) {
                (int16 wordPos, uint8 bitPos) = _position(compressed);
                // all the 1s at or to the right of the current bitPos
                uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
                uint256 masked = poolManager.getTickBitmap(poolKey.toId(), wordPos) & mask;

                // if there are no initialized ticks to the right of or at the current tick, return rightmost in the
                // word
                initialized = masked != 0;
                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                // start from the word of the next tick, since the current tick state doesn't matter
                (int16 wordPos, uint8 bitPos) = _position(++compressed);
                // all the 1s at or to the left of the bitPos
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = poolManager.getTickBitmap(poolKey.toId(), wordPos) & mask;

                // if there are no initialized ticks to the left of the current tick, return leftmost in the word
                initialized = masked != 0;
                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }

    function _compress(int24 tick, int24 tickSpacing) internal pure returns (int24 compressed) {
        // compressed = tick / tickSpacing;
        // if (tick < 0 && tick % tickSpacing != 0) compressed--;
        assembly ("memory-safe") {
            tick := signextend(2, tick)
            tickSpacing := signextend(2, tickSpacing)
            compressed :=
                sub(
                    sdiv(tick, tickSpacing),
                    // if (tick < 0 && tick % tickSpacing != 0) then tick % tickSpacing < 0, vice versa
                    slt(smod(tick, tickSpacing), 0)
                )
        }
    }

    /// @notice Computes the position in the mapping where the initialized bit for a tick lives
    /// @param tick The tick for which to compute the position
    /// @return wordPos The key in the mapping containing the word in which the bit is stored
    /// @return bitPos The bit position in the word where the flag is stored
    function _position(int24 tick) internal pure returns (int16 wordPos, uint8 bitPos) {
        assembly ("memory-safe") {
            // signed arithmetic shift right
            wordPos := sar(8, signextend(2, tick))
            bitPos := and(tick, 0xff)
        }
    }

    function liveTakerPositionDetails(uint256 takerPosId) external view returns (int256 funding, int256 pnl) {
        uint256 timeSinceLastUpdate = block.timestamp - lastFundingUpdate;
        // funding owed per second * time since last update (in seconds)
        int256 newCumulativeFundingX96 = cumulativeFundingX96 + fundingRateX96 * int256(timeSinceLastUpdate);

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolKey.toId());
        int256 newCumulativeFundingDivBySqrtMarkX96 = cumulativeFundingDivBySqrtMarkX96
            + fundingRateX96 * int256(timeSinceLastUpdate) * int256(FixedPoint96.Q96) / int256(uint256(sqrtPriceX96));

        TakerPosition memory takerPos = takerPositions[takerPosId];

        uint256 notionalValue;
        if (takerPos.isLong) {
            uint128 amountIn = takerPos.size;
            (,,, Pool.SwapResult memory result) = _simulateSwapView(
                Pool.SwapParams({
                    amountSpecified: int128(amountIn),
                    tickSpacing: poolKey.tickSpacing,
                    zeroForOne: true,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
                    lpFeeOverride: 0
                })
            );
            pnl = (int256(notionalValue) - int256(takerPos.entryValue));
        } else {
            uint128 amountOut = takerPos.size;
            _simulateSwapView(
                Pool.SwapParams({
                    amountSpecified: -int128(amountOut),
                    tickSpacing: poolKey.tickSpacing,
                    zeroForOne: false,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1,
                    lpFeeOverride: TRADING_FEE
                })
            );
            pnl = (int256(takerPos.entryValue) - int256(notionalValue));
        }

        funding = (cumulativeFundingX96 - takerPos.entryCumulativeFundingX96) * SafeCast.toInt256(takerPos.size)
            / SafeCast.toInt256(FixedPoint96.Q96);
        if (!takerPos.isLong) funding = -funding;
    }

    function liveMark() public view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolKey.toId());
        return uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / FixedPoint96.Q96;
    }
}
