// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SiphonDataLogger} from "../src/SiphonDataLogger.sol";
import {SiphonPoolOperator} from "../src/SiphonPoolOperator.sol";
import {SiphonFixture} from "./SiphonFixture.sol";

contract SiphonPoolOperatorTest is SiphonFixture {
    using StateLibrary for IPoolManager;

    int24 constant LO = -887220;
    int24 constant HI = 887220;

    function test_constructor_rejectsZero() public {
        vm.expectRevert(SiphonPoolOperator.ZeroAddress.selector);
        new SiphonPoolOperator(IPoolManager(address(0)), OWNER);
        vm.expectRevert(SiphonPoolOperator.ZeroAddress.selector);
        new SiphonPoolOperator(manager, address(0));
    }

    function test_addLiquidity_onlyOwner() public {
        (, SiphonPoolOperator operator, PoolKey memory keyB) = deployed();
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(SiphonPoolOperator.NotOwner.selector);
        operator.addLiquidity{value: 1 ether}(keyB, LO, HI, 1e18, 1 ether, 1e27);
    }

    function test_addLiquidity_valueMustMatchMax() public {
        (, SiphonPoolOperator operator, PoolKey memory keyB) = deployed();
        vm.prank(OWNER);
        vm.expectRevert(SiphonPoolOperator.BadValue.selector);
        operator.addLiquidity{value: 0.5 ether}(keyB, LO, HI, 1e18, 1 ether, 1e27);
    }

    function test_addLiquidity_proportionalAndRefunds() public {
        (, SiphonPoolOperator operator, PoolKey memory keyB) = deployed();
        uint256 ethBefore = OWNER.balance;
        uint256 siphBefore = siph.balanceOf(OWNER);
        vm.startPrank(OWNER);
        (uint128 liquidity, uint256 ethPaid, uint256 siphPaid) = stepAddLiquidity(cfg, operator, keyB, 1 ether, 100);
        vm.stopPrank();
        assertEq(manager.getLiquidity(keyB.toId()), liquidity);
        assertLe(ethPaid, 1 ether);
        assertApproxEqRel(ethPaid, 1 ether, 1e12);
        // Pool A's price: 1 ETH = 1e8 SIPH (tick-rounded), so ~1e8 SIPH per ETH paid.
        assertApproxEqRel(siphPaid, ethPaid * 1e8, 1e15);
        assertEq(ethBefore - OWNER.balance, ethPaid, "unused ETH refunded");
        assertEq(siphBefore - siph.balanceOf(OWNER), siphPaid, "unused SIPH refunded");
        assertEq(address(operator).balance, 0);
        assertEq(siph.balanceOf(address(operator)), 0);
    }

    function test_addLiquidity_revertsWhenMaxTooLow() public {
        (, SiphonPoolOperator operator, PoolKey memory keyB) = deployed();
        vm.startPrank(OWNER);
        LiquidityPlan memory plan = planLiquidity(cfg, keyB, 1 ether, 0);
        siph.approve(address(operator), plan.siphNeeded / 2);
        vm.expectRevert();
        operator.addLiquidity{value: 1 ether}(keyB, LO, HI, plan.liquidity, 1 ether, plan.siphNeeded / 2);
        vm.stopPrank();
    }

    function test_removeLiquidity_onlyOwnerAndPaysOwner() public {
        (, SiphonPoolOperator operator, PoolKey memory keyB) = live();
        uint128 liquidity = manager.getLiquidity(keyB.toId());

        vm.expectRevert(SiphonPoolOperator.NotOwner.selector);
        operator.removeLiquidity(keyB, LO, HI, liquidity);

        uint256 ethBefore = OWNER.balance;
        uint256 siphBefore = siph.balanceOf(OWNER);
        vm.prank(OWNER);
        operator.removeLiquidity(keyB, LO, HI, liquidity);
        assertEq(manager.getLiquidity(keyB.toId()), 0);
        assertApproxEqRel(OWNER.balance - ethBefore, 1 ether, 1e12);
        assertGt(siph.balanceOf(OWNER) - siphBefore, 0);
    }

    function test_collectFees_zeroLiquidity() public {
        (, SiphonPoolOperator operator, PoolKey memory keyB) = live();
        address trader = makeAddr("trader");
        vm.deal(trader, 0.1 ether);
        vm.prank(trader);
        operator.swapExactIn{value: 0.1 ether}(keyB, true, 0.1 ether, 0, 0);
        uint256 ethBefore = OWNER.balance;
        vm.prank(OWNER);
        operator.removeLiquidity(keyB, LO, HI, 0);
        // 1.25% of 0.1 ETH, less rounding.
        assertApproxEqAbs(OWNER.balance - ethBefore, 0.00125 ether, 1e6);
    }

    function test_swap_valueAndMinOut() public {
        (, SiphonPoolOperator operator, PoolKey memory keyB) = live();
        address trader = makeAddr("trader");
        vm.deal(trader, 1 ether);

        vm.prank(trader);
        vm.expectRevert(SiphonPoolOperator.BadValue.selector);
        operator.swapExactIn{value: 0.5 ether}(keyB, true, 0.001 ether, 0, 0);

        uint256 quote = quoteZeroForOne(cfg, keyB, 0.001 ether);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(SiphonPoolOperator.TooLittleReceived.selector, quote, quote + 1));
        operator.swapExactIn{value: 0.001 ether}(keyB, true, 0.001 ether, quote + 1, 0);

        vm.prank(trader);
        uint256 out = operator.swapExactIn{value: 0.001 ether}(keyB, true, 0.001 ether, quote, 0);
        assertEq(out, quote, "quote matches the pool");
        assertEq(siph.balanceOf(trader), out);
        assertEq(trader.balance, 1 ether - 0.001 ether);
    }

    function test_swap_sellSiphPullsFromCallerOnly() public {
        (, SiphonPoolOperator operator, PoolKey memory keyB) = live();
        address trader = makeAddr("trader");
        require(siph.transfer(trader, 1e23));
        vm.prank(trader);
        vm.expectRevert(SiphonPoolOperator.TransferFromFailed.selector);
        operator.swapExactIn(keyB, false, 1e23, 0, 0); // no approval

        vm.deal(trader, 1);
        vm.startPrank(trader);
        siph.approve(address(operator), 1e23);
        vm.expectRevert(SiphonPoolOperator.BadValue.selector);
        operator.swapExactIn{value: 1}(keyB, false, 1e23, 0, 0);
        vm.deal(trader, 0);
        uint256 out = operator.swapExactIn(keyB, false, 1e23, 0, 0);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(trader.balance, out);
        assertEq(siph.balanceOf(trader), 0);
    }

    function test_unlockCallback_onlyPoolManager() public {
        (, SiphonPoolOperator operator,) = deployed();
        vm.expectRevert(SiphonPoolOperator.NotPoolManager.selector);
        operator.unlockCallback("");
    }

    function testFuzz_swap_conservesFunds(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e6, 0.5 ether);
        (, SiphonPoolOperator operator, PoolKey memory keyB) = live();
        address trader = makeAddr("trader");
        vm.deal(trader, amountIn);
        uint256 managerSiph = siph.balanceOf(address(manager));
        vm.prank(trader);
        uint256 out = operator.swapExactIn{value: amountIn}(keyB, true, amountIn, 0, 0);
        assertEq(siph.balanceOf(trader), out);
        assertEq(managerSiph - siph.balanceOf(address(manager)), out);
        assertEq(trader.balance, 0);
        assertEq(address(operator).balance, 0);
    }
}
