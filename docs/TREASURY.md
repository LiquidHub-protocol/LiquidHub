# Treasury

## Overview

The on-chain Treasury contract collects protocol fees and manages fund distribution. It serves as the central revenue hub for the Liquid Hub protocol, accumulating fees from LP commissions, Trading Vault commissions, and frontend swap commissions.

One Treasury contract is deployed per network and per service family (LP pools share one Treasury, the GMX trading vault has its own, frontend swap fees have their own).

---

## Fee Sources

| Source | Tokens | Mechanism |
|--------|--------|-----------|
| LP commissions | token0 + token1 (e.g. WETH + USDC) | Collected during each rebalance, sent from vault to Treasury |
| Trading Vault commissions | USDC | Collected on realized profits (settleAll), sent from vault to Treasury |
| Frontend swap commissions | Any ERC-20 | Via DEX aggregator partner fee (`PARTNER_FEE_BPS`, e.g. 0.03%) |
| Keeper bounty fund | USDC | Pre-funded by protocol for incentive payments (see below) |

---

## Phases of Decentralization

The Treasury supports two operational phases:

- **Phase 1 — Admin-managed**: the multisig owner can withdraw a capped monthly amount of USDC to fund operations (audit, marketing, infrastructure, salaries). Each withdrawal emits an on-chain event (`AdminWithdrawal`) that anyone can audit, and is also documented off-chain on the public **Treasury Transparency** page on liquidhub.app.
- **Phase 2 — Decentralized**: the multisig calls `disableAdminWithdraw()` irreversibly. From that moment, no admin withdrawal is ever possible again. Protocol fees are routed exclusively to the StakingRewards contract via permissionless functions (see below).

---

## Phase 1 — Admin Withdrawal

- **Monthly cap**: `USDC_MONTHLY_CAP` (initial: 15,000 USDC).
- **Only the owner** (Gnosis Safe multisig) can call `adminWithdraw(amount, to)`.
- The cap resets every 30 days automatically.
- **Permanent disable**: `disableAdminWithdraw()` can be called by the owner to permanently and **irreversibly** disable all admin withdrawals (Phase 2 transition).
- The cap can be modified at any time during Phase 1 via `setMonthlyCap(newCap)` (multisig).

---

## Public Functions (callable by anyone)

These functions are **permissionless** — no authorization required. They are the foundation of the protocol's decentralization.

### swapToUSDC()

Converts **any ERC-20 token** held by the Treasury to USDC via Uniswap V3.
- Parameters: `tokenIn`, `fee` (Uniswap V3 pool fee tier), `amountIn`, `minAmountOut`.
- Fee tiers: 100 (0.01%), 500 (0.05%), 3000 (0.3%), 10000 (1%).
- USDC remains in the Treasury after the swap.
- Useful for consolidating revenue from multiple token types into USDC before distribution.

### bridgeToStakers() — Phase 2

Sends USDC cross-chain to a `StakingRewards` contract on a destination chain (e.g. Base) via Stargate v2.
- The destination address (`bridgeDestinationAddress`) is configured by the multisig and locked into the contract — the caller cannot redirect the funds.
- The caller pays the cross-chain Stargate fees (~$1–3) in native ETH via `msg.value`.
- **Pays the bridge bounty** (see below) to the caller as compensation + incentive.

### collectAndBridge() — Phase 2

Atomic combination of `swapToUSDC()` + `bridgeToStakers()` in a single transaction.
- Same parameters as `swapToUSDC()` plus `minSwapOut` for slippage protection.
- Same destination protection as `bridgeToStakers()`.
- **Pays the bridge bounty** to the caller.

### distributeToStakers() — Phase 2

Sends USDC to a local same-chain `StakingRewards` contract.
- The destination (`stakingRewardsAddress`) is configured by the multisig.
- No bridge fees, gas cost is negligible — therefore **no bounty** (drainage protection).

---

## Keeper Bounty Systems

The Treasury contracts include **two distinct bounty systems**, each rewarding a different community action with USDC paid directly from the Treasury. Both bounties are **silent no-op** when disabled or when the Treasury balance is insufficient — they never block the underlying action.

### 1. Keeper Bounty — Rebalances & Trading Vault closures

