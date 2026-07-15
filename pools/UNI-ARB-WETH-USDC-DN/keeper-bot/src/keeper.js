require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });

const { ethers } = require('ethers');
const { RPCPool } = require('./utils/rpc');
const { createContracts, TREASURY_ABI, ERC20_ABI } = require('./utils/contracts');
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

      if (CHECK_ONLY) {
        await logPriceCacheBeforeDecision(rangeManager, rpcPool);
      } else {
        await rebalancer.ensureFreshPriceCacheForDecision();
      }

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

      // --- Dynamic range snapshot (permissionless, metrics bounty) ---
      // The on-chain range is computed from price snapshots stored in a ring buffer. Anyone can
      // record one when it is due (the contract spaces them by 24h/maxSnapshotsPerDay and reverts
      // otherwise). A successful call earns the metrics bounty. Independent of the rebalance check.
      // IMPORTANT (oracle freshness): this runs BEFORE the rebalance step below and earns the metrics
      // bounty. NB: rebalance() DOES refresh the priceCache itself (it calls _refreshAndRequireValid() at
      // the top), so freshness for the rebalance no longer depends on this snapshot — but keeping the order
      // lets a single cycle both snapshot (bounty) and rebalance on a fresh price.
      if (!CHECK_ONLY) {
        try {
          const due = await rpcPool.executeWithRetry(async (p) => {
            return await rangeManager.connect(p).isSnapshotDue();
          });
          if (due) {
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
          }
        } catch (e) {
          // Revert is expected when a snapshot is not yet due or price cache is stale — not fatal.
          console.log(`  Snapshot: skipped (${(e.reason || e.message || '').slice(0, 80)})`);
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
          if (pending > 0n && positions.length > 0 && !isRebalancing) {
            const depEnabled = treasury ? await readContract(rpcPool, treasury, 'depositBountyEnabled') : false;
            const depAmount = treasury ? await readContract(rpcPool, treasury, 'depositBountyAmount') : 0n;
            await checkBountyFunding('deposit', depEnabled, depAmount, treasuryAddr, usdc, rpcPool);
            console.log(`  -> ${pending.toString()} deposit(s) pending, processing one on-chain...`);
            const result = await rebalancer.processDeposit();
            if (result.success) console.log(`  -> Deposit processed (${result.txHashes.length} tx)`);
          }
        } catch (e) {
          console.log(`  Deposit: skipped (${(e.reason || e.message || '').slice(0, 80)})`);
        }
      }

      // --- Hedge adjustment (permissionless, hedge bounty) ---
      // DN refactor: adjustHedge() pilots on the net effective short (debt - free WETH HM - free WETH RM)
      // vs target (hedgeTargetBps × token0InLP). It corrects both directions atomically with no keeper-provided
      // sizing: flash-repay for over-hedge, borrow + oracle-bounded sale + collateral supply for under-hedge.
      // The staticCall prevents a transaction when drift is below the dynamic threshold, cooldown is active,
      // or a safety post-condition cannot be met. Every successful correction can earn the bounty.
      if (!CHECK_ONLY && hedgeManager && wallet) {
        try {
          // Always simulate the on-chain action. adjustHedge() itself applies the normal cooldown, while
          // its HF-repair branch deliberately bypasses that cooldown. An off-chain cooldown gate here would
          // therefore suppress a safety repair that the contract is explicitly ready to execute.
          const hedgeEnabled = treasury ? await readContract(rpcPool, treasury, 'hedgeBountyEnabled') : false;
          const hedgeAmount = treasury ? await readContract(rpcPool, treasury, 'hedgeBountyAmount') : 0n;
          await checkBountyFunding('hedge', hedgeEnabled, hedgeAmount, treasuryAddr, usdc, rpcPool);
          console.log('  -> Hedge drift above threshold, adjusting on-chain...');
          const rcpt = await rpcPool.executeSignedTxWithRetry(async (p) => {
            const signer = wallet.connect(p);
            const hedge = hedgeManager.connect(signer);
            // Static-call first: lets us distinguish "drift below threshold" (revert, normal) from
            // actually sending a tx, so we only pay gas when an adjustment will go through.
            await hedge.adjustHedge.staticCall();
            return {
              wallet: signer,
              request: await hedge.adjustHedge.populateTransaction(),
            };
          }, 'adjustHedge');
          console.log(`  -> Hedge adjusted: ${rcpt.hash}`);
        } catch (e) {
          // Revert is expected here for low drift, normal cooldown, or an unmet safety condition. Not fatal.
          console.log(`  Hedge: no adjustment (${(e.reason || e.message || '').slice(0, 80)})`);
        }
      }

      // Public keepers can call the allowed permissionless maintenance paths:
      // snapshots, queued deposit processing, hedge adjustment and atomic rebalance().
      // on the RangeManager. Other actions (MINT_INITIAL, etc.) are gated on-chain
      // by `onlyAuthorized` and reserved for the protocol bot / Safe, so we just
      // wait silently for the next cycle.
      // AUDIT M-01/H-06 : on rebalance si le RANGE l'exige, OU si un DRIFT DN peut nécessiter une recomposition.
      // Le rebalancer simule ensuite RangeManager.rebalance() en eth_call avec les paramètres calculés et skippe
      // proprement si la gate on-chain (needsRebalance || dnDriftCritical) refuserait la tx.
      let dnDriftRebalance = false;
      if (hasPosition && (!needsRebalance || action !== 'REBALANCE')) {
        try {
          const [, dnAmtIn] = await rpcPool.executeWithRetry(async (p) => {
            return await vault.connect(p).getRebalanceSwapParams();
          });
          dnDriftRebalance = dnAmtIn > 0n;
        } catch (_) { /* vue indisponible → pas de trigger DN */ }
      }
      const doRebalance = (needsRebalance && action === 'REBALANCE') || dnDriftRebalance;

      if (!doRebalance) {
        console.log('  -> No rebalance needed\n');
      } else if (CHECK_ONLY) {
        console.log(`  -> Rebalance needed (${dnDriftRebalance && !needsRebalance ? 'DN drift in-range' : 'range'}, check-only, skipping)\n`);
      } else {
        const keeperEnabled = treasury ? await readContract(rpcPool, treasury, 'keeperBountyEnabled') : false;
        const keeperAmount = treasury ? await readContract(rpcPool, treasury, 'keeperBountyAmount') : 0n;
        await checkBountyFunding('rebalance', keeperEnabled, keeperAmount, treasuryAddr, usdc, rpcPool);
        console.log(`  -> Executing REBALANCE (${dnDriftRebalance && !needsRebalance ? 'DN drift in-range' : 'range'})...`);
        const result = await rebalancer.executeRebalance(tokenId);
        if (result.success) {
          console.log(`  -> Success (${result.txHashes.length} txs)\n`);
        } else {
          console.error(`  -> Failed: ${result.error}\n`);
        }
      }

    } catch (error) {
      console.error(`Error: ${error.message}\n`);
    }

    if (CHECK_ONLY) break;
    await new Promise(resolve => setTimeout(resolve, CHECK_INTERVAL_MS));
  }
}

main().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});
