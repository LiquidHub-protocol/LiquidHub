// SPDX-License-Identifier: MIT

const { ethers } = require('ethers');

// RangeManager ABI (only functions needed by keeper)
const RANGEMANAGER_ABI = [
  "function rebalance(bytes32 expectedDecisionHash, uint256[] calldata swapAmountsIn, uint256[] calldata minAmountsOut, address tokenIn, address tokenOut) external",
  "function getOptimalSwapParams() external view returns (tuple(bool swapNeeded, bool zeroForOne, uint256 amountIn, uint256 currentBalance0, uint256 currentBalance1, uint256 targetRatio0Bps, int24 tickLower, int24 tickUpper))",
  "function getPositionDetails(uint256 tokenId) external view returns (bool inRange, int24 tickLower, int24 tickUpper, uint128 liquidity, int24 currentTick)",
  "function priceCache() external view returns (uint128 price0, uint128 price1, uint160 poolSqrtPriceX96, int24 poolTick, uint64 timestamp, bool valid)",
  "function refreshPriceCache() external",
  "function isSystemOperational() external view returns (bool)",
  "function config() external view returns (uint24 fee, uint8 token0Decimals, uint8 token1Decimals, uint16 toleranceBps, uint24 maxSlippageBps, uint64 lastRebalanceTime, bool oraclesConfigured, uint32 maxPositions)",
  "function initMultiSwapTvl() external view returns (uint256)",
  "function vault() external view returns (address)",
  "function token0() external view returns (address)",
  "function token1() external view returns (address)",
  "function pool() external view returns (address)",
  "function positionManager() external view returns (address)",
  "function strategyEngine() external view returns (address)",
  // getOwnerPositions: confirme qu'un NFT existe (depot permissionless interdit si aucune position)
  "function getOwnerPositions() external view returns (uint256[] memory)"
];

const RANGE_STRATEGY_ENGINE_ABI = [
  "function rangeManager() external view returns (address)",
  "function pool() external view returns (address)",
  "function hedgeManager() external view returns (address)",
  "function profile() external view returns (uint8)",
  "function decisionMode() external view returns (uint8)",
  "function strategyVersion() external pure returns (uint16)",
  "function checkpointDue() external view returns (bool)",
  "function checkpointMarketState() external returns ((uint64 epoch,uint64 validUntil,uint8 action,uint8 reason,int24 currentTick,int24 currentTickLower,int24 currentTickUpper,int24 targetTickLower,int24 targetTickUpper,int32 currentScoreBps,int32 targetScoreBps,uint32 edgeBps,uint32 thresholdBps,uint32 uncertaintyBps,uint16 learningInfluenceBps,bool inRange,bool dataFresh,bytes32 decisionHash) decision)",
  "function previewDecision() external view returns ((uint64 epoch,uint64 validUntil,uint8 action,uint8 reason,int24 currentTick,int24 currentTickLower,int24 currentTickUpper,int24 targetTickLower,int24 targetTickUpper,int32 currentScoreBps,int32 targetScoreBps,uint32 edgeBps,uint32 thresholdBps,uint32 uncertaintyBps,uint16 learningInfluenceBps,bool inRange,bool dataFresh,bytes32 decisionHash) decision)",
  "function validateDecision(bytes32 expectedHash) external view returns ((uint64 epoch,uint64 validUntil,uint8 action,uint8 reason,int24 currentTick,int24 currentTickLower,int24 currentTickUpper,int24 targetTickLower,int24 targetTickUpper,int32 currentScoreBps,int32 targetScoreBps,uint32 edgeBps,uint32 thresholdBps,uint32 uncertaintyBps,uint16 learningInfluenceBps,bool inRange,bool dataFresh,bytes32 decisionHash) decision)",
  "function currentTelemetry() external view returns ((uint64 epoch,uint64 checkpointTimestamp,int24 spotTick,int24 tacticalTwapTick,int24 strategicTwapTick,int24 analyticalAnchorTick,uint24 fastVolatilityTicks,uint24 slowVolatilityTicks,uint24 upsideSemivarianceTicks,uint24 downsideSemivarianceTicks,uint16 observedFeeRateBps,uint16 forecastFeeRateBps,uint16 uncertaintyBps,uint8 candidateCount,uint8 admissibleCandidateCount,int32 expectedFeesBps,int32 transitionCostBps,int32 riskPenaltyBps,bool learningUpdated,bool learningFrozen,bytes32 decisionHash) telemetry)",
];

