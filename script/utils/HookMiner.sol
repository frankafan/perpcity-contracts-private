// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice A minimal library for mining hook addresses
library HookMiner {
    /// @notice A mask to slice out the bottom 14 bits of an address
    /// @dev 0000 ... 0000 0011 1111 1111 1111
    uint160 constant FLAG_MASK = Hooks.ALL_HOOK_MASK;

    /// @notice Maximum number of iterations to find a salt to avoid infinite loops or MemoryOOG
    /// @dev Arbitrarily set
    uint256 constant MAX_LOOP = 100_000;

    /// @notice Find a salt that produces a hook address with the desired `flags`
    /// @param deployer The address that will deploy the hook
    /// In `forge test`, this will be the test contract `address(this)` or the pranking address
    /// In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)
    /// @param flags The desired flags for the hook address
    /// Example: `uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | ...)`
    /// @param creationCode The creation code of a hook contract
    /// Example: `type(Counter).creationCode`
    /// @param constructorArgs The encoded constructor arguments of a hook contract
    /// Example: `abi.encode(constructorArg1, constructorArg2))`
    /// @return hookAddress The fresh address computed using `salt`
    /// @return salt The salt found used to successfully compute a fresh `hookAddress`
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        // use mask to obtain the bottom 14 bits of specified flags
        flags = flags & FLAG_MASK;

        // prepare creation code with constructor arguments to help compute addresses
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);

        for (uint256 uintSalt; uintSalt < MAX_LOOP; uintSalt++) {
            hookAddress = computeAddress(deployer, uintSalt, creationCodeWithArgs);

            // if the hook's bottom 14 bits match the desired flags AND
            // the address doesn't have bytecode, we found a match
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(uintSalt));
            }
        }
        revert("HookMiner: could not find salt within specified iterations");
    }

    /// @notice Precompute a contract address deployed via CREATE2
    /// @param deployer The address that will deploy the hook
    /// In `forge test`, this will be the test contract `address(this)` or the pranking address
    /// In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)
    /// @param salt The salt used to deploy the hook
    /// @param creationCodeWithArgs The creation code of a hook contract with encoded constructor arguments appended
    /// Example: `abi.encodePacked(type(Counter).creationCode, abi.encode(constructorArg1, constructorArg2))`
    /// @return hookAddress The address computed using `deployer`, `salt`, and `creationCodeWithArgs`
    function computeAddress(address deployer, uint256 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address hookAddress)
    {
        // compute the address as specified by CREATE2 (https://eips.ethereum.org/EIPS/eip-1014)
        bytes32 initCodeHash = keccak256(creationCodeWithArgs);
        bytes32 bytes32Address = keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, initCodeHash));
        return address(uint160(uint256(bytes32Address)));
    }
}
