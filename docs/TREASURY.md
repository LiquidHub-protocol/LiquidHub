# Treasury

## Overview

The on-chain Treasury contract collects protocol fees and manages fund distribution. It serves as the central revenue hub for the Liquid Hub protocol, accumulating fees from LP commissions and frontend swap commissions.

One Treasury contract is deployed per network for the LP pools.

---

## Decentralization Status — Phase 1

The protocol is currently in **Phase 1 of its decentralization roadmap**. What this means for the Treasury:

| Aspect | Phase 1 (current) | Phase 2 (planned) |
|--------|-------------------|-------------------|
| Governance | Gnosis Safe 2-of-3 multisig controls all configuration | Same multisig, but admin withdrawals locked |
| Admin withdrawals | Enabled, capped by a configurable monthly limit | `disableAdminWithdraw()` called irreversibly — Treasury locked against any admin withdrawal |
| Keeper / deposit / metrics / hedge bounties | **Enabled** — configurable by the multisig | Permissionless, fully active |
| Bridge to stakers | Mechanism deployed, **bounty disabled** (no staking contract yet) | `bridgeToStakers()` / `collectAndBridge()` live, fees routed to stakers |

We believe clarity on what is and isn't decentralized matters more than marketing claims. Every function described below already exists on-chain and is verified on the block explorer — the table above states what is *enabled* today versus what is planned.

---

## Fee Sources

| Source | Tokens | Mechanism |
|--------|--------|-----------|
| LP commissions | token0 + token1 (e.g. WETH + USDC) | Collected during each rebalance, sent from vault to Treasury |
| Frontend swap commissions | Any ERC-20 | Via DEX aggregator partner fee (`PARTNER_FEE_BPS`, e.g. 0.03%) |
| Bounty fund | USDC | Pre-funded by the protocol to pay keeper / deposit / metrics / hedge bounties (see below) |

---

## Admin Withdrawal (Phase 1)

- **Monthly cap**: `USDC_MONTHLY_CAP` (initial: 15,000 USDC).
- **Only the owner** (Gnosis Safe multisig) can call `adminWithdraw(amount, to)`.
- The cap resets every 30 days automatically.
- The cap can be modified at any time via `setMonthlyCap(newCap)` (multisig).
- Each withdrawal emits an on-chain event (`AdminWithdrawal`) that anyone can audit, and is also documented off-chain on the public **Treasury Transparency** page on liquidhub.app.
- In **Phase 2**, `disableAdminWithdraw()` can be called irreversibly, permanently locking the Treasury against any admin withdrawal.

---

## Public Functions (callable by anyone)

These functions are **permissionless** — no authorization required.

### swapToUSDC()

Converts **any ERC-20 token** held by the Treasury to USDC via the DEX router.
- Parameters: `tokenIn`, `fee` (DEX pool fee tier), `amountIn`, `minAmountOut`.
- Fee tiers: 100 (0.01%), 500 (0.05%), 3000 (0.3%), 10000 (1%).
- USDC remains in the Treasury after the swap.
- Useful for consolidating revenue from multiple token types into USDC.

---

## Keeper Bounties

The Treasury rewards community keepers who execute the protocol's permissionless actions, with USDC paid directly from the Treasury to whoever sends the transaction. Four bounties are **active** today; the bridge bounty is reserved for Phase 2. Each is configurable by the multisig and is a **silent no-op** when disabled or when the Treasury balance is insufficient — it never blocks the underlying action.

| Bounty | Triggered by | Configured via |
|--------|--------------|----------------|
| Keeper (rebalance) | `rebalance()` on the RangeManager | `setKeeperBounty(enabled, amount)` |
| Deposit (process) | `processDepositPermissionless()` on the Vault | `setDepositBounty(enabled, amount)` |
| Metrics (snapshot) | `recordPriceSnapshot()` on the RangeManager | `setMetricsBounty(enabled, amount)` |
| Hedge (DN) | `adjustHedge()` on the AaveHedgeManager | `setHedgeBounty(enabled, amount)` |
| Bridge _(Phase 2)_ | `bridgeToStakers()` / `collectAndBridge()` | `setBridgeBounty(enabled, amount)` |

> **Amounts** are not listed here. The current bounty amounts are published on the protocol's Decentralization page (https://liquidhub.app/docs#decentralization) and are the source of truth on-chain — read the live value on the Treasury contract (`keeperBountyAmount()`, `depositBountyAmount()`, etc.) before relying on it.

- The RangeManager must be authorized via `authorizeRangeManager()`, the Vault via `authorizeVault()` (deposit bounty), and (DN) the AaveHedgeManager via `authorizeHedgeManager()` before they can trigger bounty payments. This is irrelevant to which keeper executes the action — the bounty always goes to whoever called the function (`msg.sender`).
- **Anti-drain**: `processDepositPermissionless()` reverts unless a deposit is queued; community keepers also require an existing position NFT because the one-time initial mint is reserved to the protocol bot/Safe path. The deposit bounty is paid only when the processed deposit is at least 100× the bounty value, after the per-Vault cooldown, after the same-keeper cooldown for that Vault, and below the per-Vault daily cap; `recordPriceSnapshot()` reverts unless a snapshot is due (capped by `maxSnapshotsPerDay`); `adjustHedge()` reverts unless the hedge drift exceeds the on-chain threshold **and** the on-chain cooldown (`hedgeAdjustCooldown`) has elapsed.
- The **bridge bounty** mechanism is deployed but disabled until the staking contract is live (Phase 2). Activation is a single `setBridgeBounty(true, …)` transaction — no redeployment.

