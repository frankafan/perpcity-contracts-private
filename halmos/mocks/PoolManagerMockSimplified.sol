// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Simplified PoolManager mock for Halmos testing
/// @dev Barebones implementation focusing on core logic with minimal complexity
/// @dev All pool logic is inlined to reduce symbolic execution overhead
contract PoolManagerMock {
    using PoolIdLibrary for PoolKey;

    // Structs

    /// @dev Slot0 contains the current price and tick
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
    }

    /// @dev Tick info for a specific tick
    struct TickInfo {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    /// @dev Simplified pool state
    struct PoolState {
        Slot0 slot0;
        uint128 liquidity;
        mapping(int24 => TickInfo) ticks;
        mapping(int16 => uint256) tickBitmap;
    }

    /// @dev Parameters for internal modifyLiquidity
    struct ModifyLiquidityParamsInternal {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
        int24 tickSpacing;
        bytes32 salt;
    }

    /// @dev Parameters for internal swap
    struct SwapParamsInternal {
        int24 tickSpacing;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        uint128 lpFeeOverride;
    }

    // Events
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

    // State

    /// @dev Lock state - true when unlocked, false when locked
    bool internal _unlocked;

    /// @dev Pool states
    mapping(PoolId => PoolState) internal _poolStates;

    /// @dev ERC6909-style token balances: owner => tokenId => balance
    mapping(address => mapping(uint256 => uint256)) internal _tokenBalances;

    /// @dev Currency deltas for current unlock session: currency => address => delta
    mapping(Currency => mapping(address => int256)) internal _deltas;

    // Lock mechanism

    /// @notice Unlocks the pool manager and executes callback
    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!_unlocked, "Already unlocked");
        _unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        _unlocked = false;
    }

    // Pool operations

    /// @notice Initialize a new pool
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        PoolId id = key.toId();
        uint24 lpFee = key.fee;

        tick = _initializePool(_poolStates[id], sqrtPriceX96, lpFee);

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

    /// @notice Modify liquidity in a pool
    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes calldata
    ) external returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        require(_unlocked, "Manager locked");
        PoolId id = key.toId();

        (BalanceDelta principalDelta, BalanceDelta fees) = _modifyLiquidity(
            _poolStates[id],
            ModifyLiquidityParamsInternal({
                owner: msg.sender,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: int128(params.liquidityDelta),
                tickSpacing: key.tickSpacing,
                salt: params.salt
            })
        );

        callerDelta = principalDelta + fees;
        feesAccrued = fees;
        _accountDeltas(key, callerDelta, msg.sender);
        emit ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);
    }

    /// @notice Execute a swap in a pool
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (BalanceDelta delta) {
        require(_unlocked, "Manager locked");
        PoolId id = key.toId();
        PoolState storage pool = _poolStates[id];

        (delta, , , ) = _swap(
            pool,
            SwapParamsInternal({
                tickSpacing: key.tickSpacing,
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                lpFeeOverride: 0
            })
        );

        _accountDeltas(key, delta, msg.sender);
        emit Swap(
            id,
            msg.sender,
            delta.amount0(),
            delta.amount1(),
            pool.slot0.sqrtPriceX96,
            pool.liquidity,
            pool.slot0.tick,
            0
        );
    }

    /// @notice Donate tokens to a pool
    function donate(
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) external returns (BalanceDelta delta) {
        require(_unlocked, "Manager locked");
        PoolId id = key.toId();
        delta = _donate(amount0, amount1);
        _accountDeltas(key, delta, msg.sender);
        emit Donate(id, msg.sender, amount0, amount1);
    }

    // Token operations (ERC6909-like)

    /// @notice Mint tokens (settle negative delta)
    function mint(address to, uint256 id, uint256 amount) external {
        require(_unlocked, "Manager locked");
        _accountDelta(Currency.wrap(address(uint160(id))), -int128(uint128(amount)), msg.sender);
        _tokenBalances[to][id] += amount;
        emit Transfer(msg.sender, address(0), to, id, amount);
    }

    /// @notice Burn tokens (settle positive delta)
    function burn(address from, uint256 id, uint256 amount) external {
        require(_unlocked, "Manager locked");
        _accountDelta(Currency.wrap(address(uint160(id))), int128(uint128(amount)), msg.sender);
        _tokenBalances[from][id] -= amount;
        emit Transfer(msg.sender, from, address(0), id, amount);
    }

    /// @notice Settle with native currency
    function settle() external payable returns (uint256 paid) {
        require(_unlocked, "Manager locked");
        paid = msg.value;
        if (paid > 0) _accountDelta(Currency.wrap(address(0)), int128(uint128(paid)), msg.sender);
    }

    /// @notice Sync currency state (no-op for mock)
    function sync(Currency) external {
        // No-op for simplified mock
    }

    // View functions

    /// @notice Get current price and tick for a pool
    function getSlot0(
        PoolId id
    ) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) {
        Slot0 memory slot0 = _poolStates[id].slot0;
        return (slot0.sqrtPriceX96, slot0.tick, slot0.protocolFee, slot0.lpFee);
    }

    /// @notice Get tick information for a pool
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
        TickInfo memory info = _poolStates[id].ticks[tick];
        return (info.liquidityGross, info.liquidityNet, info.feeGrowthOutside0X128, info.feeGrowthOutside1X128);
    }

    /// @notice Get tick bitmap for a pool
    function getTickBitmap(PoolId id, int16 word) external view returns (uint256) {
        return _poolStates[id].tickBitmap[word];
    }

    // Internal pool logic (was in PoolMock)

    /// @dev Initialize a pool
    function _initializePool(
        PoolState storage self,
        uint160 sqrtPriceX96,
        uint24 protocolFee
    ) internal returns (int24 tick) {
        require(self.slot0.sqrtPriceX96 == 0, "Already initialized");

        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        self.slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick, protocolFee: protocolFee, lpFee: 0});
    }

    /// @dev Modify liquidity in the pool
    function _modifyLiquidity(
        PoolState storage self,
        ModifyLiquidityParamsInternal memory params
    ) internal returns (BalanceDelta delta, BalanceDelta feesAccrued) {
        // Simplified: return approximate deltas
        int128 amount0Delta = int128(params.liquidityDelta / 2);
        int128 amount1Delta = int128(params.liquidityDelta / 2);

        delta = toBalanceDelta(amount0Delta, amount1Delta);
        feesAccrued = toBalanceDelta(0, 0);

        // Update liquidity
        if (params.liquidityDelta > 0) {
            self.liquidity += uint128(params.liquidityDelta);
        } else if (params.liquidityDelta < 0) {
            self.liquidity -= uint128(-params.liquidityDelta);
        }

        // Update tick info
        _updateTick(self, params.tickLower, params.liquidityDelta);
        _updateTick(self, params.tickUpper, params.liquidityDelta);
    }

    /// @dev Execute a swap
    function _swap(
        PoolState storage self,
        SwapParamsInternal memory params
    ) internal returns (BalanceDelta delta, uint160, uint24, uint128) {
        require(params.amountSpecified != 0, "Amount cannot be zero");

        // Simplified: calculate approximate swap delta
        int128 amount0Delta;
        int128 amount1Delta;

        if (params.zeroForOne) {
            amount0Delta = int128(params.amountSpecified);
            amount1Delta = -int128(params.amountSpecified); // Simplified 1:1 swap
        } else {
            amount0Delta = -int128(params.amountSpecified);
            amount1Delta = int128(params.amountSpecified);
        }

        delta = toBalanceDelta(amount0Delta, amount1Delta);

        // Update pool state (simplified price impact)
        if (params.zeroForOne) {
            self.slot0.tick -= 1; // Price moves down
        } else {
            self.slot0.tick += 1; // Price moves up
        }
        self.slot0.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(self.slot0.tick);

        return (delta, self.slot0.sqrtPriceX96, 0, self.liquidity);
    }

    /// @dev Donate to the pool
    function _donate(uint256 amount0, uint256 amount1) internal pure returns (BalanceDelta delta) {
        // Simplified: donations are just added as deltas
        delta = toBalanceDelta(-int128(uint128(amount0)), -int128(uint128(amount1)));
    }

    /// @dev Helper to update tick info
    function _updateTick(PoolState storage self, int24 tick, int128 liquidityDelta) private {
        TickInfo storage info = self.ticks[tick];

        if (liquidityDelta > 0) {
            info.liquidityGross += uint128(liquidityDelta);
            info.liquidityNet += liquidityDelta;
        } else if (liquidityDelta < 0) {
            info.liquidityGross -= uint128(-liquidityDelta);
            info.liquidityNet += liquidityDelta; // Note: adding negative delta
        }
    }

    // Internal helpers

    /// @dev Account a single currency delta
    function _accountDelta(Currency currency, int128 delta, address target) internal {
        if (delta != 0) _deltas[currency][target] += delta;
    }

    /// @dev Account deltas for both currencies in a pool
    function _accountDeltas(PoolKey memory key, BalanceDelta delta, address target) internal {
        _accountDelta(key.currency0, delta.amount0(), target);
        _accountDelta(key.currency1, delta.amount1(), target);
    }
}