Phase 1 incentive that rewards keepers who execute critical maintenance operations:
- **LP rebalances**: paid when a community keeper calls `rebalance()` on the RangeManager during the priority window. The RangeManager itself triggers `payKeeperBounty(keeper)` on the Treasury inside a try/catch.
- **Trading Vault stop-loss / take-profit closures**: paid when a keeper executes an authorized closure after the keeper window has elapsed.
- **Configurable on-chain** via `setKeeperBounty(enabled, amount)` on the Treasury (multisig only).
- Default amount: **0.5 USDC** (`KEEPER_BOUNTY_AMOUNT=500000`).
- The RangeManager contracts must be explicitly authorized via `authorizeRangeManager()` before they can trigger bounty payments. This authorization is irrelevant to which keeper executes the rebalance — the bounty always goes to whoever called `rebalance()`.

### 2. Bridge Bounty — Phase 2 cross-chain distribution

Phase 2 incentive that rewards keepers who trigger the cross-chain delivery of accumulated fees to the StakingRewards contract:
- Paid automatically inside `bridgeToStakers()` and `collectAndBridge()` to `msg.sender`.
- Compensates the Stargate cross-chain fees paid by the caller (typically $1–3) and provides a small incentive on top.
- Default amount: **2 USDC** (`BRIDGE_BOUNTY_AMOUNT=2000000`).
- **Configurable on-chain** via `setBridgeBounty(enabled, amount)` on the Treasury (multisig only).
- Not paid on `distributeToStakers()` — same-chain transfers don't justify an incentive.

#### Anti-drain protections

Unlike rebalance/closure bounties (which can only be paid when the underlying market condition is met), bridge bounties could in principle be drained by spamming many tiny bridges. The Treasury includes **two on-chain protections**:

1. **Cooldown** (default **6 hours** = 21600s, configurable via `bridgeBountyCooldown`): the contract pays the bounty **at most once per cooldown window**. After a paid bridge, `lastBridgeBountyAt` is updated; subsequent calls during the cooldown still execute the bridge but **do not pay the bounty**.
2. **Minimum ratio** (default **50×**, configurable via `bridgeBountyMinRatio`): the bounty is paid **only if** `bridgedAmount >= bridgeBountyAmount × minRatio`. With a 2 USDC bounty and a 50× ratio, a keeper must bridge at least **100 USDC** in a single call to earn the bounty. Set `minRatio = 0` to disable this check.

Both protections are **bounty-side only** — the bridge itself is always callable, even if no bounty would be paid. The protocol's internal bot can therefore bridge any amount at any time. Configure both via:

```solidity
setBridgeBountyCooldown(uint64 cooldown, uint16 minRatio)
```

#### Coordination with the internal protocol bot

Liquid Hub runs an internal bridge bot as a fallback. To leave a fair window for community keepers:

- **Cooldown on-chain**: 6 hours (single `lastBridgeBountyAt` per Treasury, global to all callers).
- **Internal bot cron**: 12 hours (decoupled from the cooldown).

This guarantees a **6-hour community-priority window** between every potential internal bridge: any keeper who calls the bridge during this window earns the bounty. If the community is active, the internal bot rarely earns anything. If the community is dormant, the internal bot keeps the lights on and earns the bounty itself, financing its own operating costs.

The contract treats the internal bot exactly like any other caller — there is no privileged path. The decentralization is **organic**: the more active the community, the less the internal bot is involved.

### Bounty payment semantics

Both bounty systems share the same safety pattern:

```solidity
function _payBridgeBounty(address keeper) internal {
    if (!bridgeBountyEnabled || bridgeBountyAmount == 0) return;
    if (usdc.balanceOf(address(this)) < bridgeBountyAmount) return;
    usdc.safeTransfer(keeper, bridgeBountyAmount);
    emit BridgeBountyPaid(keeper, bridgeBountyAmount);
}
```

This guarantees:
- **No revert** of the rebalance / bridge / closure if the bounty cannot be paid
- **Predictable user experience** for community keepers (bounty is best-effort, action is guaranteed)
- **Multisig safety** — disabling the bounty during a configuration change cannot lock anything

---

## Asset Recovery

The Treasury includes recovery functions for tokens or native ETH accidentally sent to the contract:

