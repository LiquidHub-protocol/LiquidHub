// SPDX-License-Identifier: MIT

require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });

const { ethers } = require('ethers');
const { RPCPool } = require('./utils/rpc');
const {
  createContracts,
  syncCurrentBotModule,
  assertKeeperTopology,
  TREASURY_ABI,
  ERC20_ABI,
  STRATEGY_ACTION,
  STRATEGY_ACTION_LABELS,
  STRATEGY_REASON_LABELS,
  AAVE_HEDGE_ABI,
} = require('./utils/contracts');
const { PersistentActionAlerts } = require('./utils/action-alerts');
const { Rebalancer } = require('./rebalancer');

const CHECK_INTERVAL_MIN = Number(process.env.CHECK_INTERVAL_MIN || '1');
if (!Number.isFinite(CHECK_INTERVAL_MIN) || CHECK_INTERVAL_MIN <= 0) {
  throw new Error('CHECK_INTERVAL_MIN must be a finite number greater than 0');
}
const CHECK_INTERVAL_MS = CHECK_INTERVAL_MIN * 60 * 1000;
const CHECK_ONLY = process.argv.includes('--check-only');
const PRICE_CACHE_MAX_AGE_SEC = parseInt(
  process.env.KEEPER_PRICE_CACHE_MAX_AGE_SEC || process.env.BOT_PRICE_CACHE_MAX_AGE_SEC || '300',
  10
);
const HEDGE_ERROR_IFACE = new ethers.Interface(['error HedgeCheck(uint8 code)']);
const HEDGE_NO_ACTION_CODES = new Set([41, 42, 44]);
const AAVE_POOL_ABI = [
  'function getUserAccountData(address user) view returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor)',
];

function hedgeCheckCode(error) {
  if (error?.revert?.name === 'HedgeCheck' && error.revert.args?.length) {
    return Number(error.revert.args[0]);
  }
  const candidates = [error?.data, error?.error?.data, error?.info?.error?.data];
  for (const data of candidates) {
    if (typeof data !== 'string' || !data.startsWith('0x')) continue;
    try {
      const parsed = HEDGE_ERROR_IFACE.parseError(data);
      if (parsed?.name === 'HedgeCheck') return Number(parsed.args[0]);
    } catch (_) {}
  }
  return null;
}

function classifyHedgeSimulationError(error, rpcPool) {
  if (rpcPool.isProviderError(error)) return { kind: 'provider', code: null };
  const code = hedgeCheckCode(error);
  return { kind: HEDGE_NO_ACTION_CODES.has(code) ? 'no-action' : 'failure', code };
}

function needsPriceCacheRefresh(priceCache) {
  if (!priceCache.valid || BigInt(priceCache.price0) === 0n || BigInt(priceCache.price1) === 0n) return true;
  const ts = Number(priceCache.timestamp || 0);
  return !ts || (Math.floor(Date.now() / 1000) - ts) > PRICE_CACHE_MAX_AGE_SEC;
}

async function logPriceCacheBeforeDecision(rangeManager, rpcPool) {
  const priceCache = await rpcPool.executeWithRetry(async (provider) => {
    return await rangeManager.connect(provider).priceCache();
  });
  if (!needsPriceCacheRefresh(priceCache)) return false;
  console.log('  priceCache stale/invalid before keeper decision — action paths refresh it atomically before use');
  return true;
}

async function readContract(rpcPool, contract, method, ...args) {
  return await rpcPool.executeWithRetry(async (provider) => {
    return await contract.connect(provider)[method](...args);
  });
}

async function readLiveHfSafetyState(rpcPool, hedgeManager) {
  return await rpcPool.executeWithRetry(async (provider) => {
    const hm = hedgeManager.connect(provider);
    const [poolAddress, triggerBps] = await Promise.all([hm.pool(), hm.hfRepairTriggerBps()]);
    const aavePool = new ethers.Contract(poolAddress, AAVE_POOL_ABI, provider);
    const account = await aavePool.getUserAccountData(hedgeManager.target);
    const debtBase = BigInt(account.totalDebtBase ?? account[1]);
    const healthFactor = BigInt(account.healthFactor ?? account[5]);
    const trigger = BigInt(triggerBps);
    return {
      debtBase,
      healthFactor,
      triggerBps: trigger,
      repairRequired: debtBase > 0n && healthFactor < trigger * 100_000_000_000_000n,
    };
  });
}

