// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Perp } from "./Perp.sol";

/// @title PerpRegistry
/// @notice A registry contract that manages the registration of perp markets
/// @dev This contract maintains a list of authorized perpetual markets and their associated metadata
contract PerpRegistry is Ownable {
    /// @notice Maps perpetual market addresses to their registration status
    /// @dev true indicates the perpetual market is registered and authorized
    mapping(address perp => bool isRegistered) public perps;

    /// @notice Emitted when a new perpetual market is registered
    /// @param perp The address of the registered perpetual market
    /// @param beacon The address of the beacon contract associated with the perpetual
    /// @param startingPrice The initial mark price of the perpetual market
    event PerpRegistered(address perp, address beacon, uint256 startingPrice);

    /// @notice Emitted when a perpetual market is removed from the registry
    /// @param perp The address of the removed perpetual market
    event PerpRemoved(address perp);

    /// @notice Creates a new PerpRegistry instance
    /// @param _owner The address that will be granted ownership of the registry
    constructor(address _owner) Ownable(_owner) { }

    /// @notice Registers a new perpetual market in the registry
    /// @dev Only callable by the contract owner. Records the perpetual's beacon and starting price
    /// @param perp The address of the perpetual market to register
    function registerPerp(address perp) external onlyOwner {
        perps[perp] = true;

        address beacon = address(Perp(perp).BEACON());
        uint256 startingPrice = Perp(perp).liveMark();

        emit PerpRegistered(perp, beacon, startingPrice);
    }

    /// @notice Removes a perpetual market from the registry
    /// @dev Only callable by the contract owner. Removes the perpetual's registration status
    /// @param perp The address of the perpetual market to remove
    function removePerp(address perp) external onlyOwner {
        delete perps[perp];

        emit PerpRemoved(perp);
    }
}
