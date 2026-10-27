// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SiphonSteps, SiphonConfig} from "../script/SiphonSteps.sol";
import {SiphonDataLogger} from "../src/SiphonDataLogger.sol";
import {SiphonPoolOperator} from "../src/SiphonPoolOperator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice A local copy of the launch situation: a standard PoolManager, a SIPH stand-in, a seeded
/// ETH/SIPH Pool A at 1 ETH = 1e8 SIPH (Pool A's live price), and the CREATE2 deployer the script uses.
abstract contract SiphonFixture is Test, SiphonSteps {
    address constant OWNER = 0x735121A546092F31050A867FD7E3A750C7B0EFF9;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @dev The deterministic deployment proxy's runtime code, as read from chain 4663.
    bytes constant CREATE2_DEPLOYER_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    /// @dev Pool A's live sqrtPriceX96 on 4663: 10000 * 2^96, tick 184206/184216 region.
    uint160 constant SQRT_PRICE_A = 792281625142643375935439503360000;

    IPoolManager manager;
    MockERC20 siph;
    SiphonPoolOperator seeder;
    PoolKey keyA;
    SiphonConfig cfg;

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(address(this))));
        siph = new MockERC20("Siphon", "SIPH", 1e30);
        vm.etch(CREATE2_DEPLOYER, CREATE2_DEPLOYER_CODE);

        keyA = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(siph)),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(keyA, SQRT_PRICE_A);

        // Seed Pool A from this test contract so it has a live price and depth.
        seeder = new SiphonPoolOperator(manager, address(this));
        vm.deal(address(this), 100 ether);
        siph.approve(address(seeder), type(uint256).max);
        seeder.addLiquidity{value: 10 ether}(keyA, -887220, 887220, 1e22, 10 ether, 1e28);

        cfg = SiphonConfig({
            manager: manager,
            owner: OWNER,
            siph: address(siph),
            poolAId: PoolId.unwrap(keyA.toId()),
            fee: 12_500,
            tickSpacing: 60,
            create2Deployer: CREATE2_DEPLOYER
        });

        vm.deal(OWNER, 10 ether);
        require(siph.transfer(OWNER, 1e27));
    }

    function deployed() internal returns (SiphonDataLogger hook, SiphonPoolOperator operator, PoolKey memory keyB) {
        (hook,, operator) = stepDeploy(cfg);
        vm.startPrank(OWNER);
        (keyB,,) = stepInitializePoolB(cfg, address(hook));
        vm.stopPrank();
    }

    /// @dev Deploys, initializes Pool B, seeds it with 1 ETH from the owner and sets [A, B].
    function live() internal returns (SiphonDataLogger hook, SiphonPoolOperator operator, PoolKey memory keyB) {
        (hook, operator, keyB) = deployed();
        vm.startPrank(OWNER);
        stepAddLiquidity(cfg, operator, keyB, 1 ether, 100);
        stepSetPoolIds(cfg, hook, PoolId.unwrap(keyB.toId()));
        vm.stopPrank();
    }

    receive() external payable {}
}
