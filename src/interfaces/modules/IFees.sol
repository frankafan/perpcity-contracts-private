// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPerpManager} from "../IPerpManager.sol";

/// @title IFees
/// @notice Interface that a fee module must implement to be usable by the PerpManager
interface IFees {
    /* FUNCTIONS */

    function fees(IPerpManager.PerpConfig calldata perp) external returns (uint24 creatorFee, uint24 insuranceFee, uint24 lpFee);

    function liquidationFee(IPerpManager.PerpConfig calldata perp) external returns (uint24);
}