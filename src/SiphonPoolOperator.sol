// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @title SiphonPoolOperator
/// @notice The owner's liquidity position holder and a minimal exact-input swap router for v4 pools.
/// Only the owner may add or remove liquidity; the position is held by this contract and every
/// withdrawal goes to the owner. Anyone may swap through it with their own funds.
/// @dev Funds are pulled from `msg.sender` only (ETH by `msg.value`, ERC-20 by `transferFrom(msg.sender)`),
/// settled to the PoolManager from this contract's balance inside `unlockCallback`, and anything
/// unused is refunded in the same call. The contract holds nothing between calls.
contract SiphonPoolOperator is IUnlockCallback {
    error ZeroAddress();
    error NotOwner();
    error NotPoolManager();
    error Reentrant();
    error BadValue();
    error TransferFromFailed();
    error TooLittleReceived(uint256 amountOut, uint256 minAmountOut);
    error ExceedsMax(uint256 paid0, uint256 paid1);

    event LiquidityModified(
        PoolId indexed id, int24 tickLower, int24 tickUpper, int256 liquidityDelta, int128 amount0, int128 amount1
    );
    event Swapped(PoolId indexed id, address indexed swapper, bool zeroForOne, uint256 amountIn, uint256 amountOut);

    uint8 private constant MODIFY = 0;
    uint8 private constant SWAP = 1;

    IPoolManager public immutable poolManager;
    address public immutable owner;

    uint256 private locked = 1;

    constructor(IPoolManager manager_, address owner_) {
        if (address(manager_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        poolManager = manager_;
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (locked != 1) revert Reentrant();
        locked = 2;
        _;
        locked = 1;
    }

    /// @notice Add `liquidity` to the owner's position in [tickLower, tickUpper), paying at most
    /// `max0`/`max1`. A native currency is paid by `msg.value`, which must equal its max. Unused funds
    /// are refunded to the owner.
    function addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 max0,
        uint256 max1
    ) external payable onlyOwner nonReentrant returns (uint256 paid0, uint256 paid1) {
        _checkValue(key, max0, max1);
        _pull(key.currency0, max0);
        _pull(key.currency1, max1);
        BalanceDelta delta = _modify(key, tickLower, tickUpper, int256(uint256(liquidity)));
        paid0 = _negative(delta.amount0());
        paid1 = _negative(delta.amount1());
        if (paid0 > max0 || paid1 > max1) revert ExceedsMax(paid0, paid1);
        _send(key.currency0, msg.sender, max0 - paid0);
        _send(key.currency1, msg.sender, max1 - paid1);
    }

    /// @notice Remove `liquidity` from the owner's position (0 collects fees only); proceeds go to the owner.
    function removeLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        onlyOwner
        nonReentrant
        returns (BalanceDelta delta)
    {
        delta = _modify(key, tickLower, tickUpper, -int256(uint256(liquidity)));
    }

    /// @notice Exact-input swap of the caller's `amountIn`, output to the caller. Reverts if the output
    /// is below `minAmountOut`. `sqrtPriceLimitX96 == 0` means no limit. Input left unused because the
    /// limit was reached is refunded.
    function swapExactIn(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        uint160 sqrtPriceLimitX96
    ) external payable nonReentrant returns (uint256 amountOut) {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        if (input.isAddressZero() ? msg.value != amountIn : msg.value != 0) revert BadValue();
        _pull(input, amountIn);
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        BalanceDelta delta =
            abi.decode(poolManager.unlock(abi.encode(SWAP, abi.encode(key, params, msg.sender))), (BalanceDelta));
        uint256 spent = _negative(zeroForOne ? delta.amount0() : delta.amount1());
        amountOut = uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));
        if (amountOut < minAmountOut) revert TooLittleReceived(amountOut, minAmountOut);
        _send(input, msg.sender, amountIn - spent);
        emit Swapped(key.toId(), msg.sender, zeroForOne, spent, amountOut);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 action, bytes memory inner) = abi.decode(data, (uint8, bytes));
        BalanceDelta delta;
        PoolKey memory key;
        address recipient;
        if (action == MODIFY) {
            ModifyLiquidityParams memory params;
            (key, params) = abi.decode(inner, (PoolKey, ModifyLiquidityParams));
            (delta,) = poolManager.modifyLiquidity(key, params, "");
            recipient = owner;
        } else {
            SwapParams memory params;
            (key, params, recipient) = abi.decode(inner, (PoolKey, SwapParams, address));
            delta = poolManager.swap(key, params, "");
        }
        _settleOrTake(key.currency0, delta.amount0(), recipient);
        _settleOrTake(key.currency1, delta.amount1(), recipient);
        return abi.encode(delta);
    }

    function _modify(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        private
        returns (BalanceDelta delta)
    {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
        });
        delta = abi.decode(poolManager.unlock(abi.encode(MODIFY, abi.encode(key, params))), (BalanceDelta));
        emit LiquidityModified(key.toId(), tickLower, tickUpper, liquidityDelta, delta.amount0(), delta.amount1());
    }

    function _settleOrTake(Currency currency, int128 amount, address recipient) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                poolManager.settle{value: owed}();
            } else {
                poolManager.sync(currency);
                currency.transfer(address(poolManager), owed);
                poolManager.settle();
            }
        } else if (amount > 0) {
            poolManager.take(currency, recipient, uint256(uint128(amount)));
        }
    }

    function _checkValue(PoolKey memory key, uint256 max0, uint256 max1) private view {
        uint256 expected = key.currency0.isAddressZero() ? max0 : 0;
        if (key.currency1.isAddressZero()) expected += max1;
        if (msg.value != expected) revert BadValue();
    }

    /// @dev ERC-20 from the caller only; a native currency already arrived as msg.value.
    function _pull(Currency currency, uint256 amount) private {
        if (amount == 0 || currency.isAddressZero()) return;
        (bool ok, bytes memory ret) = Currency.unwrap(currency)
            .call(abi.encodeCall(IERC20Minimal.transferFrom, (msg.sender, address(this), amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFromFailed();
    }

    function _send(Currency currency, address to, uint256 amount) private {
        if (amount != 0) currency.transfer(to, amount);
    }

    function _negative(int128 amount) private pure returns (uint256) {
        return amount < 0 ? uint256(uint128(-amount)) : 0;
    }
}
