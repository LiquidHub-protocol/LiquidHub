# Treasury

## Overview

The on-chain Treasury contract collects protocol fees and manages fund distribution. It serves as the central revenue hub for the Liquid Hub protocol, accumulating fees from LP commissions and frontend swap commissions.

One Treasury contract is deployed per network for the LP pools.

---

## Fee Sources

| Source | Tokens | Mechanism |
|--------|--------|-----------|
| LP commissions | token0 + token1 (e.g. WETH + USDC) | Collected during each rebalance, sent from vault to Treasury |
| Frontend swap commissions | Any ERC-20 | Via DEX aggregator partner fee (`PARTNER_FEE_BPS`, e.g. 0.03%) |
| Keeper bounty fund | USDC | Pre-funded by protocol for incentive payments (see below) |

---

## Admin Withdrawal

- **Monthly cap**: `USDC_MONTHLY_CAP` (initial: 15,000 USDC).
- **Only the owner** (Gnosis Safe multisig) can call `adminWithdraw(amount, to)`.
- The cap resets every 30 days automatically.
- The cap can be modified at any time via `setMonthlyCap(newCap)` (multisig).
- Each withdrawal emits an on-chain event (`AdminWithdrawal`) that anyone can audit, and is also documented off-chain on the public **Treasury Transparency** page on liquidhub.app.

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

## Keeper Bounty

The Treasury includes a keeper bounty system that rewards community keepers who execute critical maintenance operations, with USDC paid directly from the Treasury. The bounty is **silent no-op** when disabled or when the Treasury balance is insufficient — it never blocks the underlying action.

- **LP rebalances**: paid when a community keeper calls `rebalance()` on the RangeManager during the priority window. The RangeManager itself triggers `payKeeperBounty(keeper)` on the Treasury inside a try/catch.
- **Configurable on-chain** via `setKeeperBounty(enabled, amount)` on the Treasury (multisig only).
- Default amount: **0.5 USDC** (`KEEPER_BOUNTY_AMOUNT=500000`).
- The RangeManager contracts must be explicitly authorized via `authorizeRangeManager()` before they can trigger bounty payments. This authorization is irrelevant to which keeper executes the rebalance — the bounty always goes to whoever called `rebalance()`.

### Bounty payment semantics

The bounty system uses a best-effort safety pattern: if the bounty cannot be paid (disabled, or insufficient Treasury balance), the payment is skipped silently and the underlying rebalance still succeeds.

This guarantees:
- **No revert** of the rebalance if the bounty cannot be paid
- **Predictable user experience** for community keepers (bounty is best-effort, action is guaranteed)
- **Multisig safety** — disabling the bounty during a configuration change cannot lock anything

---

## Asset Recovery

The Treasury includes recovery functions for tokens or native ETH accidentally sent to the contract:

- **`rescueToken(tokenAddr, to, amount)`**: recovers any ERC-20 except USDC (which goes through `adminWithdraw` to respect the monthly cap).
- **`rescueETH(to, amount)`**: recovers native ETH (the Treasury can receive ETH via `receive() payable`).

Both functions are `onlyOwner`.

---

## Configuration Functions (multisig only)

| Function | Purpose |
|----------|---------|
| `setMonthlyCap(newCap)` | Modify the admin withdrawal cap |
| `setKeeperBounty(enabled, amount)` | Configure the rebalance bounty |
| `authorizeRangeManager(rm, authorized)` | Whitelist a RangeManager for `payKeeperBounty()` |
| `rescueToken(token, to, amount)` | Recover ERC-20 sent by mistake (non-USDC) |
| `rescueETH(to, amount)` | Recover native ETH sent by mistake |
| `transferOwnership(newOwner)` | Transfer Treasury ownership (e.g. to a Timelock) |

---

## Public Read Functions

| Function | Returns |
|----------|---------|
| `monthlyCap()` | Current monthly cap in USDC (6 decimals) |
| `currentMonthWithdrawn()` | Already withdrawn this month |
| `keeperBountyEnabled()` / `keeperBountyAmount()` | Rebalance bounty config |

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
