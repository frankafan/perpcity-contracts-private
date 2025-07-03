// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PerpHook } from "./PerpHook.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { FixedPoint96 } from "./libraries/FixedPoint96.sol";
import { Perp } from "./libraries/Perp.sol";
import { Positions } from "./libraries/Positions.sol";

contract TradingVault is ERC4626 {
    error InvalidUSDC(address perpUSDC, address vaultUSDC);

    PerpHook public perpHook;
    mapping(PoolId perpId => uint256 positionId) public perpToPosition;
    PoolId[6] public perps;

    // note: reentrancy vulnerable if longPerps or shortPerps are malicious
    constructor(
        PerpHook _perpHook,
        IERC20 _usdc,
        PoolId[3] memory longPerps,
        PoolId[3] memory shortPerps,
        uint256 initialDeposit,
        address receiver
    )
        ERC4626(_usdc)
        ERC20("Trading Vault", "TV")
    {
        perpHook = _perpHook;

        (,,,, IERC20 usdc) = perpHook.externalContracts();

        if (address(usdc) != address(_usdc)) {
            revert InvalidUSDC(address(usdc), address(_usdc));
        }

        for (uint256 i = 0; i < 3; i++) {
            perps[i] = longPerps[i];
        }
        for (uint256 i = 3; i < 6; i++) {
            perps[i] = shortPerps[i];
        }

        deposit(initialDeposit, receiver);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        closeAllPositions();

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        openNewPositions();

        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        closeAllPositions();

        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        openNewPositions();

        return shares;
    }

    function closeAllPositions() internal {
        for (uint256 i = 0; i < 6; i++) {
            Positions.TakerInfo memory takerPos = perpHook.getTakerPosition(perps[i], perpToPosition[perps[i]]);
            if (takerPos.margin != 0) {
                perpHook.closeTakerPosition(perps[i], perpToPosition[perps[i]]);
            }
        }
    }

    // only call when all positions are closed
    function openNewPositions() internal {
        uint256 totalAssets = totalAssets();
        uint256 assetsPerPerp = totalAssets / 6;

        Perp.OpenTakerPositionParams memory longParams = Perp.OpenTakerPositionParams({
            isLong: true,
            margin: SafeCast.toUint128(assetsPerPerp),
            leverageX96: FixedPoint96.UINT_Q96
        });

        Perp.OpenTakerPositionParams memory shortParams = Perp.OpenTakerPositionParams({
            isLong: false,
            margin: SafeCast.toUint128(assetsPerPerp),
            leverageX96: FixedPoint96.UINT_Q96
        });

        for (uint256 i = 0; i < 3; i++) {
            perpHook.openTakerPosition(perps[i], longParams);
        }
        for (uint256 i = 3; i < 6; i++) {
            perpHook.openTakerPosition(perps[i], shortParams);
        }
    }
}
