# Liquid Hub Wallet Integration Guide

The reference adapter is a provider-neutral, read-only implementation for discovering and valuing Liquid Hub
positions on EVM networks. The same core logic is used for every supported blockchain; only the chain ID and deployed
registry address change.

Publishing this adapter does not automatically make Liquid Hub positions appear in a wallet. Each wallet or portfolio
provider must accept the integration and either execute this reader, wrap its output in the provider's schema, or
implement the same documented reads in its own indexer.

## Layout

- `core/reference-adapter.js`: shared discovery and position calculation;
- `core/reference-adapter.test.js`: accounting, version and chain-binding tests;
- `providers/`: provider-specific wrappers or submission material, added only when a provider gives concrete
  integration requirements;
- `../deployments.json`: public chain-to-registry deployment manifest.

## Install and test

```bash
cd registry/adapters/core
npm ci
npm test
```

The core requires Node.js 20 or newer and ethers v6. It has no signer and needs no private key or API credential.

## Generic API

```js
const { ethers } = require('ethers');
const { getLiquidHubPositions } = require('./reference-adapter');

const provider = new ethers.JsonRpcProvider('https://public-rpc.example');
const result = await getLiquidHubPositions({
  provider,
  user: '0x0000000000000000000000000000000000000001',
  registryAddress: '0x0000000000000000000000000000000000000002',
  pageSize: 25,
});
```

The returned object contains the verified chain ID, successfully decoded positions and per-vault failures:

```js
{
  chainId: 42161n,
  positions: [{
    id: 'liquidhub:42161:<vault>:<user>',
    chainId: 42161n,
    protocol: 'Liquid Hub',
    protocolId: 'UNISWAP_V3',
    strategy: 'EXPOSED',
    interfaceVersion: 1,
    vault: '0x...',
    rangeManager: '0x...',
    dexPool: '0x...',
    token0: '0x...',
    token1: '0x...',
    shares: 0n,
    totalShares: 0n,
    valueUsdRaw: 0n,
    valueUsdDecimals: 8,
    valueUsd: '0.0'
  }],
  failures: [{ vault: '0x...', reason: '...' }]
}
```

The adapter is chain-neutral code, not a cross-chain RPC reader. A wallet or indexer runs it once for each supported
network, using that network's RPC provider and the registry address published for its chain ID in `deployments.json`.
The adapter rejects a registry/provider chain mismatch. Each position also carries its verified `chainId`, and its
stable ID is namespaced as `liquidhub:<chainId>:<vault>:<user>` to prevent collisions between identical addresses on
different EVM networks.

Manifest entries with `status: "pending"` or `registryAddress: null` only announce planned compatibility and must be
ignored by runtime integrations. A provider may review those networks with the initial adapter submission, but only a
later entry containing a verified address and `status: "deployed"` activates reads for that chain. Providers remain
free to require a configuration update or a new security review when an address is activated.

## Read sequence

1. Confirm that `deploymentChainId()` matches the provider network.
2. Read `vaultCount()` and paginate through `getVaults(offset, limit)`.
3. Ignore inactive records.
4. Read `userInfo(user).shares` from each vault.
5. Skip vaults where the user owns no shares.
6. Read `totalShares()` and `getCurrentPortfolioValue()` only for relevant vaults.
7. Calculate the user's pro-rata NAV with integer rounding down.

The vault NAV uses 8 decimals. It is the same accounting value exposed by the vault, including the net Aave position
for a Delta Neutral vault.

## Failure handling

The adapter rejects:

- a registry deployed on a different chain from the provider;
- unsupported vault interface versions;
- an inconsistent vault with user shares but zero total shares;
- invalid user, registry or pagination input.

One failing vault does not erase valid positions from other vaults. The adapter returns that vault in `failures` so a
provider can retain observability without presenting an unverified value.

## RPC policy

All adapter calls are read-only and non-critical. An integration may use public RPCs first and premium RPC fallback for
availability. It must authenticate the returned chain ID and must never place premium RPC credentials in client-side
code or a public submission package.

Providers operating an indexer can follow `VaultRegistered`, `VaultMetadataUpdated` and `VaultStatusChanged` to refresh
the discovered vault set. They can follow each vault's public deposit and withdrawal events for faster account refresh,
then re-read the vault for the authoritative live value.

## Provider-specific integration

Do not fork the accounting logic for every wallet. A provider directory should contain only what that provider
actually requires, such as:

- a result transformer for its portfolio schema;
- protocol metadata and approved public brand assets;
- test fixtures;
- submission and maintenance instructions.

The registry and adapter make Liquid Hub positions discoverable and computable. Display, protocol attribution and
inclusion in a wallet's total USD balance begin only after that provider accepts and deploys the integration.

## License

The registry adapters are released under the repository [MIT License](../../LICENSE-MIT) and may be integrated,
modified and operated in production without permission from Liquid Hub.
