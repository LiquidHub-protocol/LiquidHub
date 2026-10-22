# Autonomous protocol transition validation

Revision: 14 October 2026. Operating reference: [AUTONOMOUS-PROTOCOL.md](AUTONOMOUS-PROTOCOL.md).

The release implements one autonomous-execution model for Standard and DN pools, with sealed existing rules, bounded emergency Safe powers, unlimited new-pool development and uncapped company USDC withdrawals outside protected bounty reserves. Token, DAO, governance-transition sources and installation batches are retired. Validation uses private builds and local tests; no contract was deployed or transaction broadcast during this transition.

## Completed checks

| Check | Result |
| --- | --- |
| Standard unit, security and invariants | 250 passed, zero failures/skips |
| DN unit, security and invariants | 365 passed, zero failures/skips |
| SwapTreasury | 21 passed, zero failures/skips |
| Vault registry | 13 passed, zero failures/skips |
| Standard operational archive fork | 14 passed, zero failures/skips |
| DN operational archive fork | 147 passed, zero failures/skips |
| App integration, including local database and compiled ABI checks | 2,083 passed, zero failures/skips |
| Home regressions | 42 passed, zero failures/skips |
| Standard / DN / bridge keepers | 91 / 103 / 36 passed, zero failures/skips |
| Final unsigned tooling, conversion-route and bridge architecture tests | 52 passed, zero failures/skips |
| App, Home and Admin lint / types | Passed with zero lint warnings |
| Dependency coverage | 31 / 31 / 11 pinned vendor files covered for Standard / DN / Swap |

An additional 500-scenario archive strategy-parity campaign for each pool passed earlier in this transition. Later changes concerned permissions, installation sealing, fee accounting and documentation; the four-layer strategy algorithm was unchanged. Operational fork scenarios were replayed after the final permission/sealing changes. Fork transactions execute locally through a read-only upstream RPC boundary.

Production compilation uses the pinned Foundry 1.8.5 toolchain, Solidity 0.8.36, via-IR, one optimiser run and Paris EVM. The 14 October library regrouping reduces the deployment catalogue to four libraries for Standard and six for DN, including Treasury dependencies. Every production contract and deployed library reserves at least 2,048 bytes below EIP-170, enforced before deployment and in CI. The minimum measured margins are 2,128 bytes for Standard and 2,056 for DN. The shared pool Treasury is 22,448 bytes and depends only on the byte-identical AutonomousRevenueLib; SwapTreasury is 17,358 bytes. The architecture and complete manual deployment commands are recorded in [LIBRARY-DEPLOYMENT.md](LIBRARY-DEPLOYMENT.md).

Targeted scenarios include immutable source roles and asset rules, distinct company/Safe authorities, cross-source reserve isolation, cumulative receipt rounding, uncapped withdrawal excluding unaccounted reserves, adversarial ERC20 reentrancy, smaller fixed-route conversion tranches, exact native wrapping, temporary pause expiry/reuse windows, immutable HF bounty minimum and coupled HF bounds, terminal beneficiary recovery and post-bootstrap public execution. Command preparation matches compiled ABIs and simulates from the actual authority without signing.

## Library regrouping validation on 14 October

The final regrouping passed the complete Standard suite (265 tests), complete DN suite (513), SwapTreasury (21) and Registry (13): **812 Solidity tests, no failures or skips**, including fuzz/invariant and archive-fork scenarios. The last installation-role change was followed by another complete Standard/DN replay. The strategy and security conditions were retained; public pool entry-point signatures and caller context are preserved.

Operational/bot regression tests passed 427 cases. The Standard, DN and bridge test keepers passed 91, 103 and 36 cases. The catalogue tests compare both public/admin inventories against actual compiled library dependencies and separately exercise a reused Treasury's real library address. Deployment/publication tooling, CI checks, App/Admin lint and TypeScript checks passed. The public frontend was inspected with all four Standard and all six DN library rows visible; the isolated browser required login for the Admin page, whose shared inventory was verified through code, tests and typechecking.

The deployment wizard and CI reject any pool contract or deployed library with less than 2,048 bytes runtime headroom. No contract deployment, transaction signing or real-network state mutation was performed. Public source alignment covers the local checkout; GitHub publication is a separate step.

## Source synchronisation

Exact relative file sets and file contents match in every mapped tree. There are 37 contract files and 25 keeper source files: zero different, missing or extra files. The main-bot fee-maintenance helper also matches the test/public bridge helper. Keeper tests and public configuration examples are synchronised. Public publication requires no Solidity or TypeScript build.

| Public tree | Files | SHA-256 tree digest |
| --- | --- | --- |
| `pools/UNI-ARB-WETH-USDC/contracts/src` | 14 | `2fcadfdb3d706f34040d5cb73ce9ab37fe28687283f1791f776a1066b6182bbb` |
| `pools/UNI-ARB-WETH-USDC-DN/contracts/src` | 18 | `3710bfbac562b0d1539d886d506bc9f50c70a3fd10c76a2de6f62a102a0a5bbb` |
| `swap/treasury/src` | 4 | `697fa4e8ab2f939627432b574ce8f6006ec72bcf4064f2561a8499bce058ccfd` |
| `registry/contracts/src` | 1 | `0849df6a03c79070fba6193cc388365d0191607360d82f9510c40876c76be8a5` |
| `pools/UNI-ARB-WETH-USDC/keeper-bot/src` | 10 | `d23ff37642b18ad919ea7355dd92617e4501e62efb38aa0b297e397a4cec2631` |
| `pools/UNI-ARB-WETH-USDC-DN/keeper-bot/src` | 11 | `326b8aa372bf0d707bed1fe8829db964cbf63284cfa2fd7bac9800d8b5aad55e` |
| `bridge/bridge-keeper/src` | 4 | `466adfeb0d73c86d5fc10d050e7f632993ac5b3c23a5a69364bfb153ea1c997d` |

Tree digests hash the sorted list of relative paths and each file's SHA-256 digest. This proof covers source equality; it does not certify a live contract, an independent audit or a legal qualification.

## Initial launch responsibilities

Create the intended multisig and verify the frontend's observed signer profile after deployment. Install and seal asset/source policies, global Treasury policy and pool bindings in the documented order, then perform bootstrap mint. Fund operator gas and the initial bounty budget through the explicit funding calls; enabled policies do not create USDC from nothing. Verify the deployed bytecode, linked libraries, source seals, oracle health and terminal bridge destination. Those on-chain and human setup actions remain outside this no-deployment transition.

Historical security reports retain their original source revisions and are not substituted for this release's evidence. The current functional changes require review of the installed configuration and the residual emergency powers before public launch. No regulatory authorisation or MiCA exclusion is asserted.
