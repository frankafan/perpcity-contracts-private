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
import { IBeacon } from "../interfaces/IBeacon.sol";
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

library Perp {
    using SafeCast for *;
    using Perp for Info;
    using StateLibrary for IPoolManager;
    using TokenMath for *;
    using Tick for mapping(int24 => Tick.GrowthInfo);
    using UniswapV4Utility for IUniversalRouter;
    using UniswapV4Utility for IPositionManager;

    uint128 constant UINT128_MAX = type(uint128).max;

    struct Info {
        PoolKey poolKey;
        address beacon;
        uint24 tradingFee;
        Bounds.MarginBounds marginBounds;
        Bounds.LeverageBounds leverageBounds;
        uint128 liquidationFeeX96;
        uint128 liquidationFeeSplitX96;
        int128 premiumPerSecondX96;
        int128 twPremiumX96;
        int128 twPremiumDivBySqrtPriceX96;
        int128 lastGrowthUpdate;
        int128 fundingInterval;
        uint128 nextTakerPosId;
        mapping(uint256 => Positions.TakerInfo) takerPositions;
        mapping(uint256 => Positions.MakerInfo) makerPositions;
        mapping(int24 => Tick.GrowthInfo) tickGrowthInfo;
    }

    event PerpCreated(PoolId perpId, address beacon, uint256 markPriceX96);
    event MakerPositionOpened(PoolId perpId, uint256 makerPosId, Positions.MakerInfo makerPos, uint256 markPriceX96);
    event TakerPositionOpened(PoolId perpId, uint256 takerPosId, Positions.TakerInfo takerPos, uint256 markPriceX96);
    event MakerPositionClosed(
        PoolId perpId, uint256 makerPosId, bool wasLiquidated, Positions.MakerInfo makerPos, uint256 markPriceX96
    );
    event TakerPositionClosed(
        PoolId perpId, uint256 takerPosId, bool wasLiquidated, Positions.TakerInfo takerPos, uint256 markPriceX96
    );

    error OpeningMarginOutOfBounds(uint128 margin, uint128 minMargin, uint128 maxMargin);
    error OpeningLeverageOutOfBounds(uint256 leverageX96, uint128 minLeverageX96, uint128 maxLeverageX96);
    error InvalidClose(address caller, address holder, bool isLiquidated);
    error InvalidLiquidity(uint128 liquidity);

    function createPerp(
        mapping(PoolId => Info) storage self,
        ExternalContracts.Contracts memory contracts,
        Params.CreatePerpParams memory params
    )
        public
        returns (PoolId perpId)
    {
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

        Bounds.MarginBounds memory marginBounds =
            Bounds.MarginBounds({ minOpeningMargin: params.minMargin, maxOpeningMargin: params.maxMargin });

        Bounds.LeverageBounds memory leverageBounds = Bounds.LeverageBounds({
            minOpeningLeverageX96: params.minOpeningLeverageX96,
            maxOpeningLeverageX96: params.maxOpeningLeverageX96,
            liquidationLeverageX96: params.liquidationLeverageX96
        });

        Info storage perp = self[perpId];

        perp.poolKey = poolKey;
        perp.beacon = params.beacon;
        perp.tradingFee = params.tradingFee;
        perp.marginBounds = marginBounds;
        perp.leverageBounds = leverageBounds;
        perp.liquidationFeeX96 = params.liquidationFeeX96;
        perp.liquidationFeeSplitX96 = params.liquidationFeeSplitX96;
        perp.fundingInterval = params.fundingInterval;

        emit PerpCreated(perpId, params.beacon, sqrtPriceX96ToPriceX96(params.startingSqrtPriceX96));
    }

    function openMakerPosition(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        PoolId perpId,
        Params.OpenMakerPositionParams memory params
    )
        public
        returns (uint256 makerPosId)
    {
        validateOpeningMargin(self.marginBounds, params.margin);

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
            self.poolKey, params.tickLower, params.tickUpper, params.liquidity, UINT128_MAX, UINT128_MAX
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
            entryTwPremiumDivBySqrtPriceX96: self.twPremiumDivBySqrtPriceX96
        });

        contracts.usdc.transferFrom(msg.sender, address(this), params.margin);

        emit MakerPositionOpened(
            perpId, makerPosId, self.makerPositions[makerPosId], sqrtPriceX96ToPriceX96(sqrtPriceX96)
        );
    }

    function closeMakerPosition(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        PoolId perpId,
        uint256 makerPosId,
        bool revertChanges
    )
        public
    {
        PoolKey memory poolKey = self.poolKey;
        Positions.MakerInfo memory makerPos = self.makerPositions[makerPosId];

        (uint256 perpsReceived, uint256 usdReceived) =
            contracts.positionManager.burnLiquidityPosition(poolKey, makerPosId);

        int256 pnl = usdReceived.toInt256() - makerPos.usdBorrowed.toInt256();
        int128 excessPerps = perpsReceived.toInt128() - makerPos.perpsBorrowed.toInt128();
        uint128 excessPerpsAbs = excessPerps < 0 ? (-excessPerps).toUint128() : excessPerps.toUint128();

        // if maker is last to remove liquidity, there is no liquidity left to swap against, so skip excess resolution
        uint128 liquidity = contracts.poolManager.getLiquidity(perpId);
        if (liquidity > 0) {
            if (excessPerps < 0) {
                // must buy perps to pay back debt
                pnl -= contracts.router.swapExactOutSingle(poolKey, false, excessPerpsAbs, UINT128_MAX, 0).toInt256();
            } else if (excessPerps > 0) {
                // must sell excess perp contracts
                pnl += contracts.router.swapExactInSingle(poolKey, true, excessPerpsAbs, 0, 0).toInt256();
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
        if (effectiveMargin < 0) {
            if (revertChanges) {
                LivePositionDetailsReverter.revertLivePositionDetails(pnl, funding, effectiveMargin, true);
            } else {
                emit MakerPositionClosed(perpId, makerPosId, true, makerPos, sqrtPriceX96ToPriceX96(sqrtPriceX96));
                delete self.makerPositions[makerPosId];
                return;
            }
        }

        uint256 notional = calculateMakerNotional(
            sqrtPriceX96, makerPos.sqrtPriceLowerX96, makerPos.sqrtPriceUpperX96, makerPos.liquidity
        );

        uint256 liquidationFee = FullMath.mulDiv(notional, self.liquidationFeeX96, FixedPoint96.UINT_Q96);

        bool isLiquidatable =
            isPositionLiquidatable(self.leverageBounds, notional, uint256(effectiveMargin), liquidationFee);
        // If margin after fee is below liquidation threshold, handle liquidation payout
        if (isLiquidatable) {
            // Liquidation payout: send remaining margin to position holder, liquidation fee to liquidator
            contracts.usdc.transfer(makerPos.holder, (uint256(effectiveMargin) - liquidationFee).scale18To6());
            contracts.usdc.transfer(
                msg.sender,
                FullMath.mulDiv(liquidationFee.scale18To6(), self.liquidationFeeSplitX96, FixedPoint96.UINT_Q96)
            );
        } else if (makerPos.holder == msg.sender) {
            // If not liquidated and caller is the owner, return full margin
            contracts.usdc.transfer(msg.sender, uint256(effectiveMargin).scale18To6());
        } else {
            // Otherwise, revert
            revert InvalidClose(msg.sender, makerPos.holder, false);
        }

        if (revertChanges) {
            LivePositionDetailsReverter.revertLivePositionDetails(pnl, funding, effectiveMargin, isLiquidatable);
        } else {
            uint256 markPriceX96 = sqrtPriceX96ToPriceX96(sqrtPriceX96);
            emit MakerPositionClosed(perpId, makerPosId, isLiquidatable, makerPos, markPriceX96);
            delete self.makerPositions[makerPosId];
        }
    }

    function openTakerPosition(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        PoolId perpId,
        Params.OpenTakerPositionParams memory params
    )
        public
        returns (uint256 takerPosId)
    {
        validateOpeningMargin(self.marginBounds, params.margin);
        validateOpeningLeverage(self.leverageBounds, params.leverageX96);

        uint128 perpsMoved;
        uint128 usdMoved =
            FullMath.mulDiv(params.margin.scale6To18(), params.leverageX96, FixedPoint96.UINT_Q96).toUint128();
        if (params.isLong) {
            // For long: swap USD in for Perp out
            perpsMoved =
                contracts.router.swapExactInSingle(self.poolKey, false, usdMoved, 0, self.tradingFee).toUint128();
        } else {
            // For short: swap Perp in for USD out
            perpsMoved = contracts.router.swapExactOutSingle(self.poolKey, true, usdMoved, UINT128_MAX, self.tradingFee)
                .toUint128();
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
        contracts.usdc.transferFrom(msg.sender, address(this), params.margin);

        (uint160 sqrtPriceX96,,,) = contracts.poolManager.getSlot0(perpId);
        emit TakerPositionOpened(
            perpId, takerPosId, self.takerPositions[takerPosId], sqrtPriceX96ToPriceX96(sqrtPriceX96)
        );
    }

    function closeTakerPosition(
        Info storage self,
        ExternalContracts.Contracts memory contracts,
        PoolId perpId,
        uint256 takerPosId,
        bool revertChanges
    )
        public
    {
        Positions.TakerInfo memory takerPos = self.takerPositions[takerPosId];

        uint256 notionalValue;
        int256 pnl;

        // Perform the reverse swap in Uniswap V4 pool to close the position
        // For a long: sell Perp AT for USD AT (swap in Perp, get out USD)
        if (takerPos.isLong) {
            uint128 amountIn = takerPos.size;
            // Simulate swap: Perp in, USD out
            // Execute swap: Perp in, USD out
            notionalValue = contracts.router.swapExactInSingle(self.poolKey, true, amountIn, 0, 0);
            // PnL: USD received minus entry value
            pnl = (notionalValue.toInt256() - takerPos.entryValue.toInt256());
        } else {
            // For a short: buy back Perp AT with USD AT (swap in USD, get out Perp)
            uint128 amountOut = takerPos.size;
            // Simulate swap: USD in, Perp out
            // Execute swap: USD in, Perp out
            notionalValue = contracts.router.swapExactOutSingle(self.poolKey, false, amountOut, UINT128_MAX, 0);
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
        // If margin is negative, position is liquidated
        if (effectiveMargin < 0) {
            if (revertChanges) {
                LivePositionDetailsReverter.revertLivePositionDetails(pnl, funding, effectiveMargin, true);
            } else {
                (uint160 sqrtPriceX96,,,) = contracts.poolManager.getSlot0(perpId);
                emit TakerPositionClosed(perpId, takerPosId, true, takerPos, sqrtPriceX96ToPriceX96(sqrtPriceX96));
                delete self.takerPositions[takerPosId];
                return;
            }
        }

        uint256 liquidationFee = FullMath.mulDiv(notionalValue, self.liquidationFeeX96, FixedPoint96.UINT_Q96);

        bool isLiquidatable =
            isPositionLiquidatable(self.leverageBounds, notionalValue, uint256(effectiveMargin), liquidationFee);
        // If margin after fee is below liquidation threshold, handle liquidation payout
        if (isLiquidatable) {
            // Liquidation payout: send remaining margin to position holder, liquidation fee to liquidator
            contracts.usdc.transfer(takerPos.holder, (uint256(effectiveMargin) - liquidationFee).scale18To6());
            contracts.usdc.transfer(
                msg.sender,
                FullMath.mulDiv(liquidationFee.scale18To6(), self.liquidationFeeSplitX96, FixedPoint96.UINT_Q96)
            );
        } else if (takerPos.holder == msg.sender) {
            // If not liquidated and caller is the owner, return full margin
            contracts.usdc.transfer(takerPos.holder, uint256(effectiveMargin).scale18To6());
        } else {
            // Otherwise, revert
            revert InvalidClose(msg.sender, takerPos.holder, false);
        }

        if (revertChanges) {
            LivePositionDetailsReverter.revertLivePositionDetails(pnl, funding, effectiveMargin, isLiquidatable);
        } else {
            (uint160 sqrtPriceX96,,,) = contracts.poolManager.getSlot0(perpId);
            uint256 markPriceX96 = sqrtPriceX96ToPriceX96(sqrtPriceX96);
            emit TakerPositionClosed(perpId, takerPosId, isLiquidatable, takerPos, markPriceX96);
            delete self.takerPositions[takerPosId];
        }
    }

    function validateOpeningMargin(Bounds.MarginBounds memory bounds, uint128 margin) public pure {
        if (margin < bounds.minOpeningMargin || margin > bounds.maxOpeningMargin) {
            revert OpeningMarginOutOfBounds(margin, bounds.minOpeningMargin, bounds.maxOpeningMargin);
        }
    }

    function validateOpeningLeverage(Bounds.LeverageBounds memory bounds, uint256 leverageX96) public pure {
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
        public
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
        public
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

    function sqrtPriceX96ToPriceX96(uint256 sqrtPriceX96) public pure returns (uint256) {
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.UINT_Q96);
    }

    function updateTwPremiums(Info storage self, uint160 sqrtPriceX96) public {
        int128 timeSinceLastUpdate = block.timestamp.toInt128() - self.lastGrowthUpdate;

        self.twPremiumX96 += self.premiumPerSecondX96 * timeSinceLastUpdate;

        self.twPremiumDivBySqrtPriceX96 += MoreSignedMath.mulDiv(
            self.premiumPerSecondX96, int256(timeSinceLastUpdate) * FixedPoint96.INT_Q96, sqrtPriceX96
        ).toInt128();

        self.lastGrowthUpdate = block.timestamp.toInt128();
    }

    function updatePremiumPerSecond(Info storage self, uint160 sqrtPriceX96) public {
        uint256 markPriceX96 = sqrtPriceX96ToPriceX96(sqrtPriceX96);

        (uint256 indexPriceX96,) = IBeacon(self.beacon).getData();

        self.premiumPerSecondX96 = ((int256(markPriceX96) - int256(indexPriceX96)) / self.fundingInterval).toInt128();
    }
}
