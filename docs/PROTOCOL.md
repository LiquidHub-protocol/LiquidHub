# Protocol architecture

Liquid Hub is an **autonomous-execution protocol**. Its on-chain strategy computes decisions; public contracts enforce eligibility and execution. The company installs new pools and performs the first LP mint. Keepers and the principal bot then execute ordinary operations without company approval. Each existing pool seals its strategy, commission rate, contract bindings and asset destinations before public deposits open. There is no protocol token, staking programme, DAO, Governor, timelock or later governance phase.

## Pool flows

The exposed/stable implementation queues token0/token1 deposits. The delta-neutral implementation queues token1 collateral and coordinates its LP position with Aave V3 collateral and volatile debt. Shares represent the user's actual post-action NAV entitlement. Deposit processing, canonical checkpoints, eligible rebalances, progressive continuations, fee crystallisation and compounding are guarded public operations. Withdrawal and queued-deposit refund belong to the beneficiary; public callers cannot redirect an entitlement.

The immutable four-layer `RangeStrategyEngine` combines the analytical controller, fixed multi-scenario optimiser, bounded online adaptation and false-start protection. It holds no funds and exposes canonical action identifiers, reason codes, validity and exact target ticks. `RangeManager` checks that decision and the live oracle/TWAP limits. Atomic execution either completes or reverts. Progressive execution retains a vault lock and a cumulative oracle-USD budget; each continuation revalidates the remaining plan. Arbitrary caller-selected ranges, recipients, routers or borrowing plans are excluded.

Keepers have the installed one-minute priority window for eligible checkpoints/rebalances and ordinary hedge corrections; the principal bot supplies the fallback. Existing longer bridge priority windows remain. Critical health-factor repair is immediate and does not wait for an ordinary keeper window. Deposits and compounding receive no new artificial waiting period.

## Delta-neutral operation

Ordinary over- and under-hedge correction follows the sealed strategy, cooldown and confirmation rules. Critical drift and health-factor repair bypass ordinary delays. Installed HF target, buffer and repair-trigger floors cannot be lowered by the Safe. Incident adjustments remain within published limits and cannot change the strategy, loan token, collateral token or receivers. Public debt settlement and health-factor repair remain available during bounded opening pauses.

A terminal incident can burn the LP position and close or settle the hedge only through fixed pool receivers. It enters irreversible exit-only mode: users recover their own entitlements under existing accounting, the Safe cannot reopen the pool or move user principal into company remuneration. New strategies use new pools.

## Commission settlement

Only earned LP fees incur the installed commission, never deposited principal. The remaining fees compound for users. Pool commissions are transferred through registered revenue sources into the chain's shared Treasury; swap partner fees use a separate SwapTreasury. WETH, USDC, native fees and future WBTC/USDT or other installed fee assets use sealed conversion policies.

Public conversion uses a fixed V3 router/fee route, an oracle-derived minimum, exact actual spending/output checks and a per-source input-volume window. Smaller safe tranches keep partial execution possible. Native wrapping handles only actual Treasury revenue. Proceeds stay in Treasury. Public Stargate bridging or same-chain forwarding goes to one sealed destination; callers fund native transaction/bridge fees and cannot choose the recipient.

See [Treasury accounting](TREASURY.md), [security controls](SECURITY.md) and the complete [operating specification](AUTONOMOUS-PROTOCOL.md), including numerical bounds and installation order.

## Company and discovery

The company may create an unlimited number of new pools with new strategies and assets. Installation seals each new pool and each revenue source's actor permissions. An existing sealed asset route or pool cannot be rewritten. Discovery metadata does not govern execution and holds no funds. Revenue collection does not give the company an ordinary operational control over existing pools.

Statistics describe observed fees and performance, without a pool recommendation or investment advice. Autonomous execution and transparent remuneration do not establish a legal exemption or regulatory authorisation; MiCA's decentralisation discussion is in recital 22.
