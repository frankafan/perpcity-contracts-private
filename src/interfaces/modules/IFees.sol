// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPerpManager} from "../IPerpManager.sol";

/// @title IFees
/// @notice Interface that a fee module must implement to be usable by the PerpManager
interface IFees {
    /* FUNCTIONS */

    /// @notice Returns fees to charge takers on open given a perp config
    /// @dev All fees are scaled by 1e6
    /// @param perp The configuration for the perp
    /// @return cFee The creator fee
    /// @return insFee The insurance fee
    /// @return lpFee The liquidity provider fee
    function fees(IPerpManager.PerpConfig calldata perp) external returns (uint24 cFee, uint24 insFee, uint24 lpFee);

    /// @notice Returns the fee to charge positions on liquidation given a perp config
    /// @dev The fee is scaled by 1e6
    /// @param perp The configuration for the perp
    /// @return fee The liquidation fee
    function liquidationFee(IPerpManager.PerpConfig calldata perp) external returns (uint24 fee);
}
