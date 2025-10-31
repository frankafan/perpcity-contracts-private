// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

// TODO: figure out justification / correct mock
// TODO: get correct inheritance

/// @title Mock PoolManager for Halmos Testing
/// @notice Minimal implementation focusing on functions used by PerpManager
contract PoolManagerMock {
    function unlock(bytes calldata data) external returns (bytes memory) {
        // Simple passthrough for testing
        return data;
    }
}

// import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
// import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
// import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
// import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
// import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// /// @notice Mock implementation of IPoolManager for Halmos testing
// /// @dev Simplified implementation focusing on core pool operations needed for PerpManager tests
// contract PoolManagerMock is IPoolManager {
//     using PoolIdLibrary for PoolKey;
//     using Pool for Pool.State;

//     /// @dev Pool state mapping
//     mapping(PoolId => Pool.State) internal _pools;

//     /// @dev ERC6909 balances: balances[owner][id]
//     mapping(address => mapping(uint256 => uint256)) internal _balances;

//     /// @dev ERC6909 allowances: allowances[owner][spender][id]
//     mapping(address => mapping(address => mapping(uint256 => uint256))) internal _allowances;

//     /// @dev ERC6909 operator approvals: isOperator[owner][operator]
//     mapping(address => mapping(address => bool)) internal _isOperator;

//     /// @dev Currency deltas for current unlock session: deltas[currency][address]
//     mapping(Currency => mapping(address => int256)) internal _currencyDeltas;

//     /// @dev Lock state
//     bool internal unlocked;

//     /// @dev Protocol fees accrued
//     mapping(Currency => uint256) internal _protocolFeesAccrued;

//     /// @dev Protocol fee controller
//     address internal _protocolFeeController;

//     /* IPoolManager FUNCTIONS */

//     /// @inheritdoc IPoolManager
//     function unlock(bytes calldata data) external override returns (bytes memory result) {
//         require(!unlocked, "Already unlocked");

//         unlocked = true;

//         // Callback to the caller
//         result = IUnlockCallback(msg.sender).unlockCallback(data);

//         // Lock again after callback
//         unlocked = false;
//     }

//     /// @inheritdoc IPoolManager
//     function initialize(PoolKey memory key, uint160 sqrtPriceX96) external override returns (int24 tick) {
//         PoolId id = key.toId();

//         // Initialize the pool using the Pool library
//         tick = _pools[id].initialize(sqrtPriceX96, 0);

//         emit Initialize(id, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks, sqrtPriceX96, tick);
//     }

//     /// @inheritdoc IPoolManager
//     function modifyLiquidity(
//         PoolKey memory key,
//         ModifyLiquidityParams memory params,
//         bytes calldata
//     ) external override returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
//         require(unlocked, "Manager locked");

//         PoolId id = key.toId();
//         Pool.State storage pool = _pools[id];

//         BalanceDelta principalDelta;
//         (principalDelta, feesAccrued) = pool.modifyLiquidity(
//             Pool.ModifyLiquidityParams({
//                 owner: msg.sender,
//                 tickLower: params.tickLower,
//                 tickUpper: params.tickUpper,
//                 liquidityDelta: int128(params.liquidityDelta),
//                 tickSpacing: key.tickSpacing,
//                 salt: params.salt
//             })
//         );

//         callerDelta = principalDelta + feesAccrued;

//         // Account the deltas
//         _accountPoolBalanceDelta(key, callerDelta, msg.sender);

//         emit ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);
//     }

//     /// @inheritdoc IPoolManager
//     function swap(
//         PoolKey memory key,
//         SwapParams memory params,
//         bytes calldata
//     ) external override returns (BalanceDelta swapDelta) {
//         require(unlocked, "Manager locked");
//         require(params.amountSpecified != 0, "Swap amount cannot be zero");

//         PoolId id = key.toId();
//         Pool.State storage pool = _pools[id];

//         (swapDelta, , , ) = pool.swap(
//             Pool.SwapParams({
//                 tickSpacing: key.tickSpacing,
//                 zeroForOne: params.zeroForOne,
//                 amountSpecified: params.amountSpecified,
//                 sqrtPriceLimitX96: params.sqrtPriceLimitX96,
//                 lpFeeOverride: 0
//             })
//         );

