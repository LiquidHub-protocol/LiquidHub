# Protocol Architecture

## Overview

Liquid Hub manages concentrated-liquidity DEX positions for multiple users via a vault system. Users deposit tokens, receive shares proportional to their contribution, and benefit from actively managed LP positions without needing to manage ranges themselves. The architecture is DEX-agnostic; each deployed pool documents the specific DEX it targets in its own folder.

## Core Flow

1. **Deposit** — Users deposit WETH + USDC into `MultiUserVault` (permissionless) and are queued; they receive shares representing their proportional ownership when the deposit is processed.
2. **Deposit processing (permissionless)** — Anyone can call `processDepositPermissionless()` to convert a queued deposit into LP liquidity in one atomic transaction (see Deposit Processing). Earns the deposit bounty.
3. **Delegation** — The vault delegates LP management to `RangeManager`, which handles all concentrated-liquidity position logic.
4. **Position Creation** — `RangeManager` creates concentrated-liquidity positions with **dynamic ranges computed 100% on-chain** (see Dynamic Range Calculation). The tuning parameters are set by a Gnosis Safe multisig; the math runs in the contract.
5. **Rebalance** — When price moves out of range, a keeper triggers a rebalance: burn the old position, swap tokens to rebalance the ratio, then mint a new position at the on-chain-computed range.
6. **Fee Collection** — Protocol fees (LP commissions) are collected during each rebalance and sent to the Treasury contract.
7. **Withdrawal** — Users withdraw by burning their shares. The vault burns the proportional LP position and returns the underlying tokens to the user.

---

## Deposit Processing (permissionless)

A user's `deposit()` is permissionless and queues the funds. Converting a queued deposit into LP liquidity is also permissionless via `processDepositPermissionless()` on the Vault — so the protocol can accept new capital without any privileged operator. In one atomic transaction it:

1. Refreshes the live Chainlink price cache, then requires the cache valid and fresh (`depositMaxCacheAge`).
2. Requires a position NFT to exist for community keepers; the first queued deposit can be processed through this atomic path only by the protocol bot/Safe path so the initial mint is created under the same oracle/TWAP/minOut guards.
3. Sets the rebalance lock (`_processingRebalance`) so any concurrent withdrawal reverts while funds are in transit.
4. Computes the deposit's shares on the **Chainlink oracle** (never the pool spot price → no share-inflation), transfers the funds to the RangeManager.
5. Executes the rebalancing swaps with **on-chain oracle-bounded `minAmountsOut`** (anti-MEV: a keeper-supplied min below the oracle floor reverts), each chunk capped by `initMultiSwapTvl`.
6. Adds the liquidity to the existing position or mints the first position when allowed, releases the lock, and pays the **deposit bounty** (best-effort try/catch).

It reverts if the queue is empty, the required position state is missing, or the cache is stale — so the bounty cannot be farmed. On a Delta-Neutral pool it opens the AAVE hedge atomically through `DnDepositLib` and then runs a strict on-chain hedge post-check; keepers never call AAVE directly.

---

## Dynamic Range Calculation (100% on-chain)

The range is computed entirely by `RangeManager` — no off-chain bot or database is involved in the math, so any keeper can reproduce it.

- `RangeManager` keeps a ring buffer of price snapshots. `recordPriceSnapshot()` is **permissionless** and stores a Chainlink price; the contract spaces snapshots regularly (`24h / maxSnapshotsPerDay`) and reverts if one is not yet due.
- On each mint/rebalance, the contract takes the pure high/low amplitude over the last `volatMoyDay` days — `(highest − lowest) / current price`, the real dispersion of the window independent of the instantaneous price — (trimming the `volatTrimDay` most extreme days), scales it by a governance multiplier `RANGE_MULTIPLICATOR`, and produces a symmetric range rounded up to the nearest `RANGE_STEP_BPS`. The final half-range is bounded per side by `RANGE_MIN_BPS` and `RANGE_MAX_BPS` (for example `100` means at least -1%/+1%, not 1% total width). The freshly computed range is applied on every rebalance (the position is recreated regardless), so it always tracks current volatility while staying within governance bounds.
- When `DYNAMIC_RANGE_ENABLED` is `false` (e.g. stablecoin pools), the range stays fixed at `RANGE_UP_BASE` / `RANGE_DOWN_BASE` (in basis points), configured by the multisig.

---

## Pool Types

### Standard Pool

- Directional exposure to both tokens (WETH and USDC).
- LP earns swap fees from the DEX pool.
- Simple deposit/withdraw lifecycle with no hedging.

### Delta Neutral (DN) Pool

