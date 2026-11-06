# Scoped implementation review

Reviewed components: `src/TestToken.sol` and `src/TestHook.sol`, with the compiler
and dependencies pinned in the repository. This is an implementation review,
not a separate contributor's audit or a production deployment attestation.

| Concern | Design and verification |
| --- | --- |
| Privilege / upgrade | No inherited ownership, fallback, delegatecall, setters, pause, blacklist, mint entry point, or upgrade path. Curated admin calls from deployer, recipient and outsider are rejected. |
| Callback authenticity | Every exposed v4 callback checks the immutable manager. The quote subcall checks the hook's own address. Unauthorized calls are tested. |
| Cross-pool reuse | The complete PoolKey is hashed into an immutable pool ID at construction. Initialization and swap callbacks reject other keys. |
| Fee theft / redirection | Fee rate and recipient are constants. Caller and hook data do not enter accounting. Redemption accepts no recipient or currency argument. |
| Specified/unspecified deltas | Before-swap fees only modify specified IMD; after-swap fees only modify unspecified IMD. Tests cover both orderings, both directions, both amount modes. |
| Partial fills / rounding | Reverted quote subcalls establish actual IMD fills before choosing a specified delta. Tests compare the recipient's real balance increase with actual trader/core deltas. Fee division preserves the remainder before combining terms and rounds down. |
| Accounting conservation | Returned fee deltas exactly offset successful takes or claim mints. The driver asserts its returned deltas equal its transient debts before settlement, and in prepaid mode that one `settle()` credits exactly what was transferred. Invariants check closed unlocks and conservation over mixed actions in both settlement orders. |
| Fee-related denial of service | Failed manager takes revert their own accounting before claim minting. Failed redemptions preserve claims. Tested with recipient rejection and a fresh manager funded only with the launch token. |
| Caller settlement window | `settle()` credits balance minus synced reserves, so a take of IMD while a caller has IMD synced would under-credit that caller by the fee (revert or double charge). The hook reads the manager's synced currency and mints the claim instead when it is IMD. Tested with a driver that pays before the swap and settles once, for exact-input and exact-output buys, and in the invariant handler. |
| Reentrancy | No arbitrary target or recipient-controlled ETH call. External operations target only the immutable manager and fixed IMD currency. Quote state always rolls back. Redemption uses the manager's unlock lock; nested unlock cannot succeed. Fee payout relies on the verified IMD token's standard non-callback transfers. |
| Liquidity custody | No liquidity callbacks or custom accounting: zero-delta fee collection and full withdrawals remain available. |
| Rate permanence | No reads of time, blocks, hook data, sender identity or an oracle in fee calculation. Tests vary time, blocks and arbitrary hook data. |
| Supply and launch | Constructor mints exactly 1e27 to the deployer. No other mint or fee path. Factory allocation transfers preserve every unit. |
| Dependencies | Vendored sources and licenses, exact commits and archive SHA-256 hashes. No submodules, linked external libraries, compiler binary, FFI, or network dependency in default tests. |

Remaining boundaries:

- Only the designated pair, supplied canonical v4 manager, and specified pool
  are supported. The hook cannot protect against an intentionally malicious
  manager supplied at deployment or future externally imposed IMD restrictions.
- A specified-IMD trade simulates the pool computation once before its actual
  execution. This has higher gas cost than taxing the entire request; crossing
  many initialized ticks costs more, as it does in v4 itself.
- Fixed-width deltas and `amountSpecified + beforeSwapDelta` must be representable
  in v4's arithmetic. An exact-output sell above `MAX_EXACT_OUTPUT_SELL` reverts
  with the named `ExactOutputTooLarge` rather than v4's checked-addition panic;
  the fee is never clamped to make room, as that would make the top of the range
  fee-free. Every order at or below the bound fills and pays the fee.
- An IMD transfer fee, rebase, or malicious callback behavior is unsupported by
  the standard v4 pool settlement model; no arbitrary token support is claimed.
- The protocol-level recipient and LP fee controller are outside this hook's
  control. The hook returns no LP override and never calls `updateDynamicLPFee`.
- Fork tests exercise live IMD with a fresh local canonical manager. The actual
  launch factory, its remainder/distributor infrastructure and deployed manager
  remain the independent launch rehearsal's scope.
- No Slither run, formal verification, external audit, signing, deployment,
  production fund movement or explorer source publication was performed here.
