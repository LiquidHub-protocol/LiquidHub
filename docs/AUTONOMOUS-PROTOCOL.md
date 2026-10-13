# Liquid Hub — autonomous execution and bounded emergency Safe

This is the operating specification for the exposed/stable RangeManager pool and the delta-neutral Aave pool. Liquid Hub has one model from installation: no protocol token, staking programme, DAO, Governor, timelock or later governance transition.

## Installation and growth

The company can create any number of new pools, introduce other assets and develop different strategies. There is no closed template catalogue restricting future designs. Each new design requires its own validation. Its deployment does not change an existing pool.

Before accepting deposits, each pool seals its installation. The strategy configuration, economic rules, contract bindings, asset destinations, executor topology and withdrawal/deposit rules cannot subsequently be changed. Initial configuration remains available before that seal. The first LP mint is the company's bootstrap action through the installed module; later operations are canonical public calls. Treasury routes are installed and sealed per asset, allowing new assets for new pools on the same chain Treasury without rewriting existing routes.

A Safe with three distinct signing addresses and a threshold of two or three signatures is the intended emergency authority. The company sets it up. Deployment tools do not require `getOwners`, `getThreshold` or module enablement to deploy the initial contracts. The app reports the observed owners and threshold after deployment, or reports unavailable evidence; address counts do not establish human independence.

## Autonomous operation

Both pools expose price refresh, deterministic strategy checkpoints, queued-deposit processing after bootstrap, canonical rebalances, progressive swap chunks and completion, fee collection and compounding. The DN pool additionally exposes ordinary hedge adjustment and urgent health-factor repair. Users deposit, withdraw and recover their own queued funds. Raw token transfers, arbitrary borrowing and arbitrary swaps remain restricted to the installed internal execution graph.

Keepers receive the existing priority windows for eligible checkpoints, rebalances and ordinary hedge work. The principal bot waits for those windows and takes over if no keeper acts. Urgent HF repair does not wait. Treasury settlement retains the longer bridge bounty opportunity before the principal bot's fallback. No new waiting window applies to normal queued deposits or compounding.

Commission receipts are pulled from registered pool actors; they cannot claim previously held Treasury funds. Public conversion uses a fixed asset route, canonical USDC beneficiary, execution-time oracle floor and per-source volume window. Smaller tranches can execute when the maximal tranche lacks liquidity. Invalid/stale oracles, unavailable external liquidity and failed chains cannot be bypassed to pretend an operation succeeded. Source or asset failures do not stop settlement of already available USDC.

Public native-fee wrapping verifies the actual wrapped-token balance increase. Stargate bridges only distributable USDC to the installed destination, with minimum receipt, exact input consumption, allowance cleanup and caller-funded native costs. Same-chain forwarding also uses a fixed destination. Source confirmation and destination delivery are reported separately; a successful source transaction does not prove delivery.

## Remaining Safe powers

The remaining human administration is strictly bounded, documented and predominantly for emergencies. Every call is visible on-chain. It cannot change the strategy, commission rate, principal destination or installed execution graph.

| Control | Public envelope and effect |
| --- | --- |
| Stop new inflows | 1 hour–7 days, automatic expiry, no extension while active; the Safe may resume early |
| Hold withdrawals during an incident | 1 hour–48 hours, no active extension; expiry or early resume is followed by 24 hours of normal withdrawals before another hold |
| Stop the bot relay, new hedge borrowing or revenue settlement | 1 hour–48 hours with automatic expiry and 24-hour reuse gap; canonical public maintenance, repayment and urgent HF repair retain their safety-checked routes |
| LP and oracle protections | LP slippage 50–500 bps; deviation 1–1,000 bps; freshness 3,600–172,800 seconds. Oracle addresses stay fixed |
| Optional TWAP/MEV protections | Only the optional controls may be temporarily adjusted inside their installed envelope; override expires after 48 hours and cannot repeat before the 24-hour recovery gap. Mandatory oracle, sequencer, NAV and execution checks remain enforced |
| DN protection | Hedge slippage 10–500 bps, hedge deviation 1–1,000 bps. Initial HF target, buffer and repair trigger form floors; target plus buffer cannot exceed 3.0. Strategy thresholds, topology and ordinary timing remain fixed |
| Foreign-asset rescue | Active incident only; pool token0/token1 and configured/accounted commission assets are excluded. Pool foreign assets go to the fixed Treasury, unconfigured/unaccounted Treasury assets only to the fixed company receiver |
| Terminal incident exit | Irreversible exit-only state blocks new investment. Canonical LP burning and DN closing/repayment return assets to the pool's fixed settlement contracts; users recover their own entitlement. No migration, arbitrary receiver or discretionary principal withdrawal |

