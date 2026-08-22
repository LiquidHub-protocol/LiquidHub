# Liquid Hub licensing policy

This repository uses two licenses with deliberately separate scopes.

## Core smart contracts

Files carrying `SPDX-License-Identifier: BUSL-1.1` are licensed under the
[Business Source License 1.1](LICENSE). They may be inspected, audited,
modified, redistributed and used outside production. Production software may
freely interact with the official Liquid Hub deployments listed at
https://liquidhub.app/docs#contracts-addresses.

Until **2028-08-21**, the BUSL grant does not permit deploying or operating a
copy or derivative of those core contracts in production. On that date, they
automatically become available under `GPL-2.0-or-later`.

## Permissionless ecosystem code

The following components are licensed under the [MIT License](LICENSE-MIT) and
may be used, modified, redistributed and operated in production without
permission from Liquid Hub:

- all community and bridge keeper reference implementations;
- the network vault registry and wallet/indexer adapters;
- Solidity interfaces carrying `SPDX-License-Identifier: MIT`;
- deployment scripts, tests and other files carrying an MIT SPDX marker.

The license of a third-party dependency remains the license stated by its
respective copyright holder.

## Trademarks

Neither license grants rights to the Liquid Hub name, logo or other brand
assets. A permitted software fork must not represent itself as an official
Liquid Hub deployment or product.
