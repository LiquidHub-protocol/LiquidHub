# Liquid Hub Protocol

Decentralized liquidity management protocol.

## Overview

Liquid Hub automates range management: **dynamic ranges computed 100% on-chain**, permissionless rebalancing, multi-user vaults with fair share accounting, and protocol fee collection via an on-chain Treasury. It runs on concentrated-liquidity DEXs; the architecture is DEX-agnostic, and each deployed pool documents the specific DEX it targets in its own folder.

Two pool types:
- **Standard** — Directional LP exposure on a concentrated-liquidity DEX
- **Delta Neutral (DN)** — LP exposure hedged via AAVE V3 (supply USDC collateral, borrow WETH), with a permissionless on-chain hedge rebalance (`adjustHedge()`)

## Architecture

| Contract | Description |
|---|---|
| **MultiUserVault** | Multi-user vault managing deposits, withdrawals, share accounting, and LP position lifecycle |
| **RangeManager** | DEX price range management, on-chain swaps via the DEX router, 100% on-chain dynamic-range computation, permissionless rebalancing + price snapshots |
| **RangeOperations** | Library for tick/range calculations and the on-chain dynamic-range formula |
| **SecureBotModule** | Gnosis Safe module whitelisting specific function selectors for automated operations |
| **Treasury** | Protocol fee collection, keeper / metrics / hedge bounties (+ Phase 2 bridge bounty), admin withdrawals with monthly cap |
| **AaveHedgeManager** | *(DN only)* AAVE V3 hedge: governed hedge target, permissionless over- and under-hedge correction when on-chain safety checks pass, atomic-rebalance fallback, proportional flash-loan settlement, health-factor monitoring |
| **LiquidHubVaultRegistry** | Chain-local, read-only vault discovery directory for wallet and portfolio integrations |

## Directory Structure

```
pools/
├── UNI-ARB-WETH-USDC/          # Standard pool (WETH/USDC, Arbitrum)
│   ├── contracts/               # Solidity contracts
│   └── keeper-bot/              # Keeper bot, including public regression tests
│
├── UNI-ARB-WETH-USDC-DN/       # Delta Neutral pool (WETH/USDC, Arbitrum)
│   ├── contracts/               # Solidity contracts + AaveHedgeManager
│   └── keeper-bot/              # Keeper bot + hedge monitoring + regression tests
│
registry/                         # Network registries and generic wallet adapter
├── contracts/                    # LiquidHubVaultRegistry source
└── adapters/                     # Provider-neutral reader and integration guide

docs/                            # Protocol documentation
```

## Getting Started

To run a keeper bot, see [docs/KEEPER-GUIDE.md](docs/KEEPER-GUIDE.md).

The official deployment addresses for all Liquid Hub contracts are published on the
[Contracts page](https://liquidhub.app/docs#contracts-addresses). Always verify the selected network and copy
addresses from that page before interacting with a deployment.

## Security

In Phase 1, administrative functions are controlled by the configured Gnosis Safe multisig policy. The protocol bot is restricted to the selectors exposed by each pool's `SecureBotModule`; independent community keepers use only the contracts' guarded permissionless entry points. See [docs/SECURITY.md](docs/SECURITY.md) for details.

## Documentation

- [PROTOCOL.md](docs/PROTOCOL.md) — How the protocol works (standard + DN)
- [TREASURY.md](docs/TREASURY.md) — Treasury rules and monthly cap
- [KEEPER-GUIDE.md](docs/KEEPER-GUIDE.md) — How to run a keeper
- [SECURITY.md](docs/SECURITY.md) — Multisig powers and limitations
- [Vault Registry](registry/README.md) — Per-network vault discovery contract and deployment directory
- [Wallet Integration Guide](registry/adapters/README.md) — Generic position reader and provider integration contract

## License

[Business Source License 1.1](LICENSE)
