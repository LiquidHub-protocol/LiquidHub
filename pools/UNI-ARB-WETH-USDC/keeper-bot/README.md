# Liquid Hub Keeper Bot - Standard Pool

Keeper bot for the Liquid Hub Standard Pool (UNI-ARB-WETH-USDC). This bot monitors the RangeManager contract and executes rebalances when the current liquidity position goes out of range.

## How It Works

The keeper bot follows a simple loop:

1. Calls `getBotInstructions()` on the RangeManager contract
2. If `isSnapshotDue()` is `true`, calls `recordPriceSnapshot()` to feed the on-chain range calculation (earns the metrics bounty)
3. If a deposit is queued and a position NFT exists, calls `processDepositPermissionless()` to convert one queued deposit into LP liquidity (earns the deposit bounty)
4. If `needsRebalance` is `true`, executes `rebalance()` (earns the keeper bounty)
5. Waits for the configured interval and repeats

All checks are independent: a cycle may record a snapshot, process a deposit, rebalance, any combination, or none. The snapshot step runs **before** the deposit/rebalance steps so they read a fresh Chainlink price.

### Rebalance Flow

When a rebalance is needed, the bot submits a single atomic transaction to `rebalance()` on the RangeManager. The contract performs all steps in one call:

1. **Lock vault** — prevents deposits/withdrawals during rebalance
2. **Burn old position** — removes liquidity and collects accrued fees
3. **Execute swaps** — rebalances token ratio for the new range. Large swaps are automatically split into N chunks ≤ `initMultiSwapTvl` (read from the contract).
4. **Mint new position** — creates a new position centered on the current price
5. **Unlock vault** — re-enables deposits/withdrawals
6. **Pay keeper bounty** — if bounty is enabled, USDC is sent to the keeper

Everything happens atomically: if any step fails, the whole transaction reverts and no partial state is left on-chain.

### Dynamic Range Calculation (100% on-chain)

The range is computed **entirely on-chain** by the RangeManager — the keeper does not provide any range value. The contract keeps a ring buffer of price snapshots and, on each mint/rebalance, derives a symmetric range from the high/low amplitude over `volatMoyDay` days (after trimming the `volatTrimDay` most extreme days), scaled by a governance multiplier and rounded to the nearest `rangeStepBps` (0.5%). Tuning parameters (`maxSnapshotsPerDay`, `volatMoyDay`, `volatTrimDay`, `rangeStepBps`, `rangeMultiplicatorBps`) live in `dynRangeConfig()` and are set by the Safe multisig.

Because the calculation is on-chain, **any keeper can reproduce it without the protocol's bot or database** — the keeper just feeds it price snapshots.

#### Recording snapshots (`recordPriceSnapshot`)

`recordPriceSnapshot()` is permissionless. It reads the Chainlink price and stores it in the ring buffer. The contract spaces snapshots regularly (`24h / maxSnapshotsPerDay`) and **reverts if a snapshot is not yet due** — so the keeper simply calls it whenever `isSnapshotDue()` returns `true` and treats a revert as "skip". A successful call pays the **metrics bounty**.

When `DYNAMIC_RANGE_ENABLED` is `false` (e.g. a stablecoin pool), the range stays fixed at the configured base and snapshots are not used.

#### Processing deposits (`processDepositPermissionless`)

A user's `deposit()` is permissionless and queues the funds. Converting a queued deposit into LP liquidity is also permissionless: `processDepositPermissionless()` on the Vault processes **one** queued deposit per call, atomically — it refreshes the oracle, computes shares on the Chainlink oracle, executes the rebalancing swaps, and adds the liquidity. A successful call pays the **deposit bounty**.

