require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });

const { ethers } = require('ethers');
const { RPCPool } = require('./utils/rpc');
const { createContracts, assertKeeperTopology, TREASURY_ABI, ERC20_ABI } = require('./utils/contracts');
const { PersistentActionAlerts } = require('./utils/action-alerts');
const { Rebalancer } = require('./rebalancer');

const CHECK_INTERVAL_MS = (parseInt(process.env.CHECK_INTERVAL_MIN || '10', 10)) * 60 * 1000;
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
  if (!needsPriceCacheRefresh(priceCache)) return;
  console.log('  priceCache stale/invalid before keeper decision — action paths refresh it atomically before use');
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
    console.log(`  Keeper alert state error: ${(error.message || '').slice(0, 100)}`);
  }
}

async function executeHedgeIfReady({ hedgeManager, wallet, rpcPool, actionAlerts, label, beforeSend }) {
  try {
    await rpcPool.executeWithRetry(async (provider) => {
      await hedgeManager.connect(provider).adjustHedge.staticCall();
    });
  } catch (error) {
    console.log(`  ${label}: no action (${(error.reason || error.message || '').slice(0, 80)})`);
    if (rpcPool.isProviderError(error)) {
      await trackAction(actionAlerts, 'failure', 'adjustHedge', error.reason || error.message);
    } else {
      await trackAction(actionAlerts, 'success', 'adjustHedge', 'Adjustment no longer required');
    }
    return false;
  }

  if (beforeSend) await beforeSend();
  try {
    const receipt = await rpcPool.executeSignedTxWithRetry(async (provider) => {
      const signer = wallet.connect(provider);
      return {
        wallet: signer,
        request: await hedgeManager.connect(signer).adjustHedge.populateTransaction(),
      };
    }, label);
    console.log(`  -> ${label} executed: ${receipt.hash}`);
    await trackAction(actionAlerts, 'success', 'adjustHedge', `Hedge adjusted: ${receipt.hash}`);
    return true;
  } catch (error) {
    let stillRequired = true;
    try {
      await rpcPool.executeWithRetry(async (provider) => {
        await hedgeManager.connect(provider).adjustHedge.staticCall();
      });
    } catch (recheckError) {
      stillRequired = rpcPool.isProviderError(recheckError);
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
  console.log(`Vault: ${process.env.VAULT_ADDRESS}`);
  console.log(`AaveHedgeManager: ${process.env.AAVE_HEDGE_MANAGER_ADDRESS || 'not configured'}`);
  console.log(`Check interval: ${CHECK_INTERVAL_MS / 60000} minutes`);
  console.log(`Mode: ${CHECK_ONLY ? 'CHECK ONLY' : 'ACTIVE'}\n`);

  const required = ['RPC_URL', 'RANGEMANAGER_ADDRESS', 'VAULT_ADDRESS', 'AAVE_HEDGE_MANAGER_ADDRESS', 'TOKEN0_ADDRESS', 'TOKEN1_ADDRESS'];
  if (!CHECK_ONLY) required.push('KEEPER_PRIVATE_KEY');
  for (const key of required) {
    if (!process.env[key]) {
      console.error(`Missing required env var: ${key}`);
      process.exit(1);
    }
  }

  const rpcPool = new RPCPool();
  const provider = rpcPool.getProvider();
  const { rangeManager, vault, hedgeManager, pauseController } = createContracts(provider);
  await assertKeeperTopology(rpcPool, { rangeManager, vault, hedgeManager });
  console.log('Keeper topology: RangeManager/Vault/tokens/AaveHedgeManager verified\n');

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
      const metricsEnabled = await readContract(rpcPool, treasury, 'metricsBountyEnabled');
      const metricsAmount = await readContract(rpcPool, treasury, 'metricsBountyAmount');
      const hedgeEnabled = await readContract(rpcPool, treasury, 'hedgeBountyEnabled');
      const hedgeAmount = await readContract(rpcPool, treasury, 'hedgeBountyAmount');
      const depositEnabled = await readContract(rpcPool, treasury, 'depositBountyEnabled');
      const depositAmount = await readContract(rpcPool, treasury, 'depositBountyAmount');
      console.log(`Treasury: ${treasuryAddr}`);
      console.log(`Keeper bounty (rebalance): ${keeperEnabled ? ethers.formatUnits(keeperAmount, 6) + ' USDC' : 'disabled'}`);
      console.log(`Metrics bounty (snapshot): ${metricsEnabled ? ethers.formatUnits(metricsAmount, 6) + ' USDC' : 'disabled'}`);
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

  let wallet, rebalancer;
  if (!CHECK_ONLY) {
    wallet = new ethers.Wallet(process.env.KEEPER_PRIVATE_KEY, provider);
    rebalancer = new Rebalancer(rangeManager, vault, hedgeManager, wallet, rpcPool);
    console.log(`Keeper wallet: ${wallet.address}\n`);
  }

  while (true) {
    try {
      console.log(`[${new Date().toISOString()}] Checking bot instructions...`);

      await logPriceCacheBeforeDecision(rangeManager, rpcPool);

      const [hasPosition, tokenId, needsRebalance, action, reason] = await rpcPool.executeWithRetry(
        async (p) => {
          const rm = rangeManager.connect(p);
          return await rm.getBotInstructions();
        }
      );

      console.log(`  Position: ${hasPosition ? '#' + tokenId.toString() : 'none'}`);
      if (hasPosition) {
        console.log(`  Needs rebalance: ${needsRebalance}`);
      }

      let inflowsPaused = false;
      if (pauseController) {
        try {
          inflowsPaused = await rpcPool.executeWithRetry(async (p) => {
            return await pauseController.connect(p).inflowsPaused();
          });
          if (inflowsPaused) {
            console.log('  PauseController: inflows paused — skip deposit processing; rebalance and hedge maintenance remain enabled');
          }
        } catch (e) {
          console.log(`  PauseController: unavailable (${(e.message || '').slice(0, 80)})`);
        }
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

      // --- Hedge/HF priority (permissionless) ---
      // Simuler avant snapshots et depots. Le contrat contourne le cooldown uniquement pour reparer un HF;
      // un drift insuffisant revert ici sans envoyer de transaction.
      if (!CHECK_ONLY && hedgeManager && wallet) {
        await executeHedgeIfReady({
          hedgeManager,
          wallet,
          rpcPool,
          actionAlerts,
          label: 'adjustHedge-priority',
        });
      }

      // --- Dynamic range snapshot (permissionless, metrics bounty) ---
      // The on-chain range is computed from price snapshots stored in a ring buffer. Anyone can
      // record one when it is due (the contract spaces them by 24h/maxSnapshotsPerDay and reverts
      // otherwise). A successful call earns the metrics bounty. Independent of the rebalance check.
      // IMPORTANT (oracle freshness): this runs BEFORE the rebalance step below and earns the metrics
      // bounty. NB: rebalance() DOES refresh the priceCache itself (it calls _refreshAndRequireValid() at
      // the top), so freshness for the rebalance no longer depends on this snapshot — but keeping the order
      // lets a single cycle both snapshot (bounty) and rebalance on a fresh price.
      if (!CHECK_ONLY) {
        let snapshotDue = false;
        try {
          snapshotDue = await rpcPool.executeWithRetry(async (p) => {
            return await rangeManager.connect(p).isSnapshotDue();
          });
          if (snapshotDue) {
            const metricsEnabled = treasury ? await readContract(rpcPool, treasury, 'metricsBountyEnabled') : false;
            const metricsAmount = treasury ? await readContract(rpcPool, treasury, 'metricsBountyAmount') : 0n;
            await checkBountyFunding('metrics', metricsEnabled, metricsAmount, treasuryAddr, usdc, rpcPool);
            console.log('  -> Snapshot due, recording price on-chain...');
            const rcpt = await rpcPool.executeSignedTxWithRetry(async (p) => {
              const signer = wallet.connect(p);
              const rm = rangeManager.connect(signer);
              return {
                wallet: signer,
                request: await rm.recordPriceSnapshot.populateTransaction(),
              };
            }, 'recordPriceSnapshot');
            console.log(`  -> Snapshot recorded: ${rcpt.hash}`);
            await trackAction(actionAlerts, 'success', 'snapshot', `Snapshot recorded: ${rcpt.hash}`);
          } else {
            await trackAction(actionAlerts, 'success', 'snapshot', 'Snapshot no longer due');
          }
        } catch (e) {
          console.log(`  Snapshot: skipped (${(e.reason || e.message || '').slice(0, 80)})`);
          await trackAction(actionAlerts, 'failure', 'snapshot', e.reason || e.message);
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

      // Public keepers can call the allowed permissionless maintenance paths:
      // snapshots, queued deposit processing, hedge adjustment and atomic rebalance().
      // on the RangeManager. Other actions (MINT_INITIAL, etc.) are gated on-chain
      // by `onlyAuthorized` and reserved for the protocol bot / Safe, so we just
      // wait silently for the next cycle.
      // A non-zero swap plan is not a rebalance signal. Only the on-chain instruction can open this path.
      const doRebalance = needsRebalance && action === 'REBALANCE';

      if (!doRebalance) {
        console.log('  -> No rebalance needed\n');
        await trackAction(actionAlerts, 'success', 'rebalance', 'Rebalance completed elsewhere or no longer required');
      } else if (CHECK_ONLY) {
        console.log('  -> Rebalance needed (check-only, skipping)\n');
      } else {
        const keeperEnabled = treasury ? await readContract(rpcPool, treasury, 'keeperBountyEnabled') : false;
        const keeperAmount = treasury ? await readContract(rpcPool, treasury, 'keeperBountyAmount') : 0n;
        await checkBountyFunding('rebalance', keeperEnabled, keeperAmount, treasuryAddr, usdc, rpcPool);
        console.log(`  -> Executing REBALANCE (${reason || 'on-chain signal'})...`);
        const result = await rebalancer.executeRebalance(tokenId);
        if (result.success) {
          console.log(`  -> Success (${result.txHashes.length} txs)\n`);
          await trackAction(actionAlerts, 'success', 'rebalance', `Rebalance executed: ${result.txHashes[0]}`);
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
