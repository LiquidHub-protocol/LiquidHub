const { ethers } = require('ethers');

/**
 * Splits a BigInt amount into `numChunks` as-equal-as-possible parts.
 */
function divideIntoChunks(totalAmount, numChunks) {
  if (numChunks <= 1) return [totalAmount];
  const chunks = [];
  const chunkSize = totalAmount / BigInt(numChunks);
  for (let i = 0; i < numChunks - 1; i++) chunks.push(chunkSize);
  chunks.push(totalAmount - chunkSize * BigInt(numChunks - 1));
  return chunks;
}

/**
 * Rebalancer — executes the atomic rebalance() function on the RangeManager.
 *
 * The single on-chain call performs: lock vault → burn old position → execute N swaps
 * → mint new position → unlock vault → pay keeper bounty. All in one tx.
 *
 * Permissionless: no keeper role required — anyone can trigger when needsRebalance is true.
 */
class Rebalancer {
  constructor(rangeManager, vault, wallet, rpcPool) {
    this.rangeManager = rangeManager;
    this.vault = vault;
    this.wallet = wallet;
    this.rpcPool = rpcPool;
  }

  async ensureFreshPriceCacheForDecision() {
    return await this._freshPriceCache('keeper decision');
  }

  async executeRebalance(tokenId) {
    console.log(`\n=== Starting atomic rebalance for position #${tokenId} ===`);

    try {
      await this._syncFeesForDepositPlan();
      const priceCache = await this._freshPriceCache('rebalance plan/minOut');
      // 1. Read optimal swap params (what the contract would expect) — REBALANCE = état post-burn (NFT inclus).
      const swapParams = await this.rpcPool.executeWithRetry(async (provider) => {
        return await this.rangeManager.connect(provider).getOptimalSwapParams();
      });

      let swapAmounts = [];
      let minOuts = [];
      let tokenIn = process.env.TOKEN0_ADDRESS;
      let tokenOut = process.env.TOKEN1_ADDRESS;

      if (swapParams.swapNeeded && swapParams.amountIn > 0n) {
        const token0 = process.env.TOKEN0_ADDRESS;
        const token1 = process.env.TOKEN1_ADDRESS;
        tokenIn = swapParams.zeroForOne ? token0 : token1;
        tokenOut = swapParams.zeroForOne ? token1 : token0;

        // Read on-chain chunk cap (initMultiSwapTvl in USD, contract value)
        const initMultiSwapTvl = await this.rpcPool.executeWithRetry(async (provider) => {
          return await this.rangeManager.connect(provider).initMultiSwapTvl();
        });
        // Decimals read ON-CHAIN from config() (generic for any pair, not the .env) — same source as processDeposit
        const cfg = await this.rpcPool.executeWithRetry(async (provider) => {
          return await this.rangeManager.connect(provider).config();
        });
        const dec0 = Number(cfg.token0Decimals);
        const dec1 = Number(cfg.token1Decimals);
        const decimals = swapParams.zeroForOne ? dec0 : dec1;
        const price = swapParams.zeroForOne
          ? Number(priceCache.price0) / 1e8
          : Number(priceCache.price1) / 1e8;

        const amountUSD = parseFloat(ethers.formatUnits(swapParams.amountIn, decimals)) * price;
        const capUSD = Number(initMultiSwapTvl);

        // Number of chunks to stay under the on-chain per-chunk cap
        const numSwaps = capUSD > 0 ? Math.max(1, Math.ceil(amountUSD / capUSD)) : 1;
        swapAmounts = divideIntoChunks(swapParams.amountIn, numSwaps);
        // AUDIT H-03 : minOut DOIT respecter le plancher oracle on-chain (validateMinOutsAgainstOracle) —
        // 0 ferait revert "minOut<floor". Même calcul que le dépôt (_oracleMinOut), pas de 0.
        const slippageBps = Number(cfg.maxSlippageBps);
        minOuts = swapAmounts.map((amtIn) => this._oracleMinOut(swapParams.zeroForOne, amtIn, priceCache, dec0, dec1, slippageBps));

        console.log(`  Swap: ${numSwaps} chunk(s), ~$${amountUSD.toFixed(0)} total (cap $${capUSD}/chunk), minOut oracle-floored`);
      } else {
        console.log('  No swap needed (already balanced)');
      }

      // 2. Single atomic call — contract does burn → swap(s) → mint → bounty
      console.log('  Executing rebalance() on-chain...');
      const receipt = await this.rpcPool.executeSignedTxWithRetry(async (provider) => {
        const signer = this.wallet.connect(provider);
        const rm = this.rangeManager.connect(signer);
        await rm.rebalance.staticCall(swapAmounts, minOuts, tokenIn, tokenOut);
        return {
          wallet: signer,
          request: await rm.rebalance.populateTransaction(swapAmounts, minOuts, tokenIn, tokenOut),
        };
      }, 'rebalance');
      console.log(`  Rebalance complete: ${receipt.hash}`);

      return { success: true, txHashes: [receipt.hash] };
    } catch (error) {
      console.error(`Rebalance failed: ${error.message}`);
      return { success: false, error: error.message, txHashes: [] };
    }
  }

