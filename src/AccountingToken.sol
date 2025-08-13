// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {ERC20} from "@solady/src/tokens/ERC20.sol";

// tokens held only by the perp manager and uniswap pools for accounting
contract AccountingToken is ERC20 {
    constructor(uint128 initialSupply) ERC20() {
        _mint(msg.sender, initialSupply);
    }

    function name() public pure override returns (string memory) {
        return "Perp City Accounting Token";
    }

    function symbol() public pure override returns (string memory) {
        return "PCACC";
    }
}
