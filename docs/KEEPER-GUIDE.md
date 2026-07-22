# Keeper Guide

## What is a Keeper?

Anyone can run a keeper bot to perform the protocol's permissionless actions for Liquid Hub pools. In return, keepers receive a bounty in USDC (if enabled and the Treasury is funded). There are four keeper actions:

- **Rebalance** an out-of-range LP position (`rebalance()`) — keeper bounty
- **Process a queued user deposit** (`processDepositPermissionless()`) that converts a pending deposit into LP liquidity — deposit bounty
- **Record a price snapshot** (`recordPriceSnapshot()`) that feeds the on-chain range calculation — metrics bounty
- **(Delta-Neutral only) Adjust the AAVE hedge** (`adjustHedge()`) — hedge bounty

---

## How It Works

Each cycle the keeper:

1. Calls `getBotInstructions()` on the `RangeManager`; if `needsRebalance` is `true`, executes `rebalance()`.
2. Reads `getPendingDepositsCount()`; if `> 0`, a position NFT exists, and the vault is not locked, calls `processDepositPermissionless()` to process one queued deposit (atomic; reverts if the queue is empty, no NFT exists for a community keeper, or the oracle cache is stale).
3. Calls `isSnapshotDue()`; if `true`, calls `recordPriceSnapshot()` (the contract reverts if a snapshot is not yet due).
4. **(DN only)** Tries `adjustHedge()`; it executes only if the hedge drift exceeds the on-chain threshold, otherwise it reverts (no-op).
5. After any successful action, the bounty is paid from the Treasury (if enabled).

**Important — oracle freshness**: the keeper records a price snapshot **before** rebalancing/processing deposits (it earns the metrics bounty). Note: `rebalance()` **does refresh the price cache itself** (refresh-and-validate guard at the top), so rebalance freshness no longer depends on this snapshot — keeping the order simply lets one cycle both snapshot and rebalance on a fresh price. `processDepositPermissionless()` also refreshes the oracle atomically on-chain and bounds swap outputs by the oracle (anti-MEV). The keeper must compute `minAmountsOut` from the Chainlink oracle floor for **both** deposits and rebalances (the contract enforces the floor on both paths — never pass 0).

**Important**: the range is computed **100% on-chain** by the `RangeManager` (high/low amplitude over N days, trimmed, scaled by a governance multiplier, rounded to a step). The keeper does **not** configure or calculate ranges — it only feeds price snapshots and executes rebalances. The hedge target and the deposit share count are likewise computed on-chain (on the Chainlink oracle).

---

## Setup

1. **Choose a pool** — Standard or Delta Neutral (DN). Each pool has its own `RangeManager` and `MultiUserVault` addresses.
2. **Copy `.env.example` to `.env`** and fill in the required values (see below).
3. **Fund a wallet** with ETH on Arbitrum for gas.
4. **Set `KEEPER_PRIVATE_KEY`** in your `.env` file.
5. **Install and run**:
   ```bash
   npm install
   npm start
   ```

---

## Check-Only Mode

To check pool status without executing any transactions:

```bash
npm run check
```

This prints the current pool state, whether a rebalance is needed, and the current position details.

---

## Environment Variables

> **Contract addresses** — the official deployed addresses (RangeManager, Vault, Treasury, AaveHedgeManager) are listed on the protocol's Contracts page: **http://liquidhub.app/docs#contracts-addresses**. Always copy them from there; never guess or hardcode an address.

### Required

| Variable | Description |
|----------|-------------|
| `RPC_URL` | Arbitrum RPC endpoint |
| `RANGEMANAGER_ADDRESS` | RangeManager contract address (from the Contracts page) |
| `VAULT_ADDRESS` | MultiUserVault contract address (from the Contracts page) |
| `TOKEN0_ADDRESS` | Token0 address (e.g., WETH) |
| `TOKEN1_ADDRESS` | Token1 address (e.g., USDC) |
| `KEEPER_PRIVATE_KEY` | Private key of the keeper wallet |

### Optional

| Variable | Description | Default |
|----------|-------------|---------|
| `RPC_BACKUP_1` | Backup RPC endpoint 1 | — |
| `RPC_BACKUP_2` | Backup RPC endpoint 2 | — |
| `TREASURY_ADDRESS` | Treasury address — lets the bot read the USDC balance and warn when a bounty would be skipped (falls back to `vault.treasuryAddress()`) | — |
| `CHECK_INTERVAL_MIN` | Minutes between checks; must be greater than 0 | 1 |
| `INIT_MULTI_SWAP_TVL` | Max USD per swap chunk | 10000 |

