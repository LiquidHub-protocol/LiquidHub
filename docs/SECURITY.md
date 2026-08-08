# Security Model

## Governance and emergency authority

In Phase 1, the Gnosis Safe multisig is the governance authority under the signer threshold configured directly
in that Safe. In Phase 2,
governance and ownership are transferred to the Governor-controlled Timelock. The Safe then remains only as
the fast emergency guardian for the explicitly retained pause, recovery and rescue functions.

**Capabilities:**

- **Phase 1 Safe:** owns and configures the Vault, Treasury, SecureBotModule, PauseController and DN hedge
  governance paths.
- **Phase 2 Timelock:** owns governance settings such as ranges, slippage, oracle addresses, Treasury routes,
  caps and keeper bounties.
- **Phase 2 Safe:** can trigger only the emergency actions retained in each contract. It cannot change strategy
  parameters. The bounded user-flow PauseController intentionally lets the emergency Safe both trigger and lift
  those pauses; governance retains parameter and ownership control.
- Treasury admin withdrawals are permanently disabled by the final Phase 2 lock (**irreversible**).

---

## SecureBotModule

The `SecureBotModule` is a Gnosis Safe module that whitelists specific function selectors, allowing a bot wallet to execute only pre-approved operations through the Safe.

**Whitelisted operations (high-level):**

- Operational module actions only: atomic queued-deposit processing, snapshots, cache refresh, and Treasury
  distribution/bridge calls when enabled.
- Both pool variants use the atomic public `RangeManager.rebalance(...)` entrypoint. Legacy multi-transaction
  primitives are excluded from the module core-selector set and cannot be re-enabled through `allowFunction()`.
- Refresh the price cache (`refreshPriceCache`, no address change) — oracle **addresses** themselves can only be
  set through the Vault governance relay (Safe in Phase 1, Timelock in Phase 2; never the module)
- Record price snapshots (dynamic-range ring buffer; bot fallback when no keeper acts)
- Delta-Neutral routine hedge adjustment uses the public `adjustHedge()` path; broad AAVE sweep/repay/withdraw
  operations are not part of the public keeper/module allowlist.
- Treasury bridging to stakers (Phase 2)

**Core selector set in the published contracts:**

| Selector | Function | Target / pools |
|---|---|---|
| `0x0be1c372` | `refreshPriceCache()` | RangeManager / standard + DN |
| `0x6ecfe0f8` | `recordPriceSnapshot()` | RangeManager / standard + DN |
| `0x76919a59` | `processDepositPermissionless(uint256[],uint256[],address,address)` | Vault / standard + DN |
| `0x0040718e` | `endRebalance()` | Vault unlock / standard + DN |
| `0x1e694f32` | `adjustHedge()` | AaveHedgeManager / DN only |
| `0xa5599124` | `bridgeToStakers(uint256)` | Treasury / standard + DN, Phase 2 |
| `0x56a12aca` | `distributeToStakers(uint256)` | Treasury / standard + DN, Phase 2 |

The execution entrypoint also restricts which target contract each selector can reach. `rebalance()`
(`0xed375437`) is intentionally absent: both pool variants expose it as a guarded permissionless RangeManager
function, so community keepers call it directly rather than through the Safe module.

**Blocked operations (cannot be called via the module):**

- Transfer / approve tokens
- Change ownership, upgrade, or manage the Safe
- Withdraw from Treasury (outside the bridge-to-stakers path)
- Any function not explicitly whitelisted

> **Live source of truth:** the deployed module's `isFunctionAllowed(bytes4)` result and verified bytecode are
> authoritative. The complete per-pool list is also published on the Contracts page:
> **https://liquidhub.app/docs#contracts-addresses** → section *"Bot Module Security — Whitelisted Function Selectors"*.
> Each selector can be verified on Arbiscan via the module's read-only `isFunctionAllowed(bytes4)` function.
> The table above matches the contracts in this repository; always verify it against the live address after a
> redeployment.

---

## Oracle & Price Integrity

Pricing is anchored to **Chainlink** (never the pool spot price for value-sensitive math), with multiple
independent layers so that a manipulated pool, a stale feed, or an L2 sequencer restart cannot be exploited.

### Chainlink-priced shares (anti share-inflation)
Deposit shares are computed on the **Chainlink oracle price**, not the Uniswap `slot0` spot price. An attacker
cannot mint a distorted share amount by manipulating the pool's instantaneous price.

