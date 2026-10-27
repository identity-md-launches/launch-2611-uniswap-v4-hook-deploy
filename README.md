# SiphonDataLogger: Uniswap v4 hook for Robinhood mainnet (4663)

This repository has the hook, a small owner-only liquidity and swap operator, and one Foundry
script that runs the brief's whole sequence. Every transaction is signed by the owner. It also has
tests, and the record of a full simulation against live chain-4663 state.

> **Status: built and simulated, not broadcast.** This assignment has no signing key and no authority
> to send transactions. The setPoolIds call has to come from the owner, and so do the funds for the LP
> deposit. So the owner runs the script with their own signer (step 4 below). Until then, the delivered
> transaction hash and decoded event are the values from the simulation, not on-chain receipts.

## Decisions on what the brief left open

| Open point | Decision | Why |
| --- | --- | --- |
| Who signs (the earlier attempt's question) | **Owner-executed workflow.** `script/DeploySiphon.s.sol` is run by the owner with `--sender 0x7351…EFF9` and their own signer (`--ledger`, `--trezor` or `--account <keystore>`). No key is in this repo and none was used. | Both setPoolIds and the LP deposit have to come from the owner, and a stand-in signer cannot do either. |
| The source's constructor checks the **owner's** address bits (`uint160(o)&0x3fff==0x1040`) | The check now applies to the **hook's own address** (`address(this)`). | The given owner masks to `0x2ff9`, so the constructor as written always reverts. The brief's requirement is "Hook addr must satisfy & 0x3fff == 0x1040". |
| "$5 ETH" | The ETH amount is an argument: `run(uint256 ethWei)`. The owner enters wei worth $5 at their own ETH/USD price. | The brief gives no USD price source. Pool A prices SIPH against ETH, not USD. Guessing is forbidden. |
| How the owner adds LP | Through `SiphonPoolOperator`, deployed by CREATE2 with the owner fixed at construction. Only the owner can add or remove liquidity, and withdrawals always go to the owner. | No v4 PositionManager address was given ("no lookup"). An EOA needs a contract with an unlock callback. |
| LP range | Full range (ticks ±887220, spacing 60). The ETH side is `ethWei`, and SIPH is the matching amount at Pool B's price. Unused SIPH is refunded, and the SIPH maximum has 1% headroom. | "Proportional SIPH" at one price. Full range is the simplest range to reason about. |

## Deviations from the supplied source (required for a standard PoolManager)

I checked the PoolManager at `0x8366a39C…0951` on 4663 against the source:

1. **`getSlot0` (0xc815641c) does not exist on PoolManager.** `cast call <PM> "getSlot0(bytes32)" <poolA>`
   reverts with empty data. That selector belongs to Uniswap's `StateView` lens. The standard
   PoolManager answers `extsload` instead. Slot `keccak256(poolId, 6)` for Pool A returns
   `0x0000000030d400000002cf980000000000002710000000000000000000000000`, which decodes to sqrtPriceX96
   `10000·2^96`, tick `184216` and lpFee `12500`. The source's `_r()` does `require(ok)` on that call,
   so **every swap on Pool B would revert once pool IDs were set.** The hook reads slot0 through
   v4-core's `StateLibrary` (`extsload`), the standard method, and never reverts on unknown pools: an
   uninitialized pool logs zeros.
2. **Callback signatures and selectors.** The source's `afterInitialize(bytes)` and its 7-argument
   `afterSwap` return `0x9290e989` and `0x93263c51`, and PoolManager accepts neither. With them,
   `initialize` and every swap revert (`InvalidHookResponse`). The hook implements the `IHooks`
   signatures and returns `IHooks.afterInitialize.selector` (0x6fe7e6eb) and
   `IHooks.afterSwap.selector` (0xb47b2fb1).
3. **The owner-bits check** (see above).

To be clear about "Red if PoolManager behaves non-standardly": the PoolManager *is* standard. Its
code is present, `extsload` works, and Pool A's slot0 is consistent. What did not match the standard
was the supplied hook source. I made the three fixes above, the minimum needed for it to work.
Everything else is kept: the `PoolData(uint256 indexed b, uint160 sA, int24 tA, uint160 sB, int24 tB)`
event, the pairing rule (ids `[2i]`, `[2i+1]`), the `setPoolIds` rules (2/4/6/8 distinct non-zero
ids), `pause`/`unpause`, `poolCount`, `poolIds`, `hookPermissions()` (returns `0x1040`), and the
immutable `poolManager`/`owner`. Additions: `getHookPermissions()`, custom errors, and `PoolIdsSet` and
`Paused` events.

## Deployment parameters (from the brief)

| Parameter | Value |
| --- | --- |
| Chain | Robinhood mainnet, 4663, `https://rpc.mainnet.chain.robinhood.com` |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Owner | `0x735121A546092F31050A867FD7E3A750C7B0EFF9` |
| SIPH | `0x60013a6F087CB84B3C28129Dac9a568e94d2b384` (symbol `SIPH`, 18 decimals, checked on chain) |
| Pool A id | `0x4ec8156257098665395fc6c8cc13c3943ffdb6ca1cacf8ff59957360d0e2d4d3` |
| Pool B key | currency0 = ETH (`address(0)`), currency1 = SIPH, fee 12500, tickSpacing 60, hooks = hook |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` (code present on 4663) |
| Compiler | solc 0.8.26, optimizer 1 run, CBOR metadata off, `evm_version = cancun` (`foundry.toml`) |

### Deterministic addresses (from `forge script script/DeploySiphon.s.sol --sig "predict()"`)

| | |
| --- | --- |
| Hook (SiphonDataLogger) | `0x3Ee9b9530A34359A8A38B0062b85dEA45DAc9040` (`& 0x3fff = 0x1040`), salt `0x…0158` |
| Operator (SiphonPoolOperator) | `0xae56C8CE1352E867eb625f00664161CCdd3266D7` |
| Pool B poolId | `0xc7919cbdbcdc289b68ad36e79b75a4d57485c2e7753a5d45e0f16d13cfed76ac` |

These addresses depend on the exact bytecode. The script mines the salt again at run time, so any
change to the source or the compiler settings gives new addresses. Always use the ones the script
prints.

## Sequence (`script/SiphonSteps.sol`, one function per step)

1. **Deploy.** `stepDeploy` mines the first salt whose CREATE2 address satisfies `& 0x3fff == 0x1040`,
   then deploys the hook `(PoolManager, Owner)` and the operator `(PoolManager, Owner)` through the
   CREATE2 deployer. If either is already deployed, it reuses it.
2. **Initialize Pool B.** `stepInitializePoolB` reads Pool A's current tick through `extsload` and
   calls `PoolManager.initialize(keyB, getSqrtPriceAtTick(tickA))`. It requires Pool A to be
   initialized, Pool B not to be, and the returned tick to equal tickA.
3. **Add LP.** `stepAddLiquidity`: the owner approves SIPH to the operator, then calls
   `operator.addLiquidity{value: ethWei}` for a full-range position. It refunds what is unused and
   checks that the pool's liquidity increased.
4. **setPoolIds([A, B])** from the owner. The step reads the list back to confirm it.
5. **Test swap.** `stepTestSwap` swaps 0.001 ETH for SIPH on Pool B through the operator. The
   minimum output is 99% of a quote computed from Pool B's state. The step then requires **exactly
   one** `PoolData` from the hook and **exactly one** PoolManager `Swap`. It also requires the event's
   `b`, `sA`, `tA`, `sB` and `tB` to equal `block.number` and the slot0 of A and of B after the swap.
   Otherwise it reverts.

### Running it (owner)

```sh
forge build
# 1. dry run against live state (no key needed):
forge script script/DeploySiphon.s.sol:DeploySiphon --sig "run(uint256)" <ethWei> \
  --rpc-url https://rpc.mainnet.chain.robinhood.com --sender 0x735121A546092F31050A867FD7E3A750C7B0EFF9
# 2. broadcast with the owner's signer (or --trezor / --account <keystore> instead of --ledger):
forge script script/DeploySiphon.s.sol:DeploySiphon --sig "run(uint256)" <ethWei> \
  --rpc-url https://rpc.mainnet.chain.robinhood.com --sender 0x735121A546092F31050A867FD7E3A750C7B0EFF9 \
  --ledger --broadcast --slow
```

`--slow` sends each transaction only after the previous one is mined. If any step fails, the script
reverts in simulation and nothing is broadcast.

### Simulation result (live state of chain 4663, block ≈ 26283639, `ethWei = 0.0015 ether`)

The full `run()` was executed without `--broadcast` from the owner address:

- Hook `0x3Ee9…9040`, operator `0xae56…66D7`, Pool B id `0xc791…76ac`.
- Pool A tick **184216**, so Pool B was initialized at `getSqrtPriceAtTick(184216)` =
  `792280926924313289846529216293289`.
- LP: liquidity `14999986780868554224`, **0.0015 ETH + 149,999.7356 SIPH** paid by the owner.
- Test swap: 0.001 ETH in, **59,547.63 SIPH** out.
- Exactly one `PoolData(b=26283639, sA=792281625142643375935439503360000, tA=184216,
  sB=477757342868932740153119853414591, tB=174099)`, and exactly one swap.
- 7 transactions (2 CREATE2 deploys, initialize, SIPH approve, addLiquidity, setPoolIds, swap), about 3.08M gas, estimated cost **0.000124 ETH** at a base fee of 0.020 gwei.
  Gas is not free on 4663, though it is cheap. At the time of the check the owner held 0.00892 ETH
  and 2e25 SIPH, which covers ethWei (≈ $5) + 0.001 ETH + gas.

**Price impact to expect:** with about $5 of liquidity, the 0.001 ETH test swap moves Pool B from
tick 184216 to about 174099, roughly a 64% lower SIPH-per-ETH price for Pool B. Pool A does not
move. This follows from the brief's sizes and is not a fault. Pool B stays thin until more
liquidity is added.

### Confirming on chain after broadcast

```sh
R=https://rpc.mainnet.chain.robinhood.com
cast receipt <swapTx> --rpc-url $R          # one log from the hook with topic0:
cast keccak "PoolData(uint256,uint160,int24,uint160,int24)"
cast decode-abi --input "f(uint160,int24,uint160,int24)" <log data>   # sA, tA, sB, tB; topic1 = block
cast call <hook> "poolCount()(uint256)" --rpc-url $R                    # 2
cast call <hook> "poolIds(uint256)(bytes32)" 1 --rpc-url $R             # Pool B id
```

The receipt of the `addLiquidity` transaction carries the operator's `LiquidityModified` event and the
PoolManager's `ModifyLiquidity` event. That is the LP confirmation. Do not scan with `eth_getLogs`:
the RPC rate-limits it. The receipts and `eth_call` are enough.

## After launch

Nothing has to be set for the hook to work. The owner's settings:

| Setting | Function | Value |
| --- | --- | --- |
| Pools logged | `setPoolIds(bytes32[])` on the hook | `[PoolA, PoolB]`, set by step 4. Later, up to 4 pairs, distinct and non-zero. Each call replaces the whole list. |
| Logging on/off | `pause()` / `unpause()` | Only stops or starts `PoolData`. Swaps are never blocked. |
| Owner's LP | `operator.removeLiquidity(key, -887220, 887220, liquidity)` | Proceeds go to the owner. `liquidity = 0` collects fees only. |

## Contracts

### `src/SiphonDataLogger.sol`
Hook configuration, in the Wizard's canonical shape: `{"hook":"BaseHook","name":"SiphonDataLogger",
"pausable":true (own flag; only stops logging),"currencySettler":false,"safeCast":false,
"transientStorage":false,"shares":{"options":false},"permissions":{ all false except "afterInitialize":
true, "afterSwap": true },"access":"ownable" (immutable owner, constructor argument),"info":{"license":"MIT"}}`.
It inherits nothing (no v4-periphery). PoolManager calls callbacks by selector.

- Both callbacks require `msg.sender == poolManager`. `afterSwap` returns a zero delta, and the
  address does not carry `AFTER_SWAP_RETURNS_DELTA`, so the hook cannot move value. It holds no funds
  and makes no external call other than `extsload` on PoolManager.
- Gas: at most 8 `extsload` calls and 4 events per swap on any pool that uses this hook.
- Anyone may initialize other pools with this hook. Swaps on those pools also emit the configured
  pairs' data. That is harmless, but a `PoolData` event is not proof that a swap happened on Pool B.
  The swap's own pool is the PoolManager `Swap` event in the same transaction.

### `src/SiphonPoolOperator.sol`
This is the owner's LP holder and an exact-input router. Funds come only from `msg.sender`: ETH as
`msg.value`, which must equal the maximum, and ERC-20 through `transferFrom(msg.sender, …)`. Funds are
settled in `unlockCallback`, which only PoolManager may call. Unused input is refunded in the same
call, and the contract keeps no balance. There is a reentrancy lock, `minAmountOut` on swaps, and
`max0`/`max1` on adds.

### Trust assumptions and responsibilities
- The owner has full control of the logger's pool list and pause switch, and of the LP position
  (through the operator). The owner is immutable on both contracts. There is no transfer function, so
  if the owner key is lost, the LP position is lost too.
- The owner signs and pays for all transactions, chooses `ethWei`, and runs the dry run before
  broadcasting.
- PoolManager is trusted to be the canonical v4 deployment named in the brief.
- Tests are not an audit. The operator holds the owner's position, so an independent review should
  happen before it holds meaningful value.

## Tests

```sh
forge build && forge test && forge fmt --check
```

- `test/SiphonDataLogger.t.sol`: constructor (zero addresses; address without flags or with extra
  flags; the owner's 0x2ff9 bits are accepted), permissions and v4-core address validation, and
  callbacks refusing non-PoolManager callers while returning IHooks selectors. Also: `setPoolIds`
  access control, counts, zero and duplicate ids, replacement, and a fuzz test; pause access; one
  `PoolData` per pair with the exact post-swap payload; no event when unset or paused; uninitialized
  ids log zeros without blocking; and both swap directions through a third-party router.
- `test/SiphonPoolOperator.t.sol`: owner-only add and remove, value and max checks, proportional
  amounts and refunds, fee collection, `minAmountOut`, pulls from the caller only, and fuzzed
  fund conservation.
- `test/DeploySiphon.t.sol`: the script's constants equal the brief's, the predicted address carries
  0x1040, salt mining is deterministic, wrong chain and wrong sender are refused, the **full five-step
  sequence** runs on a local PoolManager whose Pool A is at the live price, and the guards hold
  (Pool A must exist, Pool B is initialized only once, and a missing event fails the test swap).
- `test/mocks`, `test/floor`: helpers used by the network's protected hook floor. I ran that floor
  locally against this hook's creation code, with PoolManager built at `0x8366…0951`, and it passes
  (permissions, no escape hatch, callback access, factory initialization, fee collection, owner).

Dependencies are vendored as plain files under `lib/`: forge-std, Uniswap v4-core `src/`,
OpenZeppelin Contracts v5.1.0 `contracts/` (only used by the floor tests), and solmate's `Owned.sol`.
The pinned commits are in `lib/*.REV`.