### RPC Trust Model

Community keepers are permissionless and may use any RPC provider they choose. Liquid Hub does not require public keepers to use premium or MEV-protected RPCs. This is intentional: keeper safety is enforced on-chain by oracle/TWAP checks, oracle-floored `minAmountsOut`, cooldowns, caps, and DN post-checks.

A poor RPC can hurt the keeper's own liveness or bounty capture rate, but it does not grant extra permissions and cannot bypass contract validation. Use `RPC_BACKUP_1` and `RPC_BACKUP_2` for reliability.

The reference keepers populate and sign each transaction once, then fail over sequentially by rebroadcasting only that exact raw transaction across the configured RPC endpoints. They never switch to an implicit public or premium tier. If PauseController state cannot be read, queued deposits are skipped fail-closed while snapshots, rebalances and DN hedge maintenance continue normally.

### Delta Neutral (DN) Additional Variables

| Variable | Description |
|----------|-------------|
| `AAVE_HEDGE_MANAGER_ADDRESS` | AaveHedgeManager contract address |
| `AAVE_HEALTH_WARN` | Health factor warn threshold (e.g., 1.40 when reserve target is 1.40) |
| `AAVE_HEALTH_DELEVERAGE` | Health factor critical/deleverage threshold (e.g., 1.25) |
| `AAVE_HEALTH_EMERGENCY` | Health factor emergency threshold (e.g., 1.15) |

---

## Keeper Bounties

Community keepers earn bounties in USDC, paid directly from the Treasury contract to whoever sends the transaction (`msg.sender`):

| Action | Bounty |
|--------|--------|
| `rebalance()` | Keeper bounty |
| `processDepositPermissionless()` | Deposit bounty |
| `recordPriceSnapshot()` | Metrics bounty |
| `adjustHedge()` (DN) | Hedge bounty |

> **Amounts** are published on the protocol's Decentralization page (https://liquidhub.app/docs#decentralization) and are set on-chain by the multisig. Read the live value on the Treasury contract (`keeperBountyAmount()`, `depositBountyAmount()`, …) before relying on it — never assume a fixed figure.

- Paid automatically at the end of the action — no manual claim.
- The internal protocol bot waits **1 minute** before doing the action itself, leaving the priority window open for community keepers.
- Anti-drain: `recordPriceSnapshot()` reverts unless a snapshot is due; `adjustHedge()` reverts unless the hedge drift exceeds the on-chain threshold **and** the on-chain cooldown (`hedgeAdjustCooldown`) has elapsed since the last adjustment.
- **Silent no-op**: if a bounty is disabled or the Treasury has insufficient USDC, the action still completes successfully (the payment is wrapped in a try/catch by the contract) — only the bounty is skipped. Set `TREASURY_ADDRESS` so the bot warns you when the Treasury is underfunded; verify the balance on-chain before relying on bounty income.

### Bounty payment guarantees

```
- The bounty is paid by the Treasury, not the user
- The bounty payment cannot revert the underlying rebalance
- The bounty is paid to msg.sender (whoever called the function)
- All payments emit events (KeeperBountyPaid) for audit
```

---

## Security

The keeper can only call **public functions** on the contracts:

- `rebalance()` — Execute an atomic rebalance when the position is out of range
- `processDepositPermissionless()` — Process one queued deposit when contract conditions allow it
- `recordPriceSnapshot()` — Feed the on-chain dynamic range calculation when a snapshot is due
- `adjustHedge()` — Delta-Neutral pools only, adjust the AAVE hedge when drift exceeds the on-chain threshold

The keeper **cannot**:

- Access or withdraw user funds
- Modify range parameters
- Perform any admin operations
- Change contract configuration

User funds are held in the vault contract and LP positions are owned by the vault. The keeper wallet only needs ETH for gas.

---

## Gas Costs

- A typical rebalance costs **0.001–0.01 ETH** on Arbitrum.
- Multi-swap rebalances (large TVL) will cost more due to multiple swap transactions.
- Ensure your keeper wallet has sufficient ETH to cover gas.

---

## Monitoring

- **Healthy**: Logs show `"No action needed"` — the position is in range.
- **Rebalance triggered**: Logs show the rebalance steps being executed.
- **Errors**: Check logs for error messages. Common issues include insufficient gas, RPC failures, or slippage exceeding tolerance.
- Use backup RPCs (`RPC_BACKUP_1`, `RPC_BACKUP_2`) for reliability.
