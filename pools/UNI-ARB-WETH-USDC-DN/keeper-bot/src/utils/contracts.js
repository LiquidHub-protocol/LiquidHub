const { ethers } = require('ethers');

// RangeManager ABI (only functions needed by keeper)
const RANGEMANAGER_ABI = [
  "function getBotInstructions() external view returns (bool hasPosition, uint256 tokenId, bool needsRebalance, string memory action, string memory reason)",
  "function rebalance(uint256[] calldata swapAmountsIn, uint256[] calldata minAmountsOut, address tokenIn, address tokenOut) external",
  "function getOptimalSwapParams() external view returns (tuple(bool swapNeeded, bool zeroForOne, uint256 amountIn, uint256 currentBalance0, uint256 currentBalance1, uint256 targetRatio0Bps, int24 tickLower, int24 tickUpper))",
  "function getPositionDetails(uint256 tokenId) external view returns (bool inRange, int24 tickLower, int24 tickUpper, uint128 liquidity, int24 currentTick)",
  "function priceCache() external view returns (uint128 price0, uint128 price1, uint160 poolSqrtPriceX96, int24 poolTick, uint64 timestamp, bool valid)",
  "function isSystemOperational() external view returns (bool)",
  "function config() external view returns (uint24 fee, uint8 token0Decimals, uint8 token1Decimals, uint16 toleranceBps, uint24 maxSlippageBps, uint64 lastRebalanceTime, bool oraclesConfigured, uint16 rangeUpPercent, uint16 rangeDownPercent, uint32 maxPositions)",
  "function initMultiSwapTvl() external view returns (uint256)",
  // --- Dynamic range (on-chain) ---
  // recordPriceSnapshot is permissionless: it stores a Chainlink price point in the on-chain
  // ring buffer used to compute the dynamic range. The contract spaces snapshots regularly
  // (24h / maxSnapshotsPerDay) and REVERTS if one is not due yet — so callers wrap it in try/catch.
  // A successful call pays the metrics bounty (USDC) from the Treasury to msg.sender.
  "function recordPriceSnapshot() external",
  "function isSnapshotDue() external view returns (bool)",
  "function dynRangeConfig() external view returns (bool dynamicRangeEnabled, uint8 maxSnapshotsPerDay, uint8 volatMoyDay, uint8 volatTrimDay, uint16 rangeStepBps, uint16 rangeMultiplicatorBps, uint64 lastSnapshotAt)",
  // getOwnerPositions: confirme qu'un NFT existe (depot permissionless interdit si aucune position)
  "function getOwnerPositions() external view returns (uint256[] memory)"
];

// MultiUserVault ABI (only functions needed by keeper)
const VAULT_ABI = [
  "function treasuryAddress() external view returns (address)",
  // --- depot permissionless ---
  // processDepositPermissionless traite 1 depot de la file (atomique) : shares (oracle) -> swaps
  // bornes oracle -> addLiquidity -> deposit bounty. Verrou anti-withdraw concurrent. REVERT si file
  // vide / pas de NFT / cache prix perime / minOut < plancher oracle. Appeler en try/catch.
  // Le hedge DN est ouvert ATOMIQUEMENT on-chain dans processDepositPermissionless (DnDepositLib) +
  "function getPendingDepositsCount() external view returns (uint256)",
  "function getNextDepositValueUSD() external view returns (uint256)",
  "function processDepositPermissionless(uint256[] swapAmountsIn, uint256[] minAmountsOut, address tokenIn, address tokenOut) external",
  // AUDIT H-01 : plan de swap du PROCHAIN dépôt (état post-transfert + post-hedge), à utiliser pour le dépôt
  // (PAS getOptimalSwapParams du RangeManager, qui reflète l état rebalance/post-burn).
  "function getDepositSwapParams() external view returns (bool zeroForOne, uint256 amountIn)",
  // AUDIT M-01 : plan de swap rebalance compatible dette AAVE fixe (wethInLP ≈ effectiveShort/H). Utilisé par
  // executeRebalance — passe le post-check DN que le rebalance soit déclenché par range ou par drift DN in-range.
  "function getRebalanceSwapParams() external view returns (bool zeroForOne, uint256 amountIn)",
  "function isRebalancing() external view returns (bool)"
];

