require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });

const { ethers } = require('ethers');
const { RPCPool } = require('./utils/rpc');
const { createContracts, TREASURY_ABI, ERC20_ABI } = require('./utils/contracts');
const { Rebalancer } = require('./rebalancer');

const CHECK_INTERVAL_MS = (parseInt(process.env.CHECK_INTERVAL_MIN || '10', 10)) * 60 * 1000;
const CHECK_ONLY = process.argv.includes('--check-only');

/**
 * Resolves the Treasury contract. Prefers TREASURY_ADDRESS from .env (lets the keeper read
 * the USDC balance and warn when underfunded); falls back to vault.treasuryAddress() on-chain.
 * Returns { treasury, treasuryAddr, usdc } or nulls if unavailable.
 */
async function resolveTreasury(provider, vault) {
  try {
    const treasuryAddr = process.env.TREASURY_ADDRESS || await vault.treasuryAddress();
    const treasury = new ethers.Contract(treasuryAddr, TREASURY_ABI, provider);
    let usdc = null;
    try {
      const usdcAddr = await treasury.usdc();
      usdc = new ethers.Contract(usdcAddr, ERC20_ABI, provider);
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
async function checkBountyFunding(label, enabled, amount, treasuryAddr, usdc) {
  if (!enabled || !usdc || !treasuryAddr) return true;
  try {
    const bal = await usdc.balanceOf(treasuryAddr);
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

  const required = ['RPC_URL', 'RANGEMANAGER_ADDRESS', 'VAULT_ADDRESS', 'TOKEN0_ADDRESS', 'TOKEN1_ADDRESS'];
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
  const { treasury, treasuryAddr, usdc } = await resolveTreasury(provider, vault);
  if (treasury) {
    try {
      const keeperEnabled = await treasury.keeperBountyEnabled();
      const keeperAmount = await treasury.keeperBountyAmount();
      const metricsEnabled = await treasury.metricsBountyEnabled();
      const metricsAmount = await treasury.metricsBountyAmount();
      const hedgeEnabled = await treasury.hedgeBountyEnabled();
      const hedgeAmount = await treasury.hedgeBountyAmount();
      const depositEnabled = await treasury.depositBountyEnabled();
      const depositAmount = await treasury.depositBountyAmount();
      console.log(`Treasury: ${treasuryAddr}`);
      console.log(`Keeper bounty (rebalance): ${keeperEnabled ? ethers.formatUnits(keeperAmount, 6) + ' USDC' : 'disabled'}`);
      console.log(`Metrics bounty (snapshot): ${metricsEnabled ? ethers.formatUnits(metricsAmount, 6) + ' USDC' : 'disabled'}`);
      console.log(`Hedge bounty (adjustHedge): ${hedgeEnabled ? ethers.formatUnits(hedgeAmount, 6) + ' USDC' : 'disabled'}`);
      console.log(`Deposit bounty (process): ${depositEnabled ? ethers.formatUnits(depositAmount, 6) + ' USDC' : 'disabled'}`);
      if (usdc) {
        const bal = await usdc.balanceOf(treasuryAddr);
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

  let wallet, rebalancer, rmSigner, hedgeSigner;
  if (!CHECK_ONLY) {
    wallet = new ethers.Wallet(process.env.KEEPER_PRIVATE_KEY, provider);
    rebalancer = new Rebalancer(rangeManager, vault, hedgeManager, wallet);
    rmSigner = rangeManager.connect(wallet);
    if (hedgeManager) hedgeSigner = hedgeManager.connect(wallet);
    console.log(`Keeper wallet: ${wallet.address}\n`);
  }

  while (true) {
    try {
      console.log(`[${new Date().toISOString()}] Checking bot instructions...`);

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
          inflowsPaused = await pauseController.inflowsPaused();
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
          const [totalCollateralBase, totalDebtBase, healthFactor] = await hedgeManager.getHedgeData();
          const totalCollateralUSD = Number(totalCollateralBase) / 1e8;
          const totalDebtUSD = Number(totalDebtBase) / 1e8;
          if (totalCollateralUSD < 1 && totalDebtUSD < 1) {
            console.log(`  [UNI-ARB-WETH-USDC-DN] No AAVE position (collateral=$${totalCollateralUSD.toFixed(2)}, debt=$${totalDebtUSD.toFixed(2)}) — skip`);
          } else {
            const hfFloat = Number(healthFactor) / 1e18;
            const warnThreshold = parseFloat(process.env.AAVE_HEALTH_WARN || '1.25');
            let status = 'OK';
            if (hfFloat < parseFloat(process.env.AAVE_HEALTH_EMERGENCY || '1.05')) status = 'EMERGENCY';
            else if (hfFloat < parseFloat(process.env.AAVE_HEALTH_DELEVERAGE || '1.15')) status = 'DELEVERAGE';
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
          const due = await rangeManager.isSnapshotDue();
          if (due) {
            const metricsEnabled = treasury ? await treasury.metricsBountyEnabled() : false;
            const metricsAmount = treasury ? await treasury.metricsBountyAmount() : 0n;
            await checkBountyFunding('metrics', metricsEnabled, metricsAmount, treasuryAddr, usdc);
            console.log('  -> Snapshot due, recording price on-chain...');
            const tx = await rmSigner.recordPriceSnapshot();
            const rcpt = await tx.wait();
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
          const pending = await vault.getPendingDepositsCount();
          const positions = await rangeManager.getOwnerPositions();
          if (pending > 0n && positions.length > 0 && !(await vault.isRebalancing())) {
            const depEnabled = treasury ? await treasury.depositBountyEnabled() : false;
            const depAmount = treasury ? await treasury.depositBountyAmount() : 0n;
            await checkBountyFunding('deposit', depEnabled, depAmount, treasuryAddr, usdc);
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
      // vs target (hedgeTargetBps × wethInLP). It only corrects an OVER-HEDGE (repay excess, WETH bought
      // on the market). On an UNDER-HEDGE it REVERTS (custom error UnderHedged) — the staticCall below
      // catches it so we never send a tx for nothing. It also REVERTS when drift < adjustHedgeBps or the
      // on-chain cooldown (hedgeAdjustCooldown) has not elapsed. A successful (over-hedge) call earns the bounty.
      if (!CHECK_ONLY && hedgeSigner) {
        try {
          // Pre-tx cooldown check: read the on-chain cooldown + last adjust timestamp and skip BEFORE
          // any tx (and even before the static-call) when the cooldown window is still open. This is
          // the single source of truth shared with the protocol bot — no divergence. cooldown=0 = off.
          const [cooldownSec, lastAdjustAt] = await Promise.all([
            hedgeManager.hedgeAdjustCooldown(),
            hedgeManager.lastHedgeAdjustAt(),
          ]);
          const cd = Number(cooldownSec);
          if (cd > 0) {
            const nowSec = Math.floor(Date.now() / 1000);
            const elapsed = nowSec - Number(lastAdjustAt);
            if (elapsed < cd) {
              console.log(`  Hedge: cooldown active (${elapsed}s / ${cd}s), skip adjustHedge`);
              throw { __cooldownSkip: true };
            }
          }
          const hedgeEnabled = treasury ? await treasury.hedgeBountyEnabled() : false;
          const hedgeAmount = treasury ? await treasury.hedgeBountyAmount() : 0n;
          // Static-call first: lets us distinguish "drift below threshold" (revert, normal) from
          // actually sending a tx, so we only pay gas when an adjustment will go through.
          await hedgeSigner.adjustHedge.staticCall();
          await checkBountyFunding('hedge', hedgeEnabled, hedgeAmount, treasuryAddr, usdc);
          console.log('  -> Hedge drift above threshold, adjusting on-chain...');
          const tx = await hedgeSigner.adjustHedge();
          const rcpt = await tx.wait();
          console.log(`  -> Hedge adjusted: ${rcpt.hash}`);
        } catch (e) {
          // Cooldown skip already logged above — swallow it silently.
          if (e && e.__cooldownSkip) { /* already logged */ }
          else {
            // Revert is expected here: under-hedge (UnderHedged), drift < adjustHedgeBps, or cooldown. Not fatal.
            console.log(`  Hedge: no adjustment (${(e.reason || e.message || '').slice(0, 80)})`);
          }
        }
      }

      // Public keepers can ONLY call rebalance() — it is the only public function
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
        const keeperEnabled = treasury ? await treasury.keeperBountyEnabled() : false;
        const keeperAmount = treasury ? await treasury.keeperBountyAmount() : 0n;
        await checkBountyFunding('rebalance', keeperEnabled, keeperAmount, treasuryAddr, usdc);
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
