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

## Keeper Bounties

Two distinct bounties can be earned by community keepers, paid in USDC directly from the Treasury contract on the same chain.

### 1. Rebalance Bounty (Phase 1)

- Paid for every successful `rebalance()` execution during the 2-minute community priority window.
- Default amount: **0.5 USDC** per rebalance (`KEEPER_BOUNTY_AMOUNT=500000`).
- Paid automatically at the end of the rebalance — no manual claim.
- The internal protocol bot waits 2 minutes (configurable on-chain via `keeperWindow`) before doing the rebalance itself, leaving the priority window open for community keepers.
- **Silent no-op**: if the bounty is disabled or the Treasury has insufficient funds, the rebalance still completes successfully (bounty payment is wrapped in a try/catch by the contract).

### 2. Bridge Bounty (Phase 2)

Once the protocol transitions to Phase 2 (admin withdrawal irreversibly disabled via `disableAdminWithdraw()`), the protocol fees accumulated in the Treasury must be sent to the StakingRewards contract on the staking chain. This is permissionless — anyone can trigger it.

- Paid for every successful `bridgeToStakers()` or `collectAndBridge()` call.
- Default amount: **2 USDC** per bridge (`BRIDGE_BOUNTY_AMOUNT=2000000`), designed to cover the Stargate cross-chain fees (~$1–3) plus a small incentive on top.
- The caller pays the cross-chain Stargate fees in native ETH via `msg.value`.
- The destination address is configured by the multisig and locked into the contract — the keeper cannot redirect funds.
- **Silent no-op** when disabled or insufficient balance, same pattern as the rebalance bounty.

#### Anti-drain protections (read carefully)

The bridge bounty includes two **on-chain rate-limiters** to prevent abuse:

1. **Cooldown** (default 6h): the bounty is paid at most once per cooldown window. Spamming bridges only earns one bounty per window.
2. **Minimum bridged amount** (default 50× the bounty): with a 2 USDC bounty, you must bridge ≥ 100 USDC in a single call to earn the bounty.

The bridge function is always callable, only the bounty payment is rate-limited. Read `bridgeBountyCooldown`, `bridgeBountyMinRatio`, `lastBridgeBountyAt` and the Treasury USDC balance on-chain before deciding to bridge.

#### Community priority window

The protocol's internal fallback bot runs the bridge **every 12h** while the on-chain cooldown is **6h**. This means each cooldown cycle has a **6-hour community-priority window**: any community keeper who calls the bridge during that window earns the bounty before the internal bot can. If no keeper acts within those 6h, the internal bot bridges as a fallback at the next 12h tick.

A reference Phase 2 keeper implementation is provided in [`/keepers/bridge-keeper`](../keepers/bridge-keeper/).

### Bounty payment guarantees

```
- Bounties are paid by the Treasury, not the user
- Both bounties cannot revert the underlying action (rebalance or bridge)
- Bounties are paid to msg.sender (whoever called the function)
- All payments emit events (KeeperBountyPaid, BridgeBountyPaid) for audit
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