// Treasury ABI (for bounty info + USDC balance check)
const TREASURY_ABI = [
  "function keeperBountyEnabled() external view returns (bool)",
  "function keeperBountyAmount() external view returns (uint256)",
  "function metricsBountyEnabled() external view returns (bool)",
  "function metricsBountyAmount() external view returns (uint256)",
  "function hedgeBountyEnabled() external view returns (bool)",
  "function hedgeBountyAmount() external view returns (uint256)",
  "function depositBountyEnabled() external view returns (bool)",
  "function depositBountyAmount() external view returns (uint256)",
  "function usdc() external view returns (address)"
];

// Minimal ERC20 ABI (to read the Treasury USDC balance — lets the keeper warn the operator
// when the Treasury is underfunded and a bounty would be skipped).
const ERC20_ABI = [
  "function balanceOf(address account) external view returns (uint256)"
];

const PAUSE_CONTROLLER_ABI = [
  "function inflowsPaused() external view returns (bool)",
  "function withdrawalsPaused() external view returns (bool)"
];

// AaveHedgeManager ABI (DN pool: monitor + permissionless hedge adjustment)
// totalCollateralBase / totalDebtBase / availableBorrowsBase: USD with 8 decimals
// (Chainlink base-currency convention)
// healthFactor: 1e18 fixed-point
// adjustHedge() is permissionless. DN refactor: it pilots on the NET EFFECTIVE SHORT
// (effectiveShort = debt - free WETH on HedgeManager - free WETH on RangeManager) vs the target
// (hedgeTargetBps × wethInLP, default 100% = strict DN). It ONLY corrects an OVER-HEDGE (repays the
// excess, buying WETH on the market). On an UNDER-HEDGE it REVERTS with custom error UnderHedged(...)
// — a borrow would not change the net short. So the keeper's staticCall catches the revert and skips
  // the tx (0 gas, no bounty). A successful (over-hedge) call pays the hedge bounty. The under-hedge is
  // corrected by the permissionless rebalance() path, which rebuilds the LP composition and post-checks.
const AAVE_HEDGE_ABI = [
  "function getHedgeData() external view returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 healthFactor, uint256 availableBorrowsBase)",
  "function getHealthFactor() external view returns (uint256)",
  "function adjustHedge() external",
  "function adjustHedgeBps() external view returns (uint16)",   // drift threshold in bps (DN refactor)
  "function hedgeTargetBps() external view returns (uint16)",   // hedge target in bps (10000 = 100%)
  // On-chain cooldown between two permissionless adjustHedge() calls (seconds). The keeper reads
  // both values to skip the call before sending a tx when the cooldown has not elapsed yet.
  "function hedgeAdjustCooldown() external view returns (uint32)",
  "function lastHedgeAdjustAt() external view returns (uint64)"
];

function createContracts(provider) {
  const rangeManager = new ethers.Contract(
    process.env.RANGEMANAGER_ADDRESS,
    RANGEMANAGER_ABI,
    provider
  );
  const vault = new ethers.Contract(
    process.env.VAULT_ADDRESS,
    VAULT_ABI,
    provider
  );
  // hedgeManager is optional — only attached when AAVE_HEDGE_MANAGER_ADDRESS is configured.
  let hedgeManager = null;
  if (process.env.AAVE_HEDGE_MANAGER_ADDRESS) {
    hedgeManager = new ethers.Contract(
      process.env.AAVE_HEDGE_MANAGER_ADDRESS,
      AAVE_HEDGE_ABI,
      provider
    );
  }
  let pauseController = null;
  if (process.env.PAUSE_CONTROLLER_ADDRESS) {
    pauseController = new ethers.Contract(
      process.env.PAUSE_CONTROLLER_ADDRESS,
      PAUSE_CONTROLLER_ABI,
      provider
    );
  }
  return { rangeManager, vault, hedgeManager, pauseController };
}

module.exports = { RANGEMANAGER_ABI, VAULT_ABI, TREASURY_ABI, ERC20_ABI, AAVE_HEDGE_ABI, PAUSE_CONTROLLER_ABI, createContracts };
