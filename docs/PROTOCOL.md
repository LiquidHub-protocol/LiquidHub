# Protocol Architecture

## Overview

Liquid Hub manages concentrated-liquidity DEX positions for multiple users via a vault system. Users deposit tokens, receive shares proportional to their contribution, and benefit from actively managed LP positions without needing to manage ranges themselves. The architecture is DEX-agnostic; each deployed pool documents the specific DEX it targets in its own folder.

## Core Flow

1. **Deposit** — Exposed pools accept token0, token1, or both according to the deployed pair; DN pools accept token1 collateral only. Funds are queued permissionlessly, and shares representing proportional ownership are minted when the deposit is processed.
2. **Deposit processing (permissionless)** — Anyone can call `processDepositPermissionless()` to convert a queued deposit into LP liquidity in one atomic transaction (see Deposit Processing). Earns the deposit bounty.
3. **Decision** — The pool's immutable-profile `RangeStrategyEngine` updates canonical market epochs and publishes a bounded on-chain action, reason code and exact target ticks.
4. **Execution** — The vault delegates LP execution to `RangeManager`, which creates or rebuilds the concentrated-liquidity position only after validating the current engine decision.
5. **Rebalance** — When `RANGE_REBALANCE` or `RANGE_AND_HEDGE` is eligible, a keeper can trigger one atomic transaction: burn the old position, execute bounded swaps, mint the exact validated range and, for DN, synchronize the hedge.
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

## Adaptive Range Intelligence (100% on-chain)

Each Liquid Hub pool has one stateful `RangeStrategyEngine`. Its DEX pool, strategy profile, owner/Vault, linked
RangeManager and optional AAVE HedgeManager are fixed and validated during deployment. It holds no user funds.

`checkpointMarketState()` is permissionless and advances at most one canonical epoch. The caller supplies no
price, forecast, score or target ticks. The engine reads the configured DEX and oracle state and combines:

1. an **Analytical controller**, which builds a bounded range anchor from canonical TWAP horizons, trend,
   volatility, fee intensity, uncertainty and profile constraints;
2. a **Multi-scenario optimizer**, which compares a fixed set of admissible tick-aligned candidates against the
   current position after potential fees, transition costs, inactivity and tail risk;
3. **Bounded online adaptation**, which gradually adjusts fixed estimator families from realized observations.
   Influence, losses and update speed are capped, and learning freezes on stale or incoherent data;
4. **False-start protection**, which prevents a shallow spot-only range exit from authorizing a rebalance until
   tactical-TWAP, elapsed-epoch or material-depth confirmation is present. Deep or persistent exits and critical
   Delta Neutral safety actions retain their independent paths.

Every new asymmetric candidate must keep its center displacement from the live execution tick inside the governed
`maxSkewBps` budget. This constraint also applies to Delta Neutral hedge-recovery candidates, so a wide total range
cannot conceal a live price placed only a few ticks from one boundary. The condition is checked again immediately
before execution.

The public decision enum is `NO_ACTION`, `CHECKPOINT_ONLY`, `RANGE_REBALANCE`, `HEDGE_ONLY`,
`RANGE_AND_HEDGE` or `HF_REPAIR`. A range exit is an input, not automatic authorization. The engine also considers
economic edge, uncertainty, cooldown and how deep or persistent the exit is. Ordinary DN hedge drift must persist in
the same direction over the tactical confirmation horizon and clears below a lower hysteresis boundary. It respects
the four-hour hedge cooldown and may be grouped with a range action already expected within the strategic horizon.
Critical hedge drift bypasses those ordinary controls. Critical DN health-factor repair remains an independent,
immediately permissionless safety path.

For a Stable profile, the engine also compares the independently configured oracle prices. A material divergence
activates a depeg guard and fails closed with no executable range change until the pair returns within the on-chain
safety boundary.

`previewDecision()` exposes the current epoch, validity, action, reason code, target ticks, edge, threshold and
decision hash. Execution calls revalidate the same result and current safety conditions. No keeper or protocol bot
can choose a different range. Governance may change only bounded parameters or temporarily select
`ANALYTIC_ONLY`; it cannot submit an arbitrary forecast or range.

---

## Pool Types

### Exposed Pool

- Directional exposure to both tokens (WETH and USDC).
- LP earns swap fees from the DEX pool.
- Simple deposit/withdraw lifecycle with no hedging.

### Delta Neutral (DN) Pool

