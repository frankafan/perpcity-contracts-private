// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IPerpManager} from "../interfaces/IPerpManager.sol";
import {IFees} from "../interfaces/modules/IFees.sol";

/// @title Fees
/// @notice A basic implementation of a fees module
contract Fees is IFees {
    /* CONSTANTS */

    /// @notice The creator fee, equivalent to 0.01%
    uint24 public constant CREATOR_FEE = 0.0001e6;
    /// @notice The insurance fee, equivalent to 0.1%
    uint24 public constant INSURANCE_FEE = 0.001e6;
    /// @notice The liquidity provider fee, equivalent to 1%
    uint24 public constant LP_FEE = 0.01e6;
    /// @notice The liquidation fee, equivalent to 1%
    uint24 public constant LIQUIDATION_FEE = 0.01e6;

    /* FUNCTIONS */

    /// @inheritdoc IFees
    function fees(IPerpManager.PerpConfig calldata) external pure returns (uint24, uint24, uint24) {
        return (CREATOR_FEE, INSURANCE_FEE, LP_FEE);
    }

    /// @inheritdoc IFees
    function liquidationFee(IPerpManager.PerpConfig calldata) external pure returns (uint24) {
        return LIQUIDATION_FEE;
    }
}
