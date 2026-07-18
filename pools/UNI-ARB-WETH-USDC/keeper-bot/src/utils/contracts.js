const { ethers } = require('ethers');

// RangeManager ABI (only functions needed by keeper)
const RANGEMANAGER_ABI = [
  "function getBotInstructions() external view returns (bool hasPosition, uint256 tokenId, bool needsRebalance, string memory action, string memory reason)",
  "function rebalance(uint256[] calldata swapAmountsIn, uint256[] calldata minAmountsOut, address tokenIn, address tokenOut) external",
  "function getOptimalSwapParams() external view returns (tuple(bool swapNeeded, bool zeroForOne, uint256 amountIn, uint256 currentBalance0, uint256 currentBalance1, uint256 targetRatio0Bps, int24 tickLower, int24 tickUpper))",
  "function getPositionDetails(uint256 tokenId) external view returns (bool inRange, int24 tickLower, int24 tickUpper, uint128 liquidity, int24 currentTick)",
  "function priceCache() external view returns (uint128 price0, uint128 price1, uint160 poolSqrtPriceX96, int24 poolTick, uint64 timestamp, bool valid)",
  "function refreshPriceCache() external",
  "function isSystemOperational() external view returns (bool)",
  "function config() external view returns (uint24 fee, uint8 token0Decimals, uint8 token1Decimals, uint16 toleranceBps, uint24 maxSlippageBps, uint64 lastRebalanceTime, bool oraclesConfigured, uint16 rangeUpPercent, uint16 rangeDownPercent, uint32 maxPositions)",
  "function initMultiSwapTvl() external view returns (uint256)",
  "function vault() external view returns (address)",
  "function token0() external view returns (address)",
  "function token1() external view returns (address)",
  // --- Dynamic range (on-chain) ---
  // recordPriceSnapshot is permissionless: it stores a Chainlink price point in the on-chain
  // ring buffer used to compute the dynamic range. The contract spaces snapshots regularly
  // (24h / maxSnapshotsPerDay) and REVERTS if one is not due yet — so callers wrap it in try/catch.
  // A successful call pays the metrics bounty (USDC) from the Treasury to msg.sender.
  "function recordPriceSnapshot() external",
  "function isSnapshotDue() external view returns (bool)",
  "function dynRangeConfig() external view returns (bool dynamicRangeEnabled, uint8 maxSnapshotsPerDay, uint8 volatMoyDay, uint8 volatTrimDay, uint16 rangeStepBps, uint16 rangeMultiplicatorBps, uint16 rangeMinBps, uint16 rangeMaxBps, uint64 lastSnapshotAt)",
  // getOwnerPositions: confirme qu'un NFT existe (depot permissionless interdit si aucune position)
  "function getOwnerPositions() external view returns (uint256[] memory)"
];

// MultiUserVault ABI (only functions needed by keeper)
const VAULT_ABI = [
  "function treasuryAddress() external view returns (address)",
  "function rangeManager() external view returns (address)",
  "function token0() external view returns (address)",
  "function token1() external view returns (address)",
  // --- depot permissionless ---
  // processDepositPermissionless traite 1 depot de la file (atomique) : shares (oracle) -> swaps
  // bornes oracle -> addLiquidity -> deposit bounty. Verrou anti-withdraw concurrent. REVERT si file
  // vide / pas de NFT / cache prix perime / minOut < plancher oracle. Appeler en try/catch.
  "function getPendingDepositsCount() external view returns (uint256)",
  "function getNextDepositValueUSD() external view returns (uint256)",
  "function processDepositPermissionless(uint256[] swapAmountsIn, uint256[] minAmountsOut, address tokenIn, address tokenOut) external",
  // AUDIT H-01/H-03 : plan de swap du PROCHAIN dépôt (état post-transfert, ratio NFT existant). À utiliser
  // pour le dépôt (PAS getOptimalSwapParams du RangeManager, qui reflète l état rebalance/post-burn).
  "function getDepositSwapParams() external view returns (bool zeroForOne, uint256 amountIn)",
  "function syncFeesForDeposits() external",
  "function isRebalancing() external view returns (bool)"
];

// Treasury ABI (for bounty info + USDC balance check)
const TREASURY_ABI = [
  "function keeperBountyEnabled() external view returns (bool)",
  "function keeperBountyAmount() external view returns (uint256)",
  "function metricsBountyEnabled() external view returns (bool)",
  "function metricsBountyAmount() external view returns (uint256)",
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
  let pauseController = null;
  if (process.env.PAUSE_CONTROLLER_ADDRESS) {
    pauseController = new ethers.Contract(
      process.env.PAUSE_CONTROLLER_ADDRESS,
      PAUSE_CONTROLLER_ABI,
      provider
    );
  }
  return { rangeManager, vault, pauseController };
}

function sameAddress(actual, expected) {
  return ethers.getAddress(actual) === ethers.getAddress(expected);
}

async function assertKeeperTopology(rpcPool, { rangeManager, vault }) {
  const expected = {
    rangeManager: process.env.RANGEMANAGER_ADDRESS,
    vault: process.env.VAULT_ADDRESS,
    token0: process.env.TOKEN0_ADDRESS,
    token1: process.env.TOKEN1_ADDRESS,
  };

  const topology = await rpcPool.executeWithRetry(async (provider) => {
    const rm = rangeManager.connect(provider);
    const v = vault.connect(provider);
    const [rmCode, vaultCode, rmVault, rmToken0, rmToken1, vaultRm, vaultToken0, vaultToken1] = await Promise.all([
      provider.getCode(expected.rangeManager),
      provider.getCode(expected.vault),
      rm.vault(),
      rm.token0(),
      rm.token1(),
      v.rangeManager(),
      v.token0(),
      v.token1(),
    ]);
    return { rmCode, vaultCode, rmVault, rmToken0, rmToken1, vaultRm, vaultToken0, vaultToken1 };
  });

  if (topology.rmCode === '0x') throw new Error('Keeper topology: RangeManager has no runtime code');
  if (topology.vaultCode === '0x') throw new Error('Keeper topology: Vault has no runtime code');
  if (!sameAddress(topology.rmVault, expected.vault)) throw new Error('Keeper topology: RangeManager.vault mismatch');
  if (!sameAddress(topology.vaultRm, expected.rangeManager)) throw new Error('Keeper topology: Vault.rangeManager mismatch');
  if (!sameAddress(topology.rmToken0, expected.token0) || !sameAddress(topology.vaultToken0, expected.token0)) {
    throw new Error('Keeper topology: token0 mismatch');
  }
  if (!sameAddress(topology.rmToken1, expected.token1) || !sameAddress(topology.vaultToken1, expected.token1)) {
    throw new Error('Keeper topology: token1 mismatch');
  }
}

module.exports = {
  RANGEMANAGER_ABI,
  VAULT_ABI,
  TREASURY_ABI,
  ERC20_ABI,
  PAUSE_CONTROLLER_ABI,
  createContracts,
  assertKeeperTopology,
};