const STRATEGY_ACTION = Object.freeze({
  NO_ACTION: 0,
  CHECKPOINT_ONLY: 1,
  RANGE_REBALANCE: 2,
  HEDGE_ONLY: 3,
  RANGE_AND_HEDGE: 4,
  HF_REPAIR: 5,
});

const STRATEGY_ACTION_LABELS = Object.freeze([
  'NO_ACTION', 'CHECKPOINT_ONLY', 'RANGE_REBALANCE', 'HEDGE_ONLY', 'RANGE_AND_HEDGE', 'HF_REPAIR',
]);

const STRATEGY_REASON_LABELS = Object.freeze([
  'NONE', 'INITIAL_MINT_REQUIRED', 'CHECKPOINT_DUE', 'DATA_STALE', 'ORACLE_GUARD',
  'IN_RANGE_EDGE_LOW', 'OUT_OF_RANGE_EVALUATING', 'EDGE_SUFFICIENT', 'OUT_OF_RANGE_PERSISTENT',
  'OUT_OF_RANGE_DEEP', 'COOLDOWN_ACTIVE', 'HEDGE_DRIFT', 'HEALTH_FACTOR_CRITICAL', 'AAVE_CONSTRAINT',
  'NO_ADMISSIBLE_CANDIDATE', 'DECISION_ALREADY_EXECUTED', 'HEDGE_CONFIRMING',
  'HEDGE_COALESCING',
]);

// MultiUserVault ABI (only functions needed by keeper)
const VAULT_ABI = [
  "function treasuryAddress() external view returns (address)",
  "function rangeManager() external view returns (address)",
  "function token0() external view returns (address)",
  "function token1() external view returns (address)",
  "function hedgeManager() external view returns (address)",
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
  "function syncFeesForDeposits() external",
  "function isRebalancing() external view returns (bool)"
];

