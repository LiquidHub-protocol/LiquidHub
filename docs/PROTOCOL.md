# Protocol Architecture

## Overview

Liquid Hub manages concentrated-liquidity DEX positions for multiple users via a vault system. Users deposit tokens, receive shares proportional to their contribution, and benefit from actively managed LP positions without needing to manage ranges themselves. The architecture is DEX-agnostic; each deployed pool documents the specific DEX it targets in its own folder.

## Core Flow

1. **Deposit** — Standard pools accept token0, token1, or both according to the deployed pair; DN pools accept token1 collateral only. Funds are queued permissionlessly, and shares representing proportional ownership are minted when the deposit is processed.
2. **Deposit processing (permissionless)** — Anyone can call `processDepositPermissionless()` to convert a queued deposit into LP liquidity in one atomic transaction (see Deposit Processing). Earns the deposit bounty.
3. **Delegation** — The vault delegates LP management to `RangeManager`, which handles all concentrated-liquidity position logic.
4. **Position Creation** — `RangeManager` creates concentrated-liquidity positions with **dynamic ranges computed 100% on-chain** (see Dynamic Range Calculation). The tuning parameters are set by a Gnosis Safe multisig; the math runs in the contract.
5. **Rebalance** — When price moves out of range, a keeper triggers a rebalance: burn the old position, swap tokens to rebalance the ratio, then mint a new position at the on-chain-computed range.
6. **Fee Collection** — Accrued LP fees are crystallized before value-sensitive share operations and during position maintenance. The protocol commission is sent to the pool Treasury; the net remainder stays in the strategy and auto-compounds.
7. **Withdrawal** — Users withdraw by burning their shares. The vault burns the proportional LP position and returns the underlying tokens to the user.

---

## Deposit Processing (permissionless)

A user's `deposit()` is permissionless and queues the funds. Converting a queued deposit into LP liquidity is also permissionless via `processDepositPermissionless()` on the Vault — so the protocol can accept new capital without any privileged operator. In one atomic transaction it:

1. Refreshes the live Chainlink price cache, then requires the cache valid and fresh (`depositMaxCacheAge`).
2. Requires a position NFT to exist for community keepers; the first queued deposit can be processed through this atomic path only by the protocol bot/Safe path so the initial mint is created under the same oracle/TWAP/minOut guards.
3. Sets the rebalance lock (`_processingRebalance`) so any concurrent withdrawal reverts while funds are in transit.
4. Values the portfolio with the **Chainlink oracle** rather than the pool spot price, transfers the funds to the RangeManager, then mints shares from the actual post-action NAV increase so failed or partially consumed plans cannot over-credit a depositor.
5. Executes the rebalancing swaps with **on-chain oracle-bounded `minAmountsOut`** (anti-MEV: a keeper-supplied min below the oracle floor reverts), each chunk capped by `initMultiSwapTvl`.
6. Adds the liquidity to the existing position or mints the first position when allowed, releases the lock, and pays the **deposit bounty** (best-effort try/catch).

It reverts if the queue is empty, the required position state is missing, or live oracle validation fails. Deposit bounties are additionally bounded by a deposit-to-bounty ratio, per-Vault and per-keeper cooldowns, and a per-Vault daily cap. On a Delta-Neutral pool it opens the AAVE hedge atomically through `DnDepositLib` and then runs a strict on-chain hedge post-check; keepers never call AAVE directly.

---

## Dynamic Range Calculation (100% on-chain)

The range is computed entirely by `RangeManager` — no off-chain bot or database is involved in the math, so any keeper can reproduce it.

