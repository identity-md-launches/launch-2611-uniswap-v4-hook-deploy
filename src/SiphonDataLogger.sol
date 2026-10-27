// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HookFlags} from "./HookFlags.sol";

/// @title SiphonDataLogger
/// @notice A Uniswap v4 hook that, after every swap on a pool using it, emits one `PoolData` event per
/// configured pair of pools with both pools' current sqrtPriceX96 and tick. It never moves funds,
/// never returns a delta, and never makes a swap fail: an unset, paused or uninitialized pool list only
/// means nothing (or zeros) is logged.
/// @dev Port of the requester's source to the standard v4 PoolManager. Three changes, each required for
/// the hook to work against the standard PoolManager at all (see README "Deviations from the brief"):
/// 1. callbacks use the IHooks signatures and return IHooks selectors (the brief's 0x9290e989 and
///    0x93263c51 are not selectors PoolManager accepts);
/// 2. slot0 is read with `extsload` (StateLibrary), because PoolManager has no `getSlot0(bytes32)`
///    (0xc815641c is the StateView lens's selector; on PoolManager it reverts, which would revert every swap);
/// 3. the permission-bit check applies to the hook's own address, not to the owner's.
contract SiphonDataLogger {
    using StateLibrary for IPoolManager;

    error ZeroAddress();
    error BadHookAddress();
    error NotPoolManager();
    error NotOwner();
    error BadPoolIdCount();
    error ZeroPoolId();
    error DuplicatePoolId();

    /// @notice One pair (A = ids[2i], B = ids[2i+1]) read after a swap. `b` is the block number.
    event PoolData(uint256 indexed b, uint160 sA, int24 tA, uint160 sB, int24 tB);
    event PoolIdsSet(bytes32[] ids);
    event Paused(bool paused);

    IPoolManager public immutable poolManager;
    address public immutable owner;
    bool public paused;
    bytes32[] private p;

    constructor(IPoolManager m, address o) {
        if (address(m) == address(0) || o == address(0)) revert ZeroAddress();
        if (!HookFlags.matches(address(this), HookFlags.SIPHON)) revert BadHookAddress();
        poolManager = m;
        owner = o;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice The permission bits this hook's address must carry, as in the brief.
    function hookPermissions() external pure returns (bytes32) {
        return bytes32(uint256(HookFlags.SIPHON));
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory perms) {
        perms.afterInitialize = true;
        perms.afterSwap = true;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        uint256 n = p.length;
        if (!paused && n >= 2) {
            for (uint256 i = 0; i < n / 2; i++) {
                (uint160 sA, int24 tA) = _read(p[i * 2]);
                (uint160 sB, int24 tB) = _read(p[i * 2 + 1]);
                emit PoolData(block.number, sA, tA, sB, tB);
            }
        }
        return (IHooks.afterSwap.selector, int128(0));
    }

    /// @notice Replace the pool list. 2, 4, 6 or 8 non-zero, distinct ids, read in pairs (A, B).
    function setPoolIds(bytes32[] calldata ids) external onlyOwner {
        uint256 n = ids.length;
        if (n != 2 && n != 4 && n != 6 && n != 8) revert BadPoolIdCount();
        for (uint256 i = 0; i < n; i++) {
            if (ids[i] == bytes32(0)) revert ZeroPoolId();
            for (uint256 j = i + 1; j < n; j++) {
                if (ids[i] == ids[j]) revert DuplicatePoolId();
            }
        }
        delete p;
        for (uint256 i = 0; i < n; i++) {
            p.push(ids[i]);
        }
        emit PoolIdsSet(ids);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Paused(false);
    }

    function poolCount() external view returns (uint256) {
        return p.length;
    }

    function poolIds(uint256 i) external view returns (bytes32) {
        return p[i];
    }

    function _read(bytes32 id) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(PoolId.wrap(id));
    }
}
