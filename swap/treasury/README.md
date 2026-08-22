# Liquid Hub Swap Treasury

This folder exposes the dedicated frontend swap-fee treasury contract for public audit.

The published source is compiled for deployment with Solidity 0.8.36, the Paris
EVM target, `via_ir = true` and 200 optimizer runs.

Official deployment addresses for every network are published on the
[Liquid Hub Contracts page](https://liquidhub.app/docs#contracts-addresses); never infer an address from this
source directory.

The frontend Velora integration sends partner fees to a chain-specific `SwapTreasury` address. This treasury is intentionally separate from LP pool treasuries, so swap revenue is not mixed with strategy revenue.
It holds protocol commission revenue only: user deposit principal never passes through this contract.

Main responsibilities:

- hold frontend swap fees received through Velora `partnerAddress`
- convert configured non-USDC fee tokens to the chain USDC through owner-only, oracle-bounded Velora Augustus calldata
- bridge USDC permissionlessly to the governed Phase 2 destination through Stargate
- pay the existing permissionless Bridge Bounty when on-chain cooldown and minimum-ratio conditions are met

Conversion and bridging are intentionally separate: a public keeper cannot choose the sale timing, token amount,
route or slippage for Treasury-held non-USDC revenue. Safe governance in Phase 1, then Timelock governance in
Phase 2, supplies fresh Velora calldata; the contract pins the Augustus target and independently enforces exact
input spending, its oracle minimum and receipt of canonical USDC by the Treasury. Keepers can only bridge the
available USDC to the destination fixed on-chain.

The private Safe tooling that prepares these governance transactions explicitly requests a zero partner fee, so
consolidating already-earned protocol revenue does not charge Liquid Hub's frontend commission a second time.

The public bridge keeper remains in `../bridge/bridge-keeper`. It is the shared keeper for pool and swap treasuries.

## License

`SwapTreasury.sol` is source-available under the repository [Business Source License](../../LICENSE). Production
software may freely interact with an official deployment, but copies and derivatives may not be deployed in
production before **2028-08-21**. The contract becomes `GPL-2.0-or-later` on that date. The bridge keeper is separately
licensed under MIT.