  /**
   * Processes ONE queued user deposit permissionlessly (earns the deposit bounty).
   *
   * Anti-MEV: deposits AND rebalances require minAmountsOut[i] >= the on-chain oracle floor.
   * So we MUST compute minOuts from the Chainlink price here (not 0), otherwise the tx reverts
   * with "minOut<floor". The contract re-validates everything on-chain — the keeper only needs
   * to meet/exceed the floor.
   */
  async processDeposit() {
    console.log('\n=== Processing queued deposit (permissionless) ===');
    try {
      const priceCache = await this._freshPriceCache('deposit plan/minOut');
      await this._syncFeesForDepositPlan();
      // AUDIT H-01/H-03 : DÉPÔT → vue dédiée (état post-transfert du dépôt + ratio NFT existant), PAS
      // getOptimalSwapParams (qui reflète l'état rebalance/post-burn → faux pour un dépôt).
      const [zeroForOne, amountIn] = await this.rpcPool.executeWithRetry(async (provider) => {
        return await this.vault.connect(provider).getDepositSwapParams();
      });

      let swapAmounts = [];
      let minOuts = [];
      let tokenIn = process.env.TOKEN0_ADDRESS;
      let tokenOut = process.env.TOKEN1_ADDRESS;

      if (amountIn > 0n) {
        const token0 = process.env.TOKEN0_ADDRESS;
        const token1 = process.env.TOKEN1_ADDRESS;
        tokenIn = zeroForOne ? token0 : token1;
        tokenOut = zeroForOne ? token1 : token0;

        const [initMultiSwapTvl, cfg] = await this.rpcPool.executeWithRetry(async (provider) => {
          const rm = this.rangeManager.connect(provider);
          return await Promise.all([rm.initMultiSwapTvl(), rm.config()]);
        });

        const dec0 = Number(cfg.token0Decimals);
        const dec1 = Number(cfg.token1Decimals);
        const decimals = zeroForOne ? dec0 : dec1;
        const price = zeroForOne
          ? Number(priceCache.price0) / 1e8
          : Number(priceCache.price1) / 1e8;

        const amountUSD = parseFloat(ethers.formatUnits(amountIn, decimals)) * price;
        const capUSD = Number(initMultiSwapTvl);
        const numSwaps = capUSD > 0 ? Math.max(1, Math.ceil(amountUSD / capUSD)) : 1;
        swapAmounts = divideIntoChunks(amountIn, numSwaps);

        // Oracle-floored minOuts (replicates RangeOperations.oracleMinOut on-chain math) — au plancher exact.
        const slippageBps = Number(cfg.maxSlippageBps);
        minOuts = swapAmounts.map((amt) => this._oracleMinOut(zeroForOne, amt, priceCache, dec0, dec1, slippageBps));

        console.log(`  Swap: ${numSwaps} chunk(s), ~$${amountUSD.toFixed(0)} total (cap $${capUSD}/chunk), minOut floored by oracle`);
      } else {
        console.log('  No swap needed (deposit already balanced)');
      }

      console.log('  Executing processDepositPermissionless() on-chain...');
      const receipt = await this.rpcPool.executeSignedTxWithRetry(async (provider) => {
        const signer = this.wallet.connect(provider);
        const vault = this.vault.connect(signer);
        await vault.processDepositPermissionless.staticCall(swapAmounts, minOuts, tokenIn, tokenOut);
        return {
          wallet: signer,
          request: await vault.processDepositPermissionless.populateTransaction(swapAmounts, minOuts, tokenIn, tokenOut),
        };
      }, 'processDepositPermissionless');
      console.log(`  Deposit processed: ${receipt.hash}`);

      return { success: true, txHashes: [receipt.hash] };
    } catch (error) {
      // Revert expected when queue empty / no NFT / oracle stale — not fatal.
      console.log(`  Deposit: skipped (${(error.reason || error.message || '').slice(0, 90)})`);
      return { success: false, error: error.message, txHashes: [] };
    }
  }

