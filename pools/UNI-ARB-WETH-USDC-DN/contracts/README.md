# UNI-ARB-WETH-USDC-DN Contracts (Delta Neutral Pool)

> **⚠️ Already deployed — do NOT redeploy.** These contracts are live and verified on **Arbitrum** (chainId `42161`). Keeper bots connect to the **protocol's own deployed contracts**, whose addresses are listed on the Contracts page:
> **http://liquidhub.app/docs#contracts-addresses**.
>
> The source below is published **for auditing and transparency only** — it is the exact source verified on Arbiscan. There is no reason for a keeper to deploy its own copy; point your keeper `.env` at the official addresses above.

## Overview

Delta neutral strategy combining Uniswap V3 concentrated liquidity with an AAVE V3 hedge on Arbitrum. This pool neutralizes directional ETH exposure by maintaining a short WETH position on AAVE that offsets the long WETH exposure from the Uniswap V3 LP position.

## Strategy

1. **Liquidity provision**: WETH and USDC are deployed into a Uniswap V3 concentrated liquidity position, earning trading fees. The range is computed **100% on-chain** by RangeManager (high/low amplitude over N days, trimmed, scaled by a governance multiplier, rounded to a step).
2. **Hedge via AAVE V3**: token1 is supplied as collateral and token0 is borrowed to hedge LP exposure. The target is the net effective short (`debt - idle token0`) versus `hedgeTargetBps × token0InLP`. Permissionless `adjustHedge()` corrects over-hedge through an oracle-bounded flash-repay and under-hedge through atomic borrow, oracle/TWAP-bounded token0 sale and token1 supply. No caller supplies the sizing; cooldown, drift and health-factor checks are enforced on-chain. The rebalance path remains the bounded fallback when large idle balances or market conditions prevent a direct hedge adjustment.
3. **Atomic withdrawals**: When a user withdraws, the vault settles proportionally with the hedge manager. If the LP yields less WETH than the outstanding AAVE debt, a flash loan covers the shortfall -- the contract borrows WETH, repays the AAVE debt, withdraws USDC collateral, swaps USDC back to WETH via Uniswap V3 to repay the flash loan, and returns the remaining USDC to the vault for the user.

## Contracts

All contracts from the standard pool are included, plus the hedge manager:

| Contract | Description |
|---|---|
| **MultiUserVault.sol** | Multi-user vault handling deposits and withdrawals, LP position lifecycle management, and commission collection. Integrates with AaveHedgeManager for atomic delta-neutral withdrawals (flash loan + swap settlement). Exposes `processDepositPermissionless()` — anyone can convert a queued deposit into LP liquidity (shares on the Chainlink oracle, swaps oracle-bounded, withdraw-lock during processing; on DN pools it also opens the AAVE hedge atomically and post-checks the result). |
| **AaveHedgeManager.sol** | AAVE V3 integration for delta-neutral hedging. Manages collateral supply, token0 borrowing, proportional settlement on withdrawals using flash loans, and health factor monitoring. Permissionless `adjustHedge()` handles both directions atomically when the configured HF can be preserved; `rebalance()` remains the bounded fallback for an under-hedge that cannot be repaired safely in place. |
| **interfaces/IAaveV3Pool.sol** | Minimal AAVE V3 Pool interface used by AaveHedgeManager (supply, borrow, repay, withdraw, flashLoanSimple, getUserAccountData). |
| **RangeManager.sol** | Price range management with on-chain swaps via Uniswap V3. Computes the dynamic range 100% on-chain. Supports permissionless rebalancing and price snapshots triggered by keeper bots. |
| **RangeOperations.sol** | Library for tick calculations, range operations and the on-chain dynamic-range computation used by RangeManager. |
| **SecureBotModule.sol** | Gnosis Safe module that restricts bot operations to a whitelist of approved function selectors. |
| **Treasury.sol** | Protocol fee collection contract. Pays the keeper, deposit, metrics and hedge bounties (and the Phase 2 bridge bounty), and handles admin withdrawals with an enforced monthly cap. |
| **SequencerCheckedAggregator.sol** | L2 sequencer-checked Chainlink oracle wrapper. Implements `AggregatorV3Interface` as a transparent pass-through of the real Chainlink feed (same `decimals()`, same round tuple), but **reverts** when the Arbitrum sequencer is down or within the grace period after a restart (per the [Chainlink L2 Sequencer Feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds) recommendation). The deployed pool points its oracle addresses to wrappers, so **all** price consumers (RangeManager, Treasury, AaveHedgeManager) are protected without modifying those contracts. Immutable, stateless, view-only, holds no funds. |

## Build & verification

- **Compiler**: Solidity 0.8.19 — **Framework**: Foundry — **Settings**: `via_ir = true`, `optimizer_runs = 1` (the DN RangeManager carries the most logic and is close to the EIP-170 size limit, so the optimizer is tuned for size over runtime — fine for low-frequency calls on an L2).
- Each deployed contract is **verified on Arbiscan**: open the address from the Contracts page and check the "Contract" tab to confirm the on-chain bytecode matches this source.

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Uniswap V3 Core](https://github.com/Uniswap/v3-core)
- [Uniswap V3 Periphery](https://github.com/Uniswap/v3-periphery)
- [AAVE V3 Protocol](https://github.com/aave/aave-v3-core)

## Key Difference from Standard Pool

The standard pool's `MultiUserVault` handles deposits and withdrawals directly against the Uniswap V3 position. In the delta neutral variant, the vault coordinates with `AaveHedgeManager` to atomically unwind both the LP position and the AAVE hedge during withdrawals. This ensures users receive their fair share of both LP assets and hedge collateral in a single transaction, using flash loans and Uniswap V3 swaps when necessary to cover any WETH shortfall.
