# SIMD TEST - DO NOT BUY (SIMDTEST)

**This is a test token. It has no value and must not be bought.**

Logo metadata: https://www.si-md.xyz/logo.jpg

This Foundry project delivers the two launch contracts: `TestToken` and `TestHook`.
There is no owner, administrator, setter, proxy, pause, blacklist, mint function,
anti-sniper charge, clock, or block-dependent rule in either contract. The hook
never converts its fee to ETH. It does not deploy any other contract.

## Deployment parameters

| Item | Fixed value / launch-supplied argument |
| --- | --- |
| Chain | Robinhood Chain, 4663 |
| Token name / symbol | `SIMD TEST - DO NOT BUY` / `SIMDTEST` |
| `TestToken` constructor | No arguments |
| Token supply / decimals | `1000000000000000000000000000` / 18 |
| Initial token holder | The factory that deploys `TestToken` (`msg.sender`) |
| `TestHook` constructor | `(IPoolManager poolManager_, address token_)` |
| `poolManager_` | `$poolManager`, supplied by the launch deployer |
| `token_` | `$token`, the just-deployed `TestToken` |
| Paired currency | IMD, `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` |
| Hook fee | 75 basis points (0.75%) of the filled gross IMD amount |
| Fee recipient | `0xdFA1f1F6FEAA04F7874efF0b7754b7FFaEBd8BC0` |
| Pool LP fee | `12500` millionths (1.25%) |
| Tick spacing | 60 |
| Required hook address bits | `(uint160(hook) & 0x3fff) == 0x20cc` (8396) |

Deploy the token first. Encode the hook's two constructor arguments and mine a
CREATE2 salt for the **actual deploying factory** and the complete creation code.
The address is the last 20 bytes of
`keccak256(0xff ++ factory ++ salt ++ keccak256(creationCode ++ abi.encode(poolManager, token)))`.
The constructor validates the address bits, rejects zero arguments and IMD as the
launch token, and makes no external calls. It can therefore be simulated on an
empty chain. All library calls are internal; neither creation artifact needs
linking. The tests exercise actual CREATE2 deployment at the required bits.

Sort the two token addresses numerically for the `PoolKey`; set the above fee,
spacing, and hook. The immutable `poolId` binds the hook to exactly this key.
The factory initializes and seeds this pool in its launch transaction. The hook
accepts the factory without granting it any ongoing authority. Initialization
of another token pair, fee, or spacing is rejected.

The launch's nominal `pool.initialPrice` is `79228162514264337593543950336`.
The factory derives the actual opening price from the policy's 2,500 IMD opening
market capitalization and token ordering. The hook accepts that price; it does
not force a 1:1 pool. Local tests use 1:1 solely for a convenient fixture.

The factory, not either contract here, allocates the supply: 10% to its launch
MerkleDistributor, 26.69% to liquidity, and 63.31% to the supplied remainder
destination `0x4F375B772F0668282F0d1AAe573Fcb601EA04772`. The brief's claim/remainder
infrastructure belongs to that launch allocation step. This repository does not
create another claim contract or reserve tokens for the hook. No `launch.json`
is provided; the later manifest step supplies it. The fee recipient is only a
recipient and has no control over either contract.

## Fee accounting

All amounts are integer IMD minor units. With `r = 75`, `D = 10000`:

- **Buy:** if the trader spends gross IMD `G`, the hook gets
  `floor(G*r/D)` and the remainder is the pool's IMD input, including its LP fee.
- **Sell:** if the pool outputs gross IMD `G`, the hook gets
  `floor(G*r/D)` and the trader receives the remainder.

| Swap mode | Fee accounting |
| --- | --- |
| Exact-input buy | Reserve a fee within the input budget; charge only the filled gross IMD input |
| Exact-output buy | Add `floor(A*75/9925)` to the actual pool IMD input `A`, preserving the requested SIMDTEST output |
| Exact-input sell | Deduct `floor(G*75/10000)` from actual gross IMD output |
| Exact-output sell | Request gross output `N + floor(N*75/9925)` so the trader receives requested net IMD `N` on a full fill |

Thus both buys and sells use the same 0.75% gross-IMD rate, with rounding down
to whole minor units. Sub-134-wei gross amounts can have a zero fee. Full fills
respect exact-input budgets and exact-output delivery. Partial fills charge the
filled amount; unfilled quantities are not taxed.

The 1.25% LP rate plus the 0.75% hook rate is **2% nominal**. They are assessed
sequentially, on different bases: for example an exact-input buy pays 0.75% of
its gross IMD to the hook and 1.25% of the remaining 99.25% as the pool fee,
an effective 1.990625% before price impact and integer rounding. The hook does
not override the LP fee or adjust the requested 0.75% rate to manufacture an
exact 2% debit. Router quotes must include both fees and price impact.

### Callbacks and partial fills

Enabled permissions are `beforeInitialize`, `beforeSwap`, `afterSwap`,
`beforeSwapReturnDelta`, and `afterSwapReturnDelta`. The initialization callback
also prevents use of the predicted pool before the hook has code. Every callback
requires the immutable PoolManager. No liquidity or donation hooks are enabled,
so the factory can collect LP fees with a zero liquidity change and withdraw
liquidity without a hook fee or permission gate.

