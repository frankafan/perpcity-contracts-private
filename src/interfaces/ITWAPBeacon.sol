// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { IBeacon } from "./IBeacon.sol";

interface ITWAPBeacon is IBeacon {
    function getTWAP(uint32 twapSecondsAgo) external view returns (uint256);
}