**Anti-MEV — keeper must supply oracle-floored `minAmountsOut`**: unlike `rebalance()` (where the keeper may pass `minOut = 0`), the deposit function **rejects any `minAmountsOut[i]` below an on-chain oracle floor**. The reference `processDeposit()` in `rebalancer.js` computes the floor from the Chainlink price (same formula the contract uses). It reverts if the queue is empty, no position NFT exists (the one-time initial mint is the protocol bot's job), or the oracle cache is stale — so the keeper just calls it when a deposit is pending and treats a revert as "skip".

### Permissionless

`rebalance()`, `processDepositPermissionless()` and `recordPriceSnapshot()` are fully permissionless — any address can call them when the contract agrees. No whitelisting or keeper role required.

## Setup

### 1. Install dependencies

```bash
cd keeper-bot
npm install
```

### 2. Configure environment

Copy the example environment file and fill in your values:

```bash
cp ../.env.example .env
```

Edit `.env` with the following variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `RPC_URL` | Yes | Primary Arbitrum RPC endpoint |
| `RPC_BACKUP_1` | No | Backup RPC endpoint |
| `RPC_BACKUP_2` | No | Second backup RPC endpoint |
| `KEEPER_PRIVATE_KEY` | Yes* | Private key for the keeper wallet (*not needed for check-only mode) |
| `RANGEMANAGER_ADDRESS` | Yes | RangeManager contract address |
| `VAULT_ADDRESS` | Yes | MultiUserVault contract address |
| `TREASURY_ADDRESS` | No | Treasury address (from the Contracts page). Lets the bot read the Treasury USDC balance and warn when a bounty would be skipped. Falls back to `vault.treasuryAddress()` if blank. |
| `TOKEN0_ADDRESS` | Yes | Token0 address (WETH) |
| `TOKEN1_ADDRESS` | Yes | Token1 address (USDC) |
| `TOKEN0_DECIMALS` | No | Token0 decimals (default: 18) |
| `TOKEN1_DECIMALS` | No | Token1 decimals (default: 6) |
| `CHECK_INTERVAL_MIN` | No | Check interval in minutes (default: 10) |
| `INIT_MULTI_SWAP_TVL` | No | Max USD value per swap chunk (default: 10000) |

### 3. Run the bot

**Active mode** (monitors and executes rebalances):

```bash
npm start
```

**Check-only mode** (reads status once, no transactions):

```bash
npm run check
```

## Keeper Bounties

Bounties are paid in **USDC** by the Treasury to whoever sends the transaction (`msg.sender`). Three bounties apply to this pool:

| Action | Bounty | Treasury flag / amount |
|--------|--------|------------------------|
| `rebalance()` | Keeper bounty | `keeperBountyEnabled` / `keeperBountyAmount()` |
| `processDepositPermissionless()` | Deposit bounty | `depositBountyEnabled` / `depositBountyAmount()` |
| `recordPriceSnapshot()` | Metrics bounty | `metricsBountyEnabled` / `metricsBountyAmount()` |

The bot displays the bounty amounts and the Treasury USDC balance on startup.

**Important — Treasury must be funded:** a bounty is only paid if the Treasury holds at least the bounty amount in USDC. If it is underfunded, the action **still succeeds on-chain** (the contract wraps the payout in `try/catch`) but no bounty is paid. Verify the Treasury balance on-chain (the address is listed on the protocol's Contracts page) before relying on bounty income — the bot logs a warning when the balance is insufficient.

## Requirements

- **Node.js 18+**
- **Funded wallet** — The keeper wallet needs ETH on Arbitrum for gas fees. Each rebalance is a single atomic transaction (the contract performs burn + swaps + mint internally).
- **No permission required** — `rebalance()` is public; any address can call it when a rebalance is needed.

## Security

The keeper bot is fully permissionless and operates with no special privileges:

- `rebalance()` and `recordPriceSnapshot()` are public functions — anyone can call them, but only when the contract agrees (a rebalance is needed, or a snapshot is due). Both revert otherwise.
- The keeper **cannot** access, transfer, or withdraw user funds
- The keeper **cannot** modify range parameters or pool configuration — it only *feeds* price snapshots; the range formula and its tuning parameters are governed by the Safe
- All privileged operations (range settings, fee parameters, emergency actions) are restricted to the Safe multisig
- Per-swap size is capped on-chain by `initMultiSwapTvl` to protect against slippage attacks

## Architecture

```
keeper-bot/
  src/
    keeper.js          # Main entry point and check loop
    rebalancer.js      # Rebalance execution logic (multi-step flow)
    utils/
      contracts.js     # Contract ABIs and factory
      rpc.js           # RPC provider pool with failover
```

## License

BUSL-1.1
