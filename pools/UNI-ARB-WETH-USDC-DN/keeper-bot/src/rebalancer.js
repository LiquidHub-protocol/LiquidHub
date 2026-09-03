// SPDX-License-Identifier: MIT

const USD_SCALE = 100_000_000n;
const DN_MAX_DEPOSIT_SWAP_CHUNKS = 10n;

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

function divideIntoChunks(totalAmount, numChunks) {
  const count = BigInt(numChunks);
  if (count <= 1n) return [BigInt(totalAmount)];
  const chunks = [];
  const chunkSize = BigInt(totalAmount) / count;
  for (let i = 1n; i < count; i++) chunks.push(chunkSize);
  chunks.push(BigInt(totalAmount) - chunkSize * (count - 1n));
  return chunks;
}

class Rebalancer {
  constructor(
    rangeManager,
    vault,
    strategyEngine,
    hedgeManager,
    wallet,
    rpcPool,
    secureBotModule = null,
    beforeProgressiveStep = null
  ) {
    this.rangeManager = rangeManager;
    this.vault = vault;
    this.strategyEngine = strategyEngine;
    this.hedgeManager = hedgeManager;
    this.wallet = wallet;
    this.rpcPool = rpcPool;
    this.secureBotModule = secureBotModule;
    this.beforeProgressiveStep = typeof beforeProgressiveStep === 'function' ? beforeProgressiveStep : null;
  }

