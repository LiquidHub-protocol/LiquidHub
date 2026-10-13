# UNI-ARB-WETH-USDC contracts

This source tree publishes the exposed/stable autonomous-execution pool. The private source is synchronised byte for byte with this tree. There is no token, DAO, Governor, timelock or later governance phase.

`MultiUserVault` owns user entitlements and queued deposits. `RangeManager` executes the canonical `RangeStrategyEngine` decision. `RangeOperations` supplies bounded swaps, liquidity and valuation. `SecureBotModule` directly executes fixed operational paths and progressive continuation; `PauseController` provides the bounded incident controls. `Treasury` receives commissions, isolates bounty budgets and exposes fixed public conversions/settlement.

`AutonomousRevenueLib`, `RevenueBridgeLib`, `ProtocolSafetyLib`, `ProtectionPolicyLib` and `AutonomousExecutionLib` are immutably linked implementation dependencies. `AutonomousPoolLib` supplies installation checks. `SequencerCheckedAggregator` rejects invalid L2 oracle conditions. Verify the exact deployed library bindings as well as the primary bytecode.

The strategy, economics, contract/oracle bindings and receivers are sealed before deposits open. First mint uses the company bootstrap path. Thereafter canonical maintenance, deposit processing, compounding, conversions and settlement are public under their guards. The Safe retains only published incident controls and bounded protection adjustments. It cannot redirect principal; terminal shutdown becomes irreversible exit-only with beneficiary recovery.

The company can install unlimited new pools/assets with different future strategies. Existing pool rules and sealed source/asset policies cannot change. Treasury company withdrawals have no ceiling outside protected bounty reserves. See [operating specification](../../../docs/AUTONOMOUS-PROTOCOL.md), [security](../../../docs/SECURITY.md) and [Treasury](../../../docs/TREASURY.md).

The core implementation is BUSL-1.1 until 2028-08-21, then GPL-2.0-or-later. Official-deployment integrations are permitted. Source publication does not certify a live deployment or legal status.
