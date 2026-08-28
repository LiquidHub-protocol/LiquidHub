# Liquid Hub Keeper Bot - Exposed or Stable Pool

Reference keeper for a Liquid Hub Exposed or Stable pool. It reads the canonical decision from the pool's
`RangeStrategyEngine` and executes only the action authorized on-chain.

## How It Works

The keeper follows this loop:

1. Reads `previewDecision()` and `checkpointDue()` from `RangeStrategyEngine`.
2. If an epoch checkpoint is due, calls `checkpointMarketState()` without supplying prices, ticks or forecasts.
3. Reads the fresh canonical action and reason code.
4. If a deposit is queued and a position NFT already exists, calls `processDepositPermissionless()`.
5. Calls `rebalance(decisionHash, ...)` only for `RANGE_REBALANCE`; every other action is an explicit abstention.
6. Waits for the configured interval and repeats.

The one-time initial mint remains reserved to the protocol bot. Checkpoints, later deposits and accepted rebalances
are permissionless. A transaction is built only after the contract has returned a fresh decision.

### Rebalance Flow

When a rebalance is needed, the bot submits a single atomic transaction to `rebalance()` on the RangeManager. The contract performs all steps in one call:

1. **Lock vault** — prevents deposits/withdrawals during rebalance
2. **Burn old position** — removes liquidity and collects accrued fees
3. **Execute swaps** — rebalances token ratio for the new range. Large swaps are automatically split into N chunks ≤ `initMultiSwapTvl` (read from the contract).
4. **Mint new position** — creates the exact tick-aligned range validated by the strategy engine
5. **Unlock vault** — re-enables deposits/withdrawals
6. **Pay keeper bounty** — if bounty is enabled, USDC is sent to the keeper

Everything happens atomically: if any step fails, the whole transaction reverts and no partial state is left on-chain.

### Adaptive range intelligence (100% on-chain)

The keeper never computes or proposes a range. One immutable-profile `RangeStrategyEngine` per Liquid Hub pool
combines three bounded components:

- an **Analytical controller** builds a conservative range anchor from canonical on-chain observations;
- a **Multi-scenario optimizer** compares a fixed set of admissible ranges after transition costs and risk;
- **Bounded online adaptation** updates fixed expert families at canonical epochs without giving a caller discretion.

The engine returns an enum action, reason code, target ticks, epoch and `decisionHash`. `RangeManager.rebalance()`
recalculates and validates that decision before touching funds. An out-of-range position may therefore remain in
evaluation when the expected benefit does not yet exceed costs and safeguards; deep or persistent exits remain
covered by bounded liveness rules.

#### Canonical checkpoints (`checkpointMarketState`)

`checkpointMarketState()` is permissionless and callable only when `checkpointDue()` is true. Epoch boundaries and
observation horizons are fixed on-chain. The caller supplies no market value. A successful new epoch may receive
the **strategy checkpoint bounty**, at most once for that epoch and subject to Treasury limits.

Community keepers may checkpoint from the epoch boundary. Identities configured as protocol-bot callers are
rejected on-chain during the first 60 seconds of the epoch and can only act afterward as fallback. The same
contract-enforced priority applies to normal rebalances; it is not merely a timing convention in the bot code.

#### Processing deposits (`processDepositPermissionless`)

A user's `deposit()` is permissionless and queues the funds. Converting a queued deposit into LP liquidity is also permissionless: `processDepositPermissionless()` on the Vault processes **one** queued deposit per call, atomically — it refreshes the oracle, computes shares on the Chainlink oracle, executes the rebalancing swaps, and adds the liquidity. A successful call pays the **deposit bounty**.

