// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { TradingVault } from "./TradingVault.sol";
import { PerpHook } from "./PerpHook.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

contract TradingVaultRegistry {
    mapping(address vault => bool isRegistered) public isRegistered;
    PerpHook public perpHook;
    IERC20 public usdc;

    event VaultCreated(address vault);

    error InvalidUSDC(address perpUSDC, address vaultUSDC);

    constructor(PerpHook _perpHook, IERC20 _usdc) {
        perpHook = _perpHook;
        usdc = _usdc;

        (,,,, IERC20 usdcFromPerp) = perpHook.externalContracts();

        if (address(usdcFromPerp) != address(_usdc)) {
            revert InvalidUSDC(address(usdcFromPerp), address(_usdc));
        }
    }

    // note: reentrancy vulnerable if longPerps or shortPerps are malicious
    function createVault(
        PoolId[3] memory longPerps,
        PoolId[3] memory shortPerps,
        uint256 initialDeposit,
        address receiver
    )
        public
    {
        TradingVault vault = new TradingVault(perpHook, usdc, longPerps, shortPerps, initialDeposit, receiver);
        isRegistered[address(vault)] = true;
        emit VaultCreated(address(vault));
    }
}
