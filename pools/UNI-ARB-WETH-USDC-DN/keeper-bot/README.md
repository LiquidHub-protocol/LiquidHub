# Liquid Hub - Delta Neutral Keeper Bot

Keeper bot for the Liquid Hub Delta Neutral (DN) pool **UNI-ARB-WETH-USDC-DN**. This bot extends the standard keeper bot with AAVE V3 hedge monitoring and recalibration.

## Overview

The DN keeper bot performs the same rebalancing, deposit-processing and on-chain dynamic-range cycle as the standard pool (see the standard pool README for `rebalance()`, `processDepositPermissionless()` and `recordPriceSnapshot()` — all permissionless, all bountied, the range computed 100% on-chain). On top of that, the DN bot can adjust the AAVE V3 hedge permissionlessly.

At each polling cycle the bot:

1. Records a price snapshot if `isSnapshotDue()` (metrics bounty) — done first so the rest reads a fresh price
2. Processes a queued deposit if one is pending and a position NFT exists (deposit bounty)
3. Adjusts the hedge if its drift exceeds the on-chain threshold (hedge bounty — see below)
4. Rebalances if `needsRebalance` (keeper bounty)
5. Displays the current AAVE V3 collateral / debt / health factor

All steps are independent. Note: processing a deposit **opens the AAVE hedge atomically** in the same transaction (`processDepositPermissionless` → `DnDepositLib.openDepositHedge` + a strict post-check) — the keeper does not touch AAVE directly, and the transaction reverts if the resulting hedge drifts beyond tolerance.

### Hedge adjustment (`adjustHedge`, 100% on-chain)

`adjustHedge()` is **permissionless** and pilots on the **net effective short** (`effectiveShort = debt − idle token0`) versus the on-chain target. It corrects both directions without keeper-provided sizing: flash-repay for over-hedge, or atomic borrow + oracle/TWAP-bounded token0 sale + token1 collateral supply for under-hedge. The call reverts unless drift, cooldown, oracle/TWAP and AAVE health-factor checks all pass. Large idle token0 balances cannot inflate a borrow and instead require the atomic rebalance fallback. The same rules apply to community keepers and the protocol bot.

**USDC reserve management** is integrated into the same call: when the health factor is above the governance target (`RESERVE_HF_TARGET_BPS`), `adjustHedge()` releases the surplus AAVE collateral and keeps it as USDC **on the HedgeManager itself** (never sent off-contract), so the reserve used for future adjustments is replenished on-chain without any separate keeper action.

Each cycle the keeper first reads the on-chain cooldown (`hedgeAdjustCooldown` + `lastHedgeAdjustAt`) and skips before sending anything if the window is still open; otherwise it tries `adjustHedge()` via a static call to detect whether an adjustment will go through; if it would revert (drift below the dynamic threshold, under-hedge, or cooldown), it skips silently and pays no gas. A successful over-hedge correction pays the **hedge bounty**. The hedge parameters (`HEDGE_ADJUST_RANGE_DIVISOR`, `hedgeTargetBps`, `hedgeAdjustCooldown`, `swapSlippageBps`, reserve/HF parameters) are configured by the Safe via `setAdjustHedgeConfig` / `setCriticalHedgeRangeDivisor` / `setHedgeAdjustCooldown` and are the single source of truth — the protocol bot reads the same on-chain values.

`rebalance()`, `recordPriceSnapshot()` and `adjustHedge()` are all permissionless — any address can call them when the contract agrees. No whitelisting or keeper role required.

## Setup

```bash
cp ../.env.example .env
# Fill in your values
npm install
```

## Environment Variables

All standard keeper variables apply (see the standard pool README), including the optional `TREASURY_ADDRESS` (lets the bot read the Treasury USDC balance and warn when a bounty would be skipped). The DN bot adds:

| Variable | Description | Default |
|---|---|---|
| `AAVE_HEDGE_MANAGER_ADDRESS` | AaveHedgeManager contract address | -- |
| `AAVE_HEALTH_WARN` | Health factor warning threshold, usually near `RESERVE_HF_TARGET_BPS` | `1.40` |
| `AAVE_HEALTH_DELEVERAGE` | Health factor critical/deleverage threshold | `1.25` |
| `AAVE_HEALTH_EMERGENCY` | Health factor emergency threshold | `1.15` |

### RPC Trust Model

Community keepers are permissionless and may use any RPC provider they choose. Liquid Hub does not require public keepers to use premium or MEV-protected RPCs. This is intentional: keeper safety is enforced on-chain by oracle/TWAP checks, oracle-floored `minAmountsOut`, cooldowns, caps, and DN hedge post-checks.

A poor RPC can hurt the keeper's own liveness or bounty capture rate, but it does not grant extra permissions and cannot bypass contract validation. Configure backup RPCs for reliability.

## Keeper Bounties

Paid in **USDC** by the Treasury to whoever sends the transaction. The DN pool has four bounties:

| Action | Bounty | Treasury flag / amount |
|--------|--------|------------------------|
| `rebalance()` | Keeper bounty | `keeperBountyEnabled` / `keeperBountyAmount()` |
| `processDepositPermissionless()` | Deposit bounty | `depositBountyEnabled` / `depositBountyAmount()` |
| `recordPriceSnapshot()` | Metrics bounty | `metricsBountyEnabled` / `metricsBountyAmount()` |
| `adjustHedge()` | Hedge bounty | `hedgeBountyEnabled` / `hedgeBountyAmount()` |

A bounty is only paid if the Treasury holds enough USDC; otherwise the action still succeeds on-chain but no bounty is paid. The bot logs a warning and shows the Treasury balance on startup. Verify it on-chain (Contracts page) before relying on bounty income.

## Usage

```bash
# Active mode -- monitors and executes rebalances
npm start

# Check-only mode -- reads state once and exits
npm run check
```

## License

BUSL-1.1
