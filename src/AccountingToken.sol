// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {ERC20} from "@solady/src/tokens/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

// token only held by Uniswap PoolManager used for accounting
contract AccountingToken is ERC20 {
    error AlreadyInitialized();
    error TransferNotAllowed();

    bool public isInitialized;

    function initialize(IPoolManager poolManager, uint256 amountToMint) public {
        if (isInitialized) revert AlreadyInitialized();

        // wrap this token address into a Uniswap Currency
        Currency currency = Currency.wrap(address(this));

        // sync must be called before any tokens are sent into PoolManager
        // it writes current balance of specified currency to transient storage
        poolManager.sync(currency);

        // mint amountToMint ERC20 tokens to the PoolManager, increasing the delta by amountToMint
        _mint(address(poolManager), amountToMint);

        // use up the positive delta to mint amountToMint ERC6909 tokens to msg.sender
        poolManager.mint(msg.sender, currency.toId(), amountToMint);

        // ensure the delta is settled in PoolManager
        poolManager.settle();

        isInitialized = true;
    }

    function name() public pure override returns (string memory) {
        return "Perp City Accounting Token";
    }

    function symbol() public pure override returns (string memory) {
        return "PCACC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function _beforeTokenTransfer(address from, address, uint256) internal pure override {
        if (from != address(0)) revert TransferNotAllowed();
    }
}