//         // Account the deltas
//         _accountPoolBalanceDelta(key, swapDelta, msg.sender);

//         // Get slot0 data from the pool
//         uint160 sqrtPriceX96 = pool.slot0.sqrtPriceX96();
//         int24 tick = pool.slot0.tick();

//         emit Swap(id, msg.sender, swapDelta.amount0(), swapDelta.amount1(), sqrtPriceX96, pool.liquidity, tick, 0);
//     }

//     /// @inheritdoc IPoolManager
//     function donate(
//         PoolKey memory key,
//         uint256 amount0,
//         uint256 amount1,
//         bytes calldata
//     ) external override returns (BalanceDelta delta) {
//         require(unlocked, "Manager locked");

//         PoolId id = key.toId();
//         Pool.State storage pool = _pools[id];

//         delta = pool.donate(amount0, amount1);

//         _accountPoolBalanceDelta(key, delta, msg.sender);

//         emit Donate(id, msg.sender, amount0, amount1);
//     }

//     /// @inheritdoc IPoolManager
//     function sync(Currency) external override {
//         // Simplified: do nothing for mock
//     }

//     /// @inheritdoc IPoolManager
//     function take(Currency currency, address to, uint256 amount) external override {
//         require(unlocked, "Manager locked");

//         // Account the delta (taking decreases the delta)
//         _accountDelta(currency, -int128(uint128(amount)), msg.sender);

//         // Transfer would happen here in real implementation
//         // For mock, we just adjust balances
//     }

//     /// @inheritdoc IPoolManager
//     function settle() external payable override returns (uint256 paid) {
//         require(unlocked, "Manager locked");
//         return _settle(msg.sender);
//     }

//     /// @inheritdoc IPoolManager
//     function settleFor(address recipient) external payable override returns (uint256 paid) {
//         require(unlocked, "Manager locked");
//         return _settle(recipient);
//     }

//     /// @inheritdoc IPoolManager
//     function clear(Currency currency, uint256 amount) external override {
//         require(unlocked, "Manager locked");

//         int256 current = _currencyDeltas[currency][msg.sender];
//         require(current == int256(amount), "Must clear exact positive delta");

//         _accountDelta(currency, -int128(uint128(amount)), msg.sender);
//     }

//     /// @inheritdoc IPoolManager
//     function mint(address to, uint256 id, uint256 amount) external override {
//         require(unlocked, "Manager locked");

//         Currency currency = Currency.wrap(address(uint160(id)));
//         _accountDelta(currency, -int128(uint128(amount)), msg.sender);

//         _balances[to][id] += amount;
//         emit Transfer(msg.sender, address(0), to, id, amount);
//     }

//     /// @inheritdoc IPoolManager
//     function burn(address from, uint256 id, uint256 amount) external override {
//         require(unlocked, "Manager locked");

//         Currency currency = Currency.wrap(address(uint160(id)));
//         _accountDelta(currency, int128(uint128(amount)), msg.sender);

//         _balances[from][id] -= amount;
//         emit Transfer(msg.sender, from, address(0), id, amount);
//     }

//     /// @inheritdoc IPoolManager
//     function updateDynamicLPFee(PoolKey memory, uint24) external pure override {
//         // Not needed for basic mock
//         revert("Not implemented");
//     }

//     /* IERC6909Claims FUNCTIONS */

//     function balanceOf(address owner, uint256 id) external view override returns (uint256) {
//         return _balances[owner][id];
//     }

//     function allowance(address owner, address spender, uint256 id) external view override returns (uint256) {
//         return _allowances[owner][spender][id];
//     }

//     function isOperator(address owner, address operator) external view override returns (bool) {
//         return _isOperator[owner][operator];
//     }

//     function transfer(address receiver, uint256 id, uint256 amount) external override returns (bool) {
//         _balances[msg.sender][id] -= amount;
//         _balances[receiver][id] += amount;
//         emit Transfer(msg.sender, msg.sender, receiver, id, amount);
//         return true;
//     }

