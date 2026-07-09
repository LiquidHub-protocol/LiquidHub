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
  console.log('=== Liquid Hub Keeper Bot (Standard Pool) ===');
  console.log(`RangeManager: ${process.env.RANGEMANAGER_ADDRESS}`);
  console.log(`Vault: ${process.env.VAULT_ADDRESS}`);
  console.log(`Check interval: ${CHECK_INTERVAL_MS / 60000} minutes`);
  console.log(`Mode: ${CHECK_ONLY ? 'CHECK ONLY' : 'ACTIVE'}\n`);

  // Validate required env vars (VAULT_ADDRESS kept for Treasury discovery)
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
  const { rangeManager, vault, pauseController } = createContracts(provider);

  // Resolve Treasury + bounty info
  const { treasury, treasuryAddr, usdc } = await resolveTreasury(provider, vault);
  if (treasury) {
    try {
      const keeperEnabled = await treasury.keeperBountyEnabled();
      const keeperAmount = await treasury.keeperBountyAmount();
      const metricsEnabled = await treasury.metricsBountyEnabled();
      const metricsAmount = await treasury.metricsBountyAmount();
      const depositEnabled = await treasury.depositBountyEnabled();
      const depositAmount = await treasury.depositBountyAmount();
      console.log(`Treasury: ${treasuryAddr}`);
      console.log(`Keeper bounty (rebalance): ${keeperEnabled ? ethers.formatUnits(keeperAmount, 6) + ' USDC' : 'disabled'}`);
      console.log(`Metrics bounty (snapshot): ${metricsEnabled ? ethers.formatUnits(metricsAmount, 6) + ' USDC' : 'disabled'}`);
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

  let wallet, rebalancer;
  if (!CHECK_ONLY) {
    wallet = new ethers.Wallet(process.env.KEEPER_PRIVATE_KEY, provider);
    rebalancer = new Rebalancer(rangeManager, vault, wallet, rpcPool);
    console.log(`Keeper wallet: ${wallet.address}\n`);
  }

  // Main loop
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
            console.log('  PauseController: inflows paused — skip deposit processing; rebalance remains enabled');
          }
        } catch (e) {
          console.log(`  PauseController: unavailable (${(e.message || '').slice(0, 80)})`);
        }
      }

      // --- Dynamic range snapshot (permissionless, metrics bounty) ---
      // The on-chain range is computed from price snapshots stored in a ring buffer. Anyone can
      // record one when it is due (the contract spaces them by 24h/maxSnapshotsPerDay and reverts
      // otherwise). A successful call earns the metrics bounty. Independent of the rebalance check.
      // IMPORTANT (oracle freshness): recording a snapshot here keeps the ring buffer fresh and earns the
      // metrics bounty. NOTE (audit): rebalance() DOES refresh the price cache itself (refresh-and-validate
      // guard at the top), so rebalance freshness no longer depends on this snapshot — the ordering is kept
      // only so one cycle can both snapshot and rebalance on a fresh price.
      if (!CHECK_ONLY) {
        try {
          const due = await rpcPool.executeWithRetry(async (p) => {
            return await rangeManager.connect(p).isSnapshotDue();
          });
          if (due) {
            const metricsEnabled = treasury ? await treasury.metricsBountyEnabled() : false;
            const metricsAmount = treasury ? await treasury.metricsBountyAmount() : 0n;
            await checkBountyFunding('metrics', metricsEnabled, metricsAmount, treasuryAddr, usdc);
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
          if (pending > 0n && positions.length > 0 && !isRebalancing) {
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

      // Public keepers can call the allowed permissionless maintenance paths:
      // snapshots, queued deposit processing and atomic rebalance().
      // on the RangeManager. Other actions (MINT_INITIAL, etc.) are gated on-chain
      // by `onlyAuthorized` and reserved for the protocol bot / Safe, so we just
      // wait silently for the next cycle.
      if (!needsRebalance || action !== 'REBALANCE') {
        console.log('  -> No rebalance needed\n');
      } else if (CHECK_ONLY) {
        console.log('  -> Rebalance needed (check-only mode, skipping)\n');
      } else {
        const keeperEnabled = treasury ? await treasury.keeperBountyEnabled() : false;
        const keeperAmount = treasury ? await treasury.keeperBountyAmount() : 0n;
        await checkBountyFunding('rebalance', keeperEnabled, keeperAmount, treasuryAddr, usdc);
        console.log('  -> Executing REBALANCE...');
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