- **`rescueToken(tokenAddr, to, amount)`**: recovers any ERC-20 except USDC (which goes through `adminWithdraw` to respect the monthly cap).
- **`rescueETH(to, amount)`**: recovers native ETH (the Treasury can receive ETH via `receive() payable`).

Both functions are `onlyOwner` and disabled once `disableAdminWithdraw()` has been called (Phase 2).

---

## Configuration Functions (multisig only)

| Function | Purpose |
|----------|---------|
| `setMonthlyCap(newCap)` | Modify the Phase 1 admin withdrawal cap |
| `disableAdminWithdraw()` | **IRREVERSIBLE** — transition to Phase 2 |
| `setKeeperBounty(enabled, amount)` | Configure the rebalance/closure bounty |
| `setBridgeBounty(enabled, amount)` | Configure the bridge bounty |
| `setBridgeBountyCooldown(cooldown, minRatio)` | Configure anti-drain protections (cooldown + min bridged ratio) |
| `authorizeRangeManager(rm, authorized)` | Whitelist a RangeManager for `payKeeperBounty()` |
| `setBridgeConfig(enabled, dstEid, destination)` | Configure Stargate v2 destination (Phase 2 setup) |
| `setStakingRewards(address)` | Configure the local StakingRewards address (Phase 2 setup) |
| `rescueToken(token, to, amount)` | Recover ERC-20 sent by mistake (non-USDC) |
| `rescueETH(to, amount)` | Recover native ETH sent by mistake |
| `transferOwnership(newOwner)` | Transfer Treasury ownership (e.g. to a Timelock) |

---

## Public Read Functions

| Function | Returns |
|----------|---------|
| `adminWithdrawEnabled()` | `bool` — Phase 1 (true) or Phase 2 (false) |
| `monthlyCap()` | Current monthly cap in USDC (6 decimals) |
| `currentMonthWithdrawn()` | Already withdrawn this month |
| `keeperBountyEnabled()` / `keeperBountyAmount()` | Rebalance bounty config |
| `bridgeBountyEnabled()` / `bridgeBountyAmount()` | Bridge bounty config |
| `bridgeBountyCooldown()` / `bridgeBountyMinRatio()` / `lastBridgeBountyAt()` | Anti-drain state |
| `estimateBridgeFee(amount)` | LayerZero/Stargate bridge cost estimate |
| `stakingRewardsAddress()` | Configured local StakingRewards |
| `bridgeDestinationEid()` / `bridgeDestinationAddress()` | Configured cross-chain destination |

---

## Events (auditable on-chain)

| Event | Emitted by |
|-------|-----------|
| `AdminWithdrawal(amount, to)` | `adminWithdraw()` (Phase 1) |
| `AdminWithdrawDisabled(timestamp)` | `disableAdminWithdraw()` (transition Phase 1 → 2) |
| `BridgedToStakers(sent, received, dstEid, guid)` | `bridgeToStakers()` (Phase 2) |
| `CollectedAndBridged(tokenIn, swappedUSDC, bridgedUSDC, dstEid)` | `collectAndBridge()` (Phase 2) |
| `FeesDistributed(amount)` | `distributeToStakers()` (Phase 2) |
| `KeeperBountyPaid(keeper, amount)` | `payKeeperBounty()` |
| `BridgeBountyPaid(keeper, amount)` | `bridgeToStakers()` / `collectAndBridge()` |
| `KeeperBountyConfigured(enabled, amount)` | `setKeeperBounty()` |
| `BridgeBountyConfigured(enabled, amount)` | `setBridgeBounty()` |
| `BridgeBountyCooldownConfigured(cooldown, minRatio)` | `setBridgeBountyCooldown()` |
| `MonthlyCapUpdated(oldCap, newCap)` | `setMonthlyCap()` |
| `BridgeConfigured(enabled, dstEid, destination)` | `setBridgeConfig()` |
| `SwappedToUSDC(tokenIn, fee, amountIn, usdcOut)` | `swapToUSDC()` (and inside `collectAndBridge`) |
| `RangeManagerAuthorized(rm, authorized)` | `authorizeRangeManager()` |
| `TokenRescued(token, to, amount)` | `rescueToken()` |
| `ETHRescued(to, amount)` | `rescueETH()` |
