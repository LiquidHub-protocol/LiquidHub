# UNI-ARB-WETH-USDC Contracts (Exposed Pool)

> **Public audit source.** Community keeper bots connect to the protocol's official
> **Arbitrum** deployment (chainId `42161`), whose current addresses are listed on the Contracts page:
> **https://liquidhub.app/docs#contracts-addresses**.
>
> The source is published for auditing and transparency. Always compare its release/commit with the source and
> bytecode verified for the address you intend to call; an address may change after a protocol redeployment.

## Overview

Exposed Uniswap V3 liquidity management for the WETH/USDC pair on Arbitrum. Users deposit into a shared vault, while an on-chain strategy engine publishes bounded range decisions. Keepers can create canonical checkpoints, execute eligible rebalances and process queued deposits. Routine maintenance is permissionless after the controlled one-time initial mint.

## Contracts

| Contract | Description |
|---|---|
| **MultiUserVault.sol** | Multi-user vault handling deposits and withdrawals, LP position lifecycle management, and commission collection on earned fees. Exposes `processDepositPermissionless()` — anyone can convert a queued deposit into LP liquidity (shares on the Chainlink oracle, swaps oracle-bounded, withdraw-lock during processing). |
| **RangeStrategyEngine.sol** | Per-pool Exposed/Stable decision contract combining an analytical controller, fixed multi-scenario optimizer, bounded online adaptation and false-start protection. Holds no funds and cannot move liquidity; publishes the versioned action, reason code, exact target ticks, validity and decision hash that RangeManager revalidates before execution. A shallow spot-only range exit requires tactical-TWAP, elapsed-epoch or material-depth confirmation, while deep and persistent liveness paths remain independent. New asymmetric targets must keep the live execution tick inside the governed skew budget; Stable profiles additionally fail closed behind an oracle-based depeg guard. |
| **RangeManager.sol** | Executes the DEX position lifecycle and atomic, permissionless rebalances only after validating a fresh engine decision. |
| **RangeOperations.sol** | Library for tick alignment, liquidity calculations, bounded swaps, valuation and fee accounting. |
| **PauseController.sol** | Per-pool bounded circuit breaker for inflows, withdrawals and the deposit cooldown. Holds no funds and leaves documented strategy-maintenance and emergency-recovery paths available. |
| **SecureBotModule.sol** | Gnosis Safe module that restricts bot operations to a whitelist of approved function selectors, ensuring the bot can only call predefined vault/range functions. |
| **Treasury.sol** | Protocol fee collection contract. Pays keeper, deposit and strategy-checkpoint bounties (and the Phase 2 bridge bounty), and handles admin withdrawals with an enforced monthly cap. |
| **SequencerCheckedAggregator.sol** | L2 sequencer-checked Chainlink oracle wrapper. Implements `AggregatorV3Interface` as a transparent pass-through of the real Chainlink feed (same `decimals()`, same round tuple), but **reverts** when the Arbitrum sequencer is down or within the grace period after a restart (per the [Chainlink L2 Sequencer Feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds) recommendation). A production deployment points its oracle addresses to these wrappers, protecting every configured price consumer (RangeManager, Treasury). Immutable, stateless, view-only, holds no funds. |

## Emergency controls

Emergency recovery is callable directly by the dedicated Safe and is not exposed through the bot module.

- `EmergencyBurnPositions()` removes all liquidity from each tracked NFT and burns it without depending on
  Chainlink or tactical-TWAP availability. It performs no swap; principal and collected net fees remain in the
  `RangeManager` for recovery.
- `EmergencyRecoverUser(user)` then returns that user's exact pro-rata share. Other users' queued deposits are
  excluded from the calculation and remain reserved. Any reserve deficit or payment shortfall reverts the whole
  transaction, so shares cannot be cleared after a partial payment. A pending-only deposit can be recovered
  without burning a position first.
- `MultiUserVault.rescueToken()` can recover an unrelated token, or only the local token0/token1 excess above
  queued-deposit reserves. `RangeManager.rescueToken()` categorically rejects token0 and token1.

For users with active shares, the operational order is `EmergencyBurnPositions()` followed by one or more exact
`EmergencyRecoverUser(user)` calls.

## Build & verification

- **Compiler**: Solidity 0.8.36 — **Framework**: Foundry — **Settings**: `via_ir = true`, `optimizer_runs = 1`, `evm_version = "paris"`
- Each deployed contract is **verified on Arbiscan**: open the address from the Contracts page and check the "Contract" tab to confirm the on-chain bytecode matches this source.
- Before deployment, the official Forge script requires the DEX pool to answer `observe()` across the full
  canonical strategy history (`strategic horizon + epoch`). Increasing Uniswap V3 observation cardinality does
  not backfill history; a young pool must accumulate the required time before Liquid Hub deployment can proceed.

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Uniswap V3 Core](https://github.com/Uniswap/v3-core)
- [Uniswap V3 Periphery](https://github.com/Uniswap/v3-periphery)

## License

Files carrying `SPDX-License-Identifier: BUSL-1.1` are source-available under the repository
[Business Source License](../../../LICENSE). Production software may freely interact with the official deployments,
but the protected contracts may not be copied or redeployed in production before **2028-08-21**. They become
`GPL-2.0-or-later` on that date. Separately marked interfaces, scripts and tests retain their stated licenses.