- `RangeManager` keeps a ring buffer of token0/token1 oracle-ratio snapshots. `recordPriceSnapshot()` is **permissionless** and stores `token0/USD ÷ token1/USD`, normalized to 8 decimals; this remains correct when token1 is not a stablecoin. The contract spaces snapshots regularly (`24h / maxSnapshotsPerDay`) and reverts if one is not yet due.
- When a due snapshot is recorded, the contract evaluates the high/low amplitude of observations inside the last `volatMoyDay` days — `(highest − lowest) / current price`. It removes the `volatTrimDay` highest and the same number of lowest observations, scales the result by `RANGE_MULTIPLICATOR`, and rounds it up to `RANGE_STEP_BPS`. At least two observations must remain after trimming; during cold start the previous/base range is retained. The computed symmetric half-range is stored on-chain and bounded per side by `RANGE_MIN_BPS` and `RANGE_MAX_BPS` (for example `100` means at least -1%/+1%, not 1% total width). Subsequent mint and rebalance actions use that stored range until a later due snapshot updates it.
- When `DYNAMIC_RANGE_ENABLED` is `false` (e.g. stablecoin pools), the range stays fixed at `RANGE_UP_BASE` / `RANGE_DOWN_BASE` (in basis points), configured by the Safe in Phase 1 or Timelock governance in Phase 2.

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
- **Permissionless hedge adjustment** — `adjustHedge()` (see Hedge Adjustment below) is callable by any keeper for a bounty. It corrects over-hedge and under-hedge without caller-supplied sizing; every path is atomic and guarded by oracle/TWAP, drift, cooldown and final AAVE health-factor checks. The atomic LP rebalance remains the fallback when direct under-hedge repair lacks safe HF headroom or market liquidity.
- **USDC reserve** — a small USDC reserve is kept on the HedgeManager so adjustments don't have to touch the LP; it is **reconstituted on-chain inside `adjustHedge()`** when the health factor is above target (no separate action).
- **Net effect**: the strategy targets reduced token0 directional exposure while earning LP fees. Hedge drift, AAVE interest, basis, range composition and execution conditions mean neutrality is a target, not a guarantee.
- **Withdrawals are atomic**: burn LP, flash loan settlement (if needed), return tokens to user in a single transaction.
- **Health Factor** is monitored continuously. Optional keeper `AAVE_HEALTH_*` values only label local logs; all transaction acceptance, sizing and safety thresholds are enforced by the deployed contracts' on-chain configuration.

#### Hedge Adjustment (`adjustHedge`, on-chain)

`adjustHedge()` is permissionless. It reads the LP position and on-chain prices and pilots on the **net effective short** (`effectiveShort = debt − idle token0`) versus the target (`hedgeTargetBps × token0InLP`). It corrects both directions without caller-provided sizing: a flash-assisted, oracle-bounded repay for over-hedge; or an atomic borrow, oracle/TWAP-bounded token0 sale and token1 collateral supply for under-hedge. It **reverts unless the drift exceeds the dynamic threshold** and the on-chain cooldown has elapsed; the cooldown applies to **all callers**. Large idle token0 balances cannot inflate the borrow path and are handled by the atomic rebalance fallback. A successful correction pays the **hedge bounty**.

---

## Multi-Swap System

Large swap plans are split into bounded chunks for deterministic on-chain validation and gas control:

- Chunk size: `initMultiSwapTvl()` from the deployed `RangeManager` (configured on-chain; keepers do not supply a separate limit).
- Chunks are executed inside the same atomic contract call for deposits/rebalances, with each chunk individually
  bounded by the Chainlink-derived `minAmountOut` floor.
- If the plan exceeds on-chain chunk, deposit or oracle limits, the transaction reverts and the bot/keepers retry
  later with a fresh plan.
- All chunks remain in one atomic transaction, so the pool does not recover between chunks. Chunking is not
  presented as a substitute for market liquidity. The oracle/TWAP floors protect funds; when current liquidity
  cannot execute the complete plan safely, the atomic transaction reverts and the queued deposit or rebalance is
  retried in a later cycle instead of accepting extra slippage.

---

## Rebalance Flow (Detailed)

The nominal flow is a single public transaction:

1. **`rebalance(swapAmountsIn, minAmountsOut, tokenIn, tokenOut)`** — refreshes prices, verifies oracle/TWAP,
   locks the vault, burns the existing NFT, executes the chunked swap plan, mints the new range, unlocks the
   vault and pays the keeper bounty if enabled.
2. If any check fails, the whole transaction reverts and the next bot/keeper cycle can retry with a fresh plan.

On DN pools, routine drift in either direction is adjusted independently and permissionlessly via `adjustHedge()` (see Hedge Adjustment). If a direct under-hedge repair cannot preserve the configured AAVE health factor, the permissionless `rebalance()` path rebuilds the LP composition with strict post-checks; a badly hedged result reverts atomically.

---

## Commission System

- **LP commissions** use the Vault's on-chain `commissionRate` (deployed from `TAUX_PRELEV_BPS`, with `1000` bps meaning 10% of earned LP fees, never principal). Fees are crystallized before growth deposits when needed, on withdrawals, during rebalances and before a commission-rate change.
- Commissions are sent to the pool Treasury in token0 + token1 (WETH + USDC for the pools published here).
- Each **pool Treasury is scoped to one DEX protocol and one blockchain**. It can convert configured pool-revenue tokens to USDC through that deployment's owner-only DEX route. For the current Uniswap V3 pools, `swapToUSDC(tokenIn, fee, amountIn, minAmountOut)` requires the fee tier registered on-chain from the pool `FEE`; callers cannot substitute another tier.
- **Frontend swap commissions are separate**: Velora partner fees are sent to a chain-specific `SwapTreasury`, not to an LP pool Treasury. Its owner-only Velora conversion path consolidates configured commission tokens to canonical USDC.
