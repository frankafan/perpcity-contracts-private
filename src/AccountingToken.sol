// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {ERC20} from "@solady/src/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title AccountingToken
/// @notice A valueless token representing either perp contracts or usd, only held by Uniswap PoolManager
contract AccountingToken is ERC20 {
    /* STORAGE */

    /// @notice Whether the token has been initialized
    bool public isInitialized;

    /* ERRORS */

    /// @notice Thrown when trying to initialize a token that has already been initialized
    error AlreadyInitialized();
    /// @notice Thrown when trying to transfer the token
    error TransferNotAllowed();

    /* FUNCTIONS */

    /// @notice Mints accounting tokens to `PoolManager` to increase msg.sender's ERC6909 balance
    /// @dev This is called on each perp creation for a perp accounting token and usd accounting token
    /// This can only be called once for each accounting token's lifetime
    /// @param poolManager The Uniswap PoolManager to mint the tokens to
    /// @param amountToMint The amount of tokens to mint
    function initialize(IPoolManager poolManager, uint256 amountToMint) external {
        if (isInitialized) revert AlreadyInitialized();

        // wrap this token address into a Uniswap Currency
        Currency currency = Currency.wrap(address(this));

        // sync must be called before any tokens are sent into PoolManager
        // it writes current balance of specified currency to transient storage in PoolManager
        poolManager.sync(currency);

        // mint amountToMint accounting tokens to the PoolManager, increasing the delta by amountToMint
        _mint(address(poolManager), amountToMint);

        // use up the positive delta to mint amountToMint ERC6909 tokens to msg.sender
        poolManager.mint(msg.sender, currency.toId(), amountToMint);

        // ensure the delta is settled in PoolManager
        poolManager.settle();

        isInitialized = true;
    }

    /// @inheritdoc ERC20
    function name() public pure override returns (string memory) {
        return "Perp City Accounting Token";
    }

    /// @inheritdoc ERC20
    function symbol() public pure override returns (string memory) {
        return "PCACC";
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @inheritdoc ERC20
    function _beforeTokenTransfer(address from, address, uint256) internal pure override {
        if (from != address(0)) revert TransferNotAllowed();
    }
}
