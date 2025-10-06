// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {ERC20} from "@solady/src/tokens/ERC20.sol";

contract TestnetUSDC is ERC20 {
    function name() public pure override returns (string memory) {
        return "Testnet USDC";
    }

    function symbol() public pure override returns (string memory) {
        return "USDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