### Pool-vs-oracle deviation guard
Before any value-sensitive action (mint, rebalance, swap, deposit processing, withdraw), the contracts compare
the **pool price (`slot0`)** against the **Chainlink oracle price**. If they diverge beyond a governance bound
(`MAX_ORACLE_DEVIATION_BPS`, current deployment target 50 bps / 0.5%), the price cache is invalidated and the action **reverts** (`"Oracle deviation"` / `"E38"`).
On the Delta-Neutral pool, `adjustHedge()` has an analogous guard (`MAX_HEDGE_DEVIATION_BPS`, `"LP price deviation"`)
so a manipulated LP price cannot trigger a wasteful borrow/repay.

### Spot-vs-TWAP guard
Sensitive LP actions also compare the current Uniswap spot tick against a 300-second TWAP. The governance-configured
guard (`TWAP_GUARD_ENABLED`, `MAX_TWAP_DEVIATION_BPS`, current target 50 bps) invalidates the price cache when the
spot price diverges too far from the warm TWAP. The bootstrap bypass is limited to the state where the pool has
only one initialized observation. From the second initialized observation onward, any failed `observe(300s)`
call is fail-closed, including during the remaining warm-up seconds. Deployment batches require a requested
observation cardinality of at least 512 while this guard is enabled.

### Per-feed staleness
Each Chainlink feed has its own maximum age (`MAX_AGE0` / `MAX_AGE1`, per-feed heartbeats). A price older than
its bound invalidates the cache and blocks sensitive actions, rather than acting on a stale price.

### L2 Sequencer check (Arbitrum)
All Chainlink feeds are read through a **`SequencerCheckedAggregator`** wrapper that follows the
[Chainlink L2 Sequencer Feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds) recommendation: it
**reverts** when the Arbitrum sequencer is down, or within the grace period (`ORACLE_GRACE_PERIOD`, default 1h)
after a restart — preventing the use of a price that may be stale during that window. The wrapper is a
transparent pass-through (same `decimals()`, same round tuple), is **immutable / stateless / view-only / holds
no funds**, and is verified on Arbiscan. Because the contracts simply read the oracle addresses, this protects
**every** price consumer (RangeManager, Treasury, AaveHedgeManager) with no change to those contracts.

### Oracle-bounded swaps (anti-MEV / anti-sandwich)
Rebalance and deposit swaps enforce an **on-chain `minAmountsOut` floor derived from the Chainlink price**
(`"minOut<floor"`). A keeper-supplied minimum below the oracle floor reverts. Public keepers may use any RPC;
their RPC choice cannot bypass the on-chain oracle, TWAP, exact-input and minimum-output checks.

### Fail-closed on price/fee dependencies
- If the AAVE hedge valuation (`getHedgeData`) reverts while a hedge manager is set, portfolio valuation
  **reverts** rather than under-valuing the denominator (which would mis-price shares).
- Fee crystallization (`collect()`) is **not** swallowed by a try/catch on the deposit/withdraw path: if it
  fails, the action reverts rather than minting on uncrystallized fees.

---

## Deposit / Withdrawal Protections

- **Anti same-block flash-loan**: a withdrawal in the same block as the user's deposit processing reverts
  (`E_SAME_BLOCK`), breaking the atomicity required by a deposit→withdraw exploit.
- **Fees crystallized before share math**: pending Uniswap fees are collected and attributed to existing holders
  *before* a new deposit computes its shares — a new depositor cannot capture other users' pre-deposit fees.
- **Proportional, delta-bounded withdrawals**: a withdrawal sends only the *delta* of the user's proportional
  principal (snapshot before/after), never the contract's whole balance — it cannot drain other users' pending
  deposits or capital.
- **No zero-share / zero-value mints** (`E_ZERO_SHARES`).

---

## Fee Accounting & Auto-compound

- **Auto-compound**: net LP fees (after the Treasury commission) stay on the RangeManager and are re-injected
  into the LP position on the next add-liquidity/rebalance — users' withdrawals return principal **plus**
  compounded fees, with no separate claim step.
- **O(1) fee distribution (`accFeePerShare`)**: fee accounting uses a monotonic per-share accumulator with lazy
  per-user settlement (MasterChef-style). There is **no unbounded loop** over all users on distribution, and the
  active-user registry is pruned on full withdrawal — eliminating gas-griefing / DoS vectors on the fee path.

---

## Failure Tracking

`RangeManager` emits and stores operation failure counters for monitoring, alerting and bot/keeper backoff.
These counters are informational and do **not** create a persistent on-chain breaker that blocks future
permissionless maintenance. Failed rebalances or hedge adjustments are retried by the bot/keepers on later cycles;
the contracts remain fail-closed through oracle, TWAP, min-out and range checks.

---

## Emergency controls