//     function transferFrom(
//         address sender,
//         address receiver,
//         uint256 id,
//         uint256 amount
//     ) external override returns (bool) {
//         if (msg.sender != sender && !_isOperator[sender][msg.sender]) {
//             _allowances[sender][msg.sender][id] -= amount;
//         }

//         _balances[sender][id] -= amount;
//         _balances[receiver][id] += amount;
//         emit Transfer(msg.sender, sender, receiver, id, amount);
//         return true;
//     }

//     function approve(address spender, uint256 id, uint256 amount) external override returns (bool) {
//         _allowances[msg.sender][spender][id] = amount;
//         emit Approval(msg.sender, spender, id, amount);
//         return true;
//     }

//     function setOperator(address operator, bool approved) external override returns (bool) {
//         _isOperator[msg.sender][operator] = approved;
//         emit OperatorSet(msg.sender, operator, approved);
//         return true;
//     }

//     /* IProtocolFees FUNCTIONS */

//     function protocolFeesAccrued(Currency currency) external view override returns (uint256) {
//         return _protocolFeesAccrued[currency];
//     }

//     function setProtocolFee(PoolKey memory, uint24) external pure override {
//         revert("Not implemented");
//     }

//     function setProtocolFeeController(address controller) external override {
//         _protocolFeeController = controller;
//     }

//     function collectProtocolFees(address, Currency, uint256) external pure override returns (uint256) {
//         revert("Not implemented");
//     }

//     function protocolFeeController() external view override returns (address) {
//         return _protocolFeeController;
//     }

//     /* IExtsload FUNCTIONS */

//     function extsload(bytes32 slot) external view override returns (bytes32) {
//         bytes32 value;
//         assembly {
//             value := sload(slot)
//         }
//         return value;
//     }

//     function extsload(bytes32 startSlot, uint256 nSlots) external view override returns (bytes32[] memory) {
//         bytes32[] memory values = new bytes32[](nSlots);
//         for (uint256 i = 0; i < nSlots; i++) {
//             bytes32 slot = bytes32(uint256(startSlot) + i);
//             assembly {
//                 let value := sload(slot)
//                 mstore(add(add(values, 32), mul(i, 32)), value)
//             }
//         }
//         return values;
//     }

//     function extsload(bytes32[] calldata slots) external view override returns (bytes32[] memory) {
//         bytes32[] memory values = new bytes32[](slots.length);
//         for (uint256 i = 0; i < slots.length; i++) {
//             assembly {
//                 let value := sload(calldataload(add(slots.offset, mul(i, 32))))
//                 mstore(add(add(values, 32), mul(i, 32)), value)
//             }
//         }
//         return values;
//     }

//     /* IExttload FUNCTIONS */

//     function exttload(bytes32 slot) external view override returns (bytes32) {
//         bytes32 value;
//         assembly {
//             value := tload(slot)
//         }
//         return value;
//     }

//     function exttload(bytes32[] calldata slots) external view override returns (bytes32[] memory) {
//         bytes32[] memory values = new bytes32[](slots.length);
//         for (uint256 i = 0; i < slots.length; i++) {
//             assembly {
//                 let value := tload(calldataload(add(slots.offset, mul(i, 32))))
//                 mstore(add(add(values, 32), mul(i, 32)), value)
//             }
//         }
//         return values;
//     }

//     /* HELPER FUNCTIONS */

//     /// @dev Settles currency for a recipient
//     function _settle(address recipient) internal returns (uint256 paid) {
//         // Simplified for mock - would handle actual token transfers in real implementation
//         paid = msg.value;
//         if (paid > 0) {
//             Currency currency = Currency.wrap(address(0));
//             _accountDelta(currency, int128(uint128(paid)), recipient);
//         }
//     }

//     /// @dev Accounts a delta for a currency and address
//     function _accountDelta(Currency currency, int128 delta, address target) internal {
//         if (delta == 0) return;
//         _currencyDeltas[currency][target] += delta;
//     }

//     /// @dev Accounts pool balance deltas for both currencies
//     function _accountPoolBalanceDelta(PoolKey memory key, BalanceDelta delta, address target) internal {
//         _accountDelta(key.currency0, delta.amount0(), target);
//         _accountDelta(key.currency1, delta.amount1(), target);
//     }
// }
