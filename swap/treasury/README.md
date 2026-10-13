# SwapTreasury

Chain-specific swap partner fee collection, separate from pool principal and pool commissions. The implementation uses the same autonomous revenue and bridge libraries as the pool Treasury. There is no protocol token, DAO or governance transition.

Installed ERC20/native fees convert publicly through sealed V3 routes with live oracle floors, exact input/output accounting and input-volume windows. Smaller chunks remain possible. Arbitrary owner-provided swap calldata is removed. Native wrapping and conversion spend only actual revenue, with the installed wrapped-native token. USDC stays in Treasury until a public fixed bridge/forward or company withdrawal.

Five percent of cumulative actual USDC receipts, with carried rounding, funds protected bounty reserves. The company can withdraw earned USDC at any time with no ceiling outside those reserves. Receipts, conversions, reserve funding, bounty payments, settlement and withdrawals are on-chain events indexed in public histories.

The company installer can add fresh fee assets for future activity; a sealed route cannot change. The rescue Safe has only bounded incident controls and fixed foreign-token recovery under the incident predicate. It cannot extract native fees, USDC or installed/accounted assets through rescue. Oracle wrapper, linked libraries and installed Stargate destination are verified with the Treasury implementation.

See [operating specification](../../docs/AUTONOMOUS-PROTOCOL.md), [Treasury](../../docs/TREASURY.md) and [security](../../docs/SECURITY.md).
