# Liquid Hub Swap Treasury

This folder exposes the dedicated frontend swap-fee treasury contract for public audit.

The frontend Velora integration sends partner fees to a chain-specific `SwapTreasury` address. This treasury is intentionally separate from LP pool treasuries, so swap revenue is not mixed with strategy revenue.

Main responsibilities:

- hold frontend swap fees received through Velora `partnerAddress`
- convert configured non-USDC fee tokens to the chain USDC through the owner-only, oracle-bounded `swapToUSDC()` path
- bridge USDC permissionlessly to the governed Phase 2 destination through Stargate
- pay the existing permissionless Bridge Bounty when on-chain cooldown and minimum-ratio conditions are met

Conversion and bridging are intentionally separate: a public keeper cannot choose the sale timing, token amount,
route fee or slippage for Treasury-held non-USDC revenue. Safe governance in Phase 1, then Timelock governance in
Phase 2, performs the conversion; keepers can only bridge the available USDC to the destination fixed on-chain.

The public bridge keeper remains in `../bridge/bridge-keeper`. It is the shared keeper for pool and swap treasuries.