- **Targeted module pause**: `SecureBotModule.setPaused(true)` stops every privileged operation routed through
  that module, including module-routed maintenance. It does not pause the public, permissionless maintenance
  entrypoints (`rebalance()`, snapshots, deposit processing and, on DN pools, `adjustHedge()`), which remain
  protected by their on-chain guards and callable by bot/keepers. In Phase 2 the Safe can pause immediately,
  but only the Timelock owner can unpause. The Safe can also revoke/disable a compromised module.
- **PauseController**: controls user flows. Inflow pause blocks new deposit processing; withdrawal pause also
  blocks inflows. Position-maintenance actions remain available by design. In Phase 2 the Safe remains the
  pause guardian and can both trigger and lift these bounded user-flow pauses; Timelock governance retains
  parameter control and can also administer the controller.
- **Hedge pause** (DN): `AaveHedgeManager.setPaused(true)` blocks new hedge openings (`supplyAndBorrow`) but
  deliberately leaves risk-reduction and position-maintenance paths available. In Phase 2 the Safe can pause,
  while only Timelock governance can unpause.
- **ReentrancyGuard** on external fund-moving and sensitive maintenance paths of the Vault, RangeManager and
  HedgeManager. Pure/view functions and simple governance setters do not require this guard.

---

## Contract Permissions

### RangeManager

| Function | Access | Description |
|----------|--------|-------------|
| `rebalance()` | Public (permissionless) | Atomic burn → swaps → mint; protected by the refresh + deviation guard, oracle-bounded `minAmountsOut`, exact-input consumption checks, and the on-chain rebalance-needed condition |
| `executeSwap()` / `mintInitialPosition()` / `burnPosition()` | Restricted legacy primitives | Excluded from the `SecureBotModule`; production deposits use `processDepositPermissionless()` and rebalances use atomic `rebalance()` |
| `configurePriceFeeds()` / `setOracleParams()` | Vault owner relay | Governance settings via `MultiUserVault.executeRangeManagerGovernance(bytes)`: Safe in phase 1, Timelock in phase 2 |
| `refreshPriceCache()` | Public | Refreshes the price cache (no address change) |
| `configureRanges()` | Vault owner relay | Governance setting via Safe/Timelock relay, not the bot module |
| `setTreasuryAddress()` | Vault owner relay | Governance setting via Safe/Timelock relay |

### Treasury

| Function | Access | Description |
|----------|--------|-------------|
| `swapToUSDC()` | `onlyOwner` (Safe Phase 1 / Timelock Phase 2) | Converts configured ERC-20 tokens to USDC; the fee tier is fixed on-chain by the pool batch |
| `adminWithdraw()` | `onlyOwner` (Safe Phase 1 / Timelock Phase 2) | Monthly cap enforced until the irreversible final Phase 2 lock disables it |
| `payKeeperBounty()` | Authorized RangeManagers only | Called automatically after rebalance |
| `disableAdminWithdraw()` | `onlyOwner` | **IRREVERSIBLE** |
| `setBridgeConfig()` | `onlyOwner` | Configure cross-chain bridge |
| `setKeeperBounty()` | `onlyOwner` | Enable/disable bounty and set amount |

### MultiUserVault

| Function | Access | Description |
|----------|--------|-------------|
| `deposit()` / `withdraw()` | Public | Any user can deposit or withdraw |
| `startRebalance()` | `onlyBot` | Operational lock used by authorized callers |
| `endRebalance()` | Owner, module, RangeManager or emergency Safe | Clears the operational lock; moves no funds |
| `syncFeesForDeposits()` | Public, guarded | Crystallizes pending LP fees before queued-deposit share accounting when required |
| `updateTreasuryAddress()` | `onlyOwner` (Safe Phase 1 / Timelock Phase 2) | Update the Treasury address |

---

## User Fund Safety

The protocol is designed so that user funds are protected even if the keeper wallet or bot infrastructure is compromised:

- **User funds remain across the protocol contracts**: queued balances in the Vault, active liquidity in the
  RangeManager/DEX position, and DN collateral/debt in the HedgeManager/AAVE integration. They are never held by
  the bot wallet or another externally owned account.
- **The keeper cannot withdraw user funds** — it can only call public rebalance functions.
- **LP position NFTs are owned by the pool's RangeManager contract**, not by any individual or keeper.
- **Withdrawals go directly to the user's wallet** — there is no intermediary step where funds can be redirected.
- **No admin can redirect user withdrawals** — the withdrawal function sends tokens to `msg.sender`.
- **Governance changes** require the configured Safe approval threshold in Phase 1 and Governor/Timelock execution in Phase 2;
  the Safe then retains only the documented emergency guardian powers.
