/**
 * @title Perp Implementation on Uniswap V4
 * @author Perp City
 * @notice This contract implements a perpetual futures protocol using Uniswap V4 pools for price discovery, margin trading, and continuous funding.
 * @dev
 * 
 * SYSTEM OVERVIEW
 * ----------------------------------------------------------------------------
 * This contract is the core of a perpetual futures protocol, leveraging Uniswap V4 as the price discovery engine.
 * It enables two main user roles:
 *   - **Makers (LPs):** Provide liquidity to a Uniswap V4 pool using two custom accounting tokens (Perp AT and USD AT), and earn fees and funding payments.
 *   - **Takers (Traders):** Take leveraged long or short positions by swapping between the accounting tokens in the pool.
 * 
 * The protocol maintains a mark price (from the Uniswap V4 pool) and an index price (from an external Beacon contract).
 * Continuous funding payments are exchanged between longs and shorts to keep the mark price in line with the index price.
 * 
 * KEY COMPONENTS
 * ----------------------------------------------------------------------------
 * 1. **Uniswap V4 Pool (Price Discovery):**
 *    - The pool uses two custom ERC20 accounting tokens: Perp AT (perpetual asset) and USD AT (USD stablecoin).
 *    - The relative price of these tokens in the pool determines the mark price for the perpetual.
 *    - All swaps and liquidity operations are routed through this pool.
 * 
 * 2. **Accounting Tokens:**
 *    - **Perp Accounting Token (Perp AT):** Represents the perpetual asset.
 *    - **USD Accounting Token (USD AT):** Represents the stablecoin side.
 *    - These tokens are minted/burned as needed for pool operations, but are not transferrable outside the protocol.
 * 
 * 3. **Maker Positions:**
 *    - Makers provide liquidity in a tick range, similar to Uniswap V4 LPs, but with additional tracking for margin, funding, and PnL.
 *    - Each MakerPosition records the user's margin, liquidity, tick range, and entry funding state.
 *    - When closing, the protocol calculates PnL and funding, burns the LP position, and returns margin + PnL.
 * 
 * 4. **Taker Positions:**
 *    - Takers open long/short positions by swapping between USD AT and Perp AT in the pool, using leverage.
 *    - Each TakerPosition records margin, size, direction (long/short), entry value, and entry funding state.
 *    - Closing a position involves the reverse swap and PnL/funding calculation.
 * 
 * 5. **Funding Mechanism:**
 *    - Funding is calculated continuously, based on the difference between the mark price (from the pool) and the index price (from the Beacon).
 *    - Funding payments are settled on every trade, using a time-weighted premium accumulator.
 *    - This incentivizes the mark price to track the index price.
 * 
 * 6. **Beacon (Index Price Oracle):**
 *    - The Beacon contract provides the external index price for the perpetual, used in funding calculations.
 *    - It is not involved in price discovery or swaps.
 * 
 * 7. **Utilities and Libraries:**
 *    - Custom libraries (e.g., Funding, Tick, UniswapV4Utility) encapsulate funding math, tick management, and Uniswap V4 interactions.
 *    - See inline comments and referenced files for details.
 * 
 * ARCHITECTURE & FLOW
 * ----------------------------------------------------------------------------
 * - **Makers (LPs):**
 *     - Open positions by providing liquidity in a tick range to the Uniswap V4 pool, using Perp Accounting Token (Perp AT) and USD Accounting Token (USD AT).
 *     - The contract mints these accounting tokens and deposits them into the pool on behalf of the maker.
 *     - Maker positions are tracked with additional margin, funding, and PnL logic beyond standard Uniswap V4 LPs.
 *     - When closing, the contract burns the LP position, settles funding and PnL, and returns margin + PnL in USDC.
 *
 * - **Takers (Traders):**
 *     - Open long or short positions by swapping between USD AT and Perp AT in the Uniswap V4 pool.
 *     - The contract mints/burns accounting tokens as needed for the swap, and tracks taker positions with margin, size, direction, and entry funding state.
 *     - Closing a position involves the reverse swap, funding/PnL settlement, and margin return.
 *
 * - **Uniswap V4 Integration:**
 *     - All liquidity and swap operations are routed through the Uniswap V4 pool using the custom accounting tokens.
 *     - The contract interacts directly with the Uniswap V4 PoolManager, PositionManager, and Router.
 *     - The PerpHook contract is used to enforce protocol-specific fee logic and restrict pool interactions to this contract.
 *
 * - **Accounting Tokens:**
 *     - Perp AT and USD AT are non-transferrable ERC20 tokens minted/burned by this contract for pool operations.
 *     - They represent the protocol's internal accounting for perpetual and USD value, and are never held by users directly.
 *
 * - **Funding & Mark/Index Price:**
 *     - The mark price is derived from the Uniswap V4 pool (ratio of Perp AT to USD AT).
 *     - The index price is provided by the Beacon contract (external oracle).
 *     - Funding is calculated continuously and settled on every trade, using a time-weighted premium accumulator.
 *     - This mechanism incentivizes the mark price to track the index price.
 *
 * - **Transaction Flow:**
 *     - All user actions (open/close maker, open/close taker) are initiated via Perp.sol, which handles all Uniswap V4 and accounting token logic.
 *     - The PerpHook ensures only Perp.sol can interact with the pool, and applies protocol-specific fee logic.
 *     - See `docs/perp-actions-visual.png` for a step-by-step visual of these flows.
 *
 * - **Security & Invariants:**
 *     - All state transitions, funding calculations, and Uniswap V4 interactions are performed atomically within Perp.sol.
 *     - The contract enforces margin, leverage, and liquidation requirements at every step.
 *     - All critical calculations are documented inline for auditability.
 * 
 */

