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

1. Reads `getBotInstructions()` and the pool's operational state.
2. Calls `isSnapshotDue()`; if `true`, calls `recordPriceSnapshot()` (the contract reverts if a snapshot is not yet due).
3. Reads `getPendingDepositsCount()`; if `> 0`, a position NFT exists, inflows are available and no rebalance is already due, calls `processDepositPermissionless()` to process one queued deposit atomically.
4. Refreshes the instructions and, if `needsRebalance` is `true`, executes the single atomic `rebalance()` transaction.
5. **(DN only)** Simulates and, when accepted by the contract, executes `adjustHedge()`; the DN reference keeper prioritizes this risk-maintenance check before the other actions.
6. After any successful eligible action, the bounty is paid from the Treasury if enabled and funded.

**Important — snapshots and action prices are separate**: `recordPriceSnapshot()` feeds the dynamic-range history and may update the stored range. It is not used as a standalone cache refresh for a later action. `rebalance()` and `processDepositPermissionless()` refresh and validate their own price cache atomically before moving funds. The keeper computes `minAmountsOut` from the Chainlink oracle floor for both deposits and rebalances; the contracts enforce that floor, so a zero or weaker minimum is rejected.

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

> **Contract addresses** — the official deployed addresses (RangeManager, Vault, Treasury, AaveHedgeManager) are listed on the protocol's Contracts page: **https://liquidhub.app/docs#contracts-addresses**. Always copy them from there; never guess or hardcode an address.

### Required

| Variable | Description |
|----------|-------------|
| `CHAINID` | Expected chain ID; every configured RPC is authenticated against it before use |
| `RPC_URL` | Arbitrum RPC endpoint |
| `RANGEMANAGER_ADDRESS` | RangeManager contract address (from the Contracts page) |
| `VAULT_ADDRESS` | MultiUserVault contract address (from the Contracts page) |
| `TOKEN0_ADDRESS` | Token0 address (e.g., WETH) |
| `TOKEN1_ADDRESS` | Token1 address (e.g., USDC) |
| `KEEPER_PRIVATE_KEY` | Private key of the keeper wallet |
| `KEEPER_MAX_GAS_PRICE_GWEI` | Local ceiling for initial and same-nonce replacement transactions |

### Optional

| Variable | Description | Default |
|----------|-------------|---------|
| `RPC_BACKUP_1` | Backup RPC endpoint 1 | — |
| `RPC_BACKUP_2` | Backup RPC endpoint 2 | — |
| `PAUSE_CONTROLLER_ADDRESS` | Used only to gate deposit processing; if absent/unreadable, deposits are skipped while maintenance continues | — |
| `TREASURY_ADDRESS` | Treasury address — lets the bot read the USDC balance and warn when a bounty would be skipped (falls back to `vault.treasuryAddress()`) | — |
| `KEEPER_STATE_DIR` | Shared signer lock/journal directory for processes using the same chain and key | `~/.liquidhub-keeper-state` |
| `CHECK_INTERVAL_MIN` | Minutes between checks; must be greater than 0 | 1 |
| `KEEPER_PRICE_CACHE_MAX_AGE_SEC` | Local age used to decide whether an action retry should first refresh and rebuild its plan; it is not an on-chain safety limit | 300 |

The swap-chunk ceiling is not configured by a community keeper. Before building a plan, the keeper reads `initMultiSwapTvl()` from the deployed `RangeManager`; the contract then enforces the same ceiling on-chain.

### RPC Trust Model

Community keepers are permissionless and may use any RPC provider they choose. Liquid Hub does not require public keepers to use premium or MEV-protected RPCs. This is intentional: keeper safety is enforced on-chain by oracle/TWAP checks, oracle-floored `minAmountsOut`, cooldowns, caps, and DN post-checks.

A poor RPC can hurt the keeper's own liveness or bounty capture rate, but it does not grant extra permissions and cannot bypass contract validation. Use `RPC_BACKUP_1` and `RPC_BACKUP_2` for reliability.

The reference keepers populate and sign each transaction once, then fail over sequentially by rebroadcasting only that exact raw transaction across the configured RPC endpoints. They never switch to an implicit public or premium tier. If PauseController state cannot be read, queued deposits are skipped fail-closed while snapshots, rebalances and DN hedge maintenance continue normally.

### Delta Neutral (DN) Additional Variables

| Variable | Description |
|----------|-------------|
| `AAVE_HEDGE_MANAGER_ADDRESS` | AaveHedgeManager contract address |
| `AAVE_HEALTH_WARN` | Local log/status warning threshold |
| `AAVE_HEALTH_DELEVERAGE` | Local log/status critical threshold |
| `AAVE_HEALTH_EMERGENCY` | Local log/status emergency threshold |

These three values only label keeper logs. They do not size transactions, trigger privileged deleveraging or replace the on-chain health-factor, drift, cooldown, oracle and TWAP checks enforced by `AaveHedgeManager`.

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

User assets remain in the protocol contracts: pending funds in the Vault, active liquidity and its NFT in the RangeManager/DEX position, and DN collateral/debt in the HedgeManager/AAVE integration. They never enter the keeper wallet, which only needs native gas funds.

---

## Gas Costs

- A typical rebalance costs **0.001–0.01 ETH** on Arbitrum.
- Multi-swap rebalances (large TVL) cost more because one atomic transaction performs several internal swap calls.
- Ensure your keeper wallet has sufficient ETH to cover gas.

---

## Monitoring

- **Healthy**: Logs show `"No action needed"` — the position is in range.
- **Rebalance triggered**: Logs show the rebalance steps being executed.
- **Errors**: Check logs for error messages. Common issues include insufficient gas, RPC failures, or slippage exceeding tolerance.
- Use backup RPCs (`RPC_BACKUP_1`, `RPC_BACKUP_2`) for reliability.

---

## Regression Tests

Each public `keeper-bot/test` directory is intentionally versioned. After `npm install`, run `npm test` to verify RPC chain authentication and failover, signed-transaction persistence, nonce coordination, gas ceilings, action retries, pause handling, and the absence of protocol-only Telegram, Tenderly or AWS secret integrations. These tests are part of the auditable keeper distribution and should be kept in forks and releases.
