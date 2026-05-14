# Liquid Hub Protocol

Decentralized liquidity management protocol.

## Overview

Liquid Hub automates range management: dynamic range setting, permissionless rebalancing, multi-user vaults with fair share accounting, and protocol fee collection via an on-chain Treasury.

Two branches:
- **Pools** — Automated LP management on Uniswap V3
  - **Standard** — Directional LP exposure
  - **Delta Neutral (DN)** — LP exposure hedged via AAVE V3 (supply USDC collateral, borrow WETH)
- **Trading** — Automated perpetual trading on GMX v2 with AI-driven signals

## Architecture

| Contract | Description |
|---|---|
| **MultiUserVault** | Multi-user vault managing deposits, withdrawals, share accounting, and LP position lifecycle |
| **RangeManager** | Uniswap V3 price range management, on-chain swaps via SwapRouter, permissionless rebalancing |
| **RangeOperations** | Library for tick/range calculations |
| **SecureBotModule** | Gnosis Safe module whitelisting specific function selectors for automated operations |
| **Treasury** | Protocol fee collection, dual bounty system (rebalance/closure + bridge), capped admin withdrawals (Phase 1), permissionless cross-chain distribution to stakers (Phase 2) |
| **AaveHedgeManager** | *(DN only)* AAVE V3 hedge: supply/borrow, flash loan settlement, health factor monitoring |
| **TradingVault** | *(Trading)* ERC-4626 USDC vault for GMX v2 perpetual trading with on-chain risk limits |
| **TradingBotModule** | *(Trading)* Safe module for trading bot — whitelists open/close/updateSL/updateTP |

## Directory Structure

```
pools/
├── UNI-ARB-WETH-USDC/          # Standard pool (WETH/USDC, Arbitrum)
│   ├── contracts/               # Solidity contracts
│   └── keeper-bot/              # Keeper bot (check & rebalance)
│
├── UNI-ARB-WETH-USDC-DN/       # Delta Neutral pool (WETH/USDC, Arbitrum)
│   ├── contracts/               # Solidity contracts + AaveHedgeManager
│   └── keeper-bot/              # Keeper bot + hedge monitoring
│
docs/                            # Protocol documentation (pools)

trading/
├── GMX-ARB/                     # GMX v2 perpetual trading (Arbitrum)
│   ├── contracts/               # TradingVault + TradingBotModule
│   └── keeper-bot/              # SL/TP/liquidation keeper
│
trading/docs/                    # Trading documentation
```

## Getting Started

To run a keeper bot, see [docs/KEEPER-GUIDE.md](docs/KEEPER-GUIDE.md).

For post-deployment Safe configuration, see [docs/SAFE-SETUP.md](docs/SAFE-SETUP.md).

## Security

All admin functions are controlled by a Gnosis Safe 2/3 multisig. The keeper bot can only execute whitelisted operations through the SecureBotModule. See [docs/SECURITY.md](docs/SECURITY.md) for details.

## Documentation

### Pools
- [PROTOCOL.md](docs/PROTOCOL.md) — How the protocol works (standard + DN)
- [TREASURY.md](docs/TREASURY.md) — Treasury rules, monthly cap, Phase 2 roadmap
- [KEEPER-GUIDE.md](docs/KEEPER-GUIDE.md) — How to run a keeper
- [SECURITY.md](docs/SECURITY.md) — Multisig powers and limitations
- [SAFE-SETUP.md](docs/SAFE-SETUP.md) — Post-deployment Safe commands with ABIs

### Trading
- [TRADING-PROTOCOL.md](trading/docs/TRADING-PROTOCOL.md) — GMX v2 trading system overview
- [TRADING-SECURITY.md](trading/docs/TRADING-SECURITY.md) — Trading security model
- [TRADING-KEEPER-GUIDE.md](trading/docs/TRADING-KEEPER-GUIDE.md) — Trading keeper bot guide
- [TRADING-SAFE-SETUP.md](trading/docs/TRADING-SAFE-SETUP.md) — Post-deployment Safe setup with ABIs

## License

[Business Source License 1.1](LICENSE)
