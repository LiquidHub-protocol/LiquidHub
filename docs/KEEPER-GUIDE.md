# Keeper Guide

## What is a keeper?

Anyone can run a Liquid Hub community keeper. A keeper submits only permissionless transactions that the deployed
contracts independently validate. No allowlist, protocol account or private signal is required.

The supported pool actions are:

- execute an eligible range decision with `rebalance()`;
- process one queued post-mint deposit with `processDepositPermissionless()`;
- advance one due canonical strategy epoch with `checkpointMarketState()`;
- on Delta Neutral pools, execute an eligible hedge action with `adjustHedge()`.

A successful eligible action may receive a bounded USDC bounty from the pool Treasury. Bounty payment is
best-effort and never gives the caller access to user funds.

## Canonical decision loop

Each reference keeper follows the same sequence:

1. Authenticate every configured RPC against `CHAINID` and validate the configured contract topology.
2. Read `previewDecision()` and `checkpointDue()` from the pool's `RangeStrategyEngine`.
3. If an epoch is due, call `checkpointMarketState()` without supplying a price, forecast, score or target range.
4. Read the fresh enum action, reason code, epoch, validity and `decisionHash`.
5. If a post-mint deposit is queued and no incompatible maintenance action is pending, call
   `processDepositPermissionless()` for the head deposit.
6. For `RANGE_REBALANCE` or `RANGE_AND_HEDGE`, build the oracle-bounded swap plan and call
   `rebalance(decisionHash, ...)`.
7. On Delta Neutral pools, call `adjustHedge()` for `HEDGE_ONLY` or the dedicated `repairHealthFactor()` entrypoint for `HF_REPAIR`.
8. Explicitly abstain for every action that does not apply to that pool and repeat after the configured interval.

The one-time initial position mint remains reserved to the protocol bot. Strategy checkpoints, later deposits,
eligible rebalances and supported hedge actions are permissionless.

## Adaptive range intelligence

One immutable-profile `RangeStrategyEngine` is attached to each Liquid Hub pool. It holds no user funds and combines:

- an **Analytical controller** that builds a bounded range anchor from canonical on-chain observations;
- a **Multi-scenario optimizer** that compares a fixed set of admissible ranges after transition costs and risk;
- **Bounded online adaptation** that updates fixed estimator families at canonical epochs without caller discretion;
- **False-start protection** that requires tactical-TWAP, elapsed-epoch or material-depth confirmation before a
  shallow spot-only range exit can authorize a rebalance.

The engine returns `NO_ACTION`, `CHECKPOINT_ONLY`, `RANGE_REBALANCE`, `HEDGE_ONLY`, `RANGE_AND_HEDGE` or
`HF_REPAIR`, together with an exact target, reason code and `decisionHash`. A simple range exit does not authorize a
rebalance. The engine also evaluates economic edge, uncertainty, cooldown and how deep or persistent the exit is.
On Delta Neutral pools, ordinary drift must remain in the same direction over the tactical confirmation horizon,
clear the minimum portfolio-exposure filter and respect the four-hour on-chain cooldown. A lower hysteresis boundary
clears fading signals, and an eligible ordinary correction may be grouped with a range action already expected inside
the strategic horizon. Critical drift bypasses confirmation, grouping and cooldown and takes priority even near a range edge.
The engine may use a range change for hedge recovery only after direct adjustment remains infeasible for the
configured persistence period and the candidate range reduces the measured drift. Keepers cannot bypass this order.
Every new range, including a hedge-recovery candidate, must also preserve the governed skew budget around the live
execution tick. A candidate whose total width hides a near-edge price is not executable.

The keeper never computes or proposes target ticks. `RangeManager.rebalance()` revalidates the current decision,
live price and all execution guards before touching funds. A stale, superseded or mismatched decision reverts.

## Canonical checkpoints

`checkpointMarketState()` is callable only when `checkpointDue()` is true. Epoch boundaries and observation
horizons are fixed on-chain. The caller supplies no market value. A successful checkpoint can receive the strategy
checkpoint bounty at most once for that epoch, subject to the Treasury daily cap and available USDC.

Checkpoints and execution prices serve different purposes. The checkpoint advances strategy state. A deposit,
rebalance or hedge transaction independently refreshes and validates the prices required for its own asset-moving
operation.

## Deposits and rebalances

`processDepositPermissionless()` processes one FIFO deposit atomically. It requires an existing NFT for a community
keeper, refreshes the price cache, values shares against the configured oracle, executes bounded swaps, and adds
liquidity. It reverts if the queue is empty, inflows are paused or any execution guard fails.

`rebalance()` locks Vault accounting, burns the current NFT, executes the complete bounded swap plan, mints the
exact engine-approved tick range, records execution and unlocks the Vault in one transaction. For a Delta Neutral
`RANGE_AND_HEDGE` decision, the AAVE hedge is synchronized and post-checked atomically. Any failed step reverts the
entire transaction and bounty.