v4 only lets `afterSwap` adjust the **unspecified** currency. When IMD is the
specified currency, `beforeSwap` therefore simulates the fee-adjusted swap in a
self-call that **always reverts**, returning the actual filled deltas in a custom
error. All simulated pool changes, transfers, protocol accounting and events
roll back. v4 skips the hook for its own inner swap, avoiding recursion. The
actual outer swap proceeds normally, with only the appropriate IMD fee delta.
This avoids charging a full requested fee when liquidity or a price limit stops
the trade. The quote entry point requires `msg.sender == address(this)` and cannot
be used by an outside trader to bypass the fee. Specified-IMD trades execute the
pool calculation twice; this is an intentional gas cost for partial-fill accuracy.

No user identity, router allowlist, timestamp, block number, external oracle, or
`hookData` enters the fee calculation. The `sender` and `hookData` cannot select
another recipient or rate.

### Payout failures

Normally the PoolManager transfers IMD directly to the fixed recipient within
the swap. The hook never needs to receive IMD itself. Input settlement can occur
after the callback, so a manager seeded with SIMDTEST only might not yet have
enough IMD for the fee. A token-level restriction might also reject the payout.

If `take` fails, the hook instead mints an **IMD-denominated ERC-6909 claim on the
same PoolManager**, held by the hook exclusively for the same recipient. The fee
is still charged and fully accounted for; its wallet delivery is deferred. This
path does not deploy a helper or convert to ETH. `FeeCharged(amount, deferred)`
identifies which path occurred.

Anyone can call `redeemFees()` outside an existing manager unlock. It burns
available claims and transfers IMD only to the fixed recipient; it has no address
argument. Redemption is capped by manager token availability and v4's signed
delta limit. A failed transfer reverts redemption atomically, leaving the claim
intact. `FeesRedeemed` records successful delivery. No one can redirect, seize,
or change the denomination of pending fees.

## Build and tests

Solidity **0.8.26**, Cancun EVM, optimizer 200 runs, metadata bytecode hash `none`.
All dependencies are ordinary vendored source files under `lib/`; exact commits
and archive hashes are recorded in `dependencies.lock.json`, with upstream
licenses retained. No installation, network, FFI, filesystem permission, or
environment variable is required by the contracts or offline tests.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x88c525739d5cda97c5391be726bb7a4eb3938ccbb5924d57ded94b46769db829 forge test
forge fmt --check
```

Local tests use the vendored, unmodified v4 PoolManager with both token orderings.
They cover all four swap modes, tiny trades, partial fills, absent liquidity,
failed input settlement, restricted payouts, empty-manager funding, deferred
claim redemption, unauthorized callbacks, attempted admin/redirection calls,
time independence, factory fee collection and LP withdrawal. Fuzz tests run
1,000 cases each. The final offline run passed 38 tests, with the fork suite
explicitly skipped. The stateful invariant handler mixes trades, payout failure
and redemption; it checks fee and token conservation, fixed supply, fixed
recipient/rate, and zero outstanding transient manager deltas.

The fork suite is explicitly skipped when no fork is selected, keeping normal
`forge test` usable offline. It never silently treats missing RPC as a passed
fork test. To run it against the documented public source:

```sh
FOUNDRY_FUZZ_SEED=0x88c525739d5cda97c5391be726bb7a4eb3938ccbb5924d57ded94b46769db829 \
  forge test --match-contract RobinhoodForkTest \
  --fork-url https://rpc.mainnet.chain.robinhood.com \
  --fork-block-number 107794459 -vv
```

The recorded fork at block **107794459**, hash
`0xba32a1708ef2a683be75e9960ad04e80c48e7dbe2f7b31e472ec7c663d59bccf`, passed all
16 tests including two 1,000-case fuzz tests. IMD's deployed code, symbol `IMD`
and 18 decimals were checked on that chain. Test balances are assigned with
Foundry cheats; IMD code is not replaced on the fork. The fork deploys a fresh
canonical v4 PoolManager and the proposed launch contracts locally. It does not
broadcast or claim to rehearse an unspecified deployed factory/router.

## After launch

There are **no settings to configure** and no owner responsibilities. The launch
operator supplies the real PoolManager and token, mines the hook address,
initializes and funds the correct pool, and performs the allocations. It should
verify the deployed runtime and immutable parameters and use routers that quote
hook deltas correctly. Users' swap price limits and normal router slippage
checks still apply.

Anyone may monitor deferred fees with
`poolManager.balanceOf(hook, uint256(uint160(IMD)))` and call `redeemFees()` when
IMD is available and transferable. No keeper has authority over funds. Pending
claims cannot be rescued to a different address if the recipient permanently
loses the ability to receive IMD. Unsolicited ERC-20 transfers to the hook have
no rescue function; do not send tokens there directly.

The no-swap-blocking property means there are no hook trading gates and payout
failure cannot veto a valid, funded v4 trade. Core invalid-price/amount errors,
insufficient trader funds, token restrictions affecting actual trade settlement,
out-of-gas, and v4's signed arithmetic limits can still revert a transaction.
IMD itself is an external dependency; this hook cannot remove powers or transfer
restrictions in that token or the PoolManager. The deployer must verify the
supplied manager implements the pinned v4 interfaces and supports Cancun.

The implementation and adversarial tests have been reviewed locally; they are
not an independent security audit. The separate launch review and manifest
steps remain the launch system's responsibility. See [REVIEW.md](REVIEW.md) for
the scoped review and limits.

Protocol references: [v4 hook accounting](https://github.com/Uniswap/v4-core/blob/bea7f6d1c11cd5dc4f0d5151ffa37a1c239feee6/src/libraries/Hooks.sol),
[PoolManager settlement](https://github.com/Uniswap/v4-core/blob/bea7f6d1c11cd5dc4f0d5151ffa37a1c239feee6/src/PoolManager.sol).
