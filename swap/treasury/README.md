# Liquid Hub Swap Treasury

This folder exposes the dedicated frontend swap-fee treasury contract for public audit.

The frontend Velora integration sends partner fees to a chain-specific `SwapTreasury` address. This treasury is intentionally separate from LP pool treasuries, so swap revenue is not mixed with strategy revenue.

Main responsibilities:

- hold frontend swap fees received through Velora `partnerAddress`
- convert configured non-USDC fee tokens to the chain USDC with an oracle floor
- bridge USDC to the Phase 2 staking destination through Stargate
- pay the existing permissionless Bridge Bounty when on-chain cooldown and minimum-ratio conditions are met

The public bridge keeper remains in `../bridge/bridge-keeper`. It is the shared keeper for pool and swap treasuries.
