# Liquid Hub Vault Registry

`LiquidHubVaultRegistry` is the chain-local discovery directory for Liquid Hub vaults. One registry is deployed per
supported EVM blockchain and shared by every Liquid Hub pool on that chain.

The registry exists so wallets and portfolio indexers can discover Liquid Hub vaults without maintaining a hardcoded
list of individual pool addresses. It does not hold funds, account for user positions or receive permissions on a
registered vault.

## Where to find registry addresses

The official human-readable registry addresses, grouped by blockchain, are published at
[https://liquidhub.app/docs#contracts-addresses](https://liquidhub.app/docs#contracts-addresses) under
**Network Vault Registries**. Each
network entry shows its chain ID, deployment status, registry address and block-explorer link. Use this production URL,
not a local development address, before interacting with a registry.

Machine-readable deployment metadata is published in [deployments.json](deployments.json) for wallet and portfolio
integrations. A `pending` entry with a `null` address is intentionally not a deployment and must never be queried as
one. Integrators should require the address, chain ID and deployed status to agree with the Contracts page and verify
the contract on the linked block explorer.

Planned networks may be declared in the manifest before deployment so providers can review the multichain scope with
the shared adapter. Activation is deliberately fail-closed: an integration must ignore every entry unless `status` is
`deployed`, `registryAddress` is a valid non-zero address and the on-chain registry reports the same chain ID. Adding a
verified address may still require a provider-specific configuration review; the manifest does not bypass a wallet's
own release or security process.

| Network | Chain ID | Registry | Status |
|---|---:|---|---|
| Arbitrum | 42161 | Pending deployment | Pending |
| Base | 8453 | Pending deployment | Pending |
| Optimism | 10 | Pending deployment | Pending |
| Polygon | 137 | Pending deployment | Pending |
| BNB Smart Chain | 56 | Pending deployment | Pending |
| Unichain | 130 | Pending deployment | Pending |

## Source

- Contract: [contracts/src/LiquidHubVaultRegistry.sol](contracts/src/LiquidHubVaultRegistry.sol)
- Generic wallet reader: [adapters/core/reference-adapter.js](adapters/core/reference-adapter.js)
- Wallet integration guide: [adapters/README.md](adapters/README.md)

The production deployment project and administrative scripts remain environment-specific. This public directory
contains the exact registry contract source and the provider-neutral read path required for independent review and
wallet integration.

## Build profile

The registry deployment build is pinned to Solidity `0.8.36`, with the optimizer enabled for 200 runs, the Paris EVM
target, `via_ir = false`, `bytecode_hash = "none"` and `cbor_metadata = false`. These settings describe the published
source release. For a deployed registry address, integrators must verify the compiler and build settings on the block
explorer linked from the Liquid Hub Contracts page.

## Registry record

Each `VaultRecord` contains:

- the Liquid Hub vault and its bound `RangeManager`;
- the underlying DEX pool and token pair;
- public protocol and strategy identifiers;
- the supported vault interface version;
- registration and update block numbers;
- the active or inactive status.

The registry stores no wallet address, user shares, balances, NAV snapshot or fee history. Those values remain in each
vault and are read live by an adapter or indexer.

## Registration validation

Only the registry owner can register a vault. Production ownership is assigned to the Liquid Hub Safe or governance
contract. Before accepting a record, `registerVault` reads the candidate contracts and verifies that:

1. the vault, RangeManager, DEX pool and both tokens contain bytecode;
2. the vault exposes `rangeManager()`, `token0()`, `token1()` and `totalShares()`;
3. the RangeManager points back to the same vault;
4. the RangeManager and DEX pool expose the same ordered token pair;
5. protocol, strategy and interface-version metadata are non-empty.

Registration emits `VaultRegistered`. Metadata changes emit `VaultMetadataUpdated`, and retirement or reactivation
emits `VaultStatusChanged`.

## Administrative surface

The owner can perform only registry metadata operations:

- `registerVault(vault, protocolId, strategyId, interfaceVersion)`;
- `updateVaultMetadata(vault, protocolId, strategyId, interfaceVersion)`;
- `setVaultActive(vault, active)`;
- two-step ownership transfer inherited from `Ownable2Step`.

Ownership renunciation is disabled. The registry cannot transfer vault assets, mint or burn shares, rebalance a pool,
change pool risk settings or block user deposits and withdrawals.

## Read interface

Adapters can use:

- `REGISTRY_VERSION()` and `deploymentChainId()` to authenticate compatibility and chain;
- `vaultCount()` and `getVaults(offset, limit)` for bounded discovery;
- `getVault(vault)` and `isRegistered(vault)` for direct lookup;
- `activeVaultCount()` and each record's `active` flag for lifecycle state.

Pages are limited to 100 records. Inactive entries remain addressable so indexes are stable and historical records do
not silently change position.

## Position valuation

The registry is only the first discovery step. For each active vault, an adapter reads the user's shares and the live
vault accounting values:

```text
user value = getCurrentPortfolioValue() * userInfo(user).shares / totalShares()
```

This avoids duplicated accounting. A user's value can change because of market prices, generated fees, range actions
or hedge adjustments even when that user makes no transaction, so storing position values in the registry would be
stale and unsafe.

## Versioning

Registry version 1 supports vault interface version 1. A materially incompatible future vault ABI must use a new
`interfaceVersion` and receive matching adapter support before activation. Integrators must fail closed on unknown
versions instead of decoding them as version 1.

## License

The registry and its adapters are distributed under the repository [MIT License](../LICENSE-MIT). They may be used,
modified, redistributed and deployed in production without permission from Liquid Hub. This permissive license is
intentional: wallets and indexers must be able to integrate every official network registry without a licensing
dependency on the protected strategy contracts.
