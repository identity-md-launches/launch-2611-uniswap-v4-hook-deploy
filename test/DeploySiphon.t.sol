// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DeploySiphon} from "../script/DeploySiphon.s.sol";
import {SiphonConfig, SiphonResult} from "../script/SiphonSteps.sol";
import {SiphonDataLogger} from "../src/SiphonDataLogger.sol";
import {SiphonPoolOperator} from "../src/SiphonPoolOperator.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {SiphonFixture} from "./SiphonFixture.sol";

contract DeploySiphonTest is SiphonFixture {
    using StateLibrary for IPoolManager;

    function test_scriptConfigIsTheBriefs() public {
        DeploySiphon script = new DeploySiphon();
        SiphonConfig memory c = script.config();
        assertEq(address(c.manager), 0x8366a39CC670B4001A1121B8F6A443A643e40951);
        assertEq(c.owner, 0x735121A546092F31050A867FD7E3A750C7B0EFF9);
        assertEq(c.siph, 0x60013a6F087CB84B3C28129Dac9a568e94d2b384);
        assertEq(c.poolAId, 0x4ec8156257098665395fc6c8cc13c3943ffdb6ca1cacf8ff59957360d0e2d4d3);
        assertEq(c.fee, 12_500);
        assertEq(c.tickSpacing, 60);
        assertEq(c.create2Deployer, CREATE2_DEPLOYER);
    }

    function test_predictedHookAddressCarriesFlags() public {
        DeploySiphon script = new DeploySiphon();
        (address hook, bytes32 salt,, bytes32 poolBId) = script.predict();
        assertEq(uint160(hook) & 0x3fff, 0x1040);
        SiphonConfig memory c = script.config();
        assertEq(hook, create2Address(CREATE2_DEPLOYER, salt, hookInitCode(c)));
        PoolKey memory k = poolBKey(c, hook);
        assertEq(Currency.unwrap(k.currency0), address(0));
        assertEq(Currency.unwrap(k.currency1), c.siph);
        assertEq(address(k.hooks), hook);
        assertEq(poolBId, PoolId.unwrap(k.toId()));
    }

    function test_scriptRefusesWrongChainOrSender() public {
        DeploySiphon script = new DeploySiphon();
        vm.expectRevert("not Robinhood mainnet (4663)");
        script.run(1 ether);
        vm.chainId(4663);
        vm.expectRevert("run with --sender set to the owner");
        script.run(1 ether);
    }

    function test_minedSaltIsDeterministicAndDeploys() public {
        (bytes32 salt, address predicted) = mineHookSalt(cfg);
        (bytes32 again,) = mineHookSalt(cfg);
        assertEq(salt, again);
        assertTrue(HookFlags.matches(predicted, HookFlags.SIPHON));
        (SiphonDataLogger hook,,) = stepDeploy(cfg);
        assertEq(address(hook), predicted);
        // Re-running reuses the deployment instead of failing.
        (SiphonDataLogger same,,) = stepDeploy(cfg);
        assertEq(address(same), predicted);
    }

    function test_fullSequence() public {
        vm.startPrank(OWNER);
        SiphonResult memory r = runSequence(cfg, 0.0015 ether, 0.001 ether, 100);
        vm.stopPrank();

        assertEq(uint160(r.hook) & 0x3fff, 0x1040);
        (, int24 tickA,,) = manager.getSlot0(keyA.toId());
        assertEq(r.tickA, tickA);
        assertEq(r.initSqrtPriceB, TickMath.getSqrtPriceAtTick(tickA));
        assertEq(r.ethPaid, 0.0015 ether);
        assertApproxEqRel(r.siphPaid, 0.0015 ether * 1e8, 2e15);
        assertEq(SiphonDataLogger(r.hook).poolCount(), 2);
        assertEq(SiphonDataLogger(r.hook).poolIds(0), cfg.poolAId);
        assertEq(SiphonDataLogger(r.hook).poolIds(1), r.poolBId);
        assertGt(r.swapOut, 0);
        assertEq(r.sA, SQRT_PRICE_A);
        assertEq(r.tA, tickA);
        (uint160 sB, int24 tB,,) = manager.getSlot0(PoolId.wrap(r.poolBId));
        assertEq(r.sB, sB);
        assertEq(r.tB, tB);
    }

    function test_initializePoolB_requiresPoolA() public {
        cfg.poolAId = keccak256("not a pool");
        (SiphonDataLogger hook,,) = stepDeploy(cfg);
        vm.expectRevert(PoolANotInitialized.selector);
        this.initPoolB(address(hook));
    }

    function test_initializePoolB_onlyOnce() public {
        (SiphonDataLogger hook,,) = deployed();
        vm.expectRevert(PoolBAlreadyInitialized.selector);
        this.initPoolB(address(hook));
    }

    function test_testSwap_failsWhenEventMissing() public {
        (SiphonDataLogger hook, SiphonPoolOperator operator, PoolKey memory keyB) = live();
        vm.prank(OWNER);
        hook.pause();
        vm.expectRevert(abi.encodeWithSelector(UnexpectedEvents.selector, 0, 1));
        this.runTestSwap(operator, keyB);
    }

    function initPoolB(address hook) external {
        stepInitializePoolB(cfg, hook);
    }

    function runTestSwap(SiphonPoolOperator operator, PoolKey memory keyB) external {
        vm.startPrank(OWNER);
        stepTestSwap(cfg, operator, keyB, 0.001 ether);
        vm.stopPrank();
    }
}