// Treasury ABI (for bounty info + USDC balance check)
const TREASURY_ABI = [
  "function keeperBountyEnabled() external view returns (bool)",
  "function keeperBountyAmount() external view returns (uint256)",
  "function strategyCheckpointBountyEnabled() external view returns (bool)",
  "function strategyCheckpointBountyAmount() external view returns (uint256)",
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
// (hedgeTargetBps × token0InLP, default 100% = strict DN). It corrects both directions without caller sizing:
// flash-repay for over-hedge; borrow, oracle-bounded token0 sale and token1 collateral supply for under-hedge.
// The keeper staticCall skips any action whose cooldown, drift threshold or safety checks are not satisfied.
const AAVE_HEDGE_ABI = [
  "function vault() external view returns (address)",
  "function rangeManager() external view returns (address)",
  "function pool() external view returns (address)",
  "function getHedgeData() external view returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 healthFactor, uint256 availableBorrowsBase)",
  "function adjustHedge() external",
  "function repairHealthFactor() external",
  "function adjustHedgeBps() external view returns (uint16)",
  "function criticalHedgeBps() external view returns (uint16)",
  "function hfRepairTriggerBps() external view returns (uint16)", // urgent HF repair threshold
  "function hedgeTargetBps() external view returns (uint16)",   // hedge target in bps (10000 = 100%)
  // On-chain cooldown between normal permissionless adjustHedge() calls. Urgent HF repair bypasses it.
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
  const strategyEngine = new ethers.Contract(
    process.env.RANGE_STRATEGY_ENGINE_ADDRESS,
    RANGE_STRATEGY_ENGINE_ABI,
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
  return { rangeManager, vault, strategyEngine, hedgeManager, pauseController };
}

function sameAddress(actual, expected) {
  return ethers.getAddress(actual) === ethers.getAddress(expected);
}

async function assertKeeperTopology(rpcPool, { rangeManager, vault, strategyEngine, hedgeManager }) {
  if (String(process.env.STRATEGY_PROFILE || '').trim().toUpperCase() !== 'DELTA_NEUTRAL') {
    throw new Error('Keeper topology: STRATEGY_PROFILE must be DELTA_NEUTRAL for a DN keeper');
  }
  const expected = {
    rangeManager: process.env.RANGEMANAGER_ADDRESS,
    vault: process.env.VAULT_ADDRESS,
    hedgeManager: process.env.AAVE_HEDGE_MANAGER_ADDRESS,
    strategyEngine: process.env.RANGE_STRATEGY_ENGINE_ADDRESS,
    token0: process.env.TOKEN0_ADDRESS,
    token1: process.env.TOKEN1_ADDRESS,
  };

  const topology = await rpcPool.executeWithRetry(async (provider) => {
    const rm = rangeManager.connect(provider);
    const v = vault.connect(provider);
    const hm = hedgeManager.connect(provider);
    const engine = strategyEngine.connect(provider);
    const [
      rmCode,
      vaultCode,
      hmCode,
      engineCode,
      rmVault,
      rmToken0,
      rmToken1,
      rmEngine,
      vaultRm,
      vaultToken0,
      vaultToken1,
      vaultHm,
      hmVault,
      hmRm,
      engineRm,
      engineHm,
      enginePool,
      rmPool,
      engineProfile,
      engineMode,
      engineVersion,
    ] = await Promise.all([
      provider.getCode(expected.rangeManager),
      provider.getCode(expected.vault),
      provider.getCode(expected.hedgeManager),
      provider.getCode(expected.strategyEngine),
      rm.vault(),
      rm.token0(),
      rm.token1(),
      rm.strategyEngine(),
      v.rangeManager(),
      v.token0(),
      v.token1(),
      v.hedgeManager(),
      hm.vault(),
      hm.rangeManager(),
      engine.rangeManager(),
      engine.hedgeManager(),
      engine.pool(),
      rm.pool(),
      engine.profile(),
      engine.decisionMode(),
      engine.strategyVersion(),
    ]);
    return {
      rmCode, vaultCode, hmCode, engineCode, rmVault, rmToken0, rmToken1, rmEngine, vaultRm, vaultToken0,
      vaultToken1, vaultHm, hmVault, hmRm, engineRm, engineHm, enginePool, rmPool, engineProfile,
      engineMode, engineVersion,
    };
  });

  if (topology.rmCode === '0x') throw new Error('Keeper topology: RangeManager has no runtime code');
  if (topology.vaultCode === '0x') throw new Error('Keeper topology: Vault has no runtime code');
  if (topology.hmCode === '0x') throw new Error('Keeper topology: AaveHedgeManager has no runtime code');
  if (topology.engineCode === '0x') throw new Error('Keeper topology: RangeStrategyEngine has no runtime code');
  if (!sameAddress(topology.rmVault, expected.vault)) throw new Error('Keeper topology: RangeManager.vault mismatch');
  if (!sameAddress(topology.vaultRm, expected.rangeManager)) throw new Error('Keeper topology: Vault.rangeManager mismatch');
  if (!sameAddress(topology.vaultHm, expected.hedgeManager)) throw new Error('Keeper topology: Vault.hedgeManager mismatch');
  if (!sameAddress(topology.hmVault, expected.vault)) throw new Error('Keeper topology: AaveHedgeManager.vault mismatch');
  if (!sameAddress(topology.hmRm, expected.rangeManager)) throw new Error('Keeper topology: AaveHedgeManager.rangeManager mismatch');
  if (!sameAddress(topology.rmEngine, expected.strategyEngine)) throw new Error('Keeper topology: RangeManager.strategyEngine mismatch');
  if (!sameAddress(topology.engineRm, expected.rangeManager)) throw new Error('Keeper topology: engine.rangeManager mismatch');
  if (!sameAddress(topology.engineHm, expected.hedgeManager)) throw new Error('Keeper topology: engine.hedgeManager mismatch');
  if (!sameAddress(topology.enginePool, topology.rmPool)) throw new Error('Keeper topology: engine.pool mismatch');
  if (Number(topology.engineProfile) !== 1) throw new Error('Keeper topology: DN keeper requires DELTA_NEUTRAL profile');
  if (Number(topology.engineMode) !== 1) {
    throw new Error('Keeper topology: RangeStrategyEngine must use HYBRID mode');
  }
  if (Number(topology.engineVersion) !== 3) {
    throw new Error('Keeper topology: DELTA_NEUTRAL requires RangeStrategyEngine version 3');
  }
  if (!sameAddress(topology.rmToken0, expected.token0) || !sameAddress(topology.vaultToken0, expected.token0)) {
    throw new Error('Keeper topology: token0 mismatch');
  }
  if (!sameAddress(topology.rmToken1, expected.token1) || !sameAddress(topology.vaultToken1, expected.token1)) {
    throw new Error('Keeper topology: token1 mismatch');
  }
}

module.exports = {
  RANGEMANAGER_ABI,
  RANGE_STRATEGY_ENGINE_ABI,
  STRATEGY_ACTION,
  STRATEGY_ACTION_LABELS,
  STRATEGY_REASON_LABELS,
  VAULT_ABI,
  TREASURY_ABI,
  ERC20_ABI,
  AAVE_HEDGE_ABI,
  PAUSE_CONTROLLER_ABI,
  createContracts,
  assertKeeperTopology,
};
