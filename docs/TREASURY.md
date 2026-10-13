# Treasury accounting and remuneration

## Fee-only principal separation

Pool principal, LP NFTs, queued deposits and Aave positions remain in their installed pool contracts. Treasury receives protocol commissions, swap partner fees and explicit reserve funding. It is shared per chain and can install fresh fee assets and sources for future pools without changing existing sealed rules. Actor authorisations and source attribution close permanently when a source is sealed.

## Protected bounty reserve

Five percent of cumulative actual USDC receipts is allocated to the protected bounty reserve, with carried integer rounding. For a pool source, 4% funds that source's maintenance bounties and 1% funds shared bridging. Terminal/direct receipts, including bridge receipts, allocate 5% to the Treasury reserve. Direct voluntary bounty funding is fully reserved. Global reporting distinguishes cross-chain receipts from new protocol revenue to avoid double counting.

Bounty payments consume those budgets, and later receipts replenish them. This is a receipt allocation, not an eternal 5% floor on the remaining balance after bounties have been paid. Registered sources cannot spend another pool's maintenance budget. Daily caps, minimum useful actions, cooldowns and duplicate guards remain. Keeper/rebalance, deposit, strategy checkpoint, hedge and bridge bounties are installed from launch; eligible urgent HF repair uses its installed minimum-repaid-debt rule. Underlying maintenance can complete without payment when a budget is insufficient.

## Company withdrawals

`adminWithdraw(amount, recipient)` is the company's revenue action. It has no monthly cap or remuneration ceiling. It synchronises actual USDC accounting and excludes the protected bounty reserves, including previously unaccounted receipts. Non-USDC fee revenue is publicly converted first. The company chooses its withdrawal time and revenue recipient; it cannot use this action to withdraw user principal or reserved bounty funds. No dedicated payout contract is required.

Company withdrawals and receipts, conversions, funding, bounty payments, bridges and forwarding are emitted on-chain and indexed in public Treasury histories. A manual annotation can add context; the on-chain event and transaction remain the evidence.

## Public conversions and settlement

`convertFeesToUSDC` / `convertFeeChunk` use a sealed oracle-bounded route and actual output balances. The pool Treasury attributes conversions by registered source; SwapTreasury uses its own fee ledger. The input-volume window permits smaller successive tranches up to its installed budget. Caller-supplied arbitrary swap calldata and recovery recipients are excluded. Public conversion has no extra bounty, and callers may fund its gas.

Native fees have an installed exact wrapping/conversion path. Each asset's feed, V3 router/fee, input budget, minimum economic output and window are sealed. The company installer can add a fresh asset for a new pool; it cannot edit an existing asset. Source registration has no fixed asset/pool-count ceiling or global strategy-template catalogue.

`bridgeRevenue(amount)` uses the installed Stargate route and quoted native fee to the sealed terminal Treasury. `forwardRevenue(amount)` uses the fixed same-chain USDC destination. The available amount excludes reserve funds. Bounties use the shared bridge reserve and installed cooldown/minimum economic ratio. Terminal Treasury USDC remains available for company withdrawals. A confirmed source bridge receipt is not proof that destination delivery has completed.

## Emergency scope

The Treasury rescue Safe can pause revenue operations for 1–48 hours with a 24-hour reuse gap. It cannot reconfigure economics, sources or existing routes after sealing. Unrelated unaccounted foreign-token rescue requires an active incident and the fixed company receiver; USDC, accounted or installed fee assets and native fees retain their protections. Revenue pause does not grant an unlimited rescue of protocol balances.

See [full published bounds](AUTONOMOUS-PROTOCOL.md), [security model](SECURITY.md) and [custom error reference](autonomous-errors.json).