  /**
   * Replicates RangeOperations.oracleMinOut (on-chain) as a BigInt computation, so the
   * keeper-supplied minOut meets the contract floor exactly. amountIn / output in token native units.
   */
  _oracleMinOut(tokenInIsToken0, amountIn, priceCache, dec0, dec1, slippageBps) {
    const priceIn = tokenInIsToken0 ? BigInt(priceCache.price0) : BigInt(priceCache.price1);
    const priceOut = tokenInIsToken0 ? BigInt(priceCache.price1) : BigInt(priceCache.price0);
    const decIn = tokenInIsToken0 ? dec0 : dec1;
    const decOut = tokenInIsToken0 ? dec1 : dec0;
    if (priceOut === 0n) return 0n;
    const theo = (BigInt(amountIn) * priceIn * (10n ** BigInt(decOut))) / (priceOut * (10n ** BigInt(decIn)));
    const slip = slippageBps >= 10000 ? 9999n : BigInt(slippageBps);
    return (theo * (10000n - slip)) / 10000n;
  }

  async _freshPriceCache(label) {
    let priceCache = await this.rpcPool.executeWithRetry(async (provider) => {
      return await this.rangeManager.connect(provider).priceCache();
    });
    if (!this._needsPriceCacheRefresh(priceCache)) return priceCache;

    console.log(`  priceCache stale/invalid before ${label}; calling refreshPriceCache()...`);
    try {
      const receipt = await this.rpcPool.executeSignedTxWithRetry(async (provider) => {
        const signer = this.wallet.connect(provider);
        const rm = this.rangeManager.connect(signer);
        return {
          wallet: signer,
          request: await rm.refreshPriceCache.populateTransaction(),
        };
      }, 'refreshPriceCache');
      console.log(`  priceCache refreshed: ${receipt.hash}`);
      priceCache = await this.rpcPool.executeWithRetry(async (provider) => {
        return await this.rangeManager.connect(provider).priceCache();
      });
    } catch (error) {
      console.log(`  refreshPriceCache skipped/failed: ${(error.reason || error.shortMessage || error.message || '').slice(0, 100)}`);
    }

    if (!priceCache.valid || BigInt(priceCache.price0) === 0n || BigInt(priceCache.price1) === 0n) {
      throw new Error('priceCache invalid after refresh attempt');
    }
    if (this._needsPriceCacheRefresh(priceCache)) {
      throw new Error('priceCache still stale after refresh attempt');
    }
    return priceCache;
  }

  async _syncFeesForDepositPlan() {
    try {
      const receipt = await this.rpcPool.executeSignedTxWithRetry(async (provider) => {
        const signer = this.wallet.connect(provider);
        const vault = this.vault.connect(signer);
        return {
          wallet: signer,
          request: await vault.syncFeesForDeposits.populateTransaction(),
        };
      }, 'syncFeesForDeposits');
      console.log(`  Fees synced before action plan: ${receipt.hash}`);
    } catch (error) {
      throw new Error(`Fee sync required before recomputing the plan: ${(error.reason || error.message || '').slice(0, 120)}`);
    }
  }

  _needsPriceCacheRefresh(priceCache) {
    if (!priceCache.valid || BigInt(priceCache.price0) === 0n || BigInt(priceCache.price1) === 0n) return true;
    const maxAgeSec = parseInt(process.env.KEEPER_PRICE_CACHE_MAX_AGE_SEC || process.env.BOT_PRICE_CACHE_MAX_AGE_SEC || '300', 10);
    const ts = Number(priceCache.timestamp || 0);
    if (!Number.isFinite(maxAgeSec) || maxAgeSec <= 0 || !ts) return false;
    return Math.floor(Date.now() / 1000) - ts > maxAgeSec;
  }
}

module.exports = { Rebalancer };