  async executeRebalance(tokenId, expectedDecisionHash) {
    console.log(`\n=== Starting adaptive DN rebalance for position #${tokenId} ===`);

    try {
      let plan = null;
      try {
        const decision = await this._readRangeDecision(expectedDecisionHash);
        plan = await this._buildRebalancePlan(await this._readPriceCache(), decision.decisionHash);
        await this._simulateRebalance(plan);
      } catch (firstError) {
        plan = null;
        const controlResult = this._rebalanceControlResult(firstError);
        if (controlResult) return controlResult;

        let retryError = firstError;
        if (this._isFeePlanError(firstError)) {
          await this._syncFeesForActionPlan('rebalance retry');
          try {
            const decision = await this._readRangeDecision();
            plan = await this._buildRebalancePlan(await this._readPriceCache(), decision.decisionHash);
            await this._simulateRebalance(plan);
          } catch (postFeeError) {
            plan = null;
            retryError = postFeeError;
          }
        }

        if (!plan) {
          const retryControl = this._rebalanceControlResult(retryError);
          if (retryControl) return retryControl;
          if (!this._shouldRefreshForPlanError(retryError)) throw retryError;
          console.log(`  Rebalance plan rejected; refreshing once and recomputing: ${this._errorText(retryError)}`);
          const refreshed = await this._refreshPriceCacheForAction('rebalance stale-plan retry');
          const decision = await this._readRangeDecision();
          plan = await this._buildRebalancePlan(refreshed, decision.decisionHash);
          await this._simulateRebalance(plan);
        }
      }

      const latestDecision = await this._readRangeDecision();
      if (latestDecision.decisionHash !== plan.decisionHash) {
        console.log('  Strategy decision changed before submission; rebuilding the DN plan once.');
        plan = await this._buildRebalancePlan(await this._readPriceCache(), latestDecision.decisionHash);
        await this._simulateRebalance(plan);
      }

      this._logPlan(plan);
      if (plan.chunkCount > 1n) {
        console.log('  High-TVL DN plan: switching to the resumable on-chain rebalance path...');
        return await this._runProgressiveRebalance(plan.decisionHash);
      }

      console.log('  Executing atomic rebalance() on-chain...');
      const receipt = await this.rpcPool.executeSignedTxWithRetry(async (provider) => {
        const signer = this.wallet.connect(provider);
        const rm = this.rangeManager.connect(signer);
        const request = await rm.rebalance.populateTransaction(
          plan.decisionHash,
          plan.swapAmounts,
          plan.minOuts,
          plan.tokenIn,
          plan.tokenOut
        );
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

  async processDeposit() {
    console.log('\n=== Processing queued deposit (permissionless) ===');
    try {
      const decision = await this.rpcPool.executeWithRetry(async (provider) => {
        return await this.strategyEngine.connect(provider).previewDecision();
      });
      if ([3, 4, 5].includes(Number(decision.action))) {
        console.log('  DN deposit deferred: canonical range/hedge maintenance is eligible first.');
        return { success: false, deferred: true, error: 'DN maintenance required before deposit', txHashes: [] };
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
      console.log(`  Deposit: skipped (${this._errorText(error).slice(0, 90)})`);
      const message = error.message || '';
      return {
        success: false,
        stateMayHaveChanged: message.includes('broadcast tx:') || message.includes('signed broadcast tx:'),
        error: message,
        txHashes: [],
      };
    }
  }

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

  async _buildRebalancePlan(priceCache, decisionHash) {
    const swapParams = await this.rpcPool.executeWithRetry(async (provider) => {
      return await this.rangeManager.connect(provider).getOptimalSwapParams();
    });
    const plan = await this._buildPlan(
      swapParams.zeroForOne,
      swapParams.swapNeeded ? swapParams.amountIn : 0n,
      priceCache,
      false
    );
    plan.decisionHash = decisionHash;
    return plan;
  }

  async _readRangeDecision(expectedDecisionHash = null) {
    const decision = await this.rpcPool.executeWithRetry(async (provider) => {
      return await this.strategyEngine.connect(provider).previewDecision();
    });
    if (Number(decision.action) !== 4 || !decision.dataFresh) {
      throw new Error('E90: canonical strategy decision does not authorize RANGE_AND_HEDGE');
    }
    if (expectedDecisionHash && decision.decisionHash !== expectedDecisionHash) {
      console.log('  Strategy decision advanced since the cycle read; using the latest canonical hash.');
    }
    return decision;
  }

  async _buildDepositPlan(priceCache) {
    const [zeroForOne, amountIn] = await this.rpcPool.executeWithRetry(async (provider) => {
      return await this.vault.connect(provider).getDepositSwapParams();
    });
    return await this._buildPlan(zeroForOne, amountIn, priceCache, true);
  }

  async _buildPlan(zeroForOne, amountIn, priceCache, enforceDepositCap) {
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
    if (enforceDepositCap && chunkCount > DN_MAX_DEPOSIT_SWAP_CHUNKS) {
      throw new Error(`deposit needs ${chunkCount} swap chunks; on-chain maximum is ${DN_MAX_DEPOSIT_SWAP_CHUNKS}`);
    }

    plan.tokenIn = zeroForOne ? process.env.TOKEN0_ADDRESS : process.env.TOKEN1_ADDRESS;
    plan.tokenOut = zeroForOne ? process.env.TOKEN1_ADDRESS : process.env.TOKEN0_ADDRESS;
    // A high-TVL rebalance is recomputed after every confirmed transaction. Do not allocate
    // a potentially huge, stale off-chain chunk array that will never be submitted atomically.
    if (!enforceDepositCap && chunkCount > 1n) {
      plan.amountUsd8 = amountUsd8;
      plan.chunkCount = chunkCount;
      plan.capUsd = BigInt(initMultiSwapTvl);
      return plan;
    }
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
      if (plan.chunkCount > 1n) {
        const module = this._requireProgressiveModule().connect(this.wallet.connect(provider));
        return await module.beginProgressiveRebalance.staticCall(plan.decisionHash);
      }
      const rm = this.rangeManager.connect(this.wallet.connect(provider));
      return await rm.rebalance.staticCall(
        plan.decisionHash,
        plan.swapAmounts,
        plan.minOuts,
        plan.tokenIn,
        plan.tokenOut
      );
    });
  }

  _requireProgressiveModule() {
    if (!this.secureBotModule) {
      throw new Error('SAFE_MODULE_ADDRESS is required for high-TVL DN rebalances');
    }
    return this.secureBotModule;
  }

  async getProgressiveRebalanceStatus() {
    return Number(await this.rpcPool.executeWithRetry(async (provider) => {
      return await this._requireProgressiveModule().connect(provider).progressiveRebalanceStatus();
    }));
  }

  async _sendProgressiveTransaction(method, args, label) {
    return await this.rpcPool.executeSignedTxWithRetry(async (provider) => {
      const signer = this.wallet.connect(provider);
      const module = this._requireProgressiveModule().connect(signer);
      const request = await module[method].populateTransaction(...args);
      return {
        wallet: signer,
        request: await this._boundTransactionGas(provider, signer, request, label),
      };
    }, label);
  }

  async _readProgressivePlan() {
    return await this.rpcPool.executeWithRetry(async (provider) => {
      const module = this._requireProgressiveModule().connect(provider);
      const rm = this.rangeManager.connect(provider);
      const status = Number(await module.progressiveRebalanceStatus());
      if (status !== 2) return { status };
      const [plan, priceCache, cfg, capUsd, budgetUsd8, reverseBudgetUsd8, initialZeroForOne] = await Promise.all([
        module.getProgressiveSwapParams(),
        rm.priceCache(),
        rm.config(),
        rm.initMultiSwapTvl(),
        module.progressiveSwapBudgetUsdE8(),
        module.progressiveReverseBudgetUsdE8(),
        module.progressiveInitialZeroForOne(),
      ]);
      return { status, plan, priceCache, cfg, capUsd, budgetUsd8, reverseBudgetUsd8, initialZeroForOne };
    });
  }

  _progressiveAmountCap(state) {
    const { plan, priceCache, cfg, capUsd } = state;
    const tokenInIsToken0 = Boolean(plan.zeroForOne);
    const priceIn = BigInt(tokenInIsToken0 ? priceCache.price0 : priceCache.price1);
    const decimals = Number(tokenInIsToken0 ? cfg.token0Decimals : cfg.token1Decimals);
    if (priceIn <= 0n || BigInt(capUsd) <= 0n) throw new Error('invalid on-chain progressive cap or price');
    let remainingBudgetUsd8 = BigInt(state.budgetUsd8);
    if (tokenInIsToken0 !== Boolean(state.initialZeroForOne)) {
      const reverseBudgetUsd8 = BigInt(state.reverseBudgetUsd8);
      if (reverseBudgetUsd8 < remainingBudgetUsd8) remainingBudgetUsd8 = reverseBudgetUsd8;
    }
    if (remainingBudgetUsd8 <= 0n) throw new Error('progressive budget exhausted; cycle remains resumable or Safe-cancellable');
    const perChunkCapUsd8 = BigInt(capUsd) * USD_SCALE;
    const effectiveCapUsd8 = remainingBudgetUsd8 < perChunkCapUsd8 ? remainingBudgetUsd8 : perChunkCapUsd8;
    const capRaw = (effectiveCapUsd8 * (10n ** BigInt(decimals))) / priceIn;
    if (capRaw === 0n) throw new Error('progressive budget is below the smallest token input unit');
    return capRaw;
  }

  async _runProgressiveRebalance(expectedDecisionHash = null) {
    const txHashes = [];
    let status = await this.getProgressiveRebalanceStatus();

    if (status === 0) {
      if (this.beforeProgressiveStep) await this.beforeProgressiveStep();
      if (!expectedDecisionHash) throw new Error('canonical decision hash required to start progressive DN rebalance');
      const receipt = await this._sendProgressiveTransaction(
        'beginProgressiveRebalance', [expectedDecisionHash], 'beginProgressiveRebalance'
      );
      txHashes.push(receipt.hash);
      status = await this.getProgressiveRebalanceStatus();
    }
    if (status !== 2) throw new Error(`unexpected progressive DN rebalance state: ${status}`);

    let staleRetries = 0;
    while (true) {
      if (this.beforeProgressiveStep) await this.beforeProgressiveStep();
      const state = await this._readProgressivePlan();
      if (state.status === 0) break;
      if (state.status !== 2) throw new Error(`non-executable progressive DN rebalance state: ${state.status}`);

      const swapNeeded = Boolean(state.plan.swapNeeded);
      const planAmount = BigInt(state.plan.amountIn);
      const tokenInIsToken0 = Boolean(state.plan.zeroForOne);
      if (!swapNeeded || planAmount === 0n) {
        const receipt = await this._sendProgressiveTransaction(
          'finalizeProgressiveRebalance', [0n, 0n], 'finalizeProgressiveRebalance'
        );
        txHashes.push(receipt.hash);
        break;
      }

      const capRaw = this._progressiveAmountCap(state);
      let amountIn = planAmount < capRaw ? planAmount : capRaw;
      let finalize = planAmount <= capRaw;
      let receipt = null;
      let refreshRequested = false;

      for (let shrink = 0; shrink < 256 && amountIn > 0n; shrink++) {
        const minOut = this._oracleMinOut(
          tokenInIsToken0,
          amountIn,
          state.priceCache,
          Number(state.cfg.token0Decimals),
          Number(state.cfg.token1Decimals),
          Number(state.cfg.maxSlippageBps)
        );
        const method = finalize ? 'finalizeProgressiveRebalance' : 'continueProgressiveRebalance';
        try {
          receipt = await this._sendProgressiveTransaction(method, [amountIn, minOut], method);
          break;
        } catch (error) {
          const text = this._errorText(error).toLowerCase();
          if (text.includes('hf repair') && this.beforeProgressiveStep) {
            await this.beforeProgressiveStep();
            refreshRequested = true;
            break;
          }
          if (['partialfill', 'partial fill', 'sqrt', 'price limit', 'spl'].some((marker) => text.includes(marker)) && amountIn > 1n) {
            amountIn /= 2n;
            finalize = false;
            console.log(`  Price-impact bound reached; retrying a smaller DN chunk (${amountIn})`);
            continue;
          }
          if (this._shouldRefreshForPlanError(error) && staleRetries < 2) {
            staleRetries += 1;
            await this._refreshPriceCacheForAction('progressive DN rebalance retry');
            refreshRequested = true;
            break;
          }
          throw error;
        }
      }

      if (!receipt) {
        if (refreshRequested) continue;
        throw new Error('unable to produce an executable progressive DN chunk');
      }
      staleRetries = 0;
      txHashes.push(receipt.hash);
      if (finalize) break;
    }

    return { success: true, progressive: true, txHashes };
  }

  async resumeProgressiveRebalanceIfActive() {
    if (await this.getProgressiveRebalanceStatus() === 0) return null;
    console.log('  Active progressive DN rebalance detected; resuming it before ordinary actions.');
    return await this._runProgressiveRebalance();
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
    return ['stale', 'cache', 'oracle', 'twap', 'price', 'minout', 'too little received', 'partialfill', 'partial fill', 'cycle budget', 'reverse budget', 'use atomic', 'swapchunkabovecap', 'e38', 'e72', 'e73', 'e90', 'e91', 'e96', 'e93', 'e94']
      .some((marker) => text.includes(marker));
  }

  _rebalanceControlResult(error) {
    const text = this._errorText(error);
    if (/e90|e96/i.test(text)) {
      console.log('  Rebalance no longer required after on-chain simulation; no transaction sent.');
      return { success: true, noAction: true, txHashes: [] };
    }
    if (/e03/i.test(text)) {
      console.log('  Rebalance cooldown is still active; retry deferred to the next keeper cycle.');
      return { success: false, deferred: true, error: text, txHashes: [] };
    }
    return null;
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
        return { wallet: signer, request: await vault.syncFeesForDeposits.populateTransaction() };
      }, `syncFeesForDeposits ${action}`);
      console.log(`  Fees synced before ${action} plan: ${receipt.hash}`);
    } catch (error) {
      throw new Error(`Fee sync required before ${action} plan: ${this._errorText(error)}`);
    }
  }
}

module.exports = { Rebalancer, calculateChunkPlan, divideIntoChunks };