### Bounty payment semantics

The payment uses a best-effort safety pattern: if a bounty cannot be paid (disabled or insufficient Treasury balance), it is skipped silently and the underlying action still succeeds.

This guarantees:
- **No revert** of the action if the bounty cannot be paid
- **Predictable experience** for community keepers (bounty is best-effort, action is guaranteed)
- **Multisig safety** — enabling or disabling a bounty during a configuration change cannot lock anything

---

## Asset Recovery

The Treasury includes recovery functions for tokens or native ETH accidentally sent to the contract:

- **`rescueToken(tokenAddr, to, amount)`**: recovers any ERC-20 except USDC (which goes through `adminWithdraw` to respect the monthly cap).
- **`rescueETH(to, amount)`**: recovers native ETH (the Treasury can receive ETH via `receive() payable`).

Both functions are `onlyOwner`.

---

## Configuration Functions (multisig only)

| Function | Purpose | Status |
|----------|---------|--------|
| `setMonthlyCap(newCap)` | Modify the admin withdrawal cap | Active (Phase 1) |
| `setKeeperBounty(enabled, amount)` | Configure the rebalance bounty | Active (Phase 1) |
| `setDepositBounty(enabled, amount)` | Configure the deposit-processing bounty | Active (Phase 1) |
| `setDepositBountyLimits(vaultCooldown, keeperCooldown, dailyCap)` | Configure anti-drain limits for deposit-processing bounties | Active (Phase 1) |
| `setMetricsBounty(enabled, amount)` | Configure the snapshot bounty | Active (Phase 1) |
| `setHedgeBounty(enabled, amount)` | Configure the hedge bounty (DN) | Active (Phase 1) |
| `setBridgeBounty(enabled, amount)` | Configure the bridge bounty | _Phase 2 — disabled by default_ |
| `authorizeRangeManager(rm, authorized)` | Whitelist a RangeManager for `payKeeperBounty()` / `payMetricsBounty()` | Active (Phase 1) |
| `authorizeVault(vault, authorized)` | Whitelist a Vault for `payDepositBounty()` | Active (Phase 1) |
| `authorizeHedgeManager(hm, authorized)` | Whitelist an AaveHedgeManager for `payHedgeBounty()` | Active (Phase 1) |
| `disableAdminWithdraw()` | Irreversibly lock the Treasury against admin withdrawals | _Phase 2_ |
| `rescueToken(token, to, amount)` | Recover ERC-20 sent by mistake (non-USDC) | Active |
| `rescueETH(to, amount)` | Recover native ETH sent by mistake | Active |
| `transferOwnership(newOwner)` | Transfer Treasury ownership (e.g. to a Timelock) | Active |

---

## Public Read Functions

| Function | Returns |
|----------|---------|
| `monthlyCap()` | Current monthly cap in USDC (6 decimals) |
| `currentMonthWithdrawn()` | Already withdrawn this month |
| `keeperBountyEnabled()` / `keeperBountyAmount()` | Rebalance bounty config |
| `depositBountyEnabled()` / `depositBountyAmount()` | Deposit-processing bounty config |
| `depositBountyCooldown()` / `depositBountyKeeperCooldown()` / `depositBountyDailyCap()` | Deposit bounty anti-drain limits |
| `metricsBountyEnabled()` / `metricsBountyAmount()` | Snapshot bounty config |
| `hedgeBountyEnabled()` / `hedgeBountyAmount()` | Hedge bounty config (DN) |
| `usdc()` | Address of the USDC token (used to read the Treasury balance) |

---

## Events (auditable on-chain)

| Event | Emitted by |
|-------|-----------|
| `AdminWithdrawal(amount, to)` | `adminWithdraw()` |
| `KeeperBountyPaid(keeper, amount)` | `payKeeperBounty()` |
| `KeeperBountyConfigured(enabled, amount)` | `setKeeperBounty()` |
| `DepositBountyPaid(keeper, amount)` | `payDepositBounty()` |
| `DepositBountyConfigured(enabled, amount)` | `setDepositBounty()` |
| `DepositBountyLimitsConfigured(vaultCooldown, keeperCooldown, dailyCap)` | `setDepositBountyLimits()` |
| `VaultAuthorized(vault, authorized)` | `authorizeVault()` |
| `MetricsBountyPaid(keeper, amount)` | `payMetricsBounty()` |
| `MetricsBountyConfigured(enabled, amount)` | `setMetricsBounty()` |
| `HedgeBountyPaid(keeper, amount)` | `payHedgeBounty()` (DN) |
| `HedgeBountyConfigured(enabled, amount)` | `setHedgeBounty()` (DN) |
| `MonthlyCapUpdated(oldCap, newCap)` | `setMonthlyCap()` |
| `SwappedToUSDC(tokenIn, fee, amountIn, usdcOut)` | `swapToUSDC()` |
| `RangeManagerAuthorized(rm, authorized)` | `authorizeRangeManager()` |
| `TokenRescued(token, to, amount)` | `rescueToken()` |
| `ETHRescued(to, amount)` | `rescueETH()` |
