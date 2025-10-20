// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IFees} from "../interfaces/modules/IFees.sol";
import {IPerpManager} from "../interfaces/IPerpManager.sol";

contract Fees is IFees {
    uint24 public constant CREATOR_FEE = 0.0001e6; // 0.01%
    uint24 public constant INSURANCE_FEE = 0.001e6; // 0.1%
    uint24 public constant LP_FEE = 0.01e6; // 1%
    uint24 public constant LIQUIDATION_FEE = 0.01e6; // 1%

    function fees(IPerpManager.PerpConfig calldata perp) external returns (uint24 creatorFee, uint24 insuranceFee, uint24 lpFee) {
        return (CREATOR_FEE, INSURANCE_FEE, LP_FEE);
    }

    function liquidationFee(IPerpManager.PerpConfig calldata perp) external returns (uint24) {
        return LIQUIDATION_FEE;
    }
}