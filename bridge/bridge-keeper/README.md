# Bridge Keeper Bot — Liquid Hub Phase 2

> **⚠️ Phase 2 only**
>
> This keeper is only useful **after** the protocol transitions to Phase 2 (the multisig has called `disableAdminWithdraw()` irreversibly on the Treasury contracts). In Phase 1, treasuries are managed by the multisig and bridges are not active.
>
> **Don't run this keeper before Phase 2 is announced.** The bridge bounty will not be paid before then.

## What it does

This keeper bot earns USDC bounties by triggering the cross-chain delivery of accumulated protocol fees to the StakingRewards contract. The same keeper can serve pool and frontend swap treasuries.

In Phase 2, every Liquid Hub Treasury exposes one **permissionless bridge** function:

- **`bridgeToStakers(amount)`** — sends USDC cross-chain via Stargate v2 to the configured StakingRewards contract.
Anyone can call this function and earn the **Bridge Bounty** in USDC, paid directly by the Treasury. Non-USDC fee tokens are first converted through owner-only `swapToUSDC()` by the Safe/timelock using a protected execution route; a public keeper cannot choose the swap timing or amount. The bounty is configured by governance and designed to cover the Stargate cross-chain fees with a small incentive on top. The current amount is published on the protocol's Decentralization page (https://liquidhub.app/docs#decentralization) and is the source of truth on-chain — read `bridgeBountyAmount()` on the Treasury before relying on it.

## Anti-drain protections (read this!)

The Bridge Bounty includes two on-chain protections to prevent abuse:

1. **Cooldown** (default 6 hours): the Treasury pays the bounty **at most once per cooldown window**. If two keepers bridge in the same window, only the first one earns the bounty.
2. **Minimum ratio** (default 50×): the bounty is paid **only if** `bridgedAmount >= bountyAmount × minRatio`. With a 50× ratio you must bridge at least 50× the bounty amount in a single call to earn the bounty.

The bridge function itself is **always callable** (anyone can bridge any time). The cooldown and ratio only gate the **bounty payment** — never the bridge. So if you bridge a small amount or right after another keeper, the bridge succeeds but you don't earn the bounty.

**Implication for keepers:**

- Don't bridge tiny amounts. Wait until the Treasury accumulates at least `bountyAmount × minRatio` in USDC.
- Don't bridge faster than the cooldown. Use the `lastBridgeBountyAt` storage variable to know when the next paid window opens.
- Read `bridgeBountyCooldown`, `bridgeBountyMinRatio`, `bridgeBountyAmount`, `bridgeBountyEnabled` on-chain before deciding to bridge.
- Bridge only `bridgeableUsdc()` when the contract exposes it. This preserves the bounty reserve and avoids reverting by trying to bridge the full USDC balance.
- Do not configure non-USDC tokens in this keeper. Governance must convert them with `swapToUSDC()` first; the keeper will pick up the resulting USDC on a later cycle.
- Configure the exact `usdc` address for every Treasury entry. The keeper verifies it against `Treasury.usdc()` on-chain before reading balances or signing anything; it never reads private pool configuration and never guesses an address from the chain ID.
- Configure at least three distinct endpoints in `rpcUrls`. Reads and the same signed transaction rotate across them on timeout; community keepers may choose any RPC because execution safety is enforced on-chain.
- Set the required `KEEPER_MAX_GAS_PRICE_GWEI` cap. Legacy `gasPrice`, EIP-1559 `maxFeePerGas`, and `maxPriorityFeePerGas` are all checked before signing.
- The keeper reads the `pending` nonce from every currently chain-authenticated RPC. It uses the highest coherent observation, refuses an abnormal divergence, persists every signed raw transaction before broadcast, and locks the signer nonce per chain.
- Signed transactions and receipt reconciliation use only RPC endpoints authenticated against the configured `chainId`; an unavailable or mismatched endpoint never receives a raw transaction.
- Configure a live native/USD Chainlink feed with `NATIVE_USD_ORACLE_<chainId>` or `nativeOracle` in the treasury entry. The keeper no longer accepts fixed native-token prices for the Stargate fee cap.
- Incidents are persisted and logged locally after three consecutive failed cycles; recovery is logged too.
  This public/community keeper never accesses protocol Telegram or AWS secrets. Retries continue indefinitely.

## Coordination with the protocol bots

Community keepers may call the Treasury directly whenever its on-chain conditions allow it. The pool bot can also call the same bridge function after pool maintenance. When the bounty is active, that bot waits six hours after the on-chain bounty cooldown expires; on its first Phase 2 observation, it waits six hours before attempting a bridge. A separate internal bridge worker runs on a twelve-hour schedule as an independent fallback. Its schedule is not synchronized to the exact bounty cooldown, so **a fixed six-hour exclusive community window is not guaranteed by that worker**. The first eligible caller receives the bounty when the on-chain conditions are satisfied.

If a Treasury uses same-chain distribution instead of Stargate, the main pool bot can perform it. A community keeper may opt in with `ENABLE_UNPAID_SAME_CHAIN_DISTRIBUTION=true`; this route pays no protocol bounty, so the operator bears its gas cost.

The on-chain cooldown is global to a Treasury. It limits bounty payment, not permissionless access to the bridge function. Before broadcasting, independent operators should read the current Treasury state, estimated fee and bounty conditions rather than assume a payment.