///  ┌─────────────────────────────────────────────────────────────────────────────┐
///  │                                 Perp.sol                                   │
///  │ ────────────────────────────────────────────────────────────────────────── │
///  │                                                                             │
///  │  [State: funding, mark price, index price, positions, tick info, etc.]      │
///  │                                                                             │
///  │   ┌──────────────┐        ┌──────────────┐                                  │
///  │   │   Maker      │        │   Taker      │                                  │
///  │   │  (LP User)   │        │  (Trader)    │                                  │
///  │   └─────┬────────┘        └─────┬────────┘                                  │
///  │         │                         │                                         │
///  │         │ Provide liquidity       │ Open/close long/short                   │
///  │         │ (margin, tick range)    │ (swap USD AT <-> Perp AT)               │
///  │         │                         │                                         │
///  │         ▼                         ▼                                         │
///  │   ┌─────────────────────────────────────────────┐                            │
///  │   │   Mint/Burn Perp AT & USD AT (accounting)   │                            │
///  │   └─────────────────────────────────────────────┘                            │
///  │         │                         │                                         │
///  │         └────────────┬────────────┘                                         │
///  │                      │                                                      │
///  │                      ▼                                                      │
///  │         ┌─────────────────────────────────────────────┐                      │
///  │         │         Uniswap V4 Pool (Perp AT/USD AT)    │                      │
///  │         │ ─────────────────────────────────────────── │                      │
///  │         │  - Holds Perp AT and USD AT                 │                      │
///  │         │  - AMM logic for swaps and LP positions     │                      │
///  │         │  - Mark price = Perp AT / USD AT            │                      │
///  │         │  - Fees, tick accounting, liquidity math    │                      │
///  │         └─────────────────────────────────────────────┘                      │
///  │                      │                                                      │
///  │                      ▼                                                      │
///  │         ┌───────────────────────────────┐                                    │
///  │         │      PerpHook.sol             │                                    │
///  │         │  - Restricts pool access      │                                    │
///  │         │  - Enforces fee logic         │                                    │
///  │         └───────────────────────────────┘                                    │
///  │                                                                             │
///  │   [Perp.sol stores and updates:]                                            │
///  │     - fundingRateX96 (funding)                                             │
///  │     - twPremiumX96 (funding accumulator)                                    │
///  │     - mark price (from V4 pool)                                            │
///  │     - index price (from Beacon)                                            │
///  │     - all open positions (maker/taker)                                     │
///  │                                                                             │
///  │   [External:]                                                              │
///  │     ┌──────────────┐                                                       │
///  │     │   Beacon     │                                                       │
///  │     │ (Index Oracle)│                                                      │
///  │     └─────┬────────┘                                                       │
///  │           │                                                                │
///  │           ▼                                                                │
///  │     Supplies index price to Perp.sol for funding calculations              │
///  └─────────────────────────────────────────────────────────────────────────────┘

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