A withdrawal hold is an incident-response window, not a repair to immutable code. It gives time to diagnose, close risky positions and activate exit-only recovery. A vulnerability in the withdrawal route can remain after expiry; this limitation is explicit. The Safe cannot keep users locked through repeated extensions. A compromised signing group still presents risks within its published envelope.

## Company remuneration and bounty funding

The company receives protocol commissions on generated fees, never a discretionary withdrawal of pool principal. `adminWithdraw(amount, to)` is controlled by the installed company revenue administrator and has no monthly ceiling, lifetime ceiling or separate payout contract. It can withdraw available USDC whenever it chooses. Treasury balance, conversion, bridge, bounty and company withdrawal events are publicly reported. An on-chain withdrawal does not wait for a manually supplied history entry.

Five percent of cumulative actual USDC receipts is allocated to protected bounty budgets, with carried rounding. For registered pool sources, four fifths of that allocation (4% of receipts) funds that source's maintenance and one fifth (1% of receipts) funds shared bridge work. Direct donations and incoming Stargate receipts use the Treasury root budget. A source cannot spend another pool's maintenance budget. Voluntary bounty funding is fully reserved. Paying an earned bounty consumes its allocated budget; subsequent receipts replenish it. This is a receipts-allocation rule, not a promise that an unchanged percentage of the live balance remains forever after bounty payments. Withdrawals and bridges cannot consume the current protected reserve.

Daily bounty caps, duplicate checks, per-source cooldowns and minimum economic actions remain enforced. Maintenance may complete without a bounty when its budget cannot pay; depletion cannot stop critical maintenance. Treasury configuration and existing payout policies are sealed. New pools and fee assets can be installed by the company without an upper pool-count limit. After global Treasury sealing, `installer()` identifies the company; existing asset rules and all actor roles of a sealed revenue source cannot be modified. The Safe controls only the published incident and protection paths on existing pools. Cross-chain receipt allocations must be distinguished from fresh protocol fees in global turnover reporting.

## Frontend, Terms and legal position

Resources describe an **Autonomous-execution protocol**, display installed bounds, current emergency values, pauses, reserve and company authority, and explain the remaining Safe powers openly. Pool exits and entry conditions use actual chain state. Terms retain version `v1` for this development release; earlier development-only acceptance records may be reset with a backup after confirming their scope.

Liquid Hub provides product implementation, maintenance and support. It does not give investment advice or personalised pool recommendations. The frontend reports historical fees and observed yields; it does not tell depositors to enter a particular pool. Indicator colours are red below 50 and green at or above 50, without entry recommendations.

Revenue, public contracts and autonomous bots do not by themselves establish regulatory exclusion. MiCA's fully decentralised, intermediary-free service discussion is in **recital 22**, not Article 22. The company's deployment, support, remuneration and bounded Safe powers remain facts to include in the legal qualification of each service and of pooled investment arrangements. No automatic exemption or acquired authorisation is claimed. Sources: [MiCA official text](https://eur-lex.europa.eu/eli/reg/2023/1114/oj/eng), [AMF MiCA dossier](https://www.amf-france.org/fr/actualites-publications/dossiers-thematiques/mica).

## Release verification

Validate both private pool builds, the SwapTreasury build, unit/security/fork scenarios, EIP-170 runtime sizes, unsigned installation batches, command authority, principal-bot and keeper fallback, source accounting, frontend types and legal copy. Compare the full public contract trees and keeper source trees byte for byte with private sources and test keepers. Publishing sources and creating unsigned batches are separate from deployment. No contract deployment is part of this transition task.

## Licensing

Core contracts retain their BUSL-1.1 policy with the change date **2028-08-21** and subsequent **GPL-2.0-or-later** licence. Production interaction with official deployments is permitted under the published integration grant. Interfaces and the fundless integration registry retain their MIT licence. Refer to the public repository's [LICENSING.md](https://github.com/LiquidHub-protocol/LiquidHub/blob/main/LICENSING.md) for the controlling terms. Removing token/governance phases does not alter these grants.

## Unsigned installation order

For a fresh shared Treasury, the initial Safe bundle installs its immutable settlement path, enables all configured bounties, installs and seals asset routes, assigns and seals each new revenue source, seals global Treasury policy, then seals the pool bindings before registry registration. For a reused Treasury with a distinct company installer, `company-installation.json` contains only fresh asset/source calls to execute first; the pool Safe bundle follows. A distinct discovery owner uses `registry-installation.json` afterward. These files contain unsigned calldata and signer addresses, never private keys. Existing sources cannot be remapped or granted another role after their source seal. Deployment does not query or gate Safe signer counts or thresholds.

Wrapped-native handling is configured from the first installation even for WBTC/USDT or other pool pairs. SwapTreasury includes an installed native placeholder route. Decimal amounts larger than JavaScript's safe integer range must be supplied as strings. Future strategies may use separate implementations and artifacts; source registration does not enforce a closed global template catalog.
