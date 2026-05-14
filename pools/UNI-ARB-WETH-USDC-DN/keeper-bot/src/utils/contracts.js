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
  "function initMultiSwapTvl() external view returns (uint256)"
];

// MultiUserVault ABI (only functions needed by keeper)
const VAULT_ABI = [
  "function treasuryAddress() external view returns (address)"
];

// Treasury ABI (for bounty info)
const TREASURY_ABI = [
  "function keeperBountyEnabled() external view returns (bool)",
  "function keeperBountyAmount() external view returns (uint256)"
];

// AaveHedgeManager ABI (for monitoring the AAVE V3 hedge on the DN pool)
// totalCollateralBase / totalDebtBase / availableBorrowsBase: USD with 8 decimals
// (Chainlink base-currency convention)
// healthFactor: 1e18 fixed-point
const AAVE_HEDGE_ABI = [
  "function getHedgeData() external view returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 healthFactor, uint256 availableBorrowsBase)",
  "function getHealthFactor() external view returns (uint256)"
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
  return { rangeManager, vault, hedgeManager };
}

module.exports = { RANGEMANAGER_ABI, VAULT_ABI, TREASURY_ABI, AAVE_HEDGE_ABI, createContracts };
