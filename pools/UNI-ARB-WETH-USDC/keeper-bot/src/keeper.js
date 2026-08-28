// SPDX-License-Identifier: MIT

require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });

const { ethers } = require('ethers');
const { RPCPool } = require('./utils/rpc');
const {
  createContracts,
  assertKeeperTopology,
  TREASURY_ABI,
  ERC20_ABI,
  STRATEGY_ACTION,
  STRATEGY_ACTION_LABELS,
  STRATEGY_REASON_LABELS,
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
  try {
    await alerts[method](...args);
  } catch (error) {
    console.log(`  Keeper incident state error: ${(error.message || '').slice(0, 100)}`);
  }
}

function persistedActionName(label) {
  const value = String(label || '').toLowerCase();
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

async function main() {
  console.log('=== Liquid Hub Keeper Bot (Standard Pool) ===');
  console.log(`RangeManager: ${process.env.RANGEMANAGER_ADDRESS}`);
  console.log(`RangeStrategyEngine: ${process.env.RANGE_STRATEGY_ENGINE_ADDRESS}`);
  console.log(`Vault: ${process.env.VAULT_ADDRESS}`);
  console.log(`Check interval: ${CHECK_INTERVAL_MS / 60000} minutes`);
  console.log(`Mode: ${CHECK_ONLY ? 'CHECK ONLY' : 'ACTIVE'}\n`);

  // Validate required env vars (VAULT_ADDRESS kept for Treasury discovery)
  const required = [
    'RPC_URL',
    'RANGEMANAGER_ADDRESS',
    'RANGE_STRATEGY_ENGINE_ADDRESS',
    'VAULT_ADDRESS',
    'TOKEN0_ADDRESS',
    'TOKEN1_ADDRESS',
  ];
  if (!CHECK_ONLY) required.push('KEEPER_PRIVATE_KEY');
  for (const key of required) {
    if (!process.env[key]) {
      console.error(`Missing required env var: ${key}`);
      process.exit(1);
    }
  }

  const rpcPool = new RPCPool();
  await rpcPool.verifyProviderChains();
  const provider = rpcPool.getProvider();
  const { rangeManager, vault, strategyEngine, pauseController } = createContracts(provider);
  await assertKeeperTopology(rpcPool, { rangeManager, vault, strategyEngine });
  console.log('Keeper topology: RangeManager/Vault/RangeStrategyEngine/tokens verified\n');

  const actionAlerts = new PersistentActionAlerts({
    poolName: process.env.POOL_NAME || 'UNI-ARB-WETH-USDC',
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
      const depositEnabled = await readContract(rpcPool, treasury, 'depositBountyEnabled');
      const depositAmount = await readContract(rpcPool, treasury, 'depositBountyAmount');
      console.log(`Treasury: ${treasuryAddr}`);
      console.log(`Keeper bounty (rebalance): ${keeperEnabled ? ethers.formatUnits(keeperAmount, 6) + ' USDC' : 'disabled'}`);
      console.log(`Strategy checkpoint bounty: ${checkpointEnabled ? ethers.formatUnits(checkpointAmount, 6) + ' USDC' : 'disabled'}`);
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

  let wallet, rebalancer;
  if (!CHECK_ONLY) {
    wallet = new ethers.Wallet(process.env.KEEPER_PRIVATE_KEY, provider);
    rebalancer = new Rebalancer(rangeManager, vault, strategyEngine, wallet, rpcPool);
    console.log(`Keeper wallet: ${wallet.address}\n`);
  }

  // Main loop
  while (true) {
    try {
      await reconcileSignerState(rpcPool, actionAlerts);
      console.log(`[${new Date().toISOString()}] Checking bot instructions...`);

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
        console.log('  PauseController: not configured — skip deposits; strategy maintenance remains enabled');
      }

      // The checkpoint is permissionless and computes the canonical market state on-chain.
      // A keeper supplies no price, score, range or hedge target.
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
            console.log('  -> Recording canonical strategy checkpoint...');
            const receipt = await rpcPool.executeSignedTxWithRetry(async (p) => {
              const signer = wallet.connect(p);
              const engine = strategyEngine.connect(signer);
              return {
                wallet: signer,
                request: await engine.checkpointMarketState.populateTransaction(),
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

      // --- Process queued user deposit (permissionless, deposit bounty) ---
      // Convert a queued deposit into LP liquidity. The contract is atomic and self-protecting:
      // it refreshes the oracle, computes shares on the oracle, bounds swaps by the oracle (anti-MEV),
      // sets the rebalance lock (a concurrent withdraw reverts E32), and pays the deposit bounty.
      // It REVERTS if the queue is empty, no position NFT exists (initial mint is the protocol bot's
      // job), or the cache is stale — so we just try when a deposit is pending and skip on revert.
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
          } else if (strategyAction === STRATEGY_ACTION.RANGE_REBALANCE) {
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

      // Public keepers execute only the action authorized by the canonical on-chain enum.
      // Initial mint remains the sole protocol-bot-only operational path.
      if (strategyAction !== STRATEGY_ACTION.RANGE_REBALANCE) {
        console.log('  -> No rebalance needed\n');
        await trackAction(actionAlerts, 'success', 'rebalance', 'Rebalance completed elsewhere or no longer required');
      } else if (CHECK_ONLY) {
        console.log('  -> Rebalance needed (check-only mode, skipping)\n');
      } else {
        const keeperEnabled = treasury ? await readContract(rpcPool, treasury, 'keeperBountyEnabled') : false;
        const keeperAmount = treasury ? await readContract(rpcPool, treasury, 'keeperBountyAmount') : 0n;
        await checkBountyFunding('rebalance', keeperEnabled, keeperAmount, treasuryAddr, usdc, rpcPool);
        console.log('  -> Executing REBALANCE...');
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
