// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {ILockupPeriod} from "../interfaces/modules/ILockupPeriod.sol";
import {IPerpManager} from "../interfaces/IPerpManager.sol";

contract Lockup is ILockupPeriod {
    uint32 public constant LOCKUP_PERIOD = 7 days;
    function lockupPeriod(IPerpManager.PerpConfig calldata perp) external returns (uint32) {
        return LOCKUP_PERIOD;
    }
}