- Same LP mechanism as a standard pool — positions are minted on the DEX and earn swap fees.
- Additionally uses an **AAVE V3 hedge** to neutralize directional price exposure:
  - USDC is supplied as AAVE collateral and WETH is borrowed against it.
  - The borrowed WETH offsets the LP's long WETH exposure. The hedge is piloted on the **net effective short** (`effectiveShort = debt − idle WETH`, idle on the HedgeManager and RangeManager) versus a target of `hedgeTargetBps × wethInLP` (100% = strict delta-neutral by default). The borrowed WETH is integrated into the LP (never left idle), so the AAVE debt is a real short covering the LP's WETH.
- **Permissionless hedge adjustment** — `adjustHedge()` (see Hedge Adjustment below) is callable by any keeper for a bounty: it corrects an **over-hedge** on-chain (repay) and **reverts on under-hedge** (an under-hedge is corrected by rebuilding the LP composition during a `rebalance()`, with an on-chain post-check).
- **USDC reserve** — a small USDC reserve is kept on the HedgeManager so adjustments don't have to touch the LP; it is **reconstituted on-chain inside `adjustHedge()`** when the health factor is above target (no separate action).
- **Net effect**: LP fees are earned without directional price exposure.
- **Withdrawals are atomic**: burn LP, flash loan settlement (if needed), return tokens to user in a single transaction.
- **Health Factor** is monitored continuously:
  - Warn threshold: 1.25
  - Deleverage threshold: 1.15
  - Emergency threshold: 1.05

#### Hedge Adjustment (`adjustHedge`, on-chain)

`adjustHedge()` is permissionless. It reads the LP position and the Chainlink price on-chain and pilots on the **net effective short** (`effectiveShort = debt − idle WETH`) versus the target (`hedgeTargetBps × wethInLP`). If **over-hedged** it repays the excess — the repay leg acquires WETH via an on-chain USDC→WETH swap bounded by the oracle (anti-MEV, `SWAP_SLIPPAGE_BPS`). If **under-hedged** it **reverts `UnderHedged`** — borrowing-and-holding would not change the net short, so an under-hedge is corrected by rebuilding the LP composition during a `rebalance()` (with an on-chain post-check), not here. It **reverts unless the drift vs the target exceeds the dynamic on-chain threshold** (`adjustHedgeBps()` returns the current effective threshold; internally it is `max(100 bps, rangeWidth / HEDGE_ADJUST_RANGE_DIVISOR)`) **and the on-chain cooldown (`hedgeAdjustCooldown`) has elapsed** — the cooldown applies to **all callers** (keepers and the protocol bot alike). After an over-hedge correction, surplus collateral above `RESERVE_HF_TARGET_BPS` is released as USDC on the HedgeManager to replenish the reserve, all in the same call. A successful over-hedge correction pays the **hedge bounty**.

---

## Multi-Swap System

Large swaps are split into smaller chunks to reduce price impact on the pool:

- Default chunk size: `INIT_MULTI_SWAP_TVL` (~$10k per swap).
- Chunks are executed inside the same atomic contract call for deposits/rebalances, with each chunk individually
  bounded by the Chainlink-derived `minAmountOut` floor.
- If the plan exceeds on-chain chunk, deposit or oracle limits, the transaction reverts and the bot/keepers retry
  later with a fresh plan.
- This mechanism reduces per-swap price impact while keeping the whole position update atomic.

---

## Rebalance Flow (Detailed)

The nominal flow is a single public transaction:

1. **`rebalance(swapAmountsIn, minAmountsOut, tokenIn, tokenOut)`** — refreshes prices, verifies oracle/TWAP,
   locks the vault, burns the existing NFT, executes the chunked swap plan, mints the new range, unlocks the
   vault and pays the keeper bounty if enabled.
2. If any check fails, the whole transaction reverts and the next bot/keeper cycle can retry with a fresh plan.

On DN pools, routine over-hedge corrections are adjusted independently and permissionlessly via `adjustHedge()` (see Hedge Adjustment). Severe under-hedge is handled by the permissionless `rebalance()` path: the LP composition is rebuilt and the transaction includes strict post-checks so a badly hedged result reverts atomically.

---

## Commission System

- **LP commissions** are collected on each rebalance (`TAUX_PRELEV_BPS`, default `1000` bps = 10% of earned fees).
- Commissions are sent to the Treasury contract in WETH + USDC.
- Treasury can convert any ERC-20 token to USDC via `swapToUSDC(tokenIn, fee, amountIn, minAmountOut)`.
- **Frontend swap commission**: a partner fee (`PARTNER_FEE_BPS=3`, i.e. 0.03%) is applied on frontend swaps and sent directly to the Treasury. The Treasury accepts any token received from these swaps.
