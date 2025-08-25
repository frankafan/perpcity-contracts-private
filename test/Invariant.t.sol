// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {PerpManager} from "../src/PerpManager.sol";
import {IPerpManager} from "../src/interfaces/IPerpManager.sol";
import {FixedPoint96} from "../src/libraries/FixedPoint96.sol";
import {TradingFee} from "../src/libraries/TradingFee.sol";
import {TestnetUSDC} from "../src/testnet/TestnetUSDC.sol";
import {PerpHandler} from "./PerpHandler.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {RouterParameters} from "@uniswap/universal-router/contracts/types/RouterParameters.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Test} from "forge-std/Test.sol";

contract InvariantTest is Test, Fixtures {
    // using EasyPosm for IPositionManager;

    IUniversalRouter public universalRouter;
    address public usdc;

    uint128 public constant PERP_CREATION_FEE = 5e5; // 5 USDC
    address public immutable PERP_CREATION_FEE_RECIPIENT = makeAddr("perp creation fee recipient");

    function setUp() public {
        // deploys the pool manager, utility routers, and permit2
        deployFreshManagerAndRouters();
        // deploys the position manager
        deployPosm(manager);

        RouterParameters memory params = RouterParameters({
            permit2: address(permit2),
            weth9: address(0),
            v2Factory: address(0),
            v3Factory: address(0),
            pairInitCodeHash: bytes32(0),
            poolInitCodeHash: bytes32(0),
            v4PoolManager: address(manager),
            v3NFTPositionManager: address(0),
            v4PositionManager: address(posm)
        });
        universalRouter = new UniversalRouter(params);

        usdc = address(new TestnetUSDC());

        // Since PerpManager.sol is a hook, we need to deploy it to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x5555 << 144) // Namespace the address to avoid collisions
        );

        // Add all necessary constructor arguments for PerpManager.sol
        bytes memory constructorArgs = abi.encode(
            IPerpManager.ExternalContracts({poolManager: manager, posm: posm, router: universalRouter, usdc: usdc}),
            PERP_CREATION_FEE,
            PERP_CREATION_FEE_RECIPIENT
        );

        // Use StdCheats.deployCodeTo to deploy the PerpManager.sol contract to the flags address
        deployCodeTo("PerpManager.sol:PerpManager", constructorArgs, flags);

        PerpHandler perpHandler = new PerpHandler(PerpManager(flags), usdc, 10);

        targetContract(address(perpHandler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = PerpHandler.createPerp.selector;
        selectors[1] = PerpHandler.openMakerPosition.selector;
        selectors[2] = PerpHandler.addMakerMargin.selector;
        selectors[3] = PerpHandler.closeMakerPosition.selector;
        // selectors[4] = PerpHandler.openTakerPosition.selector;

        targetSelector(FuzzSelector({addr: address(perpHandler), selectors: selectors}));
    }

    function invariant_no_reverts() public {
        assert(true);
    }
}
