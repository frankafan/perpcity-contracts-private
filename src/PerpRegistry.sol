// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Perp } from "./Perp.sol";

contract PerpRegistry is Ownable {
    mapping(address perp => bool isRegistered) public perps;

    event PerpRegistered(address perp, address beacon, uint256 startingPrice);
    event PerpRemoved(address perp);

    constructor(address _owner) Ownable(_owner) { }

    function registerPerp(address perp) external onlyOwner {
        perps[perp] = true;

        address beacon = address(Perp(perp).BEACON());
        uint256 startingPrice = Perp(perp).liveMark();

        emit PerpRegistered(perp, beacon, startingPrice);
    }

    function removePerp(address perp) external onlyOwner {
        delete perps[perp];

        emit PerpRemoved(perp);
    }
}
