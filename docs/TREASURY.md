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
| Keeper bounty | **Not yet enabled** — disabled by default at deployment _(soon)_ | Permissionless, fully active |
| Bridge to stakers | Not yet deployed _(soon)_ | `bridgeToStakers()` / `collectAndBridge()` live, fees routed to stakers |

We believe clarity on what is and isn't decentralized matters more than marketing claims. Every function described below already exists on-chain and is verified on the block explorer — the table above states what is *enabled* today versus what is planned.

---

## Fee Sources

| Source | Tokens | Mechanism |
|--------|--------|-----------|
| LP commissions | token0 + token1 (e.g. WETH + USDC) | Collected during each rebalance, sent from vault to Treasury |
| Frontend swap commissions | Any ERC-20 | Via DEX aggregator partner fee (`PARTNER_FEE_BPS`, e.g. 0.03%) |
| Keeper bounty fund | USDC | Pre-funded by protocol for incentive payments _(soon — see below)_ |

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

Converts **any ERC-20 token** held by the Treasury to USDC via Uniswap V3.
- Parameters: `tokenIn`, `fee` (Uniswap V3 pool fee tier), `amountIn`, `minAmountOut`.
- Fee tiers: 100 (0.01%), 500 (0.05%), 3000 (0.3%), 10000 (1%).
- USDC remains in the Treasury after the swap.
- Useful for consolidating revenue from multiple token types into USDC.

---

## Keeper Bounty _(soon — not yet enabled)_

The Treasury includes a keeper bounty system that rewards community keepers who execute critical maintenance operations, with USDC paid directly from the Treasury. The bounty is **disabled by default at deployment** and is **not yet enabled** — it is part of the Phase 1 → Phase 2 rollout. It is configurable by the multisig in Phase 1 and becomes fully permissionless once admin withdrawals are irreversibly disabled in Phase 2.

The bounty is a **silent no-op** when disabled (which is the case today) or when the Treasury balance is insufficient — it never blocks the underlying action.

- **LP rebalances**: paid when a community keeper calls `rebalance()` on the RangeManager during the priority window. The RangeManager itself triggers `payKeeperBounty(keeper)` on the Treasury inside a try/catch.
- **Configurable on-chain** via `setKeeperBounty(enabled, amount)` on the Treasury (multisig only).
- Default amount: **0.5 USDC** (`KEEPER_BOUNTY_AMOUNT=500000`).
- The RangeManager contracts must be explicitly authorized via `authorizeRangeManager()` before they can trigger bounty payments. This authorization is irrelevant to which keeper executes the rebalance — the bounty always goes to whoever called `rebalance()`.

### Bounty payment semantics

The bounty system uses a best-effort safety pattern: if the bounty cannot be paid (disabled — which is the case today — or insufficient Treasury balance), the payment is skipped silently and the underlying rebalance still succeeds.

This guarantees:
- **No revert** of the rebalance if the bounty cannot be paid
- **Predictable user experience** for community keepers (bounty is best-effort, action is guaranteed)
- **Multisig safety** — enabling or disabling the bounty during a configuration change cannot lock anything

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
| `setKeeperBounty(enabled, amount)` | Configure the rebalance bounty | _soon — disabled by default_ |
| `authorizeRangeManager(rm, authorized)` | Whitelist a RangeManager for `payKeeperBounty()` | Active (Phase 1) |
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
| `keeperBountyEnabled()` / `keeperBountyAmount()` | Rebalance bounty config (currently disabled) |

---

## Events (auditable on-chain)

| Event | Emitted by |
|-------|-----------|
| `AdminWithdrawal(amount, to)` | `adminWithdraw()` |
| `KeeperBountyPaid(keeper, amount)` | `payKeeperBounty()` |
| `KeeperBountyConfigured(enabled, amount)` | `setKeeperBounty()` |
| `MonthlyCapUpdated(oldCap, newCap)` | `setMonthlyCap()` |
| `SwappedToUSDC(tokenIn, fee, amountIn, usdcOut)` | `swapToUSDC()` |
| `RangeManagerAuthorized(rm, authorized)` | `authorizeRangeManager()` |
| `TokenRescued(token, to, amount)` | `rescueToken()` |
| `ETHRescued(to, amount)` | `rescueETH()` |
