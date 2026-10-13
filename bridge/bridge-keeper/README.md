# Liquid Hub bridge and commission keeper

The keeper operates from initial installation. No token, DAO or later phase is required.

It reads the installed Treasury settlement route and canonical USDC, converts approved commission assets through public fixed routes, then calls `bridgeRevenue(amount)` via Stargate or `forwardRevenue(amount)` for a fixed same-chain destination. Pool principal stays in pool contracts. The current protected bounty reserve is excluded from the amount available to bridge or withdraw.

Conversions are enabled by default. `ENABLE_UNPAID_FEE_CONVERSIONS=false` disables the keeper's conversion work; conversion itself pays no bounty and the operator funds its gas. Existing USDC can still be bridged if a conversion fails. Tranche selection simulates up to eight decreasing amounts against the oracle floor, minimum USDC and per-source volume window, without broadcasting failed simulations.

Treasury configuration entries use `tokens` for direct receipts and SwapTreasury native fees. Pool receipts additionally use `conversions: [{"source":"<installed Vault>","token":"<commission token>"}]`. Install all future pool assets, including WBTC/USDT, and register them in keeper configuration. There is no protocol pool-count or asset-list limit. On-chain fixed routes, asset seals and isolated source budgets remain authoritative.

Bounties require an eligible amount, cooldown, configured ratio, available root bridge budget and confirmed execution. Read the live bounty values; they are not a guaranteed return. Main pool bots preserve the longer community bridge opportunity before fallback, and the independent bridge worker follows its existing schedule. Public callers cannot choose the bridge recipient.

The worker authenticates RPC chains, requires corroborated critical reads, uses signer locks and a persistent transaction journal, and reconciles ambiguous broadcasts before another send. Source confirmation and verified destination receipt are distinct states. Never submit another transaction merely because an RPC times out.

Emergency Safe revenue pauses expire within 48 hours and cannot be repeated before the 24-hour recovery gap. Company `adminWithdraw` has no income ceiling, but cannot consume the protected reserve. Existing asset routes and payout rules are sealed; the company can install fresh assets for new pools.

See [operating specification](../../../docs/AUTONOMOUS-PROTOCOL.md) and the contract sources. Fund the operator's gas, configure at least three independent RPC endpoints, and use the example configuration. Do not publish keys or authenticated RPC URLs.
