# Treasury

## Overview

The on-chain pool Treasury contract collects LP-strategy protocol fees and manages their distribution. User principal never becomes Treasury revenue.

One pool Treasury is deployed per **DEX protocol and blockchain** and may be shared by all compatible Liquid Hub pools in that scope. Frontend Velora partner fees use a separate **SwapTreasury per blockchain**; they are not mixed with LP-strategy revenue.

Official deployment addresses for pool Treasuries, SwapTreasuries and all other Liquid Hub contracts are
published on the [Contracts page](https://liquidhub.app/docs#contracts-addresses).

---

## Decentralization Status — Phase 1

The protocol is currently in **Phase 1 of its decentralization roadmap**. What this means for the Treasury:

| Aspect | Phase 1 (current) | Phase 2 (planned) |
|--------|-------------------|-------------------|
| Governance | Gnosis Safe multisig controls configuration | Timelock governance controls configuration; the Safe keeps only the separately documented emergency/recovery powers |
| Admin withdrawals | Enabled, capped by a configurable monthly limit | `disableAdminWithdraw()` called irreversibly — Treasury locked against any admin withdrawal |
| Keeper / deposit / metrics / hedge bounties | **Enabled** — configured by the Safe | Permissionless triggers, configuration controlled by the Timelock |
| Bridge to stakers | Mechanism deployed, **bounty disabled** (no staking contract yet) | `bridgeToStakers()` live, fees routed to the governed destination |

The table states what is enabled in Phase 1 versus planned for Phase 2. For any deployment, verify the live address and bytecode through the official Contracts page rather than assuming a source file is already deployed.

---

## Fee Sources

| Source | Tokens | Mechanism |
|--------|--------|-----------|
| LP commissions | token0 + token1 (e.g. WETH + USDC) | Crystallized before value-sensitive share operations and during position maintenance; the protocol share is sent to the pool Treasury |
| Bounty fund | USDC | Pre-funded by the protocol to pay keeper / deposit / metrics / hedge bounties (see below) |

Frontend swap commissions are documented separately in [`swap/treasury/README.md`](../swap/treasury/README.md).

---

## Admin Withdrawal (Phase 1)

- **Monthly cap**: `USDC_MONTHLY_CAP` (initial: 15,000 USDC).
- **Only the owner** (Gnosis Safe multisig) can call `adminWithdraw(amount, to)`.
- The cap resets every 30 days automatically.
- The cap can be modified at any time via `setMonthlyCap(newCap)` (multisig).
- Each withdrawal emits an on-chain event (`AdminWithdrawal`) that anyone can audit, and is also documented off-chain on the public **Treasury Transparency** page on liquidhub.app.
- In **Phase 2**, `disableAdminWithdraw()` can be called irreversibly, permanently locking the Treasury against any admin withdrawal.

---

## Treasury Swaps

### swapToUSDC()

Converts a configured ERC-20 pool-revenue token held by the Treasury to USDC via the router for that Treasury's DEX protocol and blockchain. This function is **owner-only** (Safe in Phase 1, Timelock governance in Phase 2).
- Parameters: `tokenIn`, `fee`, `amountIn`, `minAmountOut`.
- The deployment/onboarding batch records the approved fee tier for each token from the pool `FEE`. The supplied `fee` must match that on-chain value, so the caller cannot select a different route tier.
- The current Uniswap V3 implementation supports fee tiers 100 (0.01%), 500 (0.05%), 3000 (0.3%) and 10000 (1%). A Treasury for another protocol uses that protocol's audited route implementation rather than pretending to be Uniswap-compatible.
- USDC remains in the Treasury after the swap.
- Useful for consolidating revenue from multiple token types into USDC.

Conversion and bridging are deliberately separate. Governance first calls owner-only `swapToUSDC()` through the Safe
in Phase 1 or the Timelock in Phase 2. A keeper may then call permissionless `bridgeToStakers()` for the resulting
USDC. There is no permissionless function that can choose when or how Treasury-held non-USDC assets are sold.

---

## Keeper Bounties

The Treasury rewards community keepers who execute the protocol's permissionless actions, with USDC paid directly from the Treasury to whoever sends the transaction. Four bounties are **active** today; the bridge bounty is reserved for Phase 2. Each is configured by the Safe in Phase 1 or Timelock governance in Phase 2 and is a **silent no-op** when disabled or when the Treasury balance is insufficient — it never blocks the underlying action.

| Bounty | Triggered by | Configured via |
|--------|--------------|----------------|
| Keeper (rebalance) | `rebalance()` on the RangeManager | `setKeeperBounty(enabled, amount)` |
| Deposit (process) | `processDepositPermissionless()` on the Vault | `setDepositBounty(enabled, amount)` |
| Strategy checkpoint | `checkpointMarketState()` on the RangeStrategyEngine | `setStrategyCheckpointBounty(enabled, amount)` |
| Hedge (DN) | `adjustHedge()` or urgent `repairHealthFactor()` on the AaveHedgeManager | `setHedgeBounty(enabled, amount)` |
| Bridge _(Phase 2)_ | `bridgeToStakers()` | `setBridgeBounty(enabled, amount)` |

> **Amounts** are not listed here. The current bounty amounts are published on the protocol's Protocol Design page (https://liquidhub.app/docs#protocol) and are the source of truth on-chain. Read the live value on the Treasury contract (`keeperBountyAmount()`, `depositBountyAmount()`, `strategyCheckpointBountyAmount()`, etc.) before relying on it.

- The RangeManager must be authorized via `authorizeRangeManager()`, the Vault via `authorizeVault()`, each RangeStrategyEngine via `authorizeStrategyEngine()`, and (DN) the AaveHedgeManager via `authorizeHedgeManager()` before they can trigger bounty payments. This does not restrict the keeper: the bounty is still paid to the permissionless caller.
- **Anti-drain**: `processDepositPermissionless()` reverts unless a deposit is queued; community keepers also require an existing position NFT because the one-time initial mint is reserved to the protocol bot/Safe path. Deposit bounties retain their ratio, cooldown and daily-cap guards. `checkpointMarketState()` advances only a due canonical epoch; `payStrategyCheckpointBounty()` also requires a strictly newer epoch and applies a per-engine daily cap. Normal `adjustHedge()` drift requires the on-chain threshold and cooldown; urgent HF repair is enabled only below its separate trigger and has separate bounty eligibility.
- The **bridge bounty** mechanism is deployed but disabled until the staking contract is live (Phase 2). Activation is a single `setBridgeBounty(true, …)` transaction — no redeployment.

### Bounty payment semantics

The payment uses a best-effort safety pattern: if a bounty cannot be paid (disabled or insufficient Treasury balance), it is skipped silently and the underlying action still succeeds.

This guarantees:
- **No revert** of the action if the bounty cannot be paid
- **Predictable payment semantics** for community keepers (the bounty is best-effort; the underlying action may still revert on its own safety or market checks)
- **Governance safety** — enabling or disabling a bounty cannot lock the underlying permissionless action

---

## Asset Recovery

The Treasury includes recovery functions for tokens or native ETH accidentally sent to the contract:

- **`rescueToken(tokenAddr, to, amount)`**: recovers any ERC-20 except USDC (which goes through `adminWithdraw` to respect the monthly cap).
- **`rescueETH(to, amount)`**: recovers native ETH (the Treasury can receive ETH via `receive() payable`).

Both functions are restricted to the dedicated Rescue Safe, including after ownership is transferred or
`adminWithdraw()` is irreversibly disabled. `rescueToken()` categorically rejects USDC; Treasury USDC remains
subject to the capped `adminWithdraw()` path while that path is active.

---

## Configuration Functions (multisig only)

| Function | Purpose | Status |
|----------|---------|--------|
| `setMonthlyCap(newCap)` | Modify the admin withdrawal cap | Active (Phase 1) |
| `setKeeperBounty(enabled, amount)` | Configure the rebalance bounty | Active (Phase 1) |
| `setDepositBounty(enabled, amount)` | Configure the deposit-processing bounty | Active (Phase 1) |
| `setDepositBountyLimits(vaultCooldown, keeperCooldown, dailyCap)` | Configure anti-drain limits for deposit-processing bounties | Active (Phase 1) |
| `setStrategyCheckpointBounty(enabled, amount)` | Configure the canonical strategy checkpoint bounty | Active (Phase 1) |
| `setStrategyCheckpointBountyDailyCap(dailyCap)` | Configure the per-engine checkpoint daily cap | Active (Phase 1) |
| `setHedgeBounty(enabled, amount)` | Configure the hedge bounty (DN) | Active (Phase 1) |
| `setBridgeBounty(enabled, amount)` | Configure the bridge bounty | _Phase 2 — disabled by default_ |
| `setDistributionsPaused(paused)` | Emergency-stop permissionless staking distributions/bridges; Rescue Safe may pause, owner resumes | Active |
| `authorizeRangeManager(rm, authorized)` | Authorize a RangeManager for `payKeeperBounty()` | Active (Phase 1) |
| `authorizeStrategyEngine(engine, authorized)` | Authorize an engine for `payStrategyCheckpointBounty()` | Active (Phase 1) |
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
| `strategyCheckpointBountyEnabled()` / `strategyCheckpointBountyAmount()` / `strategyCheckpointBountyDailyCap()` | Per-pool strategy checkpoint bounty config |
| `hedgeBountyEnabled()` / `hedgeBountyAmount()` | Hedge bounty config (DN) |
| `distributionsPaused()` | Whether permissionless staking distributions and bridges are stopped |
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
| `DistributionsPauseUpdated(paused, caller)` | `setDistributionsPaused()` |
| `VaultAuthorized(vault, authorized)` | `authorizeVault()` |
| `StrategyCheckpointBountyPaid(keeper, engine, epoch, amount)` | `payStrategyCheckpointBounty()` |
| `StrategyCheckpointBountyConfigured(enabled, amount)` | `setStrategyCheckpointBounty()` |
| `StrategyCheckpointBountyDailyCapConfigured(dailyCap)` | `setStrategyCheckpointBountyDailyCap()` |
| `HedgeBountyPaid(keeper, amount)` | `payHedgeBounty()` (DN) |
| `HedgeBountyConfigured(enabled, amount)` | `setHedgeBounty()` (DN) |
| `MonthlyCapUpdated(oldCap, newCap)` | `setMonthlyCap()` |
| `SwappedToUSDC(tokenIn, fee, amountIn, usdcOut)` | `swapToUSDC()` |
| `RangeManagerAuthorized(rm, authorized)` | `authorizeRangeManager()` |
| `TokenRescued(token, to, amount)` | `rescueToken()` |
| `ETHRescued(to, amount)` | `rescueETH()` |
