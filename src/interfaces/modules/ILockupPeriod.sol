// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPerpManager} from "../IPerpManager.sol";

/// @title ILockupPeriod
/// @notice Interface that a lockup period module must implement to be usable by the PerpManager
interface ILockupPeriod {
    /* FUNCTIONS */

    /// @notice Returns the lockup period of new maker positions for a perp
    /// @param perp The configuration for the perp
    /// @return lockupPeriod The lockup period in seconds
    function lockupPeriod(IPerpManager.PerpConfig calldata perp) external returns (uint32 lockupPeriod);
}
