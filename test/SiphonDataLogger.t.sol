// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SiphonDataLogger} from "../src/SiphonDataLogger.sol";
import {SiphonPoolOperator} from "../src/SiphonPoolOperator.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {SiphonFixture} from "./SiphonFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";

contract SiphonDataLoggerTest is SiphonFixture {
    using StateLibrary for IPoolManager;

    event PoolData(uint256 indexed b, uint160 sA, int24 tA, uint160 sB, int24 tB);

    address constant FLAG_ADDRESS = address((uint160(0xC0FFEE) << 136) | 0x1040);

    // ------------------------------------------------------------ construction

    function test_constructor_acceptsOwnerWhoseBitsDoNotMatch() public {
        // The brief's owner masks to 0x2ff9; the hook address is what must carry 0x1040.
        assertEq(uint160(OWNER) & 0x3fff, 0x2ff9);
        deployCodeTo("SiphonDataLogger.sol:SiphonDataLogger", abi.encode(manager, OWNER), FLAG_ADDRESS);
        SiphonDataLogger hook = SiphonDataLogger(FLAG_ADDRESS);
        assertEq(hook.owner(), OWNER);
        assertEq(address(hook.poolManager()), address(manager));
        assertFalse(hook.paused());
        assertEq(hook.poolCount(), 0);
    }

    function test_constructor_revertsAtAddressWithoutFlags() public {
        vm.expectRevert(SiphonDataLogger.BadHookAddress.selector);
        new SiphonDataLogger(manager, OWNER);
    }

    function test_constructor_revertsAtAddressWithExtraFlags() public {
        address extra = address((uint160(0xC0FFEE) << 136) | 0x1041);
        vm.expectRevert(SiphonDataLogger.BadHookAddress.selector);
        deployCodeTo("SiphonDataLogger.sol:SiphonDataLogger", abi.encode(manager, OWNER), extra);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(SiphonDataLogger.ZeroAddress.selector);
        deployCodeTo("SiphonDataLogger.sol:SiphonDataLogger", abi.encode(address(0), OWNER), FLAG_ADDRESS);
        vm.expectRevert(SiphonDataLogger.ZeroAddress.selector);
        deployCodeTo("SiphonDataLogger.sol:SiphonDataLogger", abi.encode(manager, address(0)), FLAG_ADDRESS);
    }

    function test_permissions() public {
        (SiphonDataLogger hook,,) = deployed();
        assertEq(hook.hookPermissions(), bytes32(uint256(0x1040)));
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize && p.afterSwap);
        assertFalse(p.beforeInitialize || p.beforeSwap || p.beforeAddLiquidity || p.beforeRemoveLiquidity);
        assertFalse(p.afterSwapReturnDelta || p.beforeSwapReturnDelta || p.afterAddLiquidityReturnDelta);
        assertEq(uint160(address(hook)) & 0x3fff, 0x1040);
        // v4-core agrees the address is a valid hook for these permissions.
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
    }

    // ------------------------------------------------------------ callbacks

    function test_callbacks_refuseNonPoolManager() public {
        (SiphonDataLogger hook,, PoolKey memory keyB) = deployed();
        vm.expectRevert(SiphonDataLogger.NotPoolManager.selector);
        hook.afterInitialize(address(this), keyB, SQRT_PRICE_A, 0);
        vm.expectRevert(SiphonDataLogger.NotPoolManager.selector);
        hook.afterSwap(address(this), keyB, SwapParams(true, -1, 0), BalanceDelta.wrap(0), "");
    }

    function test_callbacks_returnIHooksSelectors() public {
        (SiphonDataLogger hook,, PoolKey memory keyB) = deployed();
        vm.startPrank(address(manager));
        assertEq(hook.afterInitialize(address(this), keyB, SQRT_PRICE_A, 0), IHooks.afterInitialize.selector);
        (bytes4 sel, int128 delta) =
            hook.afterSwap(address(this), keyB, SwapParams(true, -1, 0), BalanceDelta.wrap(0), "");
        vm.stopPrank();
        assertEq(sel, IHooks.afterSwap.selector);
        assertEq(delta, 0);
    }

    // ------------------------------------------------------------ setPoolIds / pause

    function _ids(uint256 n) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = keccak256(abi.encode(i));
        }
    }

    function test_setPoolIds_onlyOwner() public {
        (SiphonDataLogger hook,,) = deployed();
        vm.expectRevert(SiphonDataLogger.NotOwner.selector);
        hook.setPoolIds(_ids(2));
    }

    function test_setPoolIds_acceptsEvenCountsUpToEight() public {
        (SiphonDataLogger hook,,) = deployed();
        for (uint256 n = 2; n <= 8; n += 2) {
            vm.prank(OWNER);
            hook.setPoolIds(_ids(n));
            assertEq(hook.poolCount(), n);
            assertEq(hook.poolIds(n - 1), keccak256(abi.encode(n - 1)));
        }
        // Replacing shrinks the list.
        vm.prank(OWNER);
        hook.setPoolIds(_ids(2));
        assertEq(hook.poolCount(), 2);
        vm.expectRevert();
        hook.poolIds(2);
    }

    function test_setPoolIds_rejectsBadCounts() public {
        (SiphonDataLogger hook,,) = deployed();
        uint256[5] memory bad = [uint256(0), 1, 3, 7, 10];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(OWNER);
            vm.expectRevert(SiphonDataLogger.BadPoolIdCount.selector);
            hook.setPoolIds(_ids(bad[i]));
        }
    }

    function test_setPoolIds_rejectsZeroAndDuplicates() public {
        (SiphonDataLogger hook,,) = deployed();
        bytes32[] memory ids = _ids(4);
        ids[3] = bytes32(0);
        vm.prank(OWNER);
        vm.expectRevert(SiphonDataLogger.ZeroPoolId.selector);
        hook.setPoolIds(ids);

        ids = _ids(4);
        ids[3] = ids[0];
        vm.prank(OWNER);
        vm.expectRevert(SiphonDataLogger.DuplicatePoolId.selector);
        hook.setPoolIds(ids);
    }

    function testFuzz_setPoolIds_validation(uint8 n, uint256 seed, bool duplicate) public {
        n = uint8(bound(n, 0, 12));
        (SiphonDataLogger hook,,) = deployed();
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = keccak256(abi.encode(seed, i));
        }
        bool badCount = n == 0 || n % 2 == 1 || n > 8;
        if (duplicate && n >= 2) ids[n - 1] = ids[0];
        vm.prank(OWNER);
        if (badCount) {
            vm.expectRevert(SiphonDataLogger.BadPoolIdCount.selector);
        } else if (duplicate) {
            vm.expectRevert(SiphonDataLogger.DuplicatePoolId.selector);
        }
        hook.setPoolIds(ids);
        if (!badCount && !duplicate) assertEq(hook.poolCount(), n);
    }

    function test_pause_onlyOwner() public {
        (SiphonDataLogger hook,,) = deployed();
        vm.expectRevert(SiphonDataLogger.NotOwner.selector);
        hook.pause();
        vm.expectRevert(SiphonDataLogger.NotOwner.selector);
        hook.unpause();
        vm.prank(OWNER);
        hook.pause();
        assertTrue(hook.paused());
        vm.prank(OWNER);
        hook.unpause();
        assertFalse(hook.paused());
    }

    // ------------------------------------------------------------ swaps

    function _swapAndCount(SiphonPoolOperator operator, PoolKey memory key, uint256 amountIn, address hook)
        internal
        returns (uint256 events)
    {
        address trader = makeAddr("trader");
        vm.deal(trader, amountIn);
        vm.recordLogs();
        vm.prank(trader);
        operator.swapExactIn{value: amountIn}(key, true, amountIn, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == hook && logs[i].topics[0] == POOL_DATA_TOPIC) events++;
        }
    }

    function test_swap_emitsOnePoolDataWithPostSwapSlot0() public {
        (SiphonDataLogger hook, SiphonPoolOperator operator, PoolKey memory keyB) = live();
        vm.deal(OWNER, 1 ether);
        vm.startPrank(OWNER);
        (uint256 out, PoolDataEvent memory ev) = stepTestSwap(cfg, operator, keyB, 0.001 ether);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(ev.b, block.number);
        (uint160 sA, int24 tA,,) = manager.getSlot0(keyA.toId());
        (uint160 sB, int24 tB,,) = manager.getSlot0(keyB.toId());
        assertEq(ev.sA, sA);
        assertEq(ev.tA, tA);
        assertEq(ev.sB, sB);
        assertEq(ev.tB, tB);
        assertEq(ev.sA, SQRT_PRICE_A, "pool A untouched by the swap on B");
        assertLt(ev.tB, tA, "selling ETH lowers pool B's tick");
        assertEq(address(hook).balance, 0);
    }

    function test_swap_exactEventPayload() public {
        (SiphonDataLogger hook, SiphonPoolOperator operator, PoolKey memory keyB) = live();
        // Predict pool B's post-swap state by running the swap on a snapshot.
        uint256 snap = vm.snapshotState();
        _swapAndCount(operator, keyB, 0.001 ether, address(hook));
        (uint160 sB, int24 tB,,) = manager.getSlot0(keyB.toId());
        vm.revertToState(snap);
        (uint160 sA, int24 tA,,) = manager.getSlot0(keyA.toId());

        address trader = makeAddr("trader");
        vm.deal(trader, 0.001 ether);
        vm.expectEmit(true, true, true, true, address(hook));
        emit PoolData(block.number, sA, tA, sB, tB);
        vm.prank(trader);
        operator.swapExactIn{value: 0.001 ether}(keyB, true, 0.001 ether, 0, 0);
    }

    function test_swap_noEventsWhenUnsetOrPaused() public {
        (SiphonDataLogger hook, SiphonPoolOperator operator, PoolKey memory keyB) = deployed();
        vm.startPrank(OWNER);
        stepAddLiquidity(cfg, operator, keyB, 1 ether, 100);
        vm.stopPrank();
        assertEq(_swapAndCount(operator, keyB, 0.001 ether, address(hook)), 0, "unset");

        vm.startPrank(OWNER);
        stepSetPoolIds(cfg, hook, PoolId.unwrap(keyB.toId()));
        hook.pause();
        vm.stopPrank();
        assertEq(_swapAndCount(operator, keyB, 0.001 ether, address(hook)), 0, "paused");

        vm.prank(OWNER);
        hook.unpause();
        assertEq(_swapAndCount(operator, keyB, 0.001 ether, address(hook)), 1, "unpaused");
    }

    function test_swap_onePoolDataPerPair() public {
        (SiphonDataLogger hook, SiphonPoolOperator operator, PoolKey memory keyB) = live();
        bytes32[] memory ids = new bytes32[](8);
        for (uint256 i = 0; i < 4; i++) {
            ids[2 * i] = PoolId.unwrap(keyA.toId());
            ids[2 * i + 1] = keccak256(abi.encode("never initialized", i));
        }
        ids[2] = keccak256("another");
        ids[4] = keccak256("another2");
        ids[6] = keccak256("another3");
        vm.prank(OWNER);
        hook.setPoolIds(ids);
        assertEq(_swapAndCount(operator, keyB, 0.001 ether, address(hook)), 4);
    }

    function test_swap_uninitializedPoolIdsLogZerosAndNeverBlock() public {
        (SiphonDataLogger hook, SiphonPoolOperator operator, PoolKey memory keyB) = live();
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("unknown A");
        ids[1] = keccak256("unknown B");
        vm.prank(OWNER);
        hook.setPoolIds(ids);
        address trader = makeAddr("trader");
        vm.deal(trader, 0.001 ether);
        vm.expectEmit(true, true, true, true, address(hook));
        emit PoolData(block.number, 0, 0, 0, 0);
        vm.prank(trader);
        operator.swapExactIn{value: 0.001 ether}(keyB, true, 0.001 ether, 0, 0);
    }

    function test_swap_bothDirectionsWithAnyRouter() public {
        (SiphonDataLogger hook,, PoolKey memory keyB) = live();
        Swapper trader = new Swapper(manager);
        vm.deal(address(trader), 1 ether);
        require(siph.transfer(address(trader), 1e24));
        vm.recordLogs();
        trader.swap(keyB, true, 0.01 ether);
        trader.swap(keyB, false, 1e23);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 events;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == POOL_DATA_TOPIC) events++;
        }
        assertEq(events, 2);
    }

    function test_initialize_otherPoolsOnTheHookWork() public {
        (SiphonDataLogger hook,,) = deployed();
        MockERC20 other = new MockERC20("O", "O", 0);
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(other)), 3000, 60, IHooks(address(hook)));
        manager.initialize(k, SQRT_PRICE_A);
        (uint160 s,,,) = manager.getSlot0(k.toId());
        assertEq(s, SQRT_PRICE_A);
    }
}
