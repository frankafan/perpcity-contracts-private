// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract vAMM is Initializable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    uint256 public perpSupply;
    uint256 public usdSupply;

    uint256 public constant PERP_PRECISION = 1e18;

    function __vAMM_init(uint256 indexPrice) internal onlyInitializing {
        perpSupply = 1000 * PERP_PRECISION; // there is 1000 PERP
        usdSupply = indexPrice * 1000; // multiply by 1000 to make sure the ratio for price == indexPrice
    }

    function _changePerpSupply(bool isRemove, uint256 amount) internal returns (uint256 usdSupplyChange) {
        uint256 newPerpSupply = isRemove ? perpSupply - amount : perpSupply + amount;

        // Calculate new USD supply with rounding
        uint256 newUsdSupply = Math.mulDiv(perpSupply, usdSupply, newPerpSupply);
        if (mulmod(perpSupply, usdSupply, newPerpSupply) * 2 >= newPerpSupply) {
            newUsdSupply += 1;
        }

        usdSupplyChange = isRemove ? newUsdSupply - usdSupply : usdSupply - newUsdSupply;

        perpSupply = newPerpSupply;
        usdSupply = newUsdSupply;
    }

    function markPrice() public view returns (uint256 price) {
        price = Math.mulDiv(usdSupply, PERP_PRECISION, perpSupply);
    }

    function previewChangePerpSupply(bool isRemove, uint256 amount) public view returns (uint256 usdSupplyChange) {
        uint256 newPerpSupply = isRemove ? perpSupply - amount : perpSupply + amount;
        uint256 newUsdSupply = Math.mulDiv(perpSupply, usdSupply, newPerpSupply);
        if (mulmod(perpSupply, usdSupply, newPerpSupply) * 2 >= newPerpSupply) {
            newUsdSupply += 1;
        }

        usdSupplyChange = isRemove ? newUsdSupply - usdSupply : usdSupply - newUsdSupply;
    }

    function previewChangeUsdSupply(bool isRemove, uint256 amount) external view returns (uint256 perpSupplyChange) {
        uint256 newUsdSupply = isRemove ? usdSupply - amount : usdSupply + amount;
        uint256 newPerpSupply = Math.mulDiv(perpSupply, usdSupply, newUsdSupply);
        if (mulmod(perpSupply, usdSupply, newUsdSupply) * 2 >= newUsdSupply) {
            newPerpSupply += 1;
        }

        perpSupplyChange = isRemove ? newPerpSupply - perpSupply : perpSupply - newPerpSupply;
    }
}