async function assertHfRepairTopology(rpcPool, hedgeManager) {
  const expectedHedgeManager = process.env.AAVE_HEDGE_MANAGER_ADDRESS;
  const topology = await rpcPool.executeWithRetry(async (provider) => {
    const hm = hedgeManager.connect(provider);
    const [hedgeCode, poolAddress, triggerBps] = await Promise.all([
      provider.getCode(expectedHedgeManager),
      hm.pool(),
      hm.hfRepairTriggerBps(),
    ]);
    const poolCode = await provider.getCode(poolAddress);
    return { hedgeCode, poolCode, poolAddress, triggerBps };
  });
  if (topology.hedgeCode === '0x') throw new Error('HF safety topology: AaveHedgeManager has no runtime code');
  if (!ethers.isAddress(topology.poolAddress) || topology.poolCode === '0x') {
    throw new Error('HF safety topology: on-chain Aave pool has no runtime code');
  }
  const trigger = Number(topology.triggerBps);
  if (!Number.isInteger(trigger) || trigger <= 10_000 || trigger > 30_000) {
    throw new Error('HF safety topology: invalid on-chain repair trigger');
  }
}

/**
 * Resolves the Treasury contract. Prefers TREASURY_ADDRESS from .env (lets the keeper read
 * the USDC balance and warn when underfunded); falls back to vault.treasuryAddress() on-chain.
 * Returns { treasury, treasuryAddr, usdc } or nulls if unavailable.
 */
async function resolveTreasury(rpcPool, vault) {
  try {
    const treasuryAddr = process.env.TREASURY_ADDRESS || await readContract(rpcPool, vault, 'treasuryAddress');
    const treasury = new ethers.Contract(treasuryAddr, TREASURY_ABI, rpcPool.getProvider());
    let usdc = null;
    try {
      const usdcAddr = await readContract(rpcPool, treasury, 'usdc');
      usdc = new ethers.Contract(usdcAddr, ERC20_ABI, rpcPool.getProvider());
    } catch (_) { /* older Treasury without usdc() getter — balance check skipped */ }
    return { treasury, treasuryAddr, usdc };
  } catch (e) {
    return { treasury: null, treasuryAddr: null, usdc: null };
  }
}

/**
 * Logs a warning if the Treasury USDC balance is below the bounty amount. The action itself
 * always succeeds on-chain (the contract wraps the payout in try/catch) — only the bounty is
 * skipped silently when the Treasury is empty. Returns true if the bounty looks payable.
 */
async function checkBountyFunding(label, enabled, amount, treasuryAddr, usdc, rpcPool) {
  if (!enabled || !usdc || !treasuryAddr) return true;
  try {
    const bal = await readContract(rpcPool, usdc, 'balanceOf', treasuryAddr);
    if (bal < amount) {
      console.log(`  ⚠️  Treasury insufficiently funded for ${label} bounty (` +
        `${ethers.formatUnits(bal, 6)} < ${ethers.formatUnits(amount, 6)} USDC) — ` +
        `action will execute, no bounty paid`);
      return false;
    }
  } catch (_) { /* balance read failed — don't block the action */ }
  return true;
}

async function trackAction(alerts, method, ...args) {
  if (!alerts || typeof alerts[method] !== 'function') return;
  try {
    await alerts[method](...args);
  } catch (error) {
    console.log(`  Keeper incident state error: ${(error.message || '').slice(0, 100)}`);
  }
}

async function runHfSafetyLane({ rpcPool, hedgeManager, wallet, actionAlerts = null }) {
  const hfSafety = await readLiveHfSafetyState(rpcPool, hedgeManager);
  if (!hfSafety.repairRequired) return { required: false, repaired: false };

  const hf = Number(hfSafety.healthFactor) / 1e18;
  console.log(
    `  🚨 HF ${hf.toFixed(4)} below ${(Number(hfSafety.triggerBps) / 10_000).toFixed(4)}; ` +
    'repairHealthFactor() takes priority over every ordinary action'
  );
  if (CHECK_ONLY) {
    console.log('  -> Safety repair required (check-only mode, skipping transaction)');
    return { required: true, repaired: false };
  }

  const repaired = await executeHedgeIfReady({
    hedgeManager,
    wallet,
    rpcPool,
    actionAlerts,
    label: 'hfRepair',
    bypassFeeCap: true,
    hfRepairOnly: true,
  });
  const afterRepair = await readLiveHfSafetyState(rpcPool, hedgeManager);
  if (afterRepair.repairRequired) {
    throw new Error('HF remains below the on-chain repair trigger; ordinary actions are deferred');
  }
  return { required: true, repaired };
}

