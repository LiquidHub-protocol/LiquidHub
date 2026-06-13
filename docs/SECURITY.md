# Security Model

## Gnosis Safe Multisig (2/3)

The Gnosis Safe multisig is the root authority for all Liquid Hub contracts. It requires 2-of-3 signers for any transaction.

**Capabilities:**

- Controls all admin functions on all contracts
- Owner of `Treasury` and `MultiUserVault`
- Holds the "Authorized" role on `RangeManager`
- Can configure ranges, slippage tolerances, and oracle addresses
- Can enable/disable keeper bounty
- Can set the monthly withdrawal cap on Treasury
- Can permanently disable admin withdrawals (**irreversible**)

---

## SecureBotModule

The `SecureBotModule` is a Gnosis Safe module that whitelists specific function selectors, allowing a bot wallet to execute only pre-approved operations through the Safe.

**Whitelisted operations (high-level):**

- Rebalance steps: burn position, execute swap, mint position, add liquidity
- Process a single queued deposit
- Configure ranges, slippage, tolerance, protections, dynamic-range toggle
- Refresh the price cache (`refreshPriceCache`, no address change) — oracle **addresses** themselves can only be
  set by the Safe (`configurePriceFeeds` / `setOracleParams` are Safe-only, not in the module)
- Record price snapshots (dynamic-range ring buffer; bot fallback when no keeper acts)
- Delta-Neutral hedge management (AAVE supply/borrow/repay/withdraw, sweeps) — DN pool module only
- Treasury bridging to stakers (Phase 2)

**Blocked operations (cannot be called via the module):**

- Transfer / approve tokens
- Change ownership, upgrade, or manage the Safe
- Withdraw from Treasury (outside the bridge-to-stakers path)
- Any function not explicitly whitelisted

> **Exhaustive, always-up-to-date list:** the complete per-pool list of whitelisted function selectors
> (with their `bytes4` values) is published on the Contracts page:
> **http://liquidhub.app/docs#contracts-addresses** → section *"Bot Module Security — Whitelisted Function Selectors"*.
> Each selector can be verified on Arbiscan via the module's read-only `isFunctionAllowed(bytes4)` function.
> This document stays intentionally high-level so it never drifts out of sync with the deployed modules.

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
(`MAX_ORACLE_DEVIATION_BPS`, default 5%), the price cache is invalidated and the action **reverts** (`"Oracle deviation"` / `"E38"`).
On the Delta-Neutral pool, `adjustHedge()` has an analogous guard (`MAX_HEDGE_DEVIATION_BPS`, `"LP price deviation"`)
so a manipulated LP price cannot trigger a wasteful borrow/repay.

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
(`"minOut<floor"`). A keeper-supplied minimum below the oracle floor reverts, so internal swaps cannot be
sandwiched. The premium RPC additionally provides MEV-protected (private) transaction submission.

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

## Failure Protection (circuit breaker)

`RangeManager` tracks consecutive operation failures. After `MAX_CONSECUTIVE_FAILURES` (5), sensitive operations
are blocked until a `FAILURE_COOLDOWN` (30 min) elapses, preventing a stuck/looping keeper from repeatedly
forcing failing actions.

---

## Emergency controls

- **Module kill-switch**: `SecureBotModule.setPaused(true)` (Safe-only) freezes **all** permissionless bot
  actions (mint / rebalance / swap / snapshot / permissionless deposit processing).
- **Hedge pause** (DN): `AaveHedgeManager.setPaused(true)` (Safe-only) freezes hedge operations.
- **ReentrancyGuard** on all state-changing entry points of the vault, RangeManager and hedge manager.

---

## Contract Permissions

### RangeManager

| Function | Access | Description |
|----------|--------|-------------|
| `rebalance()` | Public (permissionless) | Atomic burn → swaps → mint; protected by the refresh + deviation guard, oracle-bounded `minAmountsOut`, and `needsRebalance` check |
| `executeSwap()` | `onlyAuthorized` | Safe/module/RM only; refreshes the cache + enforces the oracle floor |
| `mintInitialPosition()` | `onlyAuthorized` | Safe or module only; refreshes the cache + deviation guard before minting |
| `burnPosition()` | `onlyVaultOrAuthorized` | Vault, Safe or module; tokens go to the vault |
| `configurePriceFeeds()` / `setOracleParams()` | `onlySafe` | Oracle addresses & deviation/heartbeat params — Safe only (not the module) |
| `refreshPriceCache()` | `onlyVaultOrAuthorized` | Refreshes the price cache (no address change) |
| `configureRanges()` | `onlyAuthorized` | Safe or module only |
| `setSwapFeeBps()` | `onlyAuthorized` | Safe or module only |
| `setTreasuryAddress()` | `onlyAuthorized` | Safe or module only |

### Treasury

| Function | Access | Description |
|----------|--------|-------------|
| `swapToUSDC()` | Public | Converts WETH to USDC; tokens stay in Treasury |
| `adminWithdraw()` | `onlyOwner` (Safe) | Monthly cap enforced |
| `payKeeperBounty()` | Authorized RangeManagers only | Called automatically after rebalance |
| `disableAdminWithdraw()` | `onlyOwner` | **IRREVERSIBLE** |
| `setBridgeConfig()` | `onlyOwner` | Configure cross-chain bridge |
| `setKeeperBounty()` | `onlyOwner` | Enable/disable bounty and set amount |

### MultiUserVault

| Function | Access | Description |
|----------|--------|-------------|
| `deposit()` / `withdraw()` | Public | Any user can deposit or withdraw |
| `startRebalance()` / `endRebalance()` | `onlyBot` | Safe, module, or RangeManager |
| `collectCommissions()` | `onlyBot` | Collect LP fees for Treasury |
| `updateTreasuryAddress()` | `onlyOwner` (Safe) | Update the Treasury address |

---

## User Fund Safety

The protocol is designed so that user funds are protected even if the keeper wallet or bot infrastructure is compromised:

- **User funds are held in the vault contract**, never in the bot wallet or any externally owned account.
- **The keeper cannot withdraw user funds** — it can only call public rebalance functions.
- **LP position NFTs are owned by the vault contract**, not by any individual.
- **Withdrawals go directly to the user's wallet** — there is no intermediary step where funds can be redirected.
- **No admin can redirect user withdrawals** — the withdrawal function sends tokens to `msg.sender`.
- **The Safe multisig** provides an additional layer of protection: even admin operations require 2-of-3 signer approval.
