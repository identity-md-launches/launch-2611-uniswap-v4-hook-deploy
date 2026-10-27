// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SiphonSteps, SiphonConfig, SiphonResult} from "./SiphonSteps.sol";

/// @notice Runs the brief's sequence on Robinhood mainnet (4663), every transaction signed by the owner.
/// @dev Usage (the owner chooses the signer; this repository holds no key):
///   forge script script/DeploySiphon.s.sol:DeploySiphon --sig "run(uint256)" <ethWei> \
///     --rpc-url https://rpc.mainnet.chain.robinhood.com --sender 0x735121A546092F31050A867FD7E3A750C7B0EFF9 \
///     --ledger | --trezor | --account <keystore>   [--broadcast]
/// Without --broadcast it is a full simulation against live state, which is the dry run to do first.
contract DeploySiphon is Script, SiphonSteps {
    uint256 internal constant CHAIN_ID = 4663;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant OWNER = 0x735121A546092F31050A867FD7E3A750C7B0EFF9;
    address internal constant SIPH = 0x60013a6F087CB84B3C28129Dac9a568e94d2b384;
    bytes32 internal constant POOL_A_ID = 0x4ec8156257098665395fc6c8cc13c3943ffdb6ca1cacf8ff59957360d0e2d4d3;
    uint24 internal constant FEE = 12_500;
    int24 internal constant TICK_SPACING = 60;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 internal constant SWAP_WEI = 0.001 ether;
    uint256 internal constant SIPH_SLIPPAGE_BPS = 100;

    function config() public pure returns (SiphonConfig memory) {
        return SiphonConfig({
            manager: POOL_MANAGER,
            owner: OWNER,
            siph: SIPH,
            poolAId: POOL_A_ID,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            create2Deployer: CREATE2_DEPLOYER
        });
    }

    /// @param ethWei The ETH side of the liquidity: the owner's "$5 of ETH" in wei at their ETH/USD price.
    function run(uint256 ethWei) external returns (SiphonResult memory r) {
        require(block.chainid == CHAIN_ID, "not Robinhood mainnet (4663)");
        require(msg.sender == OWNER, "run with --sender set to the owner");
        require(ethWei > 0, "ethWei");
        vm.startBroadcast(OWNER);
        r = runSequence(config(), ethWei, SWAP_WEI, SIPH_SLIPPAGE_BPS);
        vm.stopBroadcast();

        console2.log("hook", r.hook);
        console2.log("hook salt");
        console2.logBytes32(r.hookSalt);
        console2.log("operator (holds the owner's LP position)", r.operator);
        console2.log("pool B id");
        console2.logBytes32(r.poolBId);
        console2.log("pool A tick / pool B initial tick");
        console2.logInt(r.tickA);
        console2.log("LP liquidity", uint256(r.liquidity));
        console2.log("LP ETH paid (wei)", r.ethPaid);
        console2.log("LP SIPH paid (wei)", r.siphPaid);
        console2.log("test swap SIPH out (wei)", r.swapOut);
        console2.log("PoolData block", r.eventBlock);
        console2.log("PoolData sA", uint256(r.sA));
        console2.logInt(r.tA);
        console2.log("PoolData sB", uint256(r.sB));
        console2.logInt(r.tB);
    }

    /// @notice Read-only: the hook address and Pool B id this configuration produces.
    function predict() external pure returns (address hook, bytes32 salt, address operator, bytes32 poolBId) {
        SiphonConfig memory cfg = config();
        (salt, hook) = mineHookSalt(cfg);
        operator = create2Address(cfg.create2Deployer, OPERATOR_SALT, operatorInitCode(cfg));
        poolBId = keccak256(abi.encode(poolBKey(cfg, hook)));
    }
}