**Anti-MEV — keeper must supply oracle-floored `minAmountsOut`**: both `rebalance()` and `processDepositPermissionless()` reject any `minAmountsOut[i]` below an on-chain oracle floor. The reference keeper computes the floor from the Chainlink price (same formula the contract uses). Deposit processing reverts if the queue is empty, no position NFT exists for a community keeper (the one-time initial mint is the protocol bot's job), or the oracle cache is stale — so the keeper just calls it when a deposit is pending and treats a revert as "skip".

### Permissionless

`checkpointMarketState()`, `rebalance()` and post-mint `processDepositPermissionless()` are permissionless. Any
address can call them when the contracts agree; no keeper allowlist or role is required.

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
chmod 600 .env
```

Edit `.env` with the following variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `RPC_URL` | Yes | Primary Arbitrum RPC endpoint |
| `RPC_BACKUP_1` | No | Backup RPC endpoint |
| `RPC_BACKUP_2` | No | Second backup RPC endpoint |
| `KEEPER_PRIVATE_KEY` | Yes* | Private key for the keeper wallet (*not needed for check-only mode) |
| `KEEPER_MAX_GAS_PRICE_GWEI` | Yes | Local maximum accepted for `gasPrice`, `maxFeePerGas` and same-nonce replacements. |
| `KEEPER_STATE_DIR` | No | Shared local signer-state directory. Defaults to `~/.liquidhub-keeper-state`. |
| `KEEPER_PENDING_TX_FILE` | No | Deprecated migration source for an older custom journal. New transactions always use the canonical `chainId + signer` journal under `KEEPER_STATE_DIR`. |
| `RANGEMANAGER_ADDRESS` | Yes | RangeManager contract address |
| `RANGE_STRATEGY_ENGINE_ADDRESS` | Yes | RangeStrategyEngine address for this Liquid Hub pool |
| `VAULT_ADDRESS` | Yes | MultiUserVault contract address |
| `STRATEGY_PROFILE` | Yes | `EXPOSED` or `STABLE`; checked against the engine's immutable profile |
| `TREASURY_ADDRESS` | No | Treasury address (from the Contracts page). Lets the bot read the Treasury USDC balance and warn when a bounty would be skipped. Falls back to `vault.treasuryAddress()` if blank. |
| `TOKEN0_ADDRESS` | Yes | Token0 address (WETH) |
| `TOKEN1_ADDRESS` | Yes | Token1 address (USDC) |
| `TOKEN0_DECIMALS` | No | Token0 decimals (default: 18) |
| `TOKEN1_DECIMALS` | No | Token1 decimals (default: 6) |
| `CHECK_INTERVAL_MIN` | No | Check interval in minutes (default: 1; must be greater than 0) |

The swap-chunk ceiling is not a keeper setting: the keeper reads `initMultiSwapTvl()` directly from the deployed RangeManager before building each atomic plan.

### RPC Trust Model

Community keepers are permissionless and may use any RPC provider they choose. Liquid Hub does not require public keepers to use premium or MEV-protected RPCs. This is intentional: keeper safety is enforced on-chain by oracle/TWAP checks, oracle-floored `minAmountsOut`, cooldowns, caps, and reverts.

A poor RPC can hurt the keeper's own liveness or bounty capture rate, but it does not grant extra permissions and cannot bypass contract validation. Configure `RPC_BACKUP_1` and `RPC_BACKUP_2` for reliability.

Pool and bridge keepers share the canonical signer lock and pending journal.
Using one key for several local test keepers is supported when they use the same
`KEEPER_STATE_DIR`; public keepers using their own keys remain independent. This
community code never reads protocol Telegram or AWS Secrets Manager credentials.

Signed transactions are populated and signed once, then the exact raw payload is persisted before RPC failover. If that payload remains pending or underpriced, the journal may replace it at the same nonce with a 12.5% fee bump, never above `KEEPER_MAX_GAS_PRICE_GWEI`. A nonce is considered consumed only after RPC agreement, so one faulty endpoint cannot discard the journal. Local processes derive one shared lock and journal from `chainId + signer address`, so the same test key can safely run several pool keepers without nonce collisions. Do not delete signer state while a transaction is unresolved. If `PAUSE_CONTROLLER_ADDRESS` is missing or temporarily unreadable, only queued-deposit processing is skipped fail-closed. Strategy checkpoints and eligible rebalances remain active.

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
| `checkpointMarketState()` | Strategy checkpoint bounty | `strategyCheckpointBountyEnabled` / `strategyCheckpointBountyAmount()` |

The bot displays the bounty amounts and the Treasury USDC balance on startup.

**Important — Treasury must be funded:** a bounty is only paid if the Treasury holds at least the bounty amount in USDC. If it is underfunded, the action **still succeeds on-chain** (the contract wraps the payout in `try/catch`) but no bounty is paid. Verify the Treasury balance on-chain (the address is listed on the protocol's Contracts page) before relying on bounty income — the bot logs a warning when the balance is insufficient.

## Requirements

- **Node.js 18+**
- **Funded wallet** — The keeper wallet needs ETH on Arbitrum for gas fees. Each rebalance is a single atomic transaction (the contract performs burn + swaps + mint internally).
- **No permission required** — `rebalance()` is public; any address can call it when a rebalance is needed.

## Security

The keeper bot is fully permissionless and operates with no special privileges:

- `rebalance()` and `checkpointMarketState()` are public functions, but both revert unless the canonical strategy state authorizes the transition.
- The keeper **cannot** access, transfer, or withdraw user funds
- The keeper **cannot** provide ticks, scores, forecasts, prices or strategy weights.
- Governance can only modify bounded strategy settings; it cannot submit an arbitrary range through the keeper path.
- All privileged operations (range settings, fee parameters, emergency actions) are restricted to the Safe multisig
- Per-swap size is capped on-chain by `initMultiSwapTvl` to protect against slippage attacks

## Architecture

```
keeper-bot/
  src/
    keeper.js          # Main entry point and check loop
    rebalancer.js      # Atomic rebalance and queued-deposit execution logic
    utils/
      contracts.js     # Contract ABIs and factory
      rpc.js           # RPC provider pool with failover
```

## License

MIT. This reference keeper may be used, modified, redistributed and operated in production without permission from
Liquid Hub.