function persistedActionName(label) {
  const value = String(label || '').toLowerCase();
  if (value.includes('compound')) return 'compound';
  if (value.includes('checkpoint')) return 'checkpoint';
  if (value.includes('rebalance')) return 'rebalance';
  if (value.includes('hedge')) return 'adjustHedge';
  if (value.includes('deposit')) return 'deposit';
  if (value.includes('syncfees')) return 'deposit';
  return 'cycle';
}

function strategyLabel(labels, value, fallback) {
  return labels[Number(value)] || `${fallback}_${Number(value)}`;
}

async function readStrategyState(rpcPool, rangeManager, strategyEngine) {
  return await rpcPool.executeWithRetry(async (provider) => {
    const rm = rangeManager.connect(provider);
    const engine = strategyEngine.connect(provider);
    const [positions, decision, checkpointDue] = await Promise.all([
      rm.getOwnerPositions(),
      engine.previewDecision(),
      engine.checkpointDue(),
    ]);
    return { positions, decision, checkpointDue };
  });
}

async function reconcileSignerState(rpcPool, actionAlerts) {
  const recovered = await rpcPool.reconcilePendingSignedTx();
  if (!recovered) return;

  const origin = recovered.poolName || 'unknown pool';
  const action = persistedActionName(recovered.label);
  console.log(
    `  Shared signer recovery: ${recovered.status} ${recovered.label || 'transaction'} ` +
    `from ${origin} (${recovered.txHash})`
  );
  if (origin !== rpcPool.poolName) return;
  if (recovered.status === 'confirmed') {
    await trackAction(actionAlerts, 'success', action, `Recovered transaction confirmed: ${recovered.txHash}`);
  } else if (recovered.status === 'failed') {
    await trackAction(actionAlerts, 'failure', action, `Recovered transaction failed: ${recovered.txHash}`);
  }
  // "replaced" means the nonce was mined by another transaction. The cycle now
  // rereads every decision on-chain instead of attributing an unknown tx to this action.
}

async function executeHedgeIfReady({
  hedgeManager,
  wallet,
  rpcPool,
  actionAlerts,
  label,
  beforeSend,
  bypassFeeCap = false,
  hfRepairOnly = false,
}) {
  const method = hfRepairOnly ? 'repairHealthFactor' : 'adjustHedge';
  try {
    await rpcPool.executeWithRetry(async (provider) => {
      await hedgeManager.connect(provider)[method].staticCall();
    });
  } catch (error) {
    const classification = classifyHedgeSimulationError(error, rpcPool);
    const suffix = classification.code === null ? '' : ` [HedgeCheck ${classification.code}]`;
    if (classification.kind === 'no-action') {
      console.log(`  ${label}: no action${suffix}`);
      await trackAction(actionAlerts, 'success', 'adjustHedge', 'Adjustment no longer required');
    } else {
      console.log(`  ${label}: simulation failed${suffix} (${(error.reason || error.message || '').slice(0, 80)})`);
      await trackAction(actionAlerts, 'failure', 'adjustHedge', error.reason || error.message);
    }
    return false;
  }

  if (beforeSend) await beforeSend();
  try {
    const receipt = await rpcPool.executeSignedTxWithRetry(async (provider) => {
      const signer = wallet.connect(provider);
      return {
        wallet: signer,
        request: await hedgeManager.connect(signer)[method].populateTransaction(),
      };
    }, label, 3, { bypassFeeCap });
    console.log(`  -> ${label} executed: ${receipt.hash}`);
    let postRepair;
    try {
      const live = await readLiveHfSafetyState(rpcPool, hedgeManager);
      postRepair = { debtBase: live.debtBase, hf: live.healthFactor, triggerBps: live.triggerBps };
    } catch (postCheckError) {
      await trackAction(
        actionAlerts,
        'critical',
        'hfRepairPostCheck',
        `HF impossible à vérifier après la transaction confirmée ${receipt.hash}: ${postCheckError.message}. Contrôle Safe immédiat requis.`
      );
      console.log(`  🚨 ${label}: HF post-transaction impossible à vérifier`);
      return false;
    }
    const hfBps = postRepair.hf / 100_000_000_000_000n;
    if (postRepair.debtBase > 0n && hfBps < postRepair.triggerBps) {
      const hfText = (Number(postRepair.hf) / 1e18).toFixed(3);
      const safeEscalation = hfBps <= 12_500n
        ? ' HF sous 1,25: alerte Safe renforcée et intervention immédiate.'
        : ' Vérifier immédiatement une intervention Safe si aucune nouvelle réparation ne peut être confirmée.';
      await trackAction(
        actionAlerts,
        'critical',
        'hfRepairPostCheck',
        `HF ${hfText} reste sous le seuil ${(Number(postRepair.triggerBps) / 10_000).toFixed(2)} après ${receipt.hash}.${safeEscalation}`
      );
      console.log(`  🚨 ${label}: HF ${hfText} reste sous le seuil après confirmation`);
      return false;
    }
    await trackAction(actionAlerts, 'success', 'hfRepairPostCheck', `HF post-transaction validé: ${receipt.hash}`);
    await trackAction(actionAlerts, 'success', 'adjustHedge', `Hedge adjusted: ${receipt.hash}`);
    return true;
  } catch (error) {
    let stillRequired = true;
    try {
      await rpcPool.executeWithRetry(async (provider) => {
        await hedgeManager.connect(provider).adjustHedge.staticCall();
      });
    } catch (recheckError) {
      stillRequired = classifyHedgeSimulationError(recheckError, rpcPool).kind !== 'no-action';
    }
    if (stillRequired) {
      await trackAction(actionAlerts, 'failure', 'adjustHedge', error.reason || error.message);
      console.log(`  ${label}: failed while still required (${(error.reason || error.message || '').slice(0, 80)})`);
    } else {
      await trackAction(actionAlerts, 'success', 'adjustHedge', 'Adjustment completed elsewhere or no longer required');
      console.log(`  ${label}: no longer required after send race`);
    }
    return false;
  }
}