## Economics

```
Per successful paid bridge — your costs:
  Stargate cross-chain fee (paid by you in native ETH):  ~$1–3
  Gas for the bridge tx (paid by you):                   ~$0.10–0.50
  ──────────────────────────────────
  Total cost                                             ~$1.10–3.50

  Bounty received:                                       see Decentralization page
  Max paid bounties per day (with default 6h cooldown):  4
```

The bounty is sized to roughly offset the Stargate fee plus a small incentive; the exact amount is published on the protocol's Decentralization page (https://liquidhub.app/docs#decentralization) and read live from the Treasury on-chain. Net profit depends on that amount versus the live Stargate fee at the time you bridge — check both before acting.

This is a **small but real incentive**. Point the keeper at every Treasury you want to serve (configure them in `TREASURIES`) across multiple chains to accumulate. The reference implementation in this folder handles all the edge cases for you.

## What this keeper does NOT do

- It does **not** rebalance LP positions (use the [LP rebalance keeper](../../pools/UNI-ARB-WETH-USDC/keeper-bot) for that).
- Same-chain `distributeToStakers()` is disabled by default and pays no bounty. Operators may enable it with `ENABLE_UNPAID_SAME_CHAIN_DISTRIBUTION=true` and bear the gas cost.

## Setup

```bash
cd /path/to/bridge-keeper
npm install
# edit config/.env with your wallet private key, RPC URLs, USDC/native oracle addresses, and Treasury addresses
chmod 600 config/.env
node src/keeper.js
```

See `config/.env.example` for the full public configuration template. The keeper is a long-running process that polls on `CHECK_INTERVAL_MIN`. Use PM2 / systemd / Docker to supervise it.

**Recommended schedule:** every 1–6 hours, depending on Treasury activity and the configured cooldown.

Signer state is stored with permissions `0700/0600` under
`~/.liquidhub-keeper-state` by default. Pool and bridge keepers use the same
lock and pending-transaction journal derived from `chainId + signer address`.
One local test key can therefore run all keeper families without nonce
collisions, while unrelated public keepers with different keys remain isolated.
If `KEEPER_STATE_DIR` is overridden, every process sharing the same key and
network must use the exact same directory. Stop all such processes together
when upgrading from an older bridge keeper; its former `pending-bridge-*`
journal is migrated automatically before any new transaction is signed.

This community keeper has no Telegram transport, Tenderly integration, or AWS
Secrets Manager integration. Operators provide their own private key and RPC endpoints only
through their local `config/.env`; protocol-owned notification credentials are
never read by this process.

## How it works (algorithm)

For every (treasury, network) pair listed in your config:

1. Read on-chain state in parallel:
   - `bridgeBountyEnabled`, `bridgeBountyAmount`, `bridgeBountyCooldown`, `bridgeBountyMinRatio`, `lastBridgeBountyAt`
   - `bridgeEnabled`, `bridgeDestinationEid`, `bridgeDestinationAddress`
   - `usdc.balanceOf(treasury)` and `bridgeableUsdc()` when available
2. **Skip** the Treasury if any of these is false:
   - `bridgeBountyEnabled == false`
   - `bridgeEnabled == false`
   - `block.timestamp < lastBridgeBountyAt + bridgeBountyCooldown` (cooldown not elapsed)
   - bridgeable USDC < `bridgeBountyAmount × bridgeBountyMinRatio`
3. **Estimate the Stargate fee** via `estimateBridgeFee(amount)`. Convert the native fee to USD with the configured live native/USD oracle, then skip if it exceeds your `MAX_STARGATE_FEE_USD` cap.
4. **Bridge eligible amount** via `bridgeToStakers(amount)` with `msg.value = nativeFee`.
5. Wait for the tx to be mined, decode the `BridgeBountyPaid` event to confirm you earned the bounty.

That's it. Idempotent (the cooldown protects against double-bridges), safe (you can't redirect funds — the contract enforces the destination).

## Security & trust

- **You never give us your private key.** The keeper signs its own transactions.
- **No ambiguous resend.** A raw transaction is signed once, journaled locally, and then sent through the configured RPC pool. A timeout blocks later signatures until that transaction is confirmed, replaced on-chain, or rebroadcast identically.
- **Authenticated RPC broadcasts only.** Every endpoint must report the configured `chainId` before it can receive a signed raw transaction.
- **Bounded gas and coordinated nonce.** Fee fields cannot exceed `KEEPER_MAX_GAS_PRICE_GWEI`, and the nonce is derived from coherent `pending` observations across authenticated RPCs.
- **Funds always go to the configured StakingRewards.** The destination is set by the multisig and cannot be changed by anyone calling `bridgeToStakers()`.
- **No upgrade and no caller override.** The Treasury is not upgradeable, and a keeper cannot change the destination or bounty. In Phase 2 those parameters remain changeable only through the governed Timelock process; disabling admin withdrawals does not silently grant configuration power to the Safe or to a keeper.

## Open source

This keeper is provided as a **reference implementation** under the repository [MIT License](../../LICENSE-MIT).
You may use it, fork it, modify it, redistribute it and run it in production without permission from Liquid Hub.

You are encouraged to write your own keeper (Rust, Go, Python, anything) — the on-chain interface is fully public and language-agnostic.
