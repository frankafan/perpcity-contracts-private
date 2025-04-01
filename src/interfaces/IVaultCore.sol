// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

interface IVaultCore is IERC20 {
    /// @notice Emitted when the treasury gate deposits revenue into the vault.
    /// @param assets The amount of revenue deposited.
    event RevenueDeposited(uint256 assets);

    /// @notice Emitted when the treasury gate redeems revenue from the vault.
    /// @param assets The amount of revenue redeemed.
    event RevenueRedeemed(uint256 assets);

    /// @notice Error thrown when the caller is not the business.
    error CallerNotBusiness();

    /// @notice Deposits revenue into the vault, callable only by the set business.
    /// @param assets The amount of revenue to deposit.
    function depositRevenue(uint256 assets) external;

    /// @notice Redeems revenue from the vault
    /// @param receiver The address to redeem revenue to.
    function redeemRevenue(address receiver) external;
}
