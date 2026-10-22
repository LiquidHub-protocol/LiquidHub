# Liquid Hub Protocol

Autonomous-execution liquidity protocol with published, bounded multisig emergency controls.

## Overview

Liquid Hub automates range management through **adaptive decisions computed 100% on-chain**, permissionless execution, multi-user vaults with fair share accounting, and protocol fee collection via an on-chain Treasury. It runs on concentrated-liquidity DEXs; the architecture is DEX-agnostic, and each deployed pool documents the specific DEX it targets in its own folder.

3 pool types:
- **Exposed** — Directional LP exposure on a concentrated-liquidity DEX
- **Stable** — Stable LP exposure on a concentrated-liquidity DEX
- **Delta Neutral (DN)** — LP exposure hedged via AAVE V3 (supply USDC collateral, borrow WETH), with a permissionless on-chain hedge rebalance (`adjustHedge()`)

## Architecture

| Contract | Description |
|---|---|
| **MultiUserVault** | Multi-user vault managing deposits, withdrawals, share accounting, and LP position lifecycle |
| **RangeStrategyEngine** | Per-pool decision contract combining an analytical controller, fixed multi-scenario optimizer, bounded online adaptation and false-start protection; holds no funds and publishes deterministic on-chain actions, reason codes, validity and exact target ticks |
| **RangeManager** | DEX position execution, bounded on-chain swaps and permissionless execution of fresh engine-approved rebalances |
| **RangeOperations** | Library for tick alignment, LP operations, swaps and strategy math |
| **ProtocolAccountingLib** | Oracle/TWAP reads, portfolio valuation, position accounting and deterministic settlement |
| **ProtocolSafetyLib** | Canonical execution checks, installation and bounded Safe emergency/protection policy |
| **AutonomousRevenueLib** | Shared fee accounting, protected bounty reserves, fixed USDC conversions and Stargate settlement |
| **PauseController** | Per-pool bounded circuit breaker for inflows, withdrawals and the deposit cooldown; holds no funds and leaves documented position-maintenance paths available |
| **SecureBotModule** | Immutable executor for guarded public operations, canonical progressive rebalances and bootstrap mint |
| **Treasury** | Fee-only accounting, isolated bounty reserves, public conversion/settlement and uncapped company withdrawals outside those reserves |
| **AaveHedgeManager** | *(DN only)* AAVE V3 hedge: sealed strategy with bounded incident risk protection, permissionless over- and under-hedge correction when on-chain safety checks pass, atomic-rebalance fallback, proportional flash-loan settlement, health-factor monitoring |
| **DnDepositLib / RangeStrategyDnLib** | *(DN only)* Stateless linked libraries for atomic deposit/hedge coordination and bounded Delta-Neutral strategy projection; hold no funds or mutable state |
| **SequencerCheckedAggregator** | L2 oracle wrapper that rejects price reads while the sequencer is unavailable or inside its configured recovery grace period |
| **LiquidHubVaultRegistry** | Chain-local, read-only vault discovery directory for wallet and portfolio integrations |

## Directory Structure

```
pools/
├── UNI-ARB-WETH-USDC/          # Exposed pool (WETH/USDC, Arbitrum)
│   ├── contracts/               # Solidity contracts
│   └── keeper-bot/              # Keeper bot, including public regression tests
│
├── UNI-ARB-WETH-USDC-DN/       # Delta Neutral pool (WETH/USDC, Arbitrum)
│   ├── contracts/               # Solidity contracts + AaveHedgeManager
│   └── keeper-bot/              # Keeper bot + hedge monitoring + regression tests
│
├── ... OTHER POOLS
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

Existing pool rules and bindings are sealed before deposits open. Ordinary operations are public under on-chain guards. The Safe retains only the disclosed, bounded incident and protection powers; the company installs new pools and withdraws earned revenue outside protected bounty reserves. See [operating specification](docs/AUTONOMOUS-PROTOCOL.md) and [security model](docs/SECURITY.md).

## Documentation

- [Operating specification](docs/AUTONOMOUS-PROTOCOL.md) — Sealed pools, bounded emergency powers and company revenue
- [Transition validation](docs/AUTONOMOUS-TRANSITION-VALIDATION.md) — Tests, production sizes and exact source synchronisation
- [PROTOCOL.md](docs/PROTOCOL.md) — How the protocol works (exposed + DN)
- [TREASURY.md](docs/TREASURY.md) — Fee accounting, protected reserves and public settlement
- [KEEPER-GUIDE.md](docs/KEEPER-GUIDE.md) — How to run a keeper
- [SECURITY.md](docs/SECURITY.md) — Multisig powers and limitations
- [Vault Registry](registry/README.md) — Per-network vault discovery contract and deployment directory
- [Wallet Integration Guide](registry/adapters/README.md) — Generic position reader and provider integration contract

## License

Liquid Hub uses a split license so public integrations remain permissionless while the core contract implementation
is protected against production clones for two years:

- **Core strategy contracts and SwapTreasury**: [BUSL-1.1](LICENSE) until **2028-08-21**, then
  `GPL-2.0-or-later`. Production software may freely interact with the official deployments, but copies and
  derivatives of the protected contracts may not be deployed in production before the change date.
- **Community keepers, bridge keeper, vault registry, wallet/indexer adapters, interfaces, scripts and tests**:
  [MIT](LICENSE-MIT), including unrestricted production use.

See [LICENSING.md](LICENSING.md) for the precise file-level policy. Neither license grants rights to the Liquid Hub
name or branding.
