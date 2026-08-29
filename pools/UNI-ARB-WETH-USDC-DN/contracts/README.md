# UNI-ARB-WETH-USDC-DN Contracts (Delta Neutral Pool)

> **Public audit source.** Community keeper bots connect to the protocol's official
> **Arbitrum** deployment (chainId `42161`), whose current addresses are listed on the Contracts page:
> **https://liquidhub.app/docs#contracts-addresses**.
>
> The source is published for auditing and transparency. Always compare its release/commit with the source and
> bytecode verified for the address you intend to call; an address may change after a protocol redeployment.

## Overview

Delta-neutral-targeting strategy combining Uniswap V3 concentrated liquidity with an AAVE V3 hedge on Arbitrum. The pool reduces directional ETH exposure by maintaining a governed short WETH target against the long WETH exposure from the Uniswap V3 LP position. Hedge drift, AAVE interest, basis and execution conditions mean neutrality is a target rather than a guarantee.

## Strategy

1. **Liquidity provision**: WETH and USDC are deployed into a Uniswap V3 concentrated liquidity position, earning trading fees. A per-pool `RangeStrategyEngine` combines an analytical anchor, fixed multi-scenario evaluation and bounded online adaptation to publish an exact on-chain action and target range. A shallow spot-only range exit requires tactical-TWAP, elapsed-epoch or material-depth confirmation; deep and persistent range liveness remains independent. Every new asymmetric target must preserve the governed skew budget around the live execution tick, preventing a wide total range from hiding a price placed only a few ticks from one boundary.
2. **Hedge via AAVE V3**: token1 is supplied as collateral and token0 is borrowed to hedge LP exposure. The target is the net effective short (`debt - idle token0`) versus `hedgeTargetBps × token0InLP`. Permissionless `adjustHedge()` corrects over-hedge through an oracle-bounded flash-repay and under-hedge through atomic borrow, oracle/TWAP-bounded token0 sale and token1 supply. Dedicated permissionless `repairHealthFactor()` derives eligibility directly from live Aave account data, executes only the urgent repair and reverts rather than falling through to a normal hedge if another caller already restored the HF. No caller supplies the sizing. Ordinary drift requires same-direction confirmation, minimum material exposure and the four-hour on-chain cooldown, with a lower reset boundary and optional grouping with an imminent range action. Critical drift and urgent health-factor repair bypass those ordinary controls. The rebalance path is considered for hedge recovery only when direct adjustment remains infeasible for the configured persistence period and the replacement range reduces drift.
3. **Atomic withdrawals**: When a user withdraws, the vault settles proportionally with the hedge manager. If the LP yields less WETH than the outstanding AAVE debt, a flash loan covers the shortfall -- the contract borrows WETH, repays the AAVE debt, withdraws USDC collateral, swaps USDC back to WETH via Uniswap V3 to repay the flash loan, and returns the remaining USDC to the vault for the user.

## Contracts

All contracts from the standard pool are included, plus the hedge manager:

| Contract | Description |
|---|---|
| **MultiUserVault.sol** | Multi-user vault handling deposits and withdrawals, LP position lifecycle management, and commission collection. Integrates with AaveHedgeManager for atomic delta-neutral withdrawals (flash loan + swap settlement). Exposes `processDepositPermissionless()` — anyone can convert a queued deposit into LP liquidity (shares on the Chainlink oracle, swaps oracle-bounded, withdraw-lock during processing; on DN pools it also opens the AAVE hedge atomically and post-checks the result). |
| **AaveHedgeManager.sol** | AAVE V3 integration for delta-neutral hedging. Manages collateral supply, token0 borrowing, proportional settlement on withdrawals using flash loans, and health factor monitoring. Permissionless `adjustHedge()` handles normal corrections in both directions; dedicated `repairHealthFactor()` is restricted on-chain to urgent HF repair. `rebalance()` remains the bounded fallback for an under-hedge that cannot be repaired safely in place. |
| **interfaces/IAaveV3Pool.sol** | Minimal AAVE V3 Pool interface used by AaveHedgeManager (supply, borrow, repay, withdraw, flashLoanSimple, getUserAccountData). |
| **RangeStrategyEngine.sol** | Per-pool Delta Neutral decision engine. Adds hedge drift, borrow conditions and current/stressed health-factor constraints to the common analytical and multi-scenario decision. Critical hedge and health-factor safety paths are not delayed by shallow range-exit confirmation. |
| **RangeStrategyDnLib.sol** | Stateless linked library containing the bounded Delta-Neutral candidate search, live-tick skew validation, direct-hedge eligibility and canonical fee-rate normalization extracted from the engine to preserve EIP-170 deployment margins. It holds no funds, owner or mutable state. |
| **RangeManager.sol** | Executes the DEX position lifecycle and atomic engine-approved rebalances, including post-mint hedge synchronization for `RANGE_AND_HEDGE`. |
| **RangeOperations.sol** | Library for tick alignment, liquidity calculations, bounded swaps, valuation and fee accounting. |
| **SecureBotModule.sol** | Gnosis Safe module that restricts bot operations to a whitelist of approved function selectors. |
| **Treasury.sol** | Protocol fee collection contract. Pays keeper, deposit, strategy-checkpoint and hedge bounties (and the Phase 2 bridge bounty), and handles admin withdrawals with an enforced monthly cap. |
| **SequencerCheckedAggregator.sol** | L2 sequencer-checked Chainlink oracle wrapper. Implements `AggregatorV3Interface` as a transparent pass-through of the real Chainlink feed (same `decimals()`, same round tuple), but **reverts** when the Arbitrum sequencer is down or within the grace period after a restart (per the [Chainlink L2 Sequencer Feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds) recommendation). A production deployment points its oracle addresses to these wrappers, protecting every configured price consumer (RangeManager, Treasury, AaveHedgeManager). Immutable, stateless, view-only, holds no funds. |

