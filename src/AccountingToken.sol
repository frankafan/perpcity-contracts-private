// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract AccountingToken is ERC20 {
    constructor(uint256 initialSupply) ERC20("Perp City Accounting Token", "PCACC") {
        _mint(msg.sender, initialSupply);
    }
}
