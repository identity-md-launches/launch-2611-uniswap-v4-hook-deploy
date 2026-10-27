// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SiphonDataLogger} from "../src/SiphonDataLogger.sol";
import {SiphonPoolOperator} from "../src/SiphonPoolOperator.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Everything the deployment needs, as values. The script fills it with the brief's constants;
/// tests fill it with a local PoolManager and token.
struct SiphonConfig {
    IPoolManager manager;
    address owner;
    address siph;
    bytes32 poolAId;
    uint24 fee;
    int24 tickSpacing;
    /// @dev The deterministic CREATE2 deployer (0x4e59…956C) both contracts are deployed through.
    address create2Deployer;
}

/// @notice What the sequence produced, for the operator's report.
struct SiphonResult {
    address hook;
    bytes32 hookSalt;
    address operator;
    bytes32 poolBId;
    int24 tickA;
    uint160 initSqrtPriceB;
    uint128 liquidity;
    uint256 ethPaid;
    uint256 siphPaid;
    uint256 swapOut;
    uint256 eventBlock;
    uint160 sA;
    int24 tA;
    uint160 sB;
    int24 tB;
}

/// @notice The brief's sequence, one function per step, so the script and the tests run the same code.
/// Each external call made here is one transaction when the script broadcasts it from the owner.
abstract contract SiphonSteps is CommonBase {
    using StateLibrary for IPoolManager;

    error PoolANotInitialized();
    error PoolBAlreadyInitialized();
    error PoolBPriceMismatch(uint160 expected, uint160 actual);
    error NoSalt();
    error Create2Failed();
    error UnexpectedEvents(uint256 poolData, uint256 swaps);
    error EventMismatch();

    bytes32 internal constant OPERATOR_SALT = keccak256("SiphonPoolOperator");
    uint256 internal constant SALT_SEARCH = 1_000_000;
    bytes32 internal constant POOL_DATA_TOPIC = keccak256("PoolData(uint256,uint160,int24,uint160,int24)");
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    // ---------------------------------------------------------------- addresses

    function hookInitCode(SiphonConfig memory cfg) public pure returns (bytes memory) {
        return abi.encodePacked(type(SiphonDataLogger).creationCode, abi.encode(cfg.manager, cfg.owner));
    }

    function operatorInitCode(SiphonConfig memory cfg) public pure returns (bytes memory) {
        return abi.encodePacked(type(SiphonPoolOperator).creationCode, abi.encode(cfg.manager, cfg.owner));
    }

    function create2Address(address deployer, bytes32 salt, bytes memory initCode) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(initCode))))));
    }

    /// @notice The first salt whose CREATE2 address has low 14 bits exactly 0x1040.
    function mineHookSalt(SiphonConfig memory cfg) public pure returns (bytes32 salt, address hook) {
        bytes32 codeHash = keccak256(hookInitCode(cfg));
        for (uint256 i = 0; i < SALT_SEARCH; i++) {
            salt = bytes32(i);
            hook = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), cfg.create2Deployer, salt, codeHash))))
            );
            if (HookFlags.matches(hook, HookFlags.SIPHON)) return (salt, hook);
        }
        revert NoSalt();
    }

    function poolBKey(SiphonConfig memory cfg, address hook) public pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(cfg.siph),
            fee: cfg.fee,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(hook)
        });
    }

    // ---------------------------------------------------------------- step 1: deploy

    /// @notice Deploys the hook at its mined address (or reuses it if already there) and the operator.
    function stepDeploy(SiphonConfig memory cfg)
        internal
        returns (SiphonDataLogger hook, bytes32 salt, SiphonPoolOperator operator)
    {
        address predicted;
        (salt, predicted) = mineHookSalt(cfg);
        hook = SiphonDataLogger(_create2(cfg.create2Deployer, salt, hookInitCode(cfg), predicted));
        operator = SiphonPoolOperator(
            payable(_create2(
                    cfg.create2Deployer,
                    OPERATOR_SALT,
                    operatorInitCode(cfg),
                    create2Address(cfg.create2Deployer, OPERATOR_SALT, operatorInitCode(cfg))
                ))
        );
        require(address(hook.poolManager()) == address(cfg.manager) && hook.owner() == cfg.owner, "hook config");
        require(address(operator.poolManager()) == address(cfg.manager) && operator.owner() == cfg.owner, "op config");
    }

    // ---------------------------------------------------------------- step 2: initialize Pool B

    /// @notice Initializes Pool B at the sqrt price of Pool A's current tick.
    function stepInitializePoolB(SiphonConfig memory cfg, address hook)
        internal
        returns (PoolKey memory key, int24 tickA, uint160 sqrtPriceB)
    {
        uint160 sqrtA;
        (sqrtA, tickA,,) = cfg.manager.getSlot0(PoolId.wrap(cfg.poolAId));
        if (sqrtA == 0) revert PoolANotInitialized();
        key = poolBKey(cfg, hook);
        (uint160 existing,,,) = cfg.manager.getSlot0(key.toId());
        if (existing != 0) revert PoolBAlreadyInitialized();
        sqrtPriceB = TickMath.getSqrtPriceAtTick(tickA);
        int24 tickB = cfg.manager.initialize(key, sqrtPriceB);
        require(tickB == tickA, "pool B tick != pool A tick");
    }

    // ---------------------------------------------------------------- step 3: liquidity

    /// @notice Full-range liquidity worth `ethWei` of ETH at Pool B's current price.
    function fullRangeLiquidityForEth(uint160 sqrtPriceX96, int24 tickSpacing, uint256 ethWei)
        public
        pure
        returns (uint128 liquidity, int24 tickLower, int24 tickUpper)
    {
        tickLower = TickMath.minUsableTick(tickSpacing);
        tickUpper = TickMath.maxUsableTick(tickSpacing);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 l = FullMath.mulDiv(
            FullMath.mulDiv(ethWei, sqrtPriceX96, FixedPoint96.Q96), sqrtUpper, sqrtUpper - sqrtPriceX96
        );
        // One unit below, so rounding up in the pool never asks for more than `ethWei`.
        liquidity = uint128(l > 0 ? l - 1 : 0);
    }

    /// @notice Owner adds ~`ethWei` ETH and the proportional SIPH, full range, through the operator.
    /// @param maxSiphSlippageBps Head-room on the SIPH maximum; unused SIPH is refunded.
    function stepAddLiquidity(
        SiphonConfig memory cfg,
        SiphonPoolOperator operator,
        PoolKey memory key,
        uint256 ethWei,
        uint256 maxSiphSlippageBps
    ) internal returns (uint128 liquidity, uint256 ethPaid, uint256 siphPaid) {
        LiquidityPlan memory plan = planLiquidity(cfg, key, ethWei, maxSiphSlippageBps);
        liquidity = plan.liquidity;
        require(IERC20Minimal(cfg.siph).approve(address(operator), plan.maxSiph), "approve");
        (ethPaid, siphPaid) =
            operator.addLiquidity{value: ethWei}(key, plan.tickLower, plan.tickUpper, liquidity, ethWei, plan.maxSiph);
        require(cfg.manager.getLiquidity(key.toId()) >= liquidity, "liquidity not in pool");
    }

    struct LiquidityPlan {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 siphNeeded;
        uint256 maxSiph;
    }

    /// @notice The full-range position for `ethWei` at Pool B's current price, and the SIPH it needs.
    function planLiquidity(SiphonConfig memory cfg, PoolKey memory key, uint256 ethWei, uint256 maxSiphSlippageBps)
        public
        view
        returns (LiquidityPlan memory plan)
    {
        (uint160 sqrtP,,,) = cfg.manager.getSlot0(key.toId());
        (plan.liquidity, plan.tickLower, plan.tickUpper) = fullRangeLiquidityForEth(sqrtP, key.tickSpacing, ethWei);
        plan.siphNeeded =
            SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(plan.tickLower), sqrtP, plan.liquidity, true);
        plan.maxSiph = plan.siphNeeded + (plan.siphNeeded * maxSiphSlippageBps) / 10_000;
    }

    // ---------------------------------------------------------------- step 4: pool ids

    function stepSetPoolIds(SiphonConfig memory cfg, SiphonDataLogger hook, bytes32 poolBId) internal {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = cfg.poolAId;
        ids[1] = poolBId;
        hook.setPoolIds(ids);
        require(hook.poolCount() == 2 && hook.poolIds(0) == cfg.poolAId && hook.poolIds(1) == poolBId, "ids");
    }

    // ---------------------------------------------------------------- step 5: test swap

    /// @notice Expected exact-input zeroForOne output on a pool whose liquidity is in range across the move.
    function quoteZeroForOne(SiphonConfig memory cfg, PoolKey memory key, uint256 amountIn)
        public
        view
        returns (uint256)
    {
        (uint160 sqrtP,,,) = cfg.manager.getSlot0(key.toId());
        uint128 liquidity = cfg.manager.getLiquidity(key.toId());
        uint256 afterFee = (amountIn * (1_000_000 - key.fee)) / 1_000_000;
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtP, liquidity, afterFee, true);
        return SqrtPriceMath.getAmount1Delta(next, sqrtP, liquidity, false);
    }

    struct PoolDataEvent {
        uint256 b;
        uint160 sA;
        int24 tA;
        uint160 sB;
        int24 tB;
    }

    /// @notice Swaps `amountIn` ETH for SIPH on Pool B and checks the hook emitted exactly one PoolData
    /// whose values equal Pool A's and Pool B's slot0 after the swap, and that exactly one swap ran.
    function stepTestSwap(SiphonConfig memory cfg, SiphonPoolOperator operator, PoolKey memory key, uint256 amountIn)
        internal
        returns (uint256 amountOut, PoolDataEvent memory ev)
    {
        uint256 minOut = (quoteZeroForOne(cfg, key, amountIn) * 99) / 100;
        vm.recordLogs();
        amountOut = operator.swapExactIn{value: amountIn}(key, true, amountIn, minOut, 0);
        ev = _onePoolData(cfg, address(key.hooks), vm.getRecordedLogs());
        _checkAgainstSlot0(cfg, key, ev);
    }

    function _onePoolData(SiphonConfig memory cfg, address hook, Vm.Log[] memory logs)
        private
        pure
        returns (PoolDataEvent memory ev)
    {
        uint256 dataEvents;
        uint256 swaps;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == hook && logs[i].topics[0] == POOL_DATA_TOPIC) {
                dataEvents++;
                ev.b = uint256(logs[i].topics[1]);
                (ev.sA, ev.tA, ev.sB, ev.tB) = abi.decode(logs[i].data, (uint160, int24, uint160, int24));
            }
            if (logs[i].emitter == address(cfg.manager) && logs[i].topics[0] == SWAP_TOPIC) swaps++;
        }
        if (dataEvents != 1 || swaps != 1) revert UnexpectedEvents(dataEvents, swaps);
    }

    function _checkAgainstSlot0(SiphonConfig memory cfg, PoolKey memory key, PoolDataEvent memory ev) private view {
        (uint160 nowA, int24 nowTA,,) = cfg.manager.getSlot0(PoolId.wrap(cfg.poolAId));
        (uint160 nowB, int24 nowTB,,) = cfg.manager.getSlot0(key.toId());
        if (ev.b != block.number || ev.sA != nowA || ev.tA != nowTA || ev.sB != nowB || ev.tB != nowTB) {
            revert EventMismatch();
        }
    }

    // ---------------------------------------------------------------- whole sequence

    function runSequence(SiphonConfig memory cfg, uint256 ethWei, uint256 swapWei, uint256 maxSiphSlippageBps)
        internal
        returns (SiphonResult memory r)
    {
        (SiphonDataLogger hook, bytes32 salt, SiphonPoolOperator operator) = stepDeploy(cfg);
        r.hook = address(hook);
        r.hookSalt = salt;
        r.operator = address(operator);

        PoolKey memory key;
        (key, r.tickA, r.initSqrtPriceB) = stepInitializePoolB(cfg, address(hook));
        r.poolBId = PoolId.unwrap(key.toId());

        (r.liquidity, r.ethPaid, r.siphPaid) = stepAddLiquidity(cfg, operator, key, ethWei, maxSiphSlippageBps);
        stepSetPoolIds(cfg, hook, r.poolBId);
        PoolDataEvent memory ev;
        (r.swapOut, ev) = stepTestSwap(cfg, operator, key, swapWei);
        (r.eventBlock, r.sA, r.tA, r.sB, r.tB) = (ev.b, ev.sA, ev.tA, ev.sB, ev.tB);
    }

    function _create2(address deployer, bytes32 salt, bytes memory initCode, address predicted)
        private
        returns (address)
    {
        if (predicted.code.length > 0) return predicted;
        (bool ok,) = deployer.call(abi.encodePacked(salt, initCode));
        if (!ok || predicted.code.length == 0) revert Create2Failed();
        return predicted;
    }
}
