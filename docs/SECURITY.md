# Security Model

## Repository security checks

GitHub secret scanning and push protection are enabled for this public repository,
including generic-pattern and AI-detected secret alerts. Dependabot security updates
are grouped by ecosystem/directory in `.github/dependabot.yml`; development-dependency
alerts are retained for review instead of automatically dismissed.

`Public code security` runs CodeQL on JavaScript/TypeScript and GitHub Actions after
relevant changes reach `main`. It does not run on pull requests or a schedule, avoiding
duplicate scans. Documentation, HTML, CSS and Solidity-only changes do not trigger it.
The single Ubuntu job has a ten-minute timeout and does not install dependencies,
compile TypeScript/Solidity, run Foundry, or contact an RPC. Results are published to
the repository's **Security and quality → Code scanning** page. This is post-merge
monitoring, not an additional required pull-request check or a Solidity audit.

Before a major release, maintainers should also run **Actions → Public code security →
Run workflow** on the release candidate, review its alerts, and confirm the run succeeded.
Use this manual run to refresh the analysis after a long period without code changes.
Existing keeper tests and the Gitleaks check remain required before merging.

## Sealed execution and bounded emergency authority

Existing pools seal strategy, commissions, bindings, oracle feeds, executor topology and asset destinations before admitting public capital. Linked libraries are part of the implementation and must be verified with the calling contract. The company can deploy unlimited new pools and strategies; it cannot mutate a sealed pool. A chain Treasury separately closes actor permissions for every installed revenue source and seals each asset policy.

The emergency Safe has three distinct signing addresses and a threshold of two or three. Deployment scripts do not gate installation on a Safe signer/threshold query. The frontend reports the observed profile after deployment, including unavailable or mismatching data; signer addresses alone do not establish human independence.

The remaining administration is strongly bounded, publicly defined and linked to emergency protection:

- Inflow pauses: 1 hour to 7 days, with no active extension.
- Normal withdrawal pauses: 1 to 48 hours, followed by at least 24 hours open before reuse. Early resume does not remove the reuse gap.
- Module, hedge opening and revenue pauses: 1 to 48 hours with a 24-hour reuse gap. Debt settlement and urgent HF repair remain available.
- LP execution slippage: 50–500 bps; oracle deviation: 1–1,000 bps; freshness: 1–48 hours. Installed oracle addresses cannot change.
- Optional TWAP/MEV override: at most 48 hours with a 24-hour gap. Mandatory oracle/sequencer/NAV checks remain enforced.
- DN slippage: 10–500 bps and deviation 1–1,000 bps. Installed HF floors cannot be lowered; target plus buffer cannot exceed 3.0. Strategy cadence and the HF bounty minimum are sealed.

Emergency LP burn, DN close/repay/sweep and unrelated-token rescue require their incident predicates and fixed receivers. A terminal shutdown enters irreversible exit-only mode. The Safe cannot migrate assets, choose a principal recipient, reopen the pool or rewrite the strategy. Users retain their own recovery/refund paths under the accounting rules. A short withdrawal pause buys containment time; it cannot repair an immutable contract and is not a repeated indefinite administrative freeze.

## Guarded public execution

The immutable `SecureBotModule` is a direct executor. It does not require Safe module enablement for the operational path. It restricts targets and selectors; direct raw transfer/approval, arbitrary borrowing, user-selected range ticks, routers or destinations are excluded. Public canonical deposits, checkpoints, eligible rebalances, compound, progressive continuation, ordinary hedge correction and HF repair remain guarded by the installed contracts. The first mint is the company's bootstrap path. User withdrawal/recovery always fixes the beneficiary.

The one-minute keeper priority windows and principal-bot fallback remain; urgent HF repair bypasses ordinary timing. Progressive operations preserve cumulative swap budgets and the vault lock. Failure preserves the intact cycle for a retry; cancellation is a guarded recovery operation, never an arbitrary unlock or principal transfer.

## Accounting and market safety

Oracle round validity, age, sequencer recovery and NAV checks reject invalid states. Rebalance eligibility uses the shared on-chain TWAP and fee-growth gate; it never postpones critical hedge/HF repair. Swaps enforce actual spending/output and live oracle floors. Reentrancy guards cover fee receipt and public revenue synchronisation. Source accounting isolates maintenance reserves, carries USDC allocation rounding and protects previously unaccounted receipts from company withdrawal.

Public conversion fixes the installed route and source-volume budget; small tranches avoid unnecessary all-or-nothing conversion blockage. Native fees cannot be extracted by a rescue path. Stargate settlement fixes the destination and excludes bounty reserves; same-chain forwarding requires the sealed terminal USDC Treasury. Source confirmation and destination delivery are separate states.

The company installer can only add fresh assets/sources. Already sealed source roles and asset policies cannot be remapped, extended or revoked. Company remuneration is uncapped outside the protected reserves and is visible in on-chain histories; that revenue authority does not grant access to pool principal.

## Verification boundaries

Review source, linked libraries, unsigned installation batches and live settings together. The public repository is an audit/integration surface; source publication alone does not prove a deployment or completed audit. Private validation covers both pool implementations, SwapTreasury, invariant/security tests, operational archive forks, CLI authority and keeper fallback. Public publication runs keeper JavaScript and secret checks without Solidity/TypeScript builds.

See [complete operating specification](AUTONOMOUS-PROTOCOL.md) and [Treasury accounting](TREASURY.md). Autonomous execution and bounded powers do not establish an acquired MiCA exemption; the relevant decentralisation language is recital 22, and legal qualification includes the actual services and residual powers.