// ──────────────────────────────
// External Imports
// ──────────────────────────────

// OpenZeppelin
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Uniswap V4 - Types
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";

// Uniswap V4 - Interfaces
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

// Uniswap V4 - Libraries: Math
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { LiquidityMath } from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import { FixedPoint128 } from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import { UnsafeMath } from "@uniswap/v4-core/src/libraries/UnsafeMath.sol";

// Uniswap V4 - Libraries: Pool/Fees
import { Pool } from "@uniswap/v4-core/src/libraries/Pool.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { ProtocolFeeLibrary } from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import { SwapMath } from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { BitMath } from "@uniswap/v4-core/src/libraries/BitMath.sol";
import { CustomRevert } from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

// Uniswap V4 - Utilities
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

// Other External
import { IUniversalRouter } from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import { IPositionManager } from "v4-periphery/src/interfaces/IPositionManager.sol";

// ──────────────────────────────
// Internal Project Imports
// ──────────────────────────────

// Core Contracts
import { AccountingToken } from "./AccountingToken.sol";
import { IBeacon } from "./interfaces/IBeacon.sol";

// Utilities / Libraries
import { UniswapV4Utility } from "./libraries/UniswapV4Utility.sol";
import { Tick } from "./libraries/Tick.sol";
import { Funding } from "./libraries/Funding.sol";
import { FixedPoint96 } from "./libraries/FixedPoint96.sol";
import { FixedPoint192 } from "./libraries/FixedPoint192.sol";
import { TokenMath } from "./libraries/TokenMath.sol";
import { MoreSignedMath } from "./libraries/MoreSignedMath.sol";

