# Autonomous protocol transition validation

Revision: 13 October 2026. Operating reference: [AUTONOMOUS-PROTOCOL.md](AUTONOMOUS-PROTOCOL.md).

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

Production compilation uses the pinned Foundry 1.8.5 toolchain, Solidity 0.8.36, via-IR, one optimiser run and Paris EVM. All production runtimes and initcode satisfy EIP-170/EIP-3860. DN Vault runtime is 24,422 bytes (154 bytes below EIP-170), DN deposit library 24,403 (173 bytes margin), each pool Treasury 24,256 (320 bytes margin), and SwapTreasury 17,376. These small DN margins require the same compiler profile in deployment tooling; no security guard was removed to fit the limit.

Targeted scenarios include immutable source roles and asset rules, distinct company/Safe authorities, cross-source reserve isolation, cumulative receipt rounding, uncapped withdrawal excluding unaccounted reserves, adversarial ERC20 reentrancy, smaller fixed-route conversion tranches, exact native wrapping, temporary pause expiry/reuse windows, immutable HF bounty minimum and coupled HF bounds, terminal beneficiary recovery and post-bootstrap public execution. Command preparation matches compiled ABIs and simulates from the actual authority without signing.

## Source synchronisation

Exact relative file sets and file contents match in every mapped tree. There are 44 contract files and 25 keeper source files: zero different, missing or extra files. The main-bot fee-maintenance helper also matches the test/public bridge helper. Keeper tests and public configuration examples are synchronised. Public publication requires no Solidity or TypeScript build.

| Public tree | Files | SHA-256 tree digest |
| --- | --- | --- |
| `pools/UNI-ARB-WETH-USDC/contracts/src` | 16 | `cba1bf48a72ec2112412686eb2e34efebe1d759b6c6adf4ec94f76e101257495` |
| `pools/UNI-ARB-WETH-USDC-DN/contracts/src` | 21 | `686b6b080656796b7acfb81605df6440d92490f15e8018dc234cdcaff7c0156d` |
| `swap/treasury/src` | 6 | `292ac67ced82ab48869288a1e565707e76b87f721b75c766b1f4506287aa679a` |
| `registry/contracts/src` | 1 | `1ee2ba0509fdc0a57cb76557d59781854599abf015f8ee20e90f00e72ebf5895` |
| `pools/UNI-ARB-WETH-USDC/keeper-bot/src` | 10 | `ffe6f7eb16331a4811d8b7dc05acaef10c02fa0988c4e5896a27bf385ec73a2d` |
| `pools/UNI-ARB-WETH-USDC-DN/keeper-bot/src` | 11 | `969ded62b081be60de589856af5ea5a41ab6c30067d7234308f5043c4f23de0a` |
| `bridge/bridge-keeper/src` | 4 | `d6fc4afb6077b191254836614cb8dc22974d7072270588c2430efd618812e92d` |

Tree digests hash the sorted list of relative paths and each file's SHA-256 digest. This proof covers source equality; it does not certify a live contract, an independent audit or a legal qualification.

## Initial launch responsibilities

Create the intended multisig and verify the frontend's observed signer profile after deployment. Install and seal asset/source policies, global Treasury policy and pool bindings in the documented order, then perform bootstrap mint. Fund operator gas and the initial bounty budget through the explicit funding calls; enabled policies do not create USDC from nothing. Verify the deployed bytecode, linked libraries, source seals, oracle health and terminal bridge destination. Those on-chain and human setup actions remain outside this no-deployment transition.

Historical security reports retain their original source revisions and are not substituted for this release's evidence. The current functional changes require review of the installed configuration and the residual emergency powers before public launch. No regulatory authorisation or MiCA exclusion is asserted.