Both paths reject `minAmountsOut` below the on-chain oracle floor. Swap chunks are capped by
`RangeManager.initMultiSwapTvl()`; this cap is read on-chain and is not a keeper setting.

## Setup

1. Choose the Exposed/Stable or Delta Neutral keeper folder for the deployed pool.
2. Install dependencies in `keeper-bot` with `npm install`.
3. Copy the pool-level `.env.example` to `keeper-bot/.env` and set file mode `600`.
4. Copy official addresses from `https://liquidhub.app/docs#contracts-addresses`.
5. Fund the keeper address with the network's native gas token.
6. Run `npm run check` for a read-only cycle or `npm start` for active operation.

Never guess an address or reuse an address from another network.

## Required environment

| Variable | Purpose |
|---|---|
| `CHAINID` | Expected chain ID; every RPC is authenticated against it |
| `RPC_URL` | Primary keeper RPC |
| `RANGEMANAGER_ADDRESS` | Pool RangeManager |
| `RANGE_STRATEGY_ENGINE_ADDRESS` | Pool RangeStrategyEngine |
| `VAULT_ADDRESS` | Pool MultiUserVault |
| `STRATEGY_PROFILE` | Expected immutable profile: `EXPOSED`, `DELTA_NEUTRAL` or `STABLE` |
| `TOKEN0_ADDRESS`, `TOKEN1_ADDRESS` | Pool tokens |
| `KEEPER_PRIVATE_KEY` | Keeper signer, except in check-only mode |
| `KEEPER_MAX_GAS_PRICE_GWEI` | Local signing and replacement ceiling |

Common optional variables include `RPC_BACKUP_1`, `RPC_BACKUP_2`, `PAUSE_CONTROLLER_ADDRESS`,
`TREASURY_ADDRESS`, `CHECK_INTERVAL_MIN`, `KEEPER_PRICE_CACHE_MAX_AGE_SEC` and `KEEPER_STATE_DIR`. Delta Neutral
keepers also require `AAVE_HEDGE_MANAGER_ADDRESS`; local `AAVE_HEALTH_*` values only label logs and do not replace
on-chain thresholds.

## RPC and signer model

Community keepers may choose their own RPC providers. Safety does not trust an RPC response alone: the contracts
enforce oracle/TWAP checks, minimum outputs, cooldowns, caps, exact decisions and Delta Neutral post-checks. A poor
RPC can reduce a keeper's liveness or bounty capture rate but cannot grant extra permissions.

The reference keepers populate and sign once, persist the raw transaction, then rebroadcast that exact payload
sequentially through configured RPCs. Same-nonce replacement uses a bounded fee increase. Processes sharing one
chain and signer must share `KEEPER_STATE_DIR`; do not delete signer state while a transaction is unresolved.

If PauseController state is missing or unreadable, only queued deposits are skipped fail-closed. Strategy
checkpoints, eligible rebalances and DN safety maintenance remain available.

## Bounties and priority

| Action | Bounty |
|---|---|
| `rebalance()` | Keeper bounty |
| `processDepositPermissionless()` | Deposit bounty |
| `checkpointMarketState()` | Strategy checkpoint bounty |
| `adjustHedge()` (DN) | Hedge bounty |

Bounties are paid to `msg.sender` only after successful state transitions. Disabled or underfunded bounties are a
silent no-op and never revert useful work. Read current flags, amounts, caps and Treasury USDC balance on-chain.

For normal actions, the protocol bot waits one minute so community keepers have first execution opportunity.
Critical `HF_REPAIR` is immediately permissionless and is never delayed by hedge confirmation, grouping or cooldown. A checkpoint bounty is limited to one
due epoch and a daily cap. Normal hedge adjustment respects drift and cooldown rules; urgent repair has separate
health-factor and minimum-repair conditions.

## Security boundary

A keeper cannot:

- access, transfer or withdraw user funds to itself;
- supply arbitrary ticks, prices, forecasts, scores, debt targets or expert weights;
- bypass the decision epoch, oracle, TWAP, cooldown, slippage, cap, HF or post-check guards;
- call Safe-only governance or emergency functions through the permissionless path.

User assets remain in the Vault, RangeManager/DEX position and, for DN, HedgeManager/AAVE integration. The keeper
wallet holds only its own gas funds and any bounty it legitimately receives.

## Monitoring and tests

Logs expose the enum action and reason code. `NO_ACTION / OUT_OF_RANGE_EVALUATING` is a valid economic abstention;
it must not be relabeled as an execution failure. Unknown reason codes must be displayed safely rather than mapped
to an existing meaning.

Each `keeper-bot/test` directory is versioned. Run `npm test` after `npm install` to verify chain authentication,
failover, persisted signed transactions, nonce coordination, gas ceilings, action mapping, retries, pause handling
and the absence of protocol-only Telegram, Tenderly or AWS integrations.

## License

The reference keepers are MIT licensed and may be used, modified, redistributed and operated in production without
permission from Liquid Hub.