## Emergency controls

Emergency recovery is callable directly by the dedicated Safe and is not exposed through the bot module.

- `EmergencyBurnPositions()` removes all liquidity from each tracked NFT and burns it without depending on
  Chainlink or tactical-TWAP availability. It performs no swap; principal and collected net fees remain in the
  `RangeManager` for recovery and hedge settlement.
- `EmergencyRecoverUser(user)` returns the user's exact pro-rata LP share and coordinates proportional AAVE
  settlement. Other users' queued deposits are excluded and remain reserved. Any reserve deficit or payment
  shortfall reverts atomically. A pending-only deposit can be recovered without burning a position first.
- The AAVE settlement deliberately retains its oracle, slippage and post-settlement health checks. An unavailable
  oracle therefore delays the DN settlement instead of bypassing protections around debt and collateral.
- For monitoring, `EmergencyUserRecovered` reports the exact Vault leg. Reconcile it with the HedgeManager
  `SettleProportional` event and ERC-20 `Transfer` logs for the user's complete DN recovery trace.
- `MultiUserVault.rescueToken()` can recover an unrelated token, or only the local token0/token1 excess above
  queued-deposit reserves. `RangeManager.rescueToken()` categorically rejects token0 and token1.

For users with active shares, the operational order is `EmergencyBurnPositions()` followed by one or more exact
`EmergencyRecoverUser(user)` calls.

## Build & verification

- **Compiler**: Solidity 0.8.36 — **Framework**: Foundry — **Settings**: `via_ir = true`, `optimizer_runs = 1`, `evm_version = "paris"` (the linked DN libraries and RangeManager remain close to the EIP-170 size limit, so the optimizer is tuned for deployment size over runtime -- appropriate for these low-frequency L2 operations).
- Each deployed contract is **verified on Arbiscan**: open the address from the Contracts page and check the "Contract" tab to confirm the on-chain bytecode matches this source.
- Before deployment, the official Forge script requires the DEX pool to answer `observe()` across the full
  canonical strategy history (`strategic horizon + epoch`). Increasing Uniswap V3 observation cardinality does
  not backfill history; a young pool must accumulate the required time before Liquid Hub deployment can proceed.

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Uniswap V3 Core](https://github.com/Uniswap/v3-core)
- [Uniswap V3 Periphery](https://github.com/Uniswap/v3-periphery)
- [AAVE V3 Protocol](https://github.com/aave/aave-v3-core)

## Key Difference from Standard Pool

The standard pool's `MultiUserVault` handles deposits and withdrawals directly against the Uniswap V3 position. In the delta neutral variant, the vault coordinates with `AaveHedgeManager` to atomically unwind both the LP position and the AAVE hedge during withdrawals. This ensures users receive their fair share of both LP assets and hedge collateral in a single transaction, using flash loans and Uniswap V3 swaps when necessary to cover any WETH shortfall.

## License

Files carrying `SPDX-License-Identifier: BUSL-1.1` are source-available under the repository
[Business Source License](../../../LICENSE). Production software may freely interact with the official deployments,
but the protected contracts may not be copied or redeployed in production before **2028-08-21**. They become
`GPL-2.0-or-later` on that date. The Aave interface and separately marked scripts and tests retain their stated MIT
license.
