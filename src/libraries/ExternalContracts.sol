// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUniversalRouter } from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { IPermit2 } from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library ExternalContracts {
    struct Contracts {
        IPoolManager poolManager;
        IUniversalRouter router;
        IPositionManager positionManager;
        IPermit2 permit2;
        IERC20 usdc;
    }
}
