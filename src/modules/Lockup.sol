// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPerpManager} from "../interfaces/IPerpManager.sol";
import {ILockupPeriod} from "../interfaces/modules/ILockupPeriod.sol";

/// @title Lockup
/// @notice A basic implementation of a lockup period module
contract Lockup is ILockupPeriod {
    /* CONSTANTS */

    /// @notice The lockup period for new maker positions
    uint32 public constant LOCKUP_PERIOD = 7 days;

    /* FUNCTIONS */

    /// @inheritdoc ILockupPeriod
    function lockupPeriod(IPerpManager.PerpConfig calldata) external pure returns (uint32) {
        return LOCKUP_PERIOD;
    }
}
