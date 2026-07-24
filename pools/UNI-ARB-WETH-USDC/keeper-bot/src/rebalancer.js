const USD_SCALE = 100_000_000n;

function ceilDiv(value, divisor) {
  if (divisor <= 0n) throw new Error('chunk divisor must be positive');
  return (value + divisor - 1n) / divisor;
}

function calculateChunkPlan(amountIn, priceUsd8, tokenDecimals, capUsd) {
  const amountUsd8 = (BigInt(amountIn) * BigInt(priceUsd8)) / (10n ** BigInt(tokenDecimals));
  const capUsd8 = BigInt(capUsd) * USD_SCALE;
  const chunkCount = capUsd8 > 0n ? (ceilDiv(amountUsd8, capUsd8) || 1n) : 1n;
  return { amountUsd8, chunkCount };
}

function formatUsd8(value) {
  const amount = BigInt(value);
  const whole = amount / USD_SCALE;
  const fraction = (amount % USD_SCALE).toString().padStart(8, '0').slice(0, 2);
  return `${whole}.${fraction}`;
}

/**
 * Splits a BigInt amount into `numChunks` as-equal-as-possible parts.
 */
function divideIntoChunks(totalAmount, numChunks) {
  const count = BigInt(numChunks);
  if (count <= 1n) return [BigInt(totalAmount)];
  const chunks = [];
  const chunkSize = BigInt(totalAmount) / count;
  for (let i = 1n; i < count; i++) chunks.push(chunkSize);
  chunks.push(BigInt(totalAmount) - chunkSize * (count - 1n));
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

  async executeRebalance(tokenId) {
    console.log(`\n=== Starting atomic rebalance for position #${tokenId} ===`);

    try {
      await this._syncFeesForActionPlan('rebalance');
      let plan;
      try {
        plan = await this._buildRebalancePlan(await this._readPriceCache());
        await this._simulateRebalance(plan);
      } catch (firstError) {
        if (!this._shouldRefreshForPlanError(firstError)) throw firstError;
        if (this._isFeePlanError(firstError)) await this._syncFeesForActionPlan('rebalance retry');
        console.log(`  Rebalance plan rejected; refreshing once and recomputing: ${this._errorText(firstError)}`);
        const refreshed = await this._refreshPriceCacheForAction('rebalance stale-plan retry');
        plan = await this._buildRebalancePlan(refreshed);
        await this._simulateRebalance(plan);
      }

      this._logPlan(plan);
      console.log('  Executing rebalance() on-chain...');
      const receipt = await this.rpcPool.executeSignedTxWithRetry(async (provider) => {
        const signer = this.wallet.connect(provider);
        const rm = this.rangeManager.connect(signer);
        const request = await rm.rebalance.populateTransaction(plan.swapAmounts, plan.minOuts, plan.tokenIn, plan.tokenOut);
        return {
          wallet: signer,
          request: await this._boundTransactionGas(provider, signer, request, `rebalance ${plan.chunkCount} chunk(s)`),
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
      const [, , needsRebalance, action, reason] = await this.rpcPool.executeWithRetry(async (provider) => {
        return await this.rangeManager.connect(provider).getBotInstructions();
      });
      if (needsRebalance) {
        console.log(`  Deposit deferred: ${action || 'REBALANCE'} is required first (${reason || 'on-chain signal'}).`);
        return { success: false, deferred: true, error: 'rebalance required before deposit', txHashes: [] };
      }

      await this._syncFeesForActionPlan('deposit');
      let plan;
      try {
        plan = await this._buildDepositPlan(await this._readPriceCache());
        await this._simulateDeposit(plan);
      } catch (firstError) {
        if (!this._shouldRefreshForPlanError(firstError)) throw firstError;
        console.log(`  Deposit plan rejected; refreshing once and recomputing: ${this._errorText(firstError)}`);
        const refreshed = await this._refreshPriceCacheForAction('deposit stale-plan retry');
        plan = await this._buildDepositPlan(refreshed);
        await this._simulateDeposit(plan);
      }

      this._logPlan(plan);
      console.log('  Executing processDepositPermissionless() on-chain...');
      const receipt = await this.rpcPool.executeSignedTxWithRetry(async (provider) => {
        const signer = this.wallet.connect(provider);
        const vault = this.vault.connect(signer);
        const request = await vault.processDepositPermissionless.populateTransaction(
          plan.swapAmounts,
          plan.minOuts,
          plan.tokenIn,
          plan.tokenOut
        );
        return {
          wallet: signer,
          request: await this._boundTransactionGas(provider, signer, request, `deposit ${plan.chunkCount} chunk(s)`),
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

  async _readPriceCache() {
    return await this.rpcPool.executeWithRetry(async (provider) => {
      return await this.rangeManager.connect(provider).priceCache();
    });
  }

  async _refreshPriceCacheForAction(label) {
    const receipt = await this.rpcPool.executeSignedTxWithRetry(async (provider) => {
      const signer = this.wallet.connect(provider);
      const rm = this.rangeManager.connect(signer);
      return { wallet: signer, request: await rm.refreshPriceCache.populateTransaction() };
    }, label);
    console.log(`  priceCache refreshed for ${label}: ${receipt.hash}`);
    const priceCache = await this._readPriceCache();
    if (!priceCache.valid || BigInt(priceCache.price0) === 0n || BigInt(priceCache.price1) === 0n) {
      throw new Error('priceCache invalid after action-linked refresh');
    }
    return priceCache;
  }

  async _buildRebalancePlan(priceCache) {
    const swapParams = await this.rpcPool.executeWithRetry(async (provider) => {
      return await this.rangeManager.connect(provider).getOptimalSwapParams();
    });
    return await this._buildPlan(swapParams.zeroForOne, swapParams.swapNeeded ? swapParams.amountIn : 0n, priceCache);
  }

  async _buildDepositPlan(priceCache) {
    const [zeroForOne, amountIn] = await this.rpcPool.executeWithRetry(async (provider) => {
      return await this.vault.connect(provider).getDepositSwapParams();
    });
    return await this._buildPlan(zeroForOne, amountIn, priceCache);
  }

  async _buildPlan(zeroForOne, amountIn, priceCache) {
    const plan = {
      swapAmounts: [],
      minOuts: [],
      tokenIn: process.env.TOKEN0_ADDRESS,
      tokenOut: process.env.TOKEN1_ADDRESS,
      amountUsd8: 0n,
      chunkCount: 0n,
      capUsd: 0n,
    };
    if (amountIn <= 0n) return plan;

    const [initMultiSwapTvl, cfg] = await this.rpcPool.executeWithRetry(async (provider) => {
      const rm = this.rangeManager.connect(provider);
      return await Promise.all([rm.initMultiSwapTvl(), rm.config()]);
    });
    const dec0 = Number(cfg.token0Decimals);
    const dec1 = Number(cfg.token1Decimals);
    const tokenDecimals = zeroForOne ? dec0 : dec1;
    const priceUsd8 = zeroForOne ? BigInt(priceCache.price0) : BigInt(priceCache.price1);
    const { amountUsd8, chunkCount } = calculateChunkPlan(amountIn, priceUsd8, tokenDecimals, initMultiSwapTvl);

    plan.tokenIn = zeroForOne ? process.env.TOKEN0_ADDRESS : process.env.TOKEN1_ADDRESS;
    plan.tokenOut = zeroForOne ? process.env.TOKEN1_ADDRESS : process.env.TOKEN0_ADDRESS;
    plan.swapAmounts = divideIntoChunks(amountIn, chunkCount);
    plan.minOuts = plan.swapAmounts.map((amount) =>
      this._oracleMinOut(zeroForOne, amount, priceCache, dec0, dec1, Number(cfg.maxSlippageBps))
    );
    plan.amountUsd8 = amountUsd8;
    plan.chunkCount = chunkCount;
    plan.capUsd = BigInt(initMultiSwapTvl);
    return plan;
  }

  async _simulateRebalance(plan) {
    await this.rpcPool.executeWithRetry(async (provider) => {
      const rm = this.rangeManager.connect(this.wallet.connect(provider));
      return await rm.rebalance.staticCall(plan.swapAmounts, plan.minOuts, plan.tokenIn, plan.tokenOut);
    });
  }

  async _simulateDeposit(plan) {
    await this.rpcPool.executeWithRetry(async (provider) => {
      const vault = this.vault.connect(this.wallet.connect(provider));
      return await vault.processDepositPermissionless.staticCall(
        plan.swapAmounts,
        plan.minOuts,
        plan.tokenIn,
        plan.tokenOut
      );
    });
  }

  _logPlan(plan) {
    if (plan.chunkCount === 0n) {
      console.log('  No swap needed (already balanced)');
      return;
    }
    console.log(
      `  Swap: ${plan.chunkCount} chunk(s), ~$${formatUsd8(plan.amountUsd8)} total ` +
      `(cap $${plan.capUsd}/chunk), minOut oracle-floored`
    );
  }

  _errorText(error) {
    return (error.reason || error.shortMessage || error.message || 'unknown error').slice(0, 120);
  }

  _shouldRefreshForPlanError(error) {
    const text = this._errorText(error).toLowerCase();
    return ['stale', 'cache', 'oracle', 'twap', 'price', 'minout', 'e38', 'e93', 'e94']
      .some((marker) => text.includes(marker));
  }

  _isFeePlanError(error) {
    return /e93|e94/i.test(this._errorText(error));
  }

  async _boundTransactionGas(provider, signer, request, label) {
    const [estimate, block] = await Promise.all([
      provider.estimateGas({ ...request, from: signer.address }),
      provider.getBlock('latest'),
    ]);
    const blockLimit = BigInt(block.gasLimit);
    if (estimate >= blockLimit) {
      throw new Error(`${label} requires ${estimate} gas, above block limit ${blockLimit}`);
    }
    const buffered = estimate + estimate / 5n;
    request.gasLimit = buffered < blockLimit ? buffered : blockLimit - 1n;
    return request;
  }

  async _syncFeesForActionPlan(action) {
    try {
      const receipt = await this.rpcPool.executeSignedTxWithRetry(async (provider) => {
        const signer = this.wallet.connect(provider);
        const vault = this.vault.connect(signer);
        return {
          wallet: signer,
          request: await vault.syncFeesForDeposits.populateTransaction(),
        };
      }, `syncFeesForDeposits ${action}`);
      console.log(`  Fees synced before ${action} plan: ${receipt.hash}`);
    } catch (error) {
      throw new Error(`Fee sync required before ${action} plan: ${(error.reason || error.message || '').slice(0, 120)}`);
    }
  }

}

module.exports = { Rebalancer, calculateChunkPlan, divideIntoChunks };
