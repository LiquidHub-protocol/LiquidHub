# Keeper Guide

## What is a Keeper?

Anyone can run a keeper bot to monitor and execute rebalances for Liquid Hub pools. Keepers watch for out-of-range LP positions and trigger the rebalance process when needed. In return, keepers receive a bounty in USDC (if enabled by the protocol).

---

## How It Works

1. The keeper calls `getBotInstructions()` on the `RangeManager` contract.
2. If `needsRebalance` is `true`, the keeper executes the full rebalance sequence.
3. After a successful rebalance, the keeper receives a bounty from the Treasury (if enabled).

**Important**: Ranges are configured on-chain by the protocol's Gnosis Safe multisig. The keeper does **not** need to configure or calculate ranges — it only needs to execute the rebalance when instructed.

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

### Required

| Variable | Description |
|----------|-------------|
| `RPC_URL` | Arbitrum RPC endpoint |
| `RANGEMANAGER_ADDRESS` | RangeManager contract address |
| `VAULT_ADDRESS` | MultiUserVault contract address |
| `TOKEN0_ADDRESS` | Token0 address (e.g., WETH) |
| `TOKEN1_ADDRESS` | Token1 address (e.g., USDC) |
| `KEEPER_PRIVATE_KEY` | Private key of the keeper wallet |

### Optional

| Variable | Description | Default |
|----------|-------------|---------|
| `RPC_BACKUP_1` | Backup RPC endpoint 1 | — |
| `RPC_BACKUP_2` | Backup RPC endpoint 2 | — |
| `CHECK_INTERVAL_MIN` | Minutes between checks | 10 |
| `INIT_MULTI_SWAP_TVL` | Max USD per swap chunk | 10000 |

### Delta Neutral (DN) Additional Variables

| Variable | Description |
|----------|-------------|
| `AAVE_HEDGE_MANAGER_ADDRESS` | AaveHedgeManager contract address |
| `AAVE_HEALTH_WARN` | Health factor warn threshold (e.g., 1.25) |
| `AAVE_HEALTH_DELEVERAGE` | Health factor deleverage threshold (e.g., 1.15) |
| `AAVE_HEALTH_EMERGENCY` | Health factor emergency threshold (e.g., 1.05) |

---

## Keeper Bounty

Community keepers earn a bounty in USDC, paid directly from the Treasury contract.

- Paid for every successful `rebalance()` execution during the community priority window.
- Default amount: **0.5 USDC** per rebalance (`KEEPER_BOUNTY_AMOUNT=500000`).
- Paid automatically at the end of the rebalance — no manual claim.
- The internal protocol bot waits 2 minutes (configurable on-chain via `keeperWindow`) before doing the rebalance itself, leaving the priority window open for community keepers.
- **Silent no-op**: if the bounty is disabled or the Treasury has insufficient funds, the rebalance still completes successfully (bounty payment is wrapped in a try/catch by the contract).

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

- `executeSwap()` — Execute a swap during rebalance
- `mintInitialPosition()` — Mint a new LP position
- `burnPosition()` — Burn the current LP position

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