- Same LP mechanism as an Exposed pool — positions are minted on the DEX and earn swap fees.
- Additionally uses an **AAVE V3 hedge** to neutralize directional price exposure:
  - USDC is supplied as AAVE collateral and WETH is borrowed against it.
  - The borrowed WETH offsets the LP's long WETH exposure. The hedge is piloted on the **net effective short** (`effectiveShort = debt − idle WETH`, idle on the HedgeManager and RangeManager) versus a target of `hedgeTargetBps × wethInLP` (100% = strict delta-neutral by default). The borrowed WETH is integrated into the LP (never left idle), so the AAVE debt is a real short covering the LP's WETH.
- **Permissionless hedge adjustment** — `adjustHedge()` (see Hedge Adjustment below) is callable by any keeper. It corrects over-hedge and under-hedge without caller-supplied sizing. Ordinary drift requires same-direction confirmation, hysteresis and the four-hour cooldown; it may be grouped with an imminent range action. Critical drift and an urgent HF repair below the on-chain trigger bypass those ordinary controls. A critical but safely executable hedge correction remains eligible near a range edge and does not remint the shared NFT. The atomic LP rebalance is considered for hedge recovery only when direct repair is genuinely infeasible, remains so for the configured persistence period, and the replacement range demonstrably reduces the drift. Bounties remain subject to on-chain eligibility.
- **USDC reserve** — a small USDC reserve is kept on the HedgeManager so adjustments don't have to touch the LP; it is **reconstituted on-chain inside `adjustHedge()`** when the health factor is above target (no separate action).
- **Net effect**: the strategy targets reduced token0 directional exposure while earning LP fees. Hedge drift, AAVE interest, basis, range composition and execution conditions mean neutrality is a target, not a guarantee.
- **Withdrawals are atomic**: burn LP, flash loan settlement (if needed), return tokens to user in a single transaction.
- **Health Factor** is monitored continuously. Optional keeper `AAVE_HEALTH_*` values only label local logs; all transaction acceptance, sizing and safety thresholds are enforced by the deployed contracts' on-chain configuration.

#### Hedge Adjustment (`adjustHedge`, on-chain)

`adjustHedge()` is permissionless. It reads the LP position and on-chain prices and pilots on the **net effective short** (`effectiveShort = debt − idle token0`) versus the target (`hedgeTargetBps × token0InLP`). It corrects both directions without caller-provided sizing. Ordinary drift must exceed the governed relative threshold and minimum portfolio exposure, remain in the same direction over the tactical confirmation horizon and wait for the four-hour on-chain cooldown. A lower hysteresis boundary clears fading signals, while an eligible correction may be grouped with an imminent range action. Critical drift bypasses confirmation, grouping and cooldown. Separately, when HF falls below `HF_REPAIR_TRIGGER_BPS`, an urgent repair also bypasses those ordinary controls and restores toward `HF_REPAIR_TARGET_BPS`. The urgent repair always remains executable, but it earns a bounty only when the AAVE debt actually repaid reaches `HF_REPAIR_BOUNTY_MIN_USD`; smaller repairs execute without a bounty.

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

On DN pools, routine drift in either direction is adjusted independently and permissionlessly via `adjustHedge()` (see Hedge Adjustment). A `RANGE_AND_HEDGE` decision rebuilds the LP composition and synchronizes the hedge in one atomic path with strict post-checks; a badly hedged result reverts atomically.

---

## Commission System

- **LP commissions** use the Vault's on-chain `commissionRate` (deployed from `TAUX_PRELEV_BPS`, with `1000` bps meaning 10% of earned LP fees, never principal). Fees are crystallized before growth deposits when needed, on withdrawals, during rebalances and before a commission-rate change.
- Commissions are sent to the pool Treasury in token0 + token1 (WETH + USDC for the pools published here).
- Each **pool Treasury is scoped to one DEX protocol and one blockchain**. It can convert configured pool-revenue tokens to USDC through that deployment's owner-only DEX route. For the current Uniswap V3 pools, `swapToUSDC(tokenIn, fee, amountIn, minAmountOut)` requires the fee tier registered on-chain from the pool `FEE`; callers cannot substitute another tier.
- **Frontend swap commissions are separate**: Velora partner fees are sent to a chain-specific `SwapTreasury`, not to an LP pool Treasury. Its owner-only Velora conversion path consolidates configured commission tokens to canonical USDC.
