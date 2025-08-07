// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { FixedPoint96 } from "./FixedPoint96.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import { Positions } from "./Positions.sol";
import { Tick } from "./Tick.sol";
import { MoreSignedMath } from "./MoreSignedMath.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { ITWAPBeacon } from "../interfaces/ITWAPBeacon.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccountingToken } from "../AccountingToken.sol";
import { UniswapV4Utility } from "./UniswapV4Utility.sol";
import { IUniversalRouter } from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import { IPermit2 } from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TokenMath } from "./TokenMath.sol";
import { Funding } from "./Funding.sol";
import { ExternalContracts } from "./ExternalContracts.sol";
import { LivePositionDetailsReverter } from "./LivePositionDetailsReverter.sol";
import { Params } from "./Params.sol";
import { Bounds } from "./Bounds.sol";
import { PerpVault } from "../PerpVault.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { TickTWAP } from "./TickTWAP.sol";
import { MAX_CARDINALITY } from "../utils/Constants.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Fees } from "./Fees.sol";

library Perp {
    using SafeCast for *;
    using Perp for Info;
    using StateLibrary for IPoolManager;
    using TokenMath for *;
    using Tick for mapping(int24 => Tick.GrowthInfo);
    using UniswapV4Utility for IUniversalRouter;
    using UniswapV4Utility for IPositionManager;
    using SafeERC20 for IERC20;
    using TickTWAP for TickTWAP.Observation[MAX_CARDINALITY];

    uint128 constant UINT128_MAX = type(uint128).max;

    struct Info {
        address creator;
        PoolKey poolKey;
        address vault;
        address beacon;
        Fees.FeeInfo fees;
        Bounds.MarginBounds marginBounds;
        Bounds.LeverageBounds leverageBounds;
        int128 premiumPerSecondX96;
        int128 twPremiumX96;
        int128 twPremiumDivBySqrtPriceX96;
        int128 lastGrowthUpdate;
        int128 fundingInterval;
        uint128 nextTakerPosId;
        mapping(uint256 => Positions.TakerInfo) takerPositions;
        mapping(uint256 => Positions.MakerInfo) makerPositions;
        mapping(int24 => Tick.GrowthInfo) tickGrowthInfo;
        TickTWAP.State twapState;
        uint32 twapWindow;
        uint256 creationTimestamp;
        uint256 priceImpactBandX96;
        uint256 makerLockupPeriod;
        uint256 badDebt;
        uint256 totalMargin;
        uint256 marketDeathThresholdX96;
    }

    event PerpCreated(PoolId perpId, address beacon, uint256 markPriceX96);
    event MakerPositionOpened(PoolId perpId, uint256 makerPosId, Positions.MakerInfo makerPos, uint256 markPriceX96);
    event MakerMarginAdded(PoolId perpId, uint256 makerPosId, uint128 amount);
    event TakerPositionOpened(PoolId perpId, uint256 takerPosId, Positions.TakerInfo takerPos, uint256 markPriceX96);
    event MakerPositionClosed(
        PoolId perpId, uint256 makerPosId, bool wasLiquidated, Positions.MakerInfo makerPos, uint256 markPriceX96
    );
    event TakerPositionClosed(
        PoolId perpId, uint256 takerPosId, bool wasLiquidated, Positions.TakerInfo takerPos, uint256 markPriceX96
    );
    event TakerMarginAdded(PoolId perpId, uint256 takerPosId, uint128 amount);

    error OpeningMarginOutOfBounds(uint128 margin, uint128 minMargin, uint128 maxMargin);
    error OpeningLeverageOutOfBounds(uint256 leverageX96, uint128 minLeverageX96, uint128 maxLeverageX96);
    error InvalidClose(address caller, address holder, bool isLiquidated);
    error InvalidLiquidity(uint128 liquidity);
    error CallerNotOwner(address caller, address owner);
    error InvalidFeeSplits(uint256 tradingFeeInsuranceSplitX96, uint256 tradingFeeCreatorSplitX96);
    error MakerPositionLocked(uint256 currentTimestamp, uint256 lockupPeriodEnd);
    error MarketNotKillable();

    function createPerp(
        mapping(PoolId => Info) storage self,
        ExternalContracts.Contracts memory contracts,
        Params.CreatePerpParams memory params,
        uint256 creationFee
    )
        external
        returns (PoolId perpId)
    {
        if (params.fees.tradingFeeInsuranceSplitX96 + params.fees.tradingFeeCreatorSplitX96 > FixedPoint96.UINT_Q96) {
            revert InvalidFeeSplits(params.fees.tradingFeeInsuranceSplitX96, params.fees.tradingFeeCreatorSplitX96);
        }

        IERC20 currency0 = new AccountingToken(UINT128_MAX);
        IERC20 currency1 = new AccountingToken(UINT128_MAX);

        UniswapV4Utility.approveRouterAndPositionManager(contracts, currency0, currency1);

        if (currency0 > currency1) (currency0, currency1) = (currency1, currency0);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(currency0)),
            currency1: Currency.wrap(address(currency1)),
            fee: 0,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(address(this))
        });
        perpId = poolKey.toId();

        contracts.poolManager.initialize(poolKey, params.startingSqrtPriceX96);

        PerpVault perpVault = new PerpVault(address(this), contracts.usdc);

        Fees.FeeInfo memory fees = Fees.FeeInfo({
            tradingFee: params.fees.tradingFee,
            tradingFeeCreatorSplitX96: params.fees.tradingFeeCreatorSplitX96,
            tradingFeeInsuranceSplitX96: params.fees.tradingFeeInsuranceSplitX96,
            liquidationFeeX96: params.fees.liquidationFeeX96,
            liquidationFeeSplitX96: params.fees.liquidationFeeSplitX96
        });

        Info storage perp = self[perpId];

        perp.creator = msg.sender;
        perp.poolKey = poolKey;
        perp.vault = address(perpVault);
        perp.beacon = params.beacon;
        perp.fees = fees;
        perp.marginBounds = params.marginBounds;
        perp.leverageBounds = params.leverageBounds;
        perp.fundingInterval = params.fundingInterval;
        (perp.twapState.cardinality, perp.twapState.cardinalityNext) =
            perp.twapState.observations.initialize(uint32(block.timestamp));
        perp.twapState.cardinalityNext =
            perp.twapState.observations.grow(perp.twapState.cardinalityNext, params.initialCardinalityNext);
        perp.twapWindow = params.twapWindow;
        perp.creationTimestamp = block.timestamp;
        perp.priceImpactBandX96 = params.priceImpactBandX96;
        perp.makerLockupPeriod = params.makerLockupPeriod;
        perp.marketDeathThresholdX96 = params.marketDeathThresholdX96;

        (perp.twapState.index, perp.twapState.cardinality) = perp.twapState.observations.write(
            perp.twapState.index,
            uint32(block.timestamp),
            TickMath.getTickAtSqrtPrice(params.startingSqrtPriceX96),
            perp.twapState.cardinality,
            perp.twapState.cardinalityNext
        );

        contracts.usdc.safeTransferFrom(msg.sender, contracts.creationFeeRecipient, creationFee);

        emit PerpCreated(perpId, params.beacon, sqrtPriceX96ToPriceX96(params.startingSqrtPriceX96));
    }

    function openMakerPosition(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        PoolId perpId,
        Params.OpenMakerPositionParams memory params
    )
        external
        returns (uint256 makerPosId)
    {
        validateOpeningMargin(self.marginBounds, params.margin);
        self.totalMargin += params.margin;

        if (params.liquidity == 0) {
            revert InvalidLiquidity(params.liquidity);
        }

        (uint160 sqrtPriceX96,,,) = contracts.poolManager.getSlot0(perpId);
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(params.tickUpper);

        uint256 notional = calculateMakerNotional(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, params.liquidity);
        uint256 leverageX96 = FullMath.mulDiv(notional, FixedPoint96.UINT_Q96, params.margin.scale6To18());
        validateOpeningLeverage(self.leverageBounds, leverageX96);

        uint256 perpsBorrowed;
        uint256 usdBorrowed;
        (makerPosId, perpsBorrowed, usdBorrowed) = contracts.positionManager.mintLiquidityPosition(
            self.poolKey,
            params.tickLower,
            params.tickUpper,
            params.liquidity,
            params.maxAmount0In,
            params.maxAmount1In,
            params.expiryWindow
        );

        self.makerPositions[makerPosId] = Positions.MakerInfo({
            holder: msg.sender,
            margin: params.margin,
            liquidity: params.liquidity,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            sqrtPriceLowerX96: sqrtPriceLowerX96,
            sqrtPriceUpperX96: sqrtPriceUpperX96,
            perpsBorrowed: perpsBorrowed.toUint128(),
            usdBorrowed: usdBorrowed.toUint128(),
            entryTwPremiumX96: self.twPremiumX96,
            entryTwPremiumDivBySqrtPriceX96: self.twPremiumDivBySqrtPriceX96,
            entryTimestamp: block.timestamp
        });

        contracts.usdc.safeTransferFrom(msg.sender, self.vault, params.margin);

        emit MakerPositionOpened(
            perpId, makerPosId, self.makerPositions[makerPosId], sqrtPriceX96ToPriceX96(sqrtPriceX96)
        );
    }

    function addMakerMargin(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        PoolId perpId,
        Params.AddMarginParams memory params
    )
        external
    {
        address owner = self.makerPositions[params.posId].holder;
        if (msg.sender != owner) revert CallerNotOwner(msg.sender, owner);

        self.makerPositions[params.posId].margin += params.amount;
        self.totalMargin += params.amount;
        contracts.usdc.safeTransferFrom(msg.sender, self.vault, params.amount);

        emit MakerMarginAdded(perpId, params.posId, params.amount);
    }

    function closeMakerPosition(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        PoolId perpId,
        Params.ClosePositionParams memory params,
        bool revertChanges
    )
        external
    {
        PoolKey memory poolKey = self.poolKey;
        Positions.MakerInfo memory makerPos = self.makerPositions[params.posId];

        if (!revertChanges && block.timestamp <= makerPos.entryTimestamp + self.makerLockupPeriod) {
            revert MakerPositionLocked(block.timestamp, makerPos.entryTimestamp + self.makerLockupPeriod);
        }

        self.totalMargin -= makerPos.margin;

        (uint256 perpsReceived, uint256 usdReceived) =
            contracts.positionManager.burnLiquidityPosition(poolKey, params.posId, params.expiryWindow);

        int256 pnl = usdReceived.toInt256() - makerPos.usdBorrowed.toInt256();
        int128 excessPerps = perpsReceived.toInt128() - makerPos.perpsBorrowed.toInt128();
        uint128 excessPerpsAbs = excessPerps < 0 ? (-excessPerps).toUint128() : excessPerps.toUint128();

        // if maker is last to remove liquidity, there is no liquidity left to swap against, so skip excess resolution
        uint128 liquidity = contracts.poolManager.getLiquidity(perpId);
        if (liquidity > 0) {
            if (excessPerps < 0) {
                // must buy perps to pay back debt
                pnl -= contracts.router.swapExactOutSingle(
                    poolKey, false, excessPerpsAbs, params.maxAmount1In, 0, params.expiryWindow
                ).toInt256();
            } else if (excessPerps > 0) {
                // must sell excess perp contracts
                pnl += contracts.router.swapExactInSingle(
                    poolKey, true, excessPerpsAbs, params.minAmount1Out, 0, params.expiryWindow
                ).toInt256();
            }
        }

        (uint160 sqrtPriceX96,,,) = contracts.poolManager.getSlot0(perpId);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        int256 funding = Funding.calcPendingFundingPaymentWithLiquidityCoefficient(
            makerPos.perpsBorrowed.toInt256(),
            makerPos.entryTwPremiumX96,
            Funding.Growth({
                twPremiumX96: self.twPremiumX96,
                twPremiumDivBySqrtPriceX96: self.twPremiumDivBySqrtPriceX96
            }),
            Funding.calcLiquidityCoefficientInFundingPaymentByOrder(
                makerPos.liquidity,
                makerPos.tickLower,
                makerPos.tickUpper,
                self.tickGrowthInfo.getAllFundingGrowth(
                    makerPos.tickLower,
                    makerPos.tickUpper,
                    currentTick,
                    self.twPremiumX96,
                    self.twPremiumDivBySqrtPriceX96
                )
            )
        );

        int256 effectiveMargin = makerPos.margin.scale6To18().toInt256() + pnl - funding;

        uint256 notional = calculateMakerNotional(
            sqrtPriceX96, makerPos.sqrtPriceLowerX96, makerPos.sqrtPriceUpperX96, makerPos.liquidity
        );

        uint256 liquidationFee = FullMath.mulDiv(notional, self.fees.liquidationFeeX96, FixedPoint96.UINT_Q96);

        if (effectiveMargin < 0) {
            if (revertChanges) {
                LivePositionDetailsReverter.revertLivePositionDetails(pnl, funding, effectiveMargin, true);
            } else {
                self.badDebt += uint256(-effectiveMargin);
                emit MakerPositionClosed(perpId, params.posId, true, makerPos, sqrtPriceX96ToPriceX96(sqrtPriceX96));
                delete self.makerPositions[params.posId];
                return;
            }
        } else if (uint256(effectiveMargin) < liquidationFee) {
            liquidationFee = uint256(effectiveMargin);
        }

        bool isLiquidatable =
            isPositionLiquidatable(self.leverageBounds, notional, uint256(effectiveMargin), liquidationFee);

        // If margin after fee is below liquidation threshold, handle liquidation payout
        if (isLiquidatable) {
            // Liquidation payout: send remaining margin to position holder, liquidation fee to liquidator
            contracts.usdc.safeTransferFrom(
                self.vault, makerPos.holder, (uint256(effectiveMargin) - liquidationFee).scale18To6()
            );
            contracts.usdc.safeTransferFrom(
                self.vault,
                msg.sender,
                FullMath.mulDiv(liquidationFee.scale18To6(), self.fees.liquidationFeeSplitX96, FixedPoint96.UINT_Q96)
            );
        } else if (makerPos.holder == msg.sender) {
            // If not liquidated and caller is the owner, return full margin
            contracts.usdc.safeTransferFrom(self.vault, msg.sender, uint256(effectiveMargin).scale18To6());
        } else {
            // Otherwise, revert
            revert InvalidClose(msg.sender, makerPos.holder, false);
        }

        if (revertChanges) {
            LivePositionDetailsReverter.revertLivePositionDetails(pnl, funding, effectiveMargin, isLiquidatable);
        } else {
            uint256 markPriceX96 = sqrtPriceX96ToPriceX96(sqrtPriceX96);
            emit MakerPositionClosed(perpId, params.posId, isLiquidatable, makerPos, markPriceX96);
            delete self.makerPositions[params.posId];
        }
    }

    function openTakerPosition(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        PoolId perpId,
        Params.OpenTakerPositionParams memory params
    )
        external
        returns (uint256 takerPosId)
    {
        validateOpeningMargin(self.marginBounds, params.margin);
        validateOpeningLeverage(self.leverageBounds, params.leverageX96);
        self.totalMargin += params.margin;

        uint128 perpsMoved;
        uint128 usdMoved =
            FullMath.mulDiv(params.margin.scale6To18(), params.leverageX96, FixedPoint96.UINT_Q96).toUint128();
        if (params.isLong) {
            // For long: swap USD in for Perp out
            perpsMoved = contracts.router.swapExactInSingle(
                self.poolKey, false, usdMoved, params.minAmount0Out, self.fees.tradingFee, params.expiryWindow
            ).toUint128();
        } else {
            // For short: swap Perp in for USD out
            perpsMoved = contracts.router.swapExactOutSingle(
                self.poolKey, true, usdMoved, params.maxAmount0In, self.fees.tradingFee, params.expiryWindow
            ).toUint128();
        }

        takerPosId = self.nextTakerPosId;
        self.takerPositions[takerPosId] = Positions.TakerInfo({
            holder: msg.sender,
            isLong: params.isLong,
            size: perpsMoved,
            margin: params.margin,
            entryValue: usdMoved,
            entryTwPremiumX96: self.twPremiumX96
        });
        self.nextTakerPosId++;

        // Transfer margin from the user to the contract
        contracts.usdc.safeTransferFrom(msg.sender, self.vault, params.margin);

        (uint160 sqrtPriceX96,,,) = contracts.poolManager.getSlot0(perpId);
        emit TakerPositionOpened(
            perpId, takerPosId, self.takerPositions[takerPosId], sqrtPriceX96ToPriceX96(sqrtPriceX96)
        );
    }

    function addTakerMargin(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        PoolId perpId,
        Params.AddMarginParams memory params
    )
        external
    {
        address owner = self.takerPositions[params.posId].holder;
        if (msg.sender != owner) revert CallerNotOwner(msg.sender, owner);

        self.takerPositions[params.posId].margin += params.amount;
        self.totalMargin += params.amount;
        contracts.usdc.safeTransferFrom(msg.sender, self.vault, params.amount);

        emit TakerMarginAdded(perpId, params.posId, params.amount);
    }

    function closeTakerPosition(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        PoolId perpId,
        Params.ClosePositionParams memory params,
        bool revertChanges
    )
        external
    {
        Positions.TakerInfo memory takerPos = self.takerPositions[params.posId];

        self.totalMargin -= takerPos.margin;

        uint256 notionalValue;
        int256 pnl;

        // Perform the reverse swap in Uniswap V4 pool to close the position
        // For a long: sell Perp AT for USD AT (swap in Perp, get out USD)
        if (takerPos.isLong) {
            uint128 amountIn = takerPos.size;
            // Simulate swap: Perp in, USD out
            // Execute swap: Perp in, USD out
            notionalValue = contracts.router.swapExactInSingle(
                self.poolKey, true, amountIn, params.minAmount1Out, 0, params.expiryWindow
            );
            // PnL: USD received minus entry value
            pnl = (notionalValue.toInt256() - takerPos.entryValue.toInt256());
        } else {
            // For a short: buy back Perp AT with USD AT (swap in USD, get out Perp)
            uint128 amountOut = takerPos.size;
            // Simulate swap: USD in, Perp out
            // Execute swap: USD in, Perp out
            notionalValue = contracts.router.swapExactOutSingle(
                self.poolKey, false, amountOut, params.maxAmount1In, 0, params.expiryWindow
            );
            // PnL: entry value minus USD paid to close
            pnl = (takerPos.entryValue.toInt256() - notionalValue.toInt256());
        }

        int256 funding = MoreSignedMath.mulDiv(
            self.twPremiumX96 - takerPos.entryTwPremiumX96, takerPos.size.toInt256(), FixedPoint96.UINT_Q96
        );
        // Shorts pay/receive the opposite funding sign
        if (!takerPos.isLong) funding = -funding;

        // Calculate effective margin after PnL and funding
        int256 effectiveMargin = takerPos.margin.scale6To18().toInt256() + pnl - funding;

        uint256 liquidationFee = FullMath.mulDiv(notionalValue, self.fees.liquidationFeeX96, FixedPoint96.UINT_Q96);

        // If margin is negative, position is liquidated
        if (effectiveMargin < 0) {
            if (revertChanges) {
                LivePositionDetailsReverter.revertLivePositionDetails(pnl, funding, effectiveMargin, true);
            } else {
                self.badDebt += uint256(-effectiveMargin);
                (uint160 sqrtPriceX96,,,) = contracts.poolManager.getSlot0(perpId);
                emit TakerPositionClosed(perpId, params.posId, true, takerPos, sqrtPriceX96ToPriceX96(sqrtPriceX96));
                delete self.takerPositions[params.posId];
                return;
            }
        } else if (uint256(effectiveMargin) < liquidationFee) {
            liquidationFee = uint256(effectiveMargin);
        }

        bool isLiquidatable =
            isPositionLiquidatable(self.leverageBounds, notionalValue, uint256(effectiveMargin), liquidationFee);

        // If margin after fee is below liquidation threshold, handle liquidation payout
        if (isLiquidatable) {
            // Liquidation payout: send remaining margin to position holder, liquidation fee to liquidator
            contracts.usdc.safeTransferFrom(
                self.vault, takerPos.holder, (uint256(effectiveMargin) - liquidationFee).scale18To6()
            );
            contracts.usdc.safeTransferFrom(
                self.vault,
                msg.sender,
                FullMath.mulDiv(liquidationFee.scale18To6(), self.fees.liquidationFeeSplitX96, FixedPoint96.UINT_Q96)
            );
        } else if (takerPos.holder == msg.sender) {
            // If not liquidated and caller is the owner, return full margin
            contracts.usdc.safeTransferFrom(self.vault, takerPos.holder, uint256(effectiveMargin).scale18To6());
        } else {
            // Otherwise, revert
            revert InvalidClose(msg.sender, takerPos.holder, false);
        }

        if (revertChanges) {
            LivePositionDetailsReverter.revertLivePositionDetails(pnl, funding, effectiveMargin, isLiquidatable);
        } else {
            (uint160 sqrtPriceX96,,,) = contracts.poolManager.getSlot0(perpId);
            uint256 markPriceX96 = sqrtPriceX96ToPriceX96(sqrtPriceX96);
            emit TakerPositionClosed(perpId, params.posId, isLiquidatable, takerPos, markPriceX96);
            delete self.takerPositions[params.posId];
        }
    }

    function validateOpeningMargin(Bounds.MarginBounds memory bounds, uint128 margin) internal pure {
        if (margin < bounds.minOpeningMargin || margin > bounds.maxOpeningMargin) {
            revert OpeningMarginOutOfBounds(margin, bounds.minOpeningMargin, bounds.maxOpeningMargin);
        }
    }

    function validateOpeningLeverage(Bounds.LeverageBounds memory bounds, uint256 leverageX96) internal pure {
        if (leverageX96 < bounds.minOpeningLeverageX96 || leverageX96 > bounds.maxOpeningLeverageX96) {
            revert OpeningLeverageOutOfBounds(leverageX96, bounds.minOpeningLeverageX96, bounds.maxOpeningLeverageX96);
        }
    }

    function isPositionLiquidatable(
        Bounds.LeverageBounds memory bounds,
        uint256 notional,
        uint256 effectiveMargin,
        uint256 liquidationFee
    )
        internal
        pure
        returns (bool)
    {
        if (effectiveMargin <= liquidationFee) return true;
        uint256 leverageX96 = FullMath.mulDiv(notional, FixedPoint96.UINT_Q96, (effectiveMargin - liquidationFee));
        return leverageX96 >= bounds.liquidationLeverageX96;
    }

    function calculateMakerNotional(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        uint128 liquidity
    )
        internal
        pure
        returns (uint256 notional)
    {
        // Convert liquidity to token amounts at current price
        (uint256 currency0Amount, uint256 currency1Amount) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity);

        // Convert currency0Amount (perp contracts) to their value in currency1 (USD)
        uint256 currency0Notional =
            FullMath.mulDiv(currency0Amount, sqrtPriceX96ToPriceX96(sqrtPriceX96), FixedPoint96.UINT_Q96);

        // currency1Amount is already in USD, so its notional value is its amount
        notional = currency0Notional + currency1Amount;
    }

    function sqrtPriceX96ToPriceX96(uint256 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.UINT_Q96);
    }

    function updateTwPremiums(Info storage self, uint160 sqrtPriceX96) internal {
        int128 timeSinceLastUpdate = block.timestamp.toInt128() - self.lastGrowthUpdate;

        self.twPremiumX96 += self.premiumPerSecondX96 * timeSinceLastUpdate;

        self.twPremiumDivBySqrtPriceX96 += MoreSignedMath.mulDiv(
            self.premiumPerSecondX96, int256(timeSinceLastUpdate) * FixedPoint96.INT_Q96, sqrtPriceX96
        ).toInt128();

        self.lastGrowthUpdate = block.timestamp.toInt128();
    }

    function updatePremiumPerSecond(Info storage self, uint160 sqrtPriceX96) internal {
        uint32 twapSecondsAgo = uint32(block.timestamp - self.creationTimestamp);
        twapSecondsAgo = twapSecondsAgo > self.twapWindow ? self.twapWindow : twapSecondsAgo;

        uint256 markTWAPX96 = getTWAP(self, twapSecondsAgo, TickMath.getTickAtSqrtPrice(sqrtPriceX96));
        uint256 indexTWAPX96 = ITWAPBeacon(self.beacon).getTWAP(twapSecondsAgo);

        self.premiumPerSecondX96 = ((int256(markTWAPX96) - int256(indexTWAPX96)) / self.fundingInterval).toInt128();
    }

    function getTWAP(
        Info storage self,
        uint32 twapSecondsAgo,
        int24 currentTick
    )
        internal
        view
        returns (uint256 twapPrice)
    {
        if (twapSecondsAgo == 0) {
            return sqrtPriceX96ToPriceX96(TickMath.getSqrtPriceAtTick(currentTick));
        }

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSecondsAgo;
        secondsAgos[1] = 0;
        int56[] memory tickCumulatives = self.twapState.observations.observe(
            uint32(block.timestamp), secondsAgos, currentTick, self.twapState.index, self.twapState.cardinality
        );
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        return sqrtPriceX96ToPriceX96(
            TickMath.getSqrtPriceAtTick(int24(tickCumulativesDelta / int56(uint56(twapSecondsAgo))))
        );
    }

    function increaseCardinalityNext(
        Info storage self,
        uint32 cardinalityNext
    )
        internal
        returns (uint32 cardinalityNextOld, uint32 cardinalityNextNew)
    {
        cardinalityNextOld = self.twapState.cardinalityNext;
        cardinalityNextNew = self.twapState.observations.grow(cardinalityNextOld, cardinalityNext);
        self.twapState.cardinalityNext = cardinalityNextNew;
    }

    function marketHealthX96(
        Info storage self,
        ExternalContracts.Contracts memory contracts
    )
        internal
        view
        returns (uint256)
    {
        uint256 badDebtScaled = self.badDebt.scale18To6();
        uint256 vaultBalance = contracts.usdc.balanceOf(self.vault);
        if (badDebtScaled >= vaultBalance) {
            return 0; // Market is completely insolvent
        }

        return FullMath.mulDiv(vaultBalance - badDebtScaled, FixedPoint96.UINT_Q96, self.totalMargin);
    }

    function marketDeath(Info storage self, ExternalContracts.Contracts memory contracts) internal {
        uint256 currentMarketHealthX96 = marketHealthX96(self, contracts);
        if (currentMarketHealthX96 > self.marketDeathThresholdX96) revert MarketNotKillable();

        // First pass: close taker positions without payouts until market health >= 1 or all taker positions are closed
        closeTakerPositionsInReverseOrder(self, contracts, false);

        // Check market health after taker liquidation
        currentMarketHealthX96 = marketHealthX96(self, contracts);

        if (currentMarketHealthX96 >= FixedPoint96.UINT_Q96) {
            // Market health restored, close remaining taker positions with payouts
            closeTakerPositionsInReverseOrder(self, contracts, true);

            // Close all maker positions with payouts
            closeMakerPositionsInReverseOrder(self, contracts, true);
        } else {
            // Market health still < 1, close maker positions without payouts until >= 1
            closeMakerPositionsInReverseOrder(self, contracts, false);

            // Check market health after maker liquidation
            currentMarketHealthX96 = marketHealthX96(self, contracts);

            if (currentMarketHealthX96 >= FixedPoint96.UINT_Q96) {
                // Market health restored, close remaining maker positions with payouts
                closeMakerPositionsInReverseOrder(self, contracts, true);
            }
        }
    }

    function closeTakerPositionsInReverseOrder(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        bool withPayouts
    )
        internal
    {
        uint256 currentPosId = self.nextTakerPosId;

        // Loop through taker positions in reverse order (newest first)
        while (currentPosId > 0) {
            if (self.takerPositions[currentPosId].holder != address(0)) {
                // Close the position
                closeTakerPositionInMarketDeath(self, contracts, currentPosId, withPayouts);
                // While not paying out, check if market health >= 1 to stop
                if (!withPayouts) {
                    uint256 currentMarketHealthX96 = marketHealthX96(self, contracts);
                    if (currentMarketHealthX96 >= FixedPoint96.UINT_Q96) {
                        break;
                    }
                }
            }
            currentPosId--;
        }
    }

    function closeMakerPositionsInReverseOrder(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        bool withPayouts
    )
        internal
    {
        uint256 currentPosId = contracts.positionManager.nextTokenId();

        // Close maker positions from newest to oldest (highest ID to lowest)
        while (currentPosId >= 1) {
            if (self.makerPositions[currentPosId].holder != address(0)) {
                // Close the position
                closeMakerPositionInMarketDeath(self, contracts, currentPosId, withPayouts);
                // Check if we should stop (market health >= 1) when doing payouts
                if (!withPayouts) {
                    uint256 currentMarketHealthX96 = marketHealthX96(self, contracts);
                    if (currentMarketHealthX96 >= FixedPoint96.UINT_Q96) {
                        break;
                    }
                }
            }
        }
    }

    function closeTakerPositionInMarketDeath(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        uint256 posId,
        bool withPayouts
    )
        internal
    {
        Positions.TakerInfo memory takerPos = self.takerPositions[posId];

        if (takerPos.holder == address(0)) return; // Position already closed

        self.totalMargin -= takerPos.margin;

        uint256 notionalValue;
        int256 pnl;

        // Perform the reverse swap to close the position
        if (takerPos.isLong) {
            uint128 amountIn = takerPos.size;
            notionalValue = contracts.router.swapExactInSingle(
                self.poolKey,
                true,
                amountIn,
                0,
                0,
                20 // No slippage protection in market death
            );
            pnl = (notionalValue.toInt256() - takerPos.entryValue.toInt256());
        } else {
            uint128 amountOut = takerPos.size;
            notionalValue = contracts.router.swapExactOutSingle(
                self.poolKey,
                false,
                amountOut,
                type(uint128).max,
                0,
                20 // No slippage protection in market death
            );
            pnl = (takerPos.entryValue.toInt256() - notionalValue.toInt256());
        }

        int256 funding = MoreSignedMath.mulDiv(
            self.twPremiumX96 - takerPos.entryTwPremiumX96, takerPos.size.toInt256(), FixedPoint96.UINT_Q96
        );
        if (!takerPos.isLong) funding = -funding;

        int256 effectiveMargin = takerPos.margin.scale6To18().toInt256() + pnl - funding;

        if (withPayouts && effectiveMargin > 0) {
            // Pay out the position holder
            contracts.usdc.safeTransferFrom(self.vault, takerPos.holder, uint256(effectiveMargin).scale18To6());
        } else if (effectiveMargin < 0) {
            // Add to bad debt
            self.badDebt += uint256(-effectiveMargin);
        }
        // If effectiveMargin == 0, no payout and no bad debt

        delete self.takerPositions[posId];
    }

    function closeMakerPositionInMarketDeath(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        uint256 posId,
        bool withPayouts
    )
        internal
    {
        Positions.MakerInfo memory makerPos = self.makerPositions[posId];

        if (makerPos.holder == address(0)) return; // Position already closed

        self.totalMargin -= makerPos.margin;

        (uint256 perpsReceived, uint256 usdReceived) =
            contracts.positionManager.burnLiquidityPosition(self.poolKey, posId, 0);

        int256 pnl = usdReceived.toInt256() - makerPos.usdBorrowed.toInt256();
        int128 excessPerps = perpsReceived.toInt128() - makerPos.perpsBorrowed.toInt128();
        uint128 excessPerpsAbs = excessPerps < 0 ? (-excessPerps).toUint128() : excessPerps.toUint128();

        // Handle excess perps if there's liquidity
        uint128 liquidity = contracts.poolManager.getLiquidity(self.poolKey.toId());
        if (liquidity > 0) {
            if (excessPerps < 0) {
                pnl -= contracts.router.swapExactOutSingle(self.poolKey, false, excessPerpsAbs, type(uint128).max, 0, 0)
                    .toInt256();
            } else if (excessPerps > 0) {
                pnl += contracts.router.swapExactInSingle(self.poolKey, true, excessPerpsAbs, 0, 0, 0).toInt256();
            }
        }

        (uint160 sqrtPriceX96,,,) = contracts.poolManager.getSlot0(self.poolKey.toId());
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        int256 funding = Funding.calcPendingFundingPaymentWithLiquidityCoefficient(
            makerPos.perpsBorrowed.toInt256(),
            makerPos.entryTwPremiumX96,
            Funding.Growth({
                twPremiumX96: self.twPremiumX96,
                twPremiumDivBySqrtPriceX96: self.twPremiumDivBySqrtPriceX96
            }),
            Funding.calcLiquidityCoefficientInFundingPaymentByOrder(
                makerPos.liquidity,
                makerPos.tickLower,
                makerPos.tickUpper,
                self.tickGrowthInfo.getAllFundingGrowth(
                    makerPos.tickLower,
                    makerPos.tickUpper,
                    currentTick,
                    self.twPremiumX96,
                    self.twPremiumDivBySqrtPriceX96
                )
            )
        );

        int256 effectiveMargin = makerPos.margin.scale6To18().toInt256() + pnl - funding;

        if (withPayouts && effectiveMargin > 0) {
            // Pay out the position holder
            contracts.usdc.safeTransferFrom(self.vault, makerPos.holder, uint256(effectiveMargin).scale18To6());
        } else if (effectiveMargin < 0) {
            // Add to bad debt
            self.badDebt += uint256(-effectiveMargin);
        }
        // If effectiveMargin == 0, no payout and no bad debt

        delete self.makerPositions[posId];
    }
}