contract Perp {
    using StateLibrary for IPoolManager;
    using Tick for mapping(int24 => Tick.GrowthInfo);
    using SafeCast for *;
    using ProtocolFeeLibrary for *;
    using LPFeeLibrary for uint24;
    using CustomRevert for bytes4;
    using TokenMath for uint256;
    using TokenMath for uint128;

    // ──────────────
    // Type Declarations
    // ──────────────

    /// @dev Stores addresses of core Uniswap V4 contracts used by the protocol.
    struct UniswapV4Contracts {
        address poolManager;      // Uniswap V4 PoolManager contract
        address router;           // Uniswap V4 UniversalRouter contract
        address positionManager;  // Uniswap V4 PositionManager contract
        address permit2;          // Permit2 contract for token approvals
    }

    /// @dev Stores protocol configuration parameters (fees, margin, leverage, etc.).
    struct PerpConfig {
        address usdc;                    // USDC token address
        address beacon;                  // Index price oracle (Beacon)
        uint24 tradingFee;               // Trading fee (basis points)
        uint128 minMargin;               // Minimum margin required
        uint128 maxMargin;               // Maximum margin allowed
        uint128 minOpeningLeverageX96;   // Minimum leverage (Q96)
        uint128 maxOpeningLeverageX96;   // Maximum leverage (Q96)
        uint128 liquidationMarginRatioX96; // Liquidation margin ratio (Q96)
        uint128 liquidationFeeX96;       // Liquidation fee (Q96)
        uint128 liquidationFeeSplitX96;  // Split of liquidation fee (Q96)
    }

    /// @dev Stores Uniswap V4 pool configuration (tick spacing, hook, initial price).
    struct UniswapV4PoolConfig {
        int24 tickSpacing;               // Tick spacing for the pool
        address hook;                    // PerpHook contract address
        uint160 startingSqrtPriceX96;    // Initial sqrt price (Q96)
    }

    /// @dev Represents a Maker (LP) position, including margin, liquidity, and funding state.
    struct MakerPosition {
        address holder;                  // Owner of the position
        int24 tickLower;                 // Lower tick of the LP range
        int24 tickUpper;                 // Upper tick of the LP range
        uint160 sqrtPriceLowerX96;       // Sqrt price at lower tick (Q96)
        uint160 sqrtPriceUpperX96;       // Sqrt price at upper tick (Q96)
        uint128 margin;                  // Margin posted by the maker
        uint128 liquidity;               // Liquidity provided
        uint128 perpsBorrowed;           // Perp AT borrowed (for LP accounting)
        uint128 usdBorrowed;             // USD AT borrowed (for LP accounting)
        int128 entryTwPremiumX96;        // Funding accumulator at entry (Q96)
        int128 entryTwPremiumDivBySqrtMarkX96; // Funding accumulator (divided by sqrt mark) at entry (Q96)
    }

    /// @dev Represents a Taker (trader) position, including margin, size, direction, and funding state.
    struct TakerPosition {
        address holder;                  // Owner of the position
        bool isLong;                     // True if long, false if short
        uint128 size;                    // Position size (in Perp AT)
        uint128 margin;                  // Margin posted by the taker
        uint128 entryValue;              // Entry value in USD AT
        int128 entryTwPremiumX96;        // Funding accumulator at entry (Q96)
    }

    // ──────────────
    // State Variables
    // ──────────────

    // --- Core contract addresses and configuration ---
    IPoolManager private immutable POOL_MANAGER;        // Uniswap V4 pool manager
    IUniversalRouter private immutable ROUTER;          // Uniswap V4 router
    IPositionManager private immutable POSITION_MANAGER;// Uniswap V4 position manager
    IERC20 public immutable USDC;                      // USDC token used for margin
    IBeacon public immutable BEACON;                   // Index price oracle

    // --- Protocol parameters (immutable) ---
    uint24 private immutable TRADING_FEE;              // Trading fee in basis points
    uint128 public immutable MIN_MARGIN;               // Minimum margin required
    uint128 public immutable MAX_MARGIN;               // Maximum margin allowed
    uint128 public immutable MIN_OPENING_LEVERAGE_X96; // Minimum leverage (Q96)
    uint128 public immutable MAX_OPENING_LEVERAGE_X96; // Maximum leverage (Q96)
    uint128 private immutable LIQUIDATION_MARGIN_RATIO_X96; // Liquidation margin ratio (Q96)
    uint128 private immutable LIQUIDATION_FEE_X96;     // Liquidation fee (Q96)
    uint128 private immutable LIQUIDATION_FEE_SPLIT_X96; // Split of liquidation fee (Q96)

    // --- Funding and price state ---
    int128 public fundingRateX96;                      // Current funding rate (Q96)
    int128 private twPremiumX96;                       // Funding accumulator (Q96)
    int128 private twPremiumDivBySqrtMarkX96;          // Funding accumulator divided by sqrt mark (Q96)
    int128 private lastFundingUpdate;                  // Last funding update timestamp

    // --- Position tracking ---
    uint128 private nextTakerPosId;                    // Next taker position ID
    mapping(uint256 => TakerPosition) public takerPositions; // All taker positions
    mapping(uint256 => MakerPosition) public makerPositions; // All maker positions
    mapping(int24 => Tick.GrowthInfo) private tickGrowthInfo; // Funding growth per tick

    // --- Constants ---
    int256 private constant FUNDING_PERIOD = 1 days;   // Funding period in seconds

    PoolKey private poolKey;
    PoolId private poolId;

    event MakerPositionOpened(
        uint256 makerPosId,
        address holder,
        uint256 margin,
        uint256 liquidity,
        int24 tickLower,
        int24 tickUpper,
        uint256 markPrice,
        uint256 indexPrice
    );
    event MakerPositionClosed(
        uint256 makerPosId,
        address holder,
        bool isLiquidatable,
        uint256 perpsBorrowed,
        uint256 usdBorrowed,
        uint256 markPrice
    );
    event TakerPositionOpened(
        uint256 takerPosId, address holder, bool isLong, uint256 size, uint256 markPrice, uint256 indexPrice
    );
    event TakerPositionClosed(uint256 takerPosId, address holder, bool isLong, uint256 size, uint256 markPrice);

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

        AccountingToken accountingTokenA = new AccountingToken(type(uint128).max);
        AccountingToken accountingTokenB = new AccountingToken(type(uint128).max);

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

        // assign smaller address to perpAccounting so that its always currency 0
        AccountingToken perpAccounting = accountingTokenA < accountingTokenB ? accountingTokenA : accountingTokenB;
        AccountingToken usdAccounting = accountingTokenA < accountingTokenB ? accountingTokenB : accountingTokenA;

        poolKey = PoolKey({
            currency0: Currency.wrap(address(perpAccounting)),
            currency1: Currency.wrap(address(usdAccounting)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: uniswapV4PoolConfig.tickSpacing,
            hooks: IHooks(uniswapV4PoolConfig.hook)
        });
        poolId = poolKey.toId();

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
        _validateMargin(margin);

        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        _validateMakerLeverage(margin, liquidity, sqrtPriceLowerX96, sqrtPriceUpperX96);

        (uint128 tickLowerLiquidityGrossBefore,,,) = POOL_MANAGER.getTickInfo(poolId, tickLower);
        (uint128 tickUpperLiquidityGrossBefore,,,) = POOL_MANAGER.getTickInfo(poolId, tickUpper);

        _updateTwPremiums();

        uint256 perpsBorrowed;
        uint256 usdBorrowed;
        (makerPosId, perpsBorrowed, usdBorrowed) = UniswapV4Utility._mintLiquidityPosition(
            poolKey, POSITION_MANAGER, tickLower, tickUpper, liquidity, type(uint128).max, type(uint128).max
        );

        _updateFundingRate();

        // initialize ticks if there were not initialized before
        if (tickLowerLiquidityGrossBefore == 0 || tickUpperLiquidityGrossBefore == 0) {
            (, int24 currentTick,,) = POOL_MANAGER.getSlot0(poolId);
            Tick.GrowthInfo memory growthInfo =
                Tick.GrowthInfo({ twPremiumX96: twPremiumX96, twPremiumDivBySqrtPriceX96: twPremiumDivBySqrtMarkX96 });

            if (tickLowerLiquidityGrossBefore == 0) {
                tickGrowthInfo.initialize(tickLower, currentTick, growthInfo);
            }

            if (tickUpperLiquidityGrossBefore == 0) {
                tickGrowthInfo.initialize(tickUpper, currentTick, growthInfo);
            }
        }

        makerPositions[makerPosId] = MakerPosition({
            holder: msg.sender,
            margin: margin,
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper,
            sqrtPriceLowerX96: sqrtPriceLowerX96,
            sqrtPriceUpperX96: sqrtPriceUpperX96,
            perpsBorrowed: perpsBorrowed.toUint128(),
            usdBorrowed: usdBorrowed.toUint128(),
            entryTwPremiumX96: twPremiumX96,
            entryTwPremiumDivBySqrtMarkX96: twPremiumDivBySqrtMarkX96
        });

        USDC.transferFrom(msg.sender, address(this), margin);
    }

    function closeMakerPosition(uint256 makerPosId) external {
        MakerPosition memory makerPos = makerPositions[makerPosId];

        _updateTwPremiums();

        (uint256 perpsReceived, uint256 usdReceived) =
            UniswapV4Utility._burnLiquidityPosition(poolKey, POSITION_MANAGER, makerPosId);

        int256 pnl = usdReceived.toInt256() - makerPos.usdBorrowed.toInt256();
        int128 excessPerps = perpsReceived.toInt128() - makerPos.perpsBorrowed.toInt128();
        pnl += _settleExcessPerps(excessPerps);

        _updateFundingRate();

        (uint128 tickLowerLiquidityGrossAfter,,,) = POOL_MANAGER.getTickInfo(poolId, makerPos.tickLower);
        (uint128 tickUpperLiquidityGrossAfter,,,) = POOL_MANAGER.getTickInfo(poolId, makerPos.tickUpper);

        if (tickLowerLiquidityGrossAfter == 0) {
            tickGrowthInfo.clear(makerPos.tickLower);
        }

        if (tickUpperLiquidityGrossAfter == 0) {
            tickGrowthInfo.clear(makerPos.tickUpper);
        }

        (uint160 sqrtPriceX96, int24 currentTick,,) = POOL_MANAGER.getSlot0(poolId);

        int256 funding = Funding.calcPendingFundingPaymentWithLiquidityCoefficient(
            makerPos.perpsBorrowed.toInt256(),
            makerPos.entryTwPremiumX96,
            Funding.Growth({ twPremiumX96: twPremiumX96, twPremiumDivBySqrtPriceX96: twPremiumDivBySqrtMarkX96 }),
            Funding.calcLiquidityCoefficientInFundingPaymentByOrder(
                makerPos.liquidity,
                makerPos.tickLower,
                makerPos.tickUpper,
                tickGrowthInfo.getAllFundingGrowth(
                    makerPos.tickLower, makerPos.tickUpper, currentTick, twPremiumX96, twPremiumDivBySqrtMarkX96
                )
            )
        );

        int256 effectiveMargin = makerPos.margin.scale6To18().toInt256() + pnl - funding;

        if (effectiveMargin < 0) {
            delete makerPositions[makerPosId];
            emit MakerPositionClosed(
                makerPosId, makerPos.holder, false, makerPos.perpsBorrowed, makerPos.usdBorrowed, liveMark()
            );
            return;
        }

        uint256 liquidationFee = FullMath.mulDiv(uint256(effectiveMargin), LIQUIDATION_FEE_X96, FixedPoint96.UINT_Q96);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, makerPos.sqrtPriceLowerX96, makerPos.sqrtPriceUpperX96, makerPos.liquidity
        );

        uint256 notionalValue = amount1 + amount0 * _sqrtPriceX96ToPriceX96(sqrtPriceX96);

        if (
            FullMath.mulDiv((uint256(effectiveMargin) - liquidationFee), FixedPoint96.UINT_Q96, notionalValue)
                < LIQUIDATION_MARGIN_RATIO_X96
        ) {
            USDC.transfer(msg.sender, (uint256(effectiveMargin) - liquidationFee).scale18To6());
            USDC.transfer(
                msg.sender,
                FullMath.mulDiv(liquidationFee.scale18To6(), LIQUIDATION_FEE_SPLIT_X96, FixedPoint96.UINT_Q96)
            );
        } else if (makerPos.holder == msg.sender) {
            USDC.transfer(msg.sender, uint256(effectiveMargin).scale18To6());
        } else {
            revert InvalidClose(msg.sender, makerPos.holder, false);
        }

        emit MakerPositionClosed(
            makerPosId, makerPos.holder, false, makerPos.perpsBorrowed, makerPos.usdBorrowed, liveMark()
        );

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
        _validateMargin(margin);
        _validateLeverage(leverageX96);

        _updateTwPremiums();

        uint128 perpsMoved;
        uint128 usdMoved = FullMath.mulDiv(margin.scale6To18(), leverageX96, FixedPoint96.UINT_Q96).toUint128();
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
            // perps moved out
            perpsMoved =
                UniswapV4Utility._swapExactInputSingle(ROUTER, poolKey, false, usdMoved, 0, TRADING_FEE).toUint128();
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
            // perps moved in
            perpsMoved = UniswapV4Utility._swapExactOutputSingle(ROUTER, poolKey, true, usdMoved, type(uint128).max, 0)
                .toUint128();
        }

        _updateFundingRate();

        takerPosId = nextTakerPosId;
        takerPositions[takerPosId] = TakerPosition({
            holder: msg.sender,
            isLong: isLong,
            size: perpsMoved,
            margin: margin,
            entryValue: usdMoved,
            entryTwPremiumX96: twPremiumX96
        });
        nextTakerPosId++;

        USDC.transferFrom(msg.sender, address(this), margin);

        (uint256 indexPrice,) = BEACON.getData();

        emit TakerPositionOpened(takerPosId, msg.sender, isLong, perpsMoved, liveMark(), indexPrice);
    }

    function closeTakerPosition(uint256 takerPosId) external {
        _updateTwPremiums();

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
            pnl = (notionalValue.toInt256() - takerPos.entryValue.toInt256());
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
            pnl = (takerPos.entryValue.toInt256() - notionalValue.toInt256());
        }

        _updateFundingRate();

        int256 funding = MoreSignedMath.mulDiv(
            twPremiumX96 - takerPos.entryTwPremiumX96, takerPos.size.toInt256(), FixedPoint96.UINT_Q96
        );
        if (!takerPos.isLong) funding = -funding;

        int256 effectiveMargin = takerPos.margin.scale6To18().toInt256() + pnl - funding;

        if (effectiveMargin < 0) {
            delete takerPositions[takerPosId];
            emit TakerPositionClosed(takerPosId, takerPos.holder, takerPos.isLong, takerPos.size, liveMark());
            return;
        }

        uint256 liquidationFee = FullMath.mulDiv(uint256(effectiveMargin), LIQUIDATION_FEE_X96, FixedPoint96.UINT_Q96);

        // check if isliquidatable, then liquidate, else check caller, then close, else revert
        if (
            FullMath.mulDiv((uint256(effectiveMargin) - liquidationFee), FixedPoint96.UINT_Q96, notionalValue)
                < LIQUIDATION_MARGIN_RATIO_X96
        ) {
            USDC.transfer(takerPos.holder, (uint256(effectiveMargin) - liquidationFee).scale18To6());
            USDC.transfer(
                msg.sender,
                FullMath.mulDiv(liquidationFee.scale18To6(), LIQUIDATION_FEE_SPLIT_X96, FixedPoint96.UINT_Q96)
            );
        } else if (takerPos.holder == msg.sender) {
            USDC.transfer(takerPos.holder, uint256(effectiveMargin).scale18To6());
        } else {
            revert InvalidClose(msg.sender, takerPos.holder, false);
        }

        emit TakerPositionClosed(takerPosId, takerPos.holder, takerPos.isLong, takerPos.size, liveMark());

        delete takerPositions[takerPosId];
    }

    function _validateMargin(uint256 margin) internal view {
        if (margin < MIN_MARGIN) revert MarginTooLow(margin, MIN_MARGIN);
        if (margin > MAX_MARGIN) revert MarginTooHigh(margin, MAX_MARGIN);
    }

    function _validateMakerLeverage(
        uint256 margin,
        uint128 liquidity,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96
    )
        internal
        view
    {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);

        (uint256 amount0, uint256 amount1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity);

        uint256 amount0InAmount1 =
            FullMath.mulDiv(amount0, _sqrtPriceX96ToPriceX96(sqrtPriceX96), FixedPoint96.UINT_Q96);

        uint256 notionalValue = amount1 + amount0InAmount1;

        uint256 leverageX96 = FullMath.mulDiv(notionalValue, FixedPoint96.UINT_Q96, margin.scale6To18());

        _validateLeverage(leverageX96);
    }

    function _validateLeverage(uint256 leverageX96) internal view {
        if (leverageX96 < MIN_OPENING_LEVERAGE_X96) revert LeverageTooLow(leverageX96, MIN_OPENING_LEVERAGE_X96);
        if (leverageX96 > MAX_OPENING_LEVERAGE_X96) revert LeverageTooHigh(leverageX96, MAX_OPENING_LEVERAGE_X96);
    }

    function _sqrtPriceX96ToPriceX96(uint256 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.UINT_Q96);
    }

    function _settleExcessPerps(int128 excessPerps) internal returns (int256 pnl) {
        if (excessPerps < 0) {
            // buy more perps to pay back debt
            _simulateSwap(
                Pool.SwapParams({
                    amountSpecified: excessPerps,
                    tickSpacing: poolKey.tickSpacing,
                    zeroForOne: false,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1,
                    lpFeeOverride: 0
                })
            );
            pnl = -(
                UniswapV4Utility._swapExactOutputSingle(
                    ROUTER, poolKey, false, (-excessPerps).toUint128(), type(uint128).max, 0
                ).toInt256()
            );
        } else {
            // sell excess perps
            _simulateSwap(
                Pool.SwapParams({
                    amountSpecified: excessPerps,
                    tickSpacing: poolKey.tickSpacing,
                    zeroForOne: true,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
                    lpFeeOverride: 0
                })
            );
            pnl =
                UniswapV4Utility._swapExactInputSingle(ROUTER, poolKey, true, excessPerps.toUint128(), 0, 0).toInt256();
        }
    }

    /// @notice Updates twPremiumX96 & twPremiumDivBySqrtMarkX96
    /// @dev Should be called before interactions with the pool
    function _updateTwPremiums() internal {
        int128 timeSinceLastUpdate = block.timestamp.toInt128() - lastFundingUpdate;
        // funding owed per second * time since last update (in seconds)
        twPremiumX96 += fundingRateX96 * timeSinceLastUpdate;

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        twPremiumDivBySqrtMarkX96 += MoreSignedMath.mulDiv(
            fundingRateX96, int256(timeSinceLastUpdate) * FixedPoint96.INT_Q96, sqrtPriceX96
        ).toInt128();

        lastFundingUpdate = block.timestamp.toInt128();
    }

    function _updateFundingRate() internal {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        uint256 markPriceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.UINT_Q96);

        (uint256 indexPriceX96,) = BEACON.getData();

        // a notional size 1 long position would pay (markPrice - indexPrice) over the next FUNDING_PERIOD
        fundingRateX96 = ((int256(markPriceX96) - int256(indexPriceX96)) / FUNDING_PERIOD).toInt128();
    }

    function _simulateSwap(Pool.SwapParams memory params)
        internal
        returns (BalanceDelta swapDelta, uint256 amountToProtocol, uint24 swapFee, Pool.SwapResult memory result)
    {
        (uint160 slot0sqrtPriceX96, int24 slot0tick, uint24 slot0protocolFee, uint24 slot0lpFee) =
            POOL_MANAGER.getSlot0(poolId);
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
        result.liquidity = POOL_MANAGER.getLiquidity(poolId);

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

        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = POOL_MANAGER.getFeeGrowthGlobals(poolId);
        step.feeGrowthGlobalX128 = zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128;

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (!(amountSpecifiedRemaining == 0 || result.sqrtPriceX96 == params.sqrtPriceLimitX96)) {
            step.sqrtPriceStartX96 = result.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                _nextInitializedTickWithinOneWord(result.tick, params.tickSpacing, zeroForOne);

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
                    tickGrowthInfo.cross(
                        step.tickNext,
                        Tick.GrowthInfo({
                            twPremiumX96: twPremiumX96,
                            twPremiumDivBySqrtPriceX96: twPremiumDivBySqrtMarkX96
                        })
                    );
                    (, int128 liquidityNet,,) = POOL_MANAGER.getTickInfo(poolId, step.tickNext);
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
                uint256 masked = POOL_MANAGER.getTickBitmap(poolId, wordPos) & mask;

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
                uint256 masked = POOL_MANAGER.getTickBitmap(poolId, wordPos) & mask;

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

    function liveMark() public view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        return _sqrtPriceX96ToPriceX96(sqrtPriceX96);
    }
}
