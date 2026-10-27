// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Shared owner checks for the launch floor: a launched contract is owned neither by the
/// factory that deployed it nor by the launch wallet (`tx.origin` at deployment).
abstract contract OwnerChecks is Test {
    /// @dev Stand-in for IMD's launch wallet, used as `tx.origin` when the hook is deployed.
    address internal constant ORIGIN_PROBE = address(0x0819140000000000000000000000000000000001);

    function checkOwner(string memory name, address target, address factory) internal view {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || ret.length < 32) return; // nothing to own
        address owner = abi.decode(ret, (address));
        assertTrue(owner != factory, string.concat(name, " is owned by the launch factory"));
        assertTrue(owner != ORIGIN_PROBE, string.concat(name, " is owned by the launch wallet (tx.origin)"));
    }
}
