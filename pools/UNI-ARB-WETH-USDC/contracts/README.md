# UNI-ARB-WETH-USDC Contracts (Standard Pool)

> **⚠️ Already deployed — do NOT redeploy.** These contracts are live and verified on **Arbitrum** (chainId `42161`). Keeper bots connect to the **protocol's own deployed contracts**, whose addresses are listed on the Contracts page:
> **http://liquidhub.app/docs#contracts-addresses**.
>
> The source below is published **for auditing and transparency only** — it is the exact source verified on Arbiscan. There is no reason for a keeper to deploy its own copy; point your keeper `.env` at the official addresses above.

## Overview

Standard directional Uniswap V3 liquidity management for the WETH/USDC pair on Arbitrum. Users deposit into a shared vault, and keeper bots manage concentrated liquidity positions -- rebalancing price ranges, processing queued deposits and collecting fees automatically. All critical operations are permissionless (see the keeper-bot guide).

## Contracts

| Contract | Description |
|---|---|
| **MultiUserVault.sol** | Multi-user vault handling deposits and withdrawals, LP position lifecycle management, and commission collection on earned fees. Exposes `processDepositPermissionless()` — anyone can convert a queued deposit into LP liquidity (shares on the Chainlink oracle, swaps oracle-bounded, withdraw-lock during processing). |
| **RangeManager.sol** | Price range management with on-chain swaps via Uniswap V3. Computes the dynamic range 100% on-chain. Supports permissionless rebalancing and price snapshots triggered by keeper bots. |
| **RangeOperations.sol** | Library for tick calculations, range operations and the on-chain dynamic-range computation used by RangeManager. |
| **SecureBotModule.sol** | Gnosis Safe module that restricts bot operations to a whitelist of approved function selectors, ensuring the bot can only call predefined vault/range functions. |
| **Treasury.sol** | Protocol fee collection contract. Pays the keeper, deposit and metrics bounties (and the Phase 2 bridge bounty), and handles admin withdrawals with an enforced monthly cap. |
| **SequencerCheckedAggregator.sol** | L2 sequencer-checked Chainlink oracle wrapper. Implements `AggregatorV3Interface` as a transparent pass-through of the real Chainlink feed (same `decimals()`, same round tuple), but **reverts** when the Arbitrum sequencer is down or within the grace period after a restart (per the [Chainlink L2 Sequencer Feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds) recommendation). The deployed pool points its oracle addresses to wrappers, so **all** price consumers (RangeManager, Treasury) are protected without modifying those contracts. Immutable, stateless, view-only, holds no funds. |

## Build & verification

- **Compiler**: Solidity 0.8.19 — **Framework**: Foundry — **Settings**: `via_ir = true`, `optimizer_runs = 200`
- Each deployed contract is **verified on Arbiscan**: open the address from the Contracts page and check the "Contract" tab to confirm the on-chain bytecode matches this source.

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Uniswap V3 Core](https://github.com/Uniswap/v3-core)
- [Uniswap V3 Periphery](https://github.com/Uniswap/v3-periphery)
