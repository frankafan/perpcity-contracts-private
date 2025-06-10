/**
 * @title Perp.sol: Perp Implementation on Uniswap V4
 * @author Perp City
 * @notice This contract is the core of a perpetual futures protocol, leveraging Uniswap V4 as the price discovery engine. It enables two main user roles:
 *   - **Makers (LPs):** Provide liquidity to a Uniswap V4 pool using two custom accounting tokens (Perp AT and USD AT), and earn fees and funding payments.
 *   - **Takers (Traders):** Take leveraged long or short positions by swapping between the accounting tokens in the pool.
 *
 * The protocol maintains a mark price (from the Uniswap V4 pool) and an index price (from an external Beacon contract). Continuous funding payments are exchanged between longs and shorts to keep the mark price in line with the index price. All user and protocol actions (open/close maker/taker positions, margin, funding, liquidation) are performed atomically and routed through this contract.
 *
 * SYSTEM OVERVIEW & RELATIONSHIPS
 * ----------------------------------------------------------------------------
 * - **Uniswap V4 Pool**: The central AMM for price discovery, holding Perp AT and USD AT. All swaps and liquidity operations are routed through this pool. See `poolKey`, `poolId`, and UniswapV4Utility helpers.
 * - **Accounting Tokens**: Two non-transferrable ERC20 tokens (Perp AT and USD AT) are minted/burned by this contract for internal accounting and margin. See `AccountingToken.sol`, constructor, and `poolKey` assignment.
 * - **Makers (LPs)**: Provide liquidity in a tick range using Perp AT and USD AT. Positions are tracked with additional margin, funding, and PnL logic beyond standard Uniswap V4 LPs. See `MakerPosition` struct, `makerPositions` mapping, `openMakerPosition()`, and `closeMakerPosition()`.
 * - **Takers (Traders)**: Open leveraged long or short positions by swapping between Perp AT and USD AT in the Uniswap V4 pool.
 * - **Beacon (Index Oracle)**: External contract providing the index price for funding calculations. See `IBeacon` interface, `BEACON` state variable, and `_updateFundingRate()`.
 * - **PerpHook**: Custom Uniswap V4 hook contract that restricts pool access to this contract and enforces protocol-specific fee logic. See `UniswapV4PoolConfig.hook` and swap functions.
 * - **Funding Mechanism**: Funding payments are calculated and settled on every trade to keep the mark price in line with the index price. See funding state variables, `Funding.sol`, and `_updateFundingRate()`.
 * - **Liquidation Logic**: Margin and leverage requirements are enforced for all positions. See `_validateMargin()`, `_validateLeverage()`, and close functions.
 * - **Utilities/Libraries**: All Uniswap V4 and protocol math is abstracted into dedicated libraries for safety and clarity. See `UniswapV4Utility`, `Funding`, `Tick`, `MoreSignedMath`, `TokenMath`, `FixedPoint96`, `FixedPoint192`.
 *
 * KEY COMPONENTS (with explicit references)
 * ----------------------------------------------------------------------------
 * 1. **Accounting Tokens**
 *    - Deployed in the constructor via `AccountingToken.sol`.
 *    - Always assigned to `currency0` (Perp AT) and `currency1` (USD AT) in `poolKey`.
 *    - Used in all Uniswap V4 pool operations (see `UniswapV4Utility` calls).
 *
 * 2. **Uniswap V4 Pool Integration**
 *    - All swaps and liquidity operations are routed through a Uniswap V4 pool, referenced by `poolKey` and `poolId`.
 *    - Interacts with Uniswap V4 contracts via `IPoolManager`, `IUniversalRouter`, and `IPositionManager` (see state variables `POOL_MANAGER`, `ROUTER`, `POSITION_MANAGER`).
 *    - Pool configuration is set in the constructor using `UniswapV4PoolConfig` struct.
 *    - All pool logic is abstracted via the `UniswapV4Utility` library (see `_mintLiquidityPosition`, `_burnLiquidityPosition`, swap helpers).
 *
 * 3. **Makers (LPs)**
 *    - Open positions by providing liquidity in a tick range to the Uniswap V4 pool, using Perp AT and USD AT.
 *    - The contract mints these accounting tokens and deposits them into the pool on behalf of the maker.
 *    - Maker positions are tracked with additional margin, funding, and PnL logic beyond standard Uniswap V4 LPs.
 *    - Close: `closeMakerPosition()` → burns LP position, settles funding and PnL (using `Funding` and `Tick` libraries), returns margin + PnL in USDC, and cleans up tick state if needed.
 *    - Tick funding state: managed via `tickGrowthInfo` and `Tick` library.
 *
 * 4. **Takers (Traders)**
 *    - Open leveraged long or short positions by swapping between Perp AT and USD AT in the Uniswap V4 pool.
 *    - The contract performs the swap, tracks margin, size, direction, entry value, and funding state.
 *    - Close: `closeTakerPosition()` → performs reverse swap, settles funding and PnL (using `Funding` and `MoreSignedMath` libraries), returns margin + PnL in USDC.
 *    - Events: `TakerPositionOpened`, `TakerPositionClosed`.
 *    - Errors: `MarginTooLow`, `MarginTooHigh`, `LeverageTooLow`, `LeverageTooHigh`, `InvalidClose`.
 *    - Funding and PnL are settled on close using the `Funding` and `MoreSignedMath` libraries.
 *
 * 5. **Funding Mechanism**
 *    - Continuous funding is calculated and settled on every trade.
 *    - State variables: `fundingRateX96`, `twPremiumX96`, `twPremiumDivBySqrtMarkX96`, `lastFundingUpdate`.
 *    - Core functions: `_updateFundingRate()`, `_updateTwPremiums()`.
 *    - Funding math is implemented in `Funding.sol` and used in close functions and tick growth logic.
 *
 * 6. **Beacon (Index Price Oracle)**
 *    - External price oracle contract, referenced via the `IBeacon` interface and the `BEACON` state variable.
 *    - Used in `_updateFundingRate()` and in events to provide the index price for funding calculations.
 *
 * 7. **PerpHook (Fee and Access Control)**
 *    - The `hook` address in `UniswapV4PoolConfig` restricts pool access to this contract and enforces protocol-specific fee logic.
 *    - Fee logic is set in swap functions (`openTakerPosition`, `closeTakerPosition`) and enforced by the PerpHook contract.
 *
 * 8. **Liquidation Logic**
 *    - Margin and leverage requirements are enforced in `_validateMargin()`, `_validateLeverage()`, and `_validateMakerLeverage()`.
 *    - Liquidation thresholds and fees are set by `LIQUIDATION_MARGIN_RATIO_X96`, `LIQUIDATION_FEE_X96`, and `LIQUIDATION_FEE_SPLIT_X96`.
 *    - Liquidation and payout logic is implemented in `closeMakerPosition()` and `closeTakerPosition()`.
 *    - Errors: `InvalidClose`.
 *
 * 9. **Utilities and Libraries**
 *    - `UniswapV4Utility.sol`: All Uniswap V4 pool and swap logic.
 *    - `Funding.sol`: Funding math and settlement.
 *    - `Tick.sol`: Tick growth and funding accumulator logic.
 *    - `MoreSignedMath.sol`, `TokenMath.sol`, `FixedPoint96.sol`, `FixedPoint192.sol`: Math utilities for fixed-point and signed math.
 *
 * ARCHITECTURE & FLOW (with explicit references and details)
 * ----------------------------------------------------------------------------
 * - **Makers (LPs):**
 *     - Open: `openMakerPosition()` → mints Perp AT and USD AT, provides liquidity in a tick range, records `MakerPosition` with margin, liquidity, tick range, and funding state.
 *     - Close: `closeMakerPosition()` → burns LP position, settles funding and PnL (using `Funding` and `Tick` libraries), returns margin + PnL in USDC, and cleans up tick state if needed.
 *     - Tick funding state: managed via `tickGrowthInfo` and `Tick` library.
 *
 * - **Takers (Traders):**
 *     - Open: `openTakerPosition()` → performs swap (USD AT <-> Perp AT), records `TakerPosition` with margin, size, direction, entry value, and funding state.
 *     - Close: `closeTakerPosition()` → performs reverse swap, settles funding and PnL (using `Funding` and `MoreSignedMath` libraries), returns margin + PnL in USDC.
 *
 * - **Uniswap V4 Integration:**
 *     - All pool operations use `UniswapV4Utility` helpers and interact with `POOL_MANAGER`, `ROUTER`, `POSITION_MANAGER`.
 *     - Pool configuration: `poolKey`, `poolId`, `UniswapV4PoolConfig`.
 *
 * - **Accounting Tokens:**
 *     - Minted/burned in constructor and pool operations; never transferrable to users.
 *     - See `AccountingToken.sol` and constructor logic.
 *
 * - **Funding & Mark/Index Price:**
 *     - Mark price: `liveMark()` (from pool).
 *     - Index price: `BEACON.getData()`.
 *     - Funding: `_updateFundingRate()`, `_updateTwPremiums()`, `Funding` library.
 *
 * - **Transaction Flow:**
 *     - All user actions are atomic and routed through this contract.
 *     - PerpHook restricts pool access and enforces fee logic (see `hook` in `UniswapV4PoolConfig`).
 *     - Visual: see `docs/perp-actions-visual.png`.
 *     - Design doc: see `docs/perp-high-level-design.md`.
 *
 * - **Security & Invariants:**
 *     - All state transitions, funding, and pool interactions are atomic.
 *     - Margin, leverage, and liquidation checks: `_validateMargin()`, `_validateLeverage()`, `_validateMakerLeverage()`.
 *     - All critical calculations are documented inline and use dedicated libraries for safety and clarity.
 *     - Errors are thrown for all invalid actions (see Errors section).
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
///  │                      │                                                      │
///  │                      ▼                                                      │
///  │         ┌───────────────────────────────┐                                    │
///  │         │      Perp.sol (this)          │                                    │
///  │         │  - All user actions           │                                    │
///  │         │  - Margin, funding,           │                                    │
///  │         │    liquidation logic          │                                    │
///  │         │  - Tracks all positions       │                                    │
///  │         │  - Calls Uniswap V4, Beacon   │                                    │
///  │         └───────────────────────────────┘                                    │
///  │                      │                                                      │
///  │                      ▼                                                      │
///  │         ┌───────────────────────────────┐                                    │
///  │         │      Beacon (Oracle)          │                                    │
///  │         │  - Index price feed           │                                    │
///  │         └───────────────────────────────┘                                    │
///  │                                                                             │
///  │   [Perp.sol stores and updates:]                                            │
///  │     - fundingRateX96 (funding)                                             │
///  │     - twPremiumX96 (funding accumulator)                                    │
///  │     - mark price (from V4 pool)                                            │
///  │     - index price (from Beacon)                                            │
///  │     - all open positions (maker/taker)                                     │
///  │     - tickGrowthInfo (funding per tick)                                    │
///  └─────────────────────────────────────────────────────────────────────────────┘