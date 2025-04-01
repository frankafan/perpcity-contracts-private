// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Vault is Initializable, ERC4626Upgradeable {
    mapping(address depositor => bool isAllowed) public allowedDepositors;

    error DepositorNotAllowed();

    event DepositorAdded(address depositor);
    event DepositorRemoved(address depositor);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function __DebtVault_init(
        IERC20 usdcToken,
        string memory vaultTokenName,
        string memory vaultTokenSymbol
    )
        internal
        onlyInitializing
    {
        __ERC4626_init(usdcToken);
        __ERC20_init(vaultTokenName, vaultTokenSymbol);
        _addDepositor(address(this));
    }

    function _addDepositor(address depositor) internal {
        allowedDepositors[depositor] = true;
        emit DepositorAdded(depositor);
    }

    function _removeDepositor(address depositor) internal {
        allowedDepositors[depositor] = false;
        emit DepositorRemoved(depositor);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (!allowedDepositors[receiver]) revert DepositorNotAllowed();

        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        if (!allowedDepositors[receiver]) revert DepositorNotAllowed();

        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }

        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);

        return assets;
    }
}
