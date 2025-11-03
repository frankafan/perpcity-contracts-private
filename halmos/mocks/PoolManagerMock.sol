// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Mock implementation of PoolManager for Halmos testing
/// @dev Simplified implementation focusing on core pool operations needed for PerpManager tests
/// @dev Does not inherit IPoolManager to avoid implementing unused interface methods
contract PoolManagerMock {
    using PoolIdLibrary for PoolKey;
    using Pool for Pool.State;

    /* EVENTS */

    event Initialize(
        PoolId indexed id,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96,
        int24 tick
    );
    event ModifyLiquidity(
        PoolId indexed id,
        address indexed sender,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 salt
    );
    event Swap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );
    event Donate(PoolId indexed id, address indexed sender, uint256 amount0, uint256 amount1);
    event Transfer(address indexed caller, address indexed from, address indexed to, uint256 id, uint256 amount);

    /* STORAGE */

    /// @dev Pool state mapping
    mapping(PoolId => Pool.State) internal _pools;

    /// @dev ERC6909 balances: balances[owner][id]
    mapping(address => mapping(uint256 => uint256)) internal _balances;

    /// @dev Currency deltas for current unlock session: deltas[currency][address]
    mapping(Currency => mapping(address => int256)) internal _currencyDeltas;

    /// @dev Lock state
    bool internal unlocked;

    /* CORE FUNCTIONS */

    /// @notice Unlocks the pool manager and executes callback
    /// @dev Called by: UniV4Router.executeAction() in all PerpManager entry points
    /// - PerpManager.createPerp() -> PerpLogic.createPerp() -> executeAction(CREATE_POOL)
    /// - PerpManager.openMakerPos() -> PerpLogic.openPos() -> executeAction(MODIFY_LIQUIDITY)
    /// - PerpManager.openTakerPos() -> PerpLogic.openPos() -> executeAction(SWAP, DONATE)
    /// - PerpManager.addMargin() -> PerpLogic.addMargin() (no unlock, just state updates)
    /// - PerpManager.closePosition() -> PerpLogic.closePosition() -> executeAction(MODIFY_LIQUIDITY or SWAP)
    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!unlocked, "Already unlocked");

        unlocked = true;

        // Callback to the caller
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        // Lock again after callback
        unlocked = false;
    }

    /// @dev Called by: UniV4Router.createPool() during pool creation
    /// - PerpManager.createPerp() -> PerpLogic.createPerp() -> UniV4Router.createPool()
    /// Location: src/libraries/UniV4Router.sol:141
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        PoolId id = key.toId();

        // Initialize the pool using the Pool library
        tick = _pools[id].initialize(sqrtPriceX96, 0);

        emit Initialize(
            id,
            key.currency0,
            key.currency1,
            key.fee,
            key.tickSpacing,
            address(key.hooks),
            sqrtPriceX96,
            tick
        );
    }

    /// @dev Called by: UniV4Router.modifyLiquidity() for adding/removing liquidity
    /// - PerpManager.openMakerPos() -> PerpLogic.openPos() -> UniV4Router.modifyLiquidity() (add liquidity)
    /// - PerpManager.closePosition() -> PerpLogic.closePosition() -> UniV4Router.modifyLiquidity() (remove liquidity)
    /// Location: src/libraries/UniV4Router.sol:167, 171
    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes calldata
    ) external returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        require(unlocked, "Manager locked");

        PoolId id = key.toId();
        Pool.State storage pool = _pools[id];

        BalanceDelta principalDelta;
        (principalDelta, feesAccrued) = pool.modifyLiquidity(
            Pool.ModifyLiquidityParams({
                owner: msg.sender,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: int128(params.liquidityDelta),
                tickSpacing: key.tickSpacing,
                salt: params.salt
            })
        );

        callerDelta = principalDelta + feesAccrued;

        // Account the deltas
        _accountPoolBalanceDelta(key, callerDelta, msg.sender);

        emit ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);
    }

    /// @dev Called by: UniV4Router.swap() for executing swaps
    /// - PerpManager.openTakerPos() -> PerpLogic.openPos() -> UniV4Router.swap()
    /// - PerpManager.closePosition() -> PerpLogic.closePosition() -> UniV4Router.swap() (for taker positions)
    /// Location: src/libraries/UniV4Router.sol:208
    function swap(
        PoolKey memory key,
        SwapParams memory params,
        bytes calldata
    ) external returns (BalanceDelta swapDelta) {
        require(unlocked, "Manager locked");
        require(params.amountSpecified != 0, "Swap amount cannot be zero");

        PoolId id = key.toId();
        Pool.State storage pool = _pools[id];

        (swapDelta, , , ) = pool.swap(
            Pool.SwapParams({
                tickSpacing: key.tickSpacing,
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                lpFeeOverride: 0
            })
        );

        // Account the deltas
        _accountPoolBalanceDelta(key, swapDelta, msg.sender);

        // Get slot0 data from the pool
        uint160 sqrtPriceX96 = pool.slot0.sqrtPriceX96();
        int24 tick = pool.slot0.tick();

        emit Swap(id, msg.sender, swapDelta.amount0(), swapDelta.amount1(), sqrtPriceX96, pool.liquidity, tick, 0);
    }

    /// @dev Called by: UniV4Router.donate() to distribute LP fees
    /// - PerpManager.openTakerPos() -> PerpLogic.openPos() -> UniV4Router.donate()
    /// Location: src/libraries/UniV4Router.sol:236 (called from PerpLogic.sol:229)
    function donate(
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) external returns (BalanceDelta delta) {
        require(unlocked, "Manager locked");

        PoolId id = key.toId();
        Pool.State storage pool = _pools[id];

        delta = pool.donate(amount0, amount1);

        _accountPoolBalanceDelta(key, delta, msg.sender);

        emit Donate(id, msg.sender, amount0, amount1);
    }

    /// @dev Called by: AccountingToken.initialize() during pool creation
    /// - PerpManager.createPerp() -> PerpLogic.createPerp() -> UniV4Router.createPool() -> AccountingToken.initialize()
    /// Location: src/AccountingToken.sol:38
    function sync(Currency) external {
        // Simplified: do nothing for mock
    }

    /// @dev Called by: AccountingToken.initialize() during pool creation
    /// - PerpManager.createPerp() -> PerpLogic.createPerp() -> UniV4Router.createPool() -> AccountingToken.initialize()
    /// Location: src/AccountingToken.sol:47
    function settle() external payable returns (uint256 paid) {
        require(unlocked, "Manager locked");
        return _settle(msg.sender);
    }

    /// @dev Called by: UniV4Router.clearBalance() and AccountingToken.initialize()
    /// - All PerpManager functions -> UniV4Router.clearBalance() when settling positive deltas
    /// - PerpManager.createPerp() -> AccountingToken.initialize() for initial token minting
    /// Locations: src/libraries/UniV4Router.sol:251, src/AccountingToken.sol:44
    function mint(address to, uint256 id, uint256 amount) external {
        require(unlocked, "Manager locked");

        Currency currency = Currency.wrap(address(uint160(id)));
        _accountDelta(currency, -int128(uint128(amount)), msg.sender);

        _balances[to][id] += amount;
        emit Transfer(msg.sender, address(0), to, id, amount);
    }

    /// @dev Called by: UniV4Router.clearBalance() when settling negative deltas
    /// - All PerpManager functions -> UniV4Router.clearBalance() when tokens need to be burned
    /// Location: src/libraries/UniV4Router.sol:256
    function burn(address from, uint256 id, uint256 amount) external {
        require(unlocked, "Manager locked");

        Currency currency = Currency.wrap(address(uint160(id)));
        _accountDelta(currency, int128(uint128(amount)), msg.sender);

        _balances[from][id] -= amount;
        emit Transfer(msg.sender, from, address(0), id, amount);
    }

    /* VIEW FUNCTIONS */

    /// @notice Get slot0 data for a pool
    /// @dev Called by: PerpLogic and PerpManager for price and tick information
    /// - PerpManager.timeWeightedAvgSqrtPriceX96() via StateLibrary.getSlot0()
    /// - PerpLogic.openPos() -> poolManager.getSlot0() (lines 100, 221)
    /// - PerpLogic.addMargin() -> poolManager.getSlot0() (line 281)
    /// - PerpLogic.closePosition() -> poolManager.getSlot0() (lines 324, 381)
    /// Locations: src/PerpManager.sol:156, src/libraries/PerpLogic.sol:100,221,281,324,381
    function getSlot0(
        PoolId id
    ) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) {
        Pool.State storage pool = _pools[id];
        sqrtPriceX96 = pool.slot0.sqrtPriceX96();
        tick = pool.slot0.tick();
        protocolFee = pool.slot0.protocolFee();
        lpFee = pool.slot0.lpFee();
    }

    /// @notice Get tick info for a pool
    /// @dev Called by: UniV4Router.isTickInitialized() to check if a tick is initialized
    /// - PerpLogic.openPos() -> poolManager.isTickInitialized() (lines 128, 129)
    /// - PerpLogic.closePosition() -> poolManager.isTickInitialized() (lines 353, 354)
    /// Location: src/libraries/UniV4Router.sol:277
    function getTickInfo(
        PoolId id,
        int24 tick
    )
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128
        )
    {
        Pool.State storage pool = _pools[id];
        Pool.TickInfo memory info = pool.ticks[tick];
        return (info.liquidityGross, info.liquidityNet, info.feeGrowthOutside0X128, info.feeGrowthOutside1X128);
    }

    /// @notice Get tick bitmap for a pool
    /// @dev Called by: UniV4Router.nextInitializedTickWithinOneWord() for tick iteration
    /// - Funding.crossTicks() -> poolManager.nextInitializedTickWithinOneWord() -> poolManager.getTickBitmap()
    /// Location: src/libraries/UniV4Router.sol:303, 317
    function getTickBitmap(PoolId id, int16 word) external view returns (uint256) {
        return _pools[id].tickBitmap[word];
    }

    /* HELPER FUNCTIONS */

    /// @dev Settles currency for a recipient
    function _settle(address recipient) internal returns (uint256 paid) {
        // Simplified for mock - would handle actual token transfers in real implementation
        paid = msg.value;
        if (paid > 0) {
            Currency currency = Currency.wrap(address(0));
            _accountDelta(currency, int128(uint128(paid)), recipient);
        }
    }

    /// @dev Accounts a delta for a currency and address
    function _accountDelta(Currency currency, int128 delta, address target) internal {
        if (delta == 0) return;
        _currencyDeltas[currency][target] += delta;
    }

    /// @dev Accounts pool balance deltas for both currencies
    function _accountPoolBalanceDelta(PoolKey memory key, BalanceDelta delta, address target) internal {
        _accountDelta(key.currency0, delta.amount0(), target);
        _accountDelta(key.currency1, delta.amount1(), target);
    }
}

// contract PoolManagerMock {
//     function unlock(bytes calldata data) external returns (bytes memory) {
//         return data;
//     }
// }
