# Liquid Hub - Delta Neutral Keeper Bot

Reference keeper for a Liquid Hub Delta Neutral pool. It reads the pool's immutable-profile
`RangeStrategyEngine` and extends the Exposed keeper flow with Aave V3 hedge maintenance and safety repair.

## Overview

The DN keeper uses the same canonical checkpoint, deposit-processing and atomic rebalance paths as the Exposed
keeper. The `RangeStrategyEngine` also evaluates Aave capacity, borrowing cost, delta drift and stressed health
factor before authorizing a range. The keeper supplies none of those values.

At each polling cycle the bot:

1. Reads `previewDecision()`, `checkpointDue()`, PauseController state and Aave health information.
2. Executes `HF_REPAIR` immediately when authorized; this safety path is never delayed for the protocol bot.
3. Calls `checkpointMarketState()` when a canonical epoch is due, then rereads the decision.
4. Executes `HEDGE_ONLY` through `adjustHedge()` or `RANGE_AND_HEDGE` through atomic `rebalance()` as authorized.
5. Processes one queued deposit when inflows are available, a position exists and no maintenance action takes priority.

All steps are independent. Note: processing a deposit **opens the AAVE hedge atomically** in the same transaction (`processDepositPermissionless` → `DnDepositLib.openDepositHedge` + a strict post-check) — the keeper does not touch AAVE directly, and the transaction reverts if the resulting hedge drifts beyond tolerance.

### Hedge adjustment (`adjustHedge`, 100% on-chain)

`adjustHedge()` is **permissionless** and pilots on the **net effective short** (`effectiveShort = debt − idle token0`) versus the on-chain target. It corrects both directions without keeper-provided sizing. Ordinary drift requires same-direction confirmation over the tactical horizon, a minimum portfolio exposure and the four-hour on-chain cooldown; fading signals clear below the hysteresis boundary, and an eligible correction may be grouped with an imminent range action. Critical drift bypasses confirmation, grouping and cooldown. An urgent repair is enabled only below `HF_REPAIR_TRIGGER_BPS`, also bypasses those ordinary controls for safety and restores toward `HF_REPAIR_TARGET_BPS`. It earns a bounty only when at least `HF_REPAIR_BOUNTY_MIN_USD` of AAVE debt was actually repaid; smaller repairs still execute without a bounty.

**USDC reserve management** is integrated into the same call: when the health factor is above the governance target (`HF_REPAIR_TARGET_BPS`), `adjustHedge()` releases the surplus AAVE collateral and keeps it as USDC **on the HedgeManager itself** (never sent off-contract), so the reserve used for future adjustments is replenished on-chain without any separate keeper action.

Each cycle the keeper simulates `adjustHedge()` before sending. The contract enforces sizing and all safety checks atomically. After a confirmed transaction, the keeper rereads the live HF: remaining below 1.40 raises an immediate local critical incident, reinforced below 1.25 for Safe intervention. Community keeper alerts remain local-only; protocol Telegram credentials are never distributed.

`checkpointMarketState()`, `rebalance()` and `adjustHedge()` are permissionless. Any address can call them when the
contracts agree; no keeper allowlist or role is required.

Community keepers may checkpoint from the epoch boundary. Identities configured as protocol-bot callers are
rejected on-chain during the first 60 seconds for canonical checkpoints and normal eligible rebalances, then act
only as fallback. Critical `HF_REPAIR` remains immediately permissionless and is never delayed by that window.

## Setup

```bash
cp ../.env.example .env
# Fill in your values
npm install
chmod 600 .env
```

## Environment Variables

All Exposed keeper variables apply, with `STRATEGY_PROFILE=DELTA_NEUTRAL`, including the optional
`TREASURY_ADDRESS`. The DN keeper adds:

| Variable | Description | Default |
|---|---|---|
| `AAVE_HEDGE_MANAGER_ADDRESS` | AaveHedgeManager contract address | -- |
| `AAVE_HEALTH_WARN` | Health factor warning threshold, usually near `HF_REPAIR_TARGET_BPS` | `1.50` |
| `AAVE_HEALTH_DELEVERAGE` | Health factor critical/deleverage threshold | `1.25` |
| `AAVE_HEALTH_EMERGENCY` | Health factor emergency threshold | `1.15` |
| `HF_REPAIR_TARGET_BPS` | On-chain HF restoration target | `15000` |
| `HF_REPAIR_TRIGGER_BPS` | On-chain urgent repair trigger | `14000` |

### RPC Trust Model

Community keepers are permissionless and may use any RPC provider they choose. Liquid Hub does not require public keepers to use premium or MEV-protected RPCs. This is intentional: keeper safety is enforced on-chain by oracle/TWAP checks, oracle-floored `minAmountsOut`, cooldowns, caps, and DN hedge post-checks.

A poor RPC can hurt the keeper's own liveness or bounty capture rate, but it does not grant extra permissions and cannot bypass contract validation. Configure backup RPCs for reliability.

`CHECK_INTERVAL_MIN` defaults to `1` and must be greater than zero. Signed transactions are persisted before RPC failover. A pending or underpriced payload may be replaced at the same nonce with a 12.5% fee bump, bounded by the required `KEEPER_MAX_GAS_PRICE_GWEI`; nonce consumption requires RPC agreement. Pool and bridge processes derive one shared lock and journal from `chainId + signer address`; using the same local test key for Exposed, DN and bridge keepers is supported without nonce collisions when they share `KEEPER_STATE_DIR`. Public keepers with their own keys remain independent. `KEEPER_PENDING_TX_FILE` is accepted only as a deprecated one-time migration source; new journals always use the canonical filename. This community code never reads protocol Telegram or AWS Secrets Manager credentials. If the PauseController is missing or temporarily unreadable, only queued-deposit processing is skipped fail-closed. Strategy checkpoints, hedge maintenance and eligible rebalances remain active.

## Keeper Bounties

Paid in **USDC** by the Treasury to whoever sends the transaction. The DN pool has four bounties:

| Action | Bounty | Treasury flag / amount |
|--------|--------|------------------------|
| `rebalance()` | Keeper bounty | `keeperBountyEnabled` / `keeperBountyAmount()` |
| `processDepositPermissionless()` | Deposit bounty | `depositBountyEnabled` / `depositBountyAmount()` |
| `checkpointMarketState()` | Strategy checkpoint bounty | `strategyCheckpointBountyEnabled` / `strategyCheckpointBountyAmount()` |
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

MIT. This reference keeper may be used, modified, redistributed and operated in production without permission from
Liquid Hub.