async function main() {
  console.log('=== Liquid Hub Keeper Bot (Delta Neutral Pool) ===');
  console.log(`RangeManager: ${process.env.RANGEMANAGER_ADDRESS}`);
  console.log(`RangeStrategyEngine: ${process.env.RANGE_STRATEGY_ENGINE_ADDRESS}`);
  console.log(`Vault: ${process.env.VAULT_ADDRESS}`);
  console.log(`AaveHedgeManager: ${process.env.AAVE_HEDGE_MANAGER_ADDRESS || 'not configured'}`);
  console.log(`Check interval: ${CHECK_INTERVAL_MS / 60000} minutes`);
  console.log(`Mode: ${CHECK_ONLY ? 'CHECK ONLY' : 'ACTIVE'}\n`);

  const safetyRequired = [
    'RPC_URL',
    'AAVE_HEDGE_MANAGER_ADDRESS',
  ];
  if (!CHECK_ONLY) safetyRequired.push('KEEPER_PRIVATE_KEY');
  for (const key of safetyRequired) {
    if (!process.env[key]) {
      console.error(`Missing required env var: ${key}`);
      process.exit(1);
    }
  }

  const rpcPool = new RPCPool();
  await rpcPool.verifyProviderChains();
  const provider = rpcPool.getProvider();
  const safetyHedgeManager = new ethers.Contract(
    process.env.AAVE_HEDGE_MANAGER_ADDRESS,
    AAVE_HEDGE_ABI,
    provider
  );
  await assertHfRepairTopology(rpcPool, safetyHedgeManager);
  const wallet = CHECK_ONLY ? null : new ethers.Wallet(process.env.KEEPER_PRIVATE_KEY, provider);

  // Startup safety lane comes before the RangeStrategyEngine and ordinary topology. It can also
  // replace an ordinary pending transaction at the keeper nonce through executeSignedTxWithRetry().
  await runHfSafetyLane({ rpcPool, hedgeManager: safetyHedgeManager, wallet });

  const required = [
    'RANGEMANAGER_ADDRESS',
    'RANGE_STRATEGY_ENGINE_ADDRESS',
    'SAFE_MODULE_ADDRESS',
    'VAULT_ADDRESS',
    'TOKEN0_ADDRESS',
    'TOKEN1_ADDRESS',
  ];
  for (const key of required) {
    if (!process.env[key]) {
      console.error(`Missing required env var: ${key}`);
      process.exit(1);
    }
  }
  const contracts = createContracts(provider);
  const { rangeManager, vault, strategyEngine, hedgeManager, pauseController } = contracts;
  let secureBotModule = await syncCurrentBotModule(rpcPool, rangeManager, contracts.secureBotModule);
  await assertKeeperTopology(rpcPool, { rangeManager, vault, strategyEngine, secureBotModule, hedgeManager });
  console.log('Keeper topology: RangeManager/Vault/RangeStrategyEngine/SecureBotModule/AaveHedgeManager/tokens verified\n');

  const actionAlerts = new PersistentActionAlerts({
    poolName: process.env.POOL_NAME || 'UNI-ARB-WETH-USDC-DN',
  });
  await actionAlerts.init();

  // Resolve Treasury + bounty info
  const { treasury, treasuryAddr, usdc } = await resolveTreasury(rpcPool, vault);
  if (treasury) {
    try {
      const keeperEnabled = await readContract(rpcPool, treasury, 'keeperBountyEnabled');
      const keeperAmount = await readContract(rpcPool, treasury, 'keeperBountyAmount');
      const checkpointEnabled = await readContract(rpcPool, treasury, 'strategyCheckpointBountyEnabled');
      const checkpointAmount = await readContract(rpcPool, treasury, 'strategyCheckpointBountyAmount');
      const hedgeEnabled = await readContract(rpcPool, treasury, 'hedgeBountyEnabled');
      const hedgeAmount = await readContract(rpcPool, treasury, 'hedgeBountyAmount');
      const depositEnabled = await readContract(rpcPool, treasury, 'depositBountyEnabled');
      const depositAmount = await readContract(rpcPool, treasury, 'depositBountyAmount');
      console.log(`Treasury: ${treasuryAddr}`);
      console.log(`Keeper bounty (rebalance): ${keeperEnabled ? ethers.formatUnits(keeperAmount, 6) + ' USDC' : 'disabled'}`);
      console.log(`Strategy checkpoint bounty: ${checkpointEnabled ? ethers.formatUnits(checkpointAmount, 6) + ' USDC' : 'disabled'}`);
      console.log(`Hedge bounty (adjustHedge): ${hedgeEnabled ? ethers.formatUnits(hedgeAmount, 6) + ' USDC' : 'disabled'}`);
      console.log(`Deposit bounty (process): ${depositEnabled ? ethers.formatUnits(depositAmount, 6) + ' USDC' : 'disabled'}`);
      if (usdc) {
        const bal = await readContract(rpcPool, usdc, 'balanceOf', treasuryAddr);
        console.log(`Treasury USDC balance: ${ethers.formatUnits(bal, 6)} USDC\n`);
      } else {
        console.log('');
      }
    } catch (e) {
      console.log(`Treasury bounty info unavailable: ${e.message}\n`);
    }
  } else {
    console.log('Treasury info unavailable\n');
  }

  let rebalancer;
  if (!CHECK_ONLY) {
    rebalancer = new Rebalancer(
      rangeManager,
      vault,
      strategyEngine,
      hedgeManager,
      wallet,
      rpcPool,
      secureBotModule,
      async () => runHfSafetyLane({ rpcPool, hedgeManager, wallet, actionAlerts })
    );
    console.log(`Keeper wallet: ${wallet.address}\n`);
  }

  while (true) {
    try {
      console.log(`[${new Date().toISOString()}] Checking bot instructions...`);

      // First-priority safety lane: this reads Aave directly and does not depend on the strategy engine,
      // PauseController or an ordinary pending pool action. The contract rechecks the live HF atomically.
      await runHfSafetyLane({ rpcPool, hedgeManager, wallet, actionAlerts });

      await reconcileSignerState(rpcPool, actionAlerts);

      secureBotModule = await syncCurrentBotModule(rpcPool, rangeManager, secureBotModule, rebalancer);
      const progressiveStatus = Number(await readContract(
        rpcPool, secureBotModule, 'progressiveRebalanceStatus'
      ));
      if (progressiveStatus !== 0 || await readContract(rpcPool, vault, 'isRebalancing')) {
        if (CHECK_ONLY) {
          console.log(`  Progressive DN rebalance active (state ${progressiveStatus}); an active keeper must resume it.`);
        } else {
          const result = await rebalancer.resumeProgressiveRebalanceIfActive();
          await trackAction(
            actionAlerts,
            'success',
            'rebalance',
            `Progressive DN rebalance resumed (${result?.txHashes?.length || 0} transaction(s))`
          );
        }
        await trackAction(actionAlerts, 'success', 'cycle', 'Progressive DN rebalance handled after HF safety');
        if (CHECK_ONLY) break;
        await new Promise(resolve => setTimeout(resolve, CHECK_INTERVAL_MS));
        continue;
      }

      await logPriceCacheBeforeDecision(rangeManager, rpcPool);

      let strategyState = await readStrategyState(rpcPool, rangeManager, strategyEngine);
      let { positions, decision, checkpointDue } = strategyState;
      let hasPosition = positions.length > 0;
      let tokenId = hasPosition ? positions[0] : 0n;
      let strategyAction = Number(decision.action);
      let actionLabel = strategyLabel(STRATEGY_ACTION_LABELS, decision.action, 'ACTION');
      let reasonLabel = strategyLabel(STRATEGY_REASON_LABELS, decision.reason, 'REASON');

      console.log(`  Position: ${hasPosition ? '#' + tokenId.toString() : 'none'}`);
      if (hasPosition) {
        console.log(`  Strategy action: ${actionLabel}`);
        console.log(`  Strategy reason: ${reasonLabel}`);
        console.log(`  Strategy epoch: ${decision.epoch.toString()} (${decision.dataFresh ? 'fresh' : 'not executable'})`);
      }

      // Pause reads fail closed for deposit processing only. Permissionless position
      // maintenance below remains active even when the controller cannot be read.
      let inflowsPaused = !pauseController;
      if (pauseController) {
        try {
          inflowsPaused = await rpcPool.executeWithRetry(async (p) => {
            return await pauseController.connect(p).inflowsPaused();
          });
          if (inflowsPaused) {
            console.log('  PauseController: inflows paused — skip deposit processing; strategy maintenance remains enabled');
          }
        } catch (e) {
          inflowsPaused = true;
          console.log(
            `  PauseController: unavailable (${(e.message || '').slice(0, 80)}) — ` +
            'skip deposits; strategy maintenance remains enabled'
          );
        }
      } else {
        console.log(
          '  PauseController: not configured — skip deposits; ' +
          'strategy maintenance remains enabled'
        );
      }

      // DN: Show AAVE hedge state. Mirrors the format used by the protocol's
      // dn-aave-watcher (`aave-watcher.js`) so logs are easy to compare.
      // getHedgeData() returns: totalCollateralBase, totalDebtBase, healthFactor,
      // availableBorrowsBase (all 8-decimal USD except healthFactor in 1e18).
      if (hedgeManager) {
        try {
          const [totalCollateralBase, totalDebtBase, healthFactor] = await rpcPool.executeWithRetry(async (p) => {
            return await hedgeManager.connect(p).getHedgeData();
          });
          const totalCollateralUSD = Number(totalCollateralBase) / 1e8;
          const totalDebtUSD = Number(totalDebtBase) / 1e8;
          if (totalCollateralUSD < 1 && totalDebtUSD < 1) {
            console.log(`  [UNI-ARB-WETH-USDC-DN] No AAVE position (collateral=$${totalCollateralUSD.toFixed(2)}, debt=$${totalDebtUSD.toFixed(2)}) — skip`);
          } else {
            const hfFloat = Number(healthFactor) / 1e18;
            const warnThreshold = parseFloat(process.env.AAVE_HEALTH_WARN || '1.40');
            let status = 'OK';
            if (hfFloat < parseFloat(process.env.AAVE_HEALTH_EMERGENCY || '1.15')) status = 'EMERGENCY';
            else if (hfFloat < parseFloat(process.env.AAVE_HEALTH_DELEVERAGE || '1.25')) status = 'DELEVERAGE';
            else if (hfFloat < warnThreshold) status = 'WARNING';
            console.log(`  AAVE: collateral=$${totalCollateralUSD.toFixed(2)}, debt=$${totalDebtUSD.toFixed(2)}, HF=${hfFloat.toFixed(4)} (${status})`);
          }
        } catch (e) {
          console.log(`  AAVE: unavailable (${(e.message || '').slice(0, 80)})`);
        }
      }

      // HF_REPAIR bypasses the normal keeper window and is attempted immediately by every caller.
      if (strategyAction === STRATEGY_ACTION.HF_REPAIR) {
        if (CHECK_ONLY) {
          console.log('  -> Safety repair required (check-only mode, skipping transaction)');
        } else {
          await executeHedgeIfReady({
            hedgeManager,
            wallet,
            rpcPool,
            actionAlerts,
            label: 'hfRepair',
            bypassFeeCap: true,
            hfRepairOnly: true,
          });
          strategyState = await readStrategyState(rpcPool, rangeManager, strategyEngine);
          ({ positions, decision, checkpointDue } = strategyState);
          hasPosition = positions.length > 0;
          tokenId = hasPosition ? positions[0] : 0n;
          strategyAction = Number(decision.action);
          actionLabel = strategyLabel(STRATEGY_ACTION_LABELS, decision.action, 'ACTION');
          reasonLabel = strategyLabel(STRATEGY_REASON_LABELS, decision.reason, 'REASON');
        }
      }

      // Canonical checkpoint: the keeper supplies no market data, target range or hedge size.
      if (checkpointDue) {
        if (CHECK_ONLY) {
          console.log('  -> Strategy checkpoint due (check-only mode, skipping transaction)');
        } else {
          try {
            const checkpointEnabled = treasury
              ? await readContract(rpcPool, treasury, 'strategyCheckpointBountyEnabled')
              : false;
            const checkpointAmount = treasury
              ? await readContract(rpcPool, treasury, 'strategyCheckpointBountyAmount')
              : 0n;
            await checkBountyFunding(
              'strategy checkpoint',
              checkpointEnabled,
              checkpointAmount,
              treasuryAddr,
              usdc,
              rpcPool
            );
            const receipt = await rpcPool.executeSignedTxWithRetry(async (providerForTx) => {
              const signer = wallet.connect(providerForTx);
              return {
                wallet: signer,
                request: await strategyEngine.connect(signer).checkpointMarketState.populateTransaction(),
              };
            }, 'checkpointMarketState');
            console.log(`  -> Strategy checkpoint recorded: ${receipt.hash}`);
            await trackAction(actionAlerts, 'success', 'checkpoint', `Checkpoint recorded: ${receipt.hash}`);
          } catch (error) {
            const stillDue = await readContract(rpcPool, strategyEngine, 'checkpointDue').catch(() => true);
            if (stillDue) {
              console.log(`  Strategy checkpoint skipped: ${(error.reason || error.message || '').slice(0, 90)}`);
              await trackAction(actionAlerts, 'failure', 'checkpoint', error.reason || error.message);
            } else {
              console.log('  Strategy checkpoint completed by another keeper');
              await trackAction(actionAlerts, 'success', 'checkpoint', 'Checkpoint completed by another keeper');
            }
          }
        }

        strategyState = await readStrategyState(rpcPool, rangeManager, strategyEngine);
        ({ positions, decision, checkpointDue } = strategyState);
        hasPosition = positions.length > 0;
        tokenId = hasPosition ? positions[0] : 0n;
        strategyAction = Number(decision.action);
        actionLabel = strategyLabel(STRATEGY_ACTION_LABELS, decision.action, 'ACTION');
        reasonLabel = strategyLabel(STRATEGY_REASON_LABELS, decision.reason, 'REASON');
        console.log(`  Strategy refreshed: action=${actionLabel}, reason=${reasonLabel}`);
      }

      if (strategyAction === STRATEGY_ACTION.HEDGE_ONLY) {
        if (CHECK_ONLY) {
          console.log('  -> Hedge adjustment eligible (check-only mode, skipping transaction)');
        } else {
          await executeHedgeIfReady({
            hedgeManager,
            wallet,
            rpcPool,
            actionAlerts,
            label: 'adjustHedge',
          });
          strategyState = await readStrategyState(rpcPool, rangeManager, strategyEngine);
          ({ positions, decision, checkpointDue } = strategyState);
          hasPosition = positions.length > 0;
          tokenId = hasPosition ? positions[0] : 0n;
          strategyAction = Number(decision.action);
          actionLabel = strategyLabel(STRATEGY_ACTION_LABELS, decision.action, 'ACTION');
          reasonLabel = strategyLabel(STRATEGY_REASON_LABELS, decision.reason, 'REASON');
        }
      }

      // --- Process queued user deposit (permissionless, deposit bounty) ---
      // Convert a queued deposit into LP liquidity. Atomic + self-protecting: refreshes the oracle,
      // computes shares on the oracle, bounds swaps by the oracle (anti-MEV), sets the rebalance lock
      // (concurrent withdraw reverts), pays the deposit bounty. Reverts if queue empty / no NFT
      // (initial mint is the protocol bot's job) / cache stale. AUDIT (refonte DN) : the DN hedge IS opened
      // ATOMICALLY inside processDepositPermissionless (via DnDepositLib.openDepositHedge) + a strict post-check
      // in the same tx — the keeper does not touch AAVE directly; the contract handles supply/borrow/sweep and
      // reverts if the resulting hedge drifts beyond tolerance.
      if (!CHECK_ONLY && !inflowsPaused) {
        try {
          const [pending, positions, isRebalancing] = await rpcPool.executeWithRetry(async (p) => {
            const v = vault.connect(p);
            const rm = rangeManager.connect(p);
            return await Promise.all([
              v.getPendingDepositsCount(),
              rm.getOwnerPositions(),
              v.isRebalancing(),
            ]);
          });
          if (pending === 0n) {
            await trackAction(actionAlerts, 'success', 'deposit', 'No queued deposit remains');
            await trackAction(
              actionAlerts,
              'success',
              'mint',
              positions.length > 0 ? 'Initial position is available' : 'No queued deposit requires an initial mint'
            );
          } else if (positions.length === 0) {
            const message = `${pending} queued deposit(s) waiting for the main bot initial mint`;
            console.log(`  Deposit deferred: ${message}`);
            await trackAction(actionAlerts, 'failure', 'mint', message);
          } else if ([
            STRATEGY_ACTION.HEDGE_ONLY,
            STRATEGY_ACTION.RANGE_AND_HEDGE,
            STRATEGY_ACTION.HF_REPAIR,
          ].includes(strategyAction)) {
            await trackAction(actionAlerts, 'success', 'mint', 'Initial position is available');
            console.log(`  Deposit deferred: ${actionLabel} is eligible (${reasonLabel})`);
          } else if (!isRebalancing) {
            await trackAction(actionAlerts, 'success', 'mint', 'Initial position is available');
            const depEnabled = treasury ? await readContract(rpcPool, treasury, 'depositBountyEnabled') : false;
            const depAmount = treasury ? await readContract(rpcPool, treasury, 'depositBountyAmount') : 0n;
            await checkBountyFunding('deposit', depEnabled, depAmount, treasuryAddr, usdc, rpcPool);
            console.log(`  -> ${pending.toString()} deposit(s) pending, processing one on-chain...`);
            const result = await rebalancer.processDeposit();
            if (result.success) {
              console.log(`  -> Deposit processed (${result.txHashes.length} tx)`);
              await trackAction(actionAlerts, 'success', 'deposit', `Deposit processed: ${result.txHashes[0]}`);
            } else if (!result.deferred) {
              await trackAction(actionAlerts, 'failure', 'deposit', result.error);
            }
          }
        } catch (e) {
          console.log(`  Deposit: skipped (${(e.reason || e.message || '').slice(0, 80)})`);
          await trackAction(actionAlerts, 'failure', 'deposit', e.reason || e.message);
        }
      }

      // A non-zero swap plan or an out-of-range tick is never a trigger by itself.
      // Only RANGE_AND_HEDGE from the fresh canonical decision opens this path.
      const doRebalance = strategyAction === STRATEGY_ACTION.RANGE_AND_HEDGE;

      if (!doRebalance) {
        console.log('  -> No rebalance needed\n');
        await trackAction(actionAlerts, 'success', 'rebalance', 'Rebalance completed elsewhere or no longer required');
      } else if (CHECK_ONLY) {
        console.log('  -> Rebalance needed (check-only, skipping)\n');
      } else {
        const keeperEnabled = treasury ? await readContract(rpcPool, treasury, 'keeperBountyEnabled') : false;
        const keeperAmount = treasury ? await readContract(rpcPool, treasury, 'keeperBountyAmount') : 0n;
        await checkBountyFunding('rebalance', keeperEnabled, keeperAmount, treasuryAddr, usdc, rpcPool);
        console.log(`  -> Executing RANGE_AND_HEDGE (${reasonLabel})...`);
        const result = await rebalancer.executeRebalance(tokenId, decision.decisionHash);
        if (result.noAction) {
          console.log('  -> Rebalance completed elsewhere or no longer required\n');
          await trackAction(actionAlerts, 'success', 'rebalance', 'Rebalance no longer required after simulation');
        } else if (result.success) {
          console.log(`  -> Success (${result.txHashes.length} txs)\n`);
          await trackAction(actionAlerts, 'success', 'rebalance', `Rebalance executed: ${result.txHashes[0]}`);
        } else if (result.deferred) {
          console.log(`  -> Deferred: ${result.error}\n`);
        } else {
          console.error(`  -> Failed: ${result.error}\n`);
          await trackAction(actionAlerts, 'failure', 'rebalance', result.error);
        }
      }

      // HF/hedge/range actions retain priority; HOLD may reinvest without changing Aave exposure.
      if (!CHECK_ONLY && hasPosition && [STRATEGY_ACTION.NO_ACTION, STRATEGY_ACTION.CHECKPOINT_ONLY].includes(strategyAction)) {
        try {
          const result = await rebalancer.compoundPosition();
          if (!result.noAction) console.log(`  -> Fees reinvested in the current NFT: ${result.txHashes[0]}`);
          await trackAction(actionAlerts, 'success', 'compound', result.noAction ? 'No material amount to compound' : `Compound: ${result.txHashes[0]}`);
        } catch (error) {
          console.log(`  Compound deferred: ${(error.reason || error.message || '').slice(0, 100)}`);
          await trackAction(actionAlerts, 'failure', 'compound', error.reason || error.message);
        }
      }

      await trackAction(actionAlerts, 'success', 'cycle', 'Keeper cycle completed');
    } catch (error) {
      console.error(`Error: ${error.message}\n`);
      await trackAction(actionAlerts, 'failure', 'cycle', error.message);
    }

    if (CHECK_ONLY) break;
    await new Promise(resolve => setTimeout(resolve, CHECK_INTERVAL_MS));
  }
}

main().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});
