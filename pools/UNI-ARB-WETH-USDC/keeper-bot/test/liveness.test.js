// SPDX-License-Identifier: MIT

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const fsSync = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { ethers } = require('ethers');

const { Rebalancer, calculateChunkPlan, divideIntoChunks } = require('../src/rebalancer');
const { PersistentActionAlerts } = require('../src/utils/action-alerts');
const { RPCPool } = require('../src/utils/rpc');

test('RPC timeout releases a silent provider call', async () => {
  const pool = Object.create(RPCPool.prototype);
  await assert.rejects(
    pool.withTimeout(() => new Promise(() => {}), 5, 'silent read'),
    (error) => error.code === 'TIMEOUT' && /silent read timeout/.test(error.message)
  );
});

test('RPC chain authentication rejects an endpoint from another network', async () => {
  const pool = Object.create(RPCPool.prototype);
  pool.chainId = '42161';
  pool.withTimeout = async (fn) => await fn();
  const entry = {
    provider: { send: async () => '0x1' },
    healthy: true,
    chainVerified: false,
    chainMismatch: false,
  };

  await assert.rejects(
    pool._verifyProviderChain(entry),
    (error) => error.code === 'RPC_CHAIN_MISMATCH'
  );
  assert.equal(entry.healthy, false);
  assert.equal(entry.chainVerified, false);
  assert.equal(entry.chainMismatch, true);
});

test('a wrong-chain endpoint is excluded while an authenticated fallback remains usable', async () => {
  const pool = Object.create(RPCPool.prototype);
  pool.chainId = '42161';
  pool.withTimeout = async (fn) => await fn();
  const wrong = {
    provider: { send: async () => '0x1' },
    healthy: true,
    chainVerified: false,
    chainMismatch: false,
  };
  const correct = {
    provider: { send: async () => '0xa4b1' },
    healthy: true,
    chainVerified: false,
    chainMismatch: false,
  };
  pool.providers = [wrong, correct];

  await pool.verifyProviderChains();

  assert.equal(wrong.healthy, false);
  assert.equal(wrong.chainMismatch, true);
  assert.equal(correct.chainVerified, true);
  assert.equal(correct.healthy, true);
});

test('signed nonce and broadcast paths never consult a rejected wrong-chain endpoint', async () => {
  const pool = Object.create(RPCPool.prototype);
  pool.chainId = '42161';
  pool.signerAddress = '0x0000000000000000000000000000000000000011';
  pool.withTimeout = async (fn) => await fn();
  let wrongChainCalls = 0;
  let correctBroadcasts = 0;
  const wrong = {
    getTransactionCount: async () => { wrongChainCalls += 1; return 999; },
    getTransactionReceipt: async () => { wrongChainCalls += 1; return null; },
    broadcastTransaction: async () => { wrongChainCalls += 1; },
  };
  const correct = {
    getTransactionCount: async () => 7,
    getTransactionReceipt: async () => null,
    broadcastTransaction: async () => { correctBroadcasts += 1; },
    waitForTransaction: async (hash) => ({ status: 1, hash }),
  };
  pool.providers = [
    { provider: wrong, healthy: false, errorCount: 0, chainVerified: false, chainMismatch: true },
    { provider: correct, healthy: true, errorCount: 0, chainVerified: true, chainMismatch: false },
  ];

  assert.equal(await pool._latestSignerNonce(), 7);
  const receipt = await pool._broadcastSignedTransaction('0x1234', '0xabcd', 'rebalance', 0, 1);

  assert.equal(receipt.status, 1);
  assert.equal(correctBroadcasts, 1);
  assert.equal(wrongChainCalls, 0);
});

test('nonce conflicts are not treated as an already-known raw transaction', () => {
  const pool = Object.create(RPCPool.prototype);
  assert.equal(pool.isAlreadyKnownTx(new Error('already known')), true);
  assert.equal(pool.isAlreadyKnownTx(new Error('nonce too low')), false);
  assert.equal(pool.isAlreadyKnownTx(new Error('nonce has already been used')), false);
});

function configureSignerState(pool, { dir, wallet, poolName = 'POOL' }) {
  pool.stateDir = dir;
  pool.configuredPendingTxFile = null;
  pool.pendingTxFile = null;
  pool.processLockFile = null;
  pool.signerAddress = wallet.address.toLowerCase();
  pool.signerWallet = wallet;
  pool.maxGasPriceWei = ethers.parseUnits('10', 'gwei');
  pool.chainId = '42161';
  pool.poolName = poolName;
}

test('nonce reconciliation requires agreement and ignores one high outlier', async () => {
  const pool = Object.create(RPCPool.prototype);
  pool.signerAddress = '0x0000000000000000000000000000000000000011';
  pool.withTimeout = async (fn) => await fn();
  pool._authenticatedProviderEntries = async () => [7, 7, 999].map((nonce) => ({
    provider: { getTransactionCount: async () => nonce },
  }));
  assert.equal(await pool._latestSignerNonce(), 7);
});

test('keeper rejects RPC fee suggestions above its env-defined ceiling', () => {
  const pool = Object.create(RPCPool.prototype);
  pool.maxGasPriceWei = ethers.parseUnits('10', 'gwei');
  assert.throws(
    () => pool._assertFeeCap({ maxFeePerGas: ethers.parseUnits('11', 'gwei') }, 'rebalance'),
    /above KEEPER_MAX_GAS_PRICE_GWEI/
  );
});

test('pending transaction can be replaced with the same nonce and a bounded fee bump', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'keeper-fee-replacement-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const wallet = ethers.Wallet.createRandom();
  const pool = Object.create(RPCPool.prototype);
  configureSignerState(pool, { dir, wallet });
  const provider = { send: async () => '0xa4b1', getFeeData: async () => ({ gasPrice: 2n }) };
  pool.providers = [{ provider, healthy: true, chainVerified: true, chainMismatch: false }];
  pool.withTimeout = async (fn) => await fn();
  await pool._ensureSignerState(provider);

  const rawTx = await wallet.signTransaction({
    chainId: 42161,
    nonce: 4,
    gasLimit: 21_000n,
    gasPrice: 1n,
    to: '0x0000000000000000000000000000000000000001',
  });
  const txHash = ethers.keccak256(rawTx);
  pool._persistSignedTx(rawTx, txHash, 'rebalance', 4);
  let replacementRaw;
  pool._broadcastSignedTransaction = async (raw) => {
    replacementRaw = raw;
    return { status: 1 };
  };

  const result = await pool._replacePendingSignedTx(pool._readPendingSignedTx(), 1);
  const replacement = ethers.Transaction.from(replacementRaw);
  assert.equal(result.status, 'confirmed');
  assert.equal(replacement.nonce, 4);
  assert.ok(replacement.gasPrice > 1n);
  assert.ok(replacement.gasPrice <= pool.maxGasPriceWei);
  assert.equal(fsSync.existsSync(pool.pendingTxFile), false);
});

test('signed transaction failover prepares and signs once, then rebroadcasts the same raw tx', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'keeper-shared-signer-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const pool = Object.create(RPCPool.prototype);
  const broadcasts = [];
  const first = {
    send: async () => '0xa4b1',
    getTransactionReceipt: async () => null,
    broadcastTransaction: async (rawTx) => {
      broadcasts.push(rawTx);
      const error = new Error('primary network unavailable');
      error.code = 'NETWORK_ERROR';
      throw error;
    },
  };
  const second = {
    send: async () => '0xa4b1',
    getTransactionReceipt: async () => null,
    broadcastTransaction: async (rawTx) => { broadcasts.push(rawTx); },
    waitForTransaction: async (hash) => ({ status: 1, hash }),
  };
  pool.providers = [first, second].map((provider) => ({ provider, healthy: true, errorCount: 0 }));
  pool.currentIndex = 0;
  const signingWallet = ethers.Wallet.createRandom();
  configureSignerState(pool, { dir, wallet: signingWallet });
  const timeoutLabels = [];
  pool.withTimeout = async (fn, _timeoutMs, label) => {
    timeoutLabels.push(label);
    return await fn();
  };

  let prepareCount = 0;
  let populateCount = 0;
  let signCount = 0;
  const wallet = {
    address: signingWallet.address,
    populateTransaction: async (request) => {
      populateCount += 1;
      return {
        ...request,
        chainId: 42161,
        nonce: 7,
        gasLimit: 21_000n,
        gasPrice: 1n,
      };
    },
    signTransaction: async (request) => {
      signCount += 1;
      return await signingWallet.signTransaction(request);
    },
  };
  const receipt = await pool.executeSignedTxWithRetry(async (provider) => {
    prepareCount += 1;
    assert.equal(provider, first);
    return { wallet, request: { to: '0x0000000000000000000000000000000000000001' } };
  }, 'rebalance');

  assert.equal(receipt.status, 1);
  assert.equal(prepareCount, 1);
  assert.equal(populateCount, 1);
  assert.equal(signCount, 1);
  assert.equal(broadcasts.length, 2);
  assert.equal(broadcasts[0], broadcasts[1]);
  assert.ok(timeoutLabels.some((label) => label.includes('broadcast')));
  assert.ok(timeoutLabels.some((label) => label.includes('receipt')));
});

test('signed transaction persistence is atomic and hash-bound across restarts', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'keeper-pending-tx-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const pool = Object.create(RPCPool.prototype);
  pool.pendingTxFile = path.join(dir, 'pending.json');
  pool.chainId = '42161';
  pool.poolName = 'POOL';
  const wallet = ethers.Wallet.createRandom();
  pool.signerAddress = wallet.address.toLowerCase();
  const rawTx = await wallet.signTransaction({
    chainId: 42161,
    nonce: 9,
    gasLimit: 21_000n,
    gasPrice: 1n,
    to: '0x0000000000000000000000000000000000000001',
  });
  const txHash = ethers.keccak256(rawTx);

  pool._persistSignedTx(rawTx, txHash, 'rebalance', 9);
  assert.deepEqual(pool._readPendingSignedTx(), {
    schemaVersion: 2,
    rawTx,
    txHash,
    label: 'rebalance',
    poolName: 'POOL',
    signer: wallet.address.toLowerCase(),
    chainId: '42161',
    nonce: 9,
    createdAt: pool._readPendingSignedTx().createdAt,
  });
  assert.equal(fsSync.statSync(pool.pendingTxFile).mode & 0o777, 0o600);
  pool._clearPersistedSignedTx(txHash);
  assert.equal(fsSync.existsSync(pool.pendingTxFile), false);
});

test('legacy custom pending journal migrates under the canonical signer lock', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'keeper-canonical-state-'));
  const legacyDir = await fs.mkdtemp(path.join(os.tmpdir(), 'keeper-legacy-state-'));
  t.after(() => Promise.all([
    fs.rm(dir, { recursive: true, force: true }),
    fs.rm(legacyDir, { recursive: true, force: true }),
  ]));
  const wallet = ethers.Wallet.createRandom();
  const pool = Object.create(RPCPool.prototype);
  configureSignerState(pool, { dir, wallet });
  pool.configuredPendingTxFile = path.join(legacyDir, 'custom-pending.json');
  const provider = { send: async () => '0xa4b1' };
  pool.providers = [{ provider, healthy: true, chainVerified: true, chainMismatch: false }];
  await pool._ensureSignerState(provider);

  const rawTx = await wallet.signTransaction({
    chainId: 42161,
    nonce: 10,
    gasLimit: 21_000n,
    gasPrice: 1n,
    to: '0x0000000000000000000000000000000000000001',
  });
  const txHash = ethers.keccak256(rawTx);
  fsSync.writeFileSync(pool.configuredPendingTxFile, `${JSON.stringify({
    schemaVersion: 2,
    rawTx,
    txHash,
    label: 'legacy pool action',
    poolName: 'POOL',
    signer: wallet.address.toLowerCase(),
    chainId: '42161',
    nonce: 10,
    createdAt: new Date().toISOString(),
  })}\n`, { mode: 0o600 });

  const migrated = await pool._withSignerLock(provider, async () => pool._readPendingSignedTx());
  assert.equal(migrated.txHash, txHash);
  assert.equal(fsSync.existsSync(pool.configuredPendingTxFile), false);
  assert.equal(fsSync.existsSync(pool.pendingTxFile), true);
  assert.equal(fsSync.statSync(pool.pendingTxFile).mode & 0o777, 0o600);
});

test('same signer on two pools shares state and serializes signed actions', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'keeper-signer-lock-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const wallet = ethers.Wallet.createRandom();
  const first = Object.create(RPCPool.prototype);
  const second = Object.create(RPCPool.prototype);
  configureSignerState(first, { dir, wallet, poolName: 'STANDARD' });
  configureSignerState(second, { dir, wallet, poolName: 'DN' });
  const provider = { send: async () => '0xa4b1' };
  first.providers = [{ provider, healthy: true, chainVerified: false, chainMismatch: false }];
  second.providers = [{ provider, healthy: true, chainVerified: false, chainMismatch: false }];
  await first._ensureSignerState(provider);
  await second._ensureSignerState(provider);
  assert.equal(first.pendingTxFile, second.pendingTxFile);
  assert.equal(first.processLockFile, second.processLockFile);

  const order = [];
  await Promise.all([
    first._withSignerLock(provider, async () => {
      order.push('first-start');
      await new Promise(resolve => setTimeout(resolve, 30));
      order.push('first-end');
    }),
    second._withSignerLock(provider, async () => {
      order.push('second-start');
      order.push('second-end');
    }),
  ]);
  assert.deepEqual(order, ['first-start', 'first-end', 'second-start', 'second-end']);
});

test('a stale signer lock is reclaimed even when its PID has been reused', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'keeper-stale-lock-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const wallet = ethers.Wallet.createRandom();
  const pool = Object.create(RPCPool.prototype);
  configureSignerState(pool, { dir, wallet });
  const provider = { send: async () => '0xa4b1' };
  pool.providers = [{ provider, healthy: true, chainVerified: false, chainMismatch: false }];
  await pool._ensureSignerState(provider);
  fsSync.writeFileSync(pool.processLockFile, `${JSON.stringify({ pid: process.pid, token: 'stale' })}\n`);
  const staleAt = new Date(Date.now() - 3 * 60_000);
  fsSync.utimesSync(pool.processLockFile, staleAt, staleAt);

  let executed = false;
  await pool._withSignerLock(provider, async () => { executed = true; });
  assert.equal(executed, true);
  assert.equal(fsSync.existsSync(pool.processLockFile), false);
});

test('persisted transaction is cleared when its nonce was mined by a replacement', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'keeper-replaced-nonce-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const wallet = ethers.Wallet.createRandom();
  const pool = Object.create(RPCPool.prototype);
  configureSignerState(pool, { dir, wallet });
  const provider = {
    send: async () => '0xa4b1',
    getTransactionReceipt: async () => null,
    getTransactionCount: async () => 12,
  };
  pool.providers = [{ provider, healthy: true, errorCount: 0 }];
  pool.currentIndex = 0;
  pool.withTimeout = async (fn) => await fn();
  await pool._ensureSignerState(provider);

  const rawTx = await wallet.signTransaction({
    chainId: 42161,
    nonce: 11,
    gasLimit: 21_000n,
    gasPrice: 1n,
    to: '0x0000000000000000000000000000000000000001',
  });
  const txHash = ethers.keccak256(rawTx);
  pool._persistSignedTx(rawTx, txHash, 'rebalance', 11);

  const recovered = await pool.reconcilePendingSignedTx();
  assert.equal(recovered.status, 'replaced');
  assert.equal(recovered.label, 'rebalance');
  assert.equal(fsSync.existsSync(pool.pendingTxFile), false);
});

test('chunk count and splitting stay in BigInt arithmetic', () => {
  const amountIn = 10n * 10n ** 18n;
  const priceUsd8 = 3_000n * 100_000_000n;
  const plan = calculateChunkPlan(amountIn, priceUsd8, 18, 10_000n);

  assert.equal(plan.amountUsd8, 30_000n * 100_000_000n);
  assert.equal(plan.chunkCount, 3n);

  const chunks = divideIntoChunks(amountIn, plan.chunkCount);
  assert.equal(chunks.length, 3);
  assert.equal(chunks.reduce((sum, value) => sum + value, 0n), amountIn);
  assert.ok(chunks.every((value) => typeof value === 'bigint'));
});

test('a high-TVL plan is simulated through the resumable module, never atomic rebalance', async () => {
  let atomicCalls = 0;
  let progressiveCalls = 0;
  const wallet = { connect: () => wallet };
  const rangeManager = {
    connect: () => ({
      rebalance: { staticCall: async () => { atomicCalls += 1; } },
    }),
  };
  const secureBotModule = {
    connect: () => ({
      beginProgressiveRebalance: {
        staticCall: async (decisionHash) => {
          progressiveCalls += 1;
          assert.equal(decisionHash, '0x' + '11'.repeat(32));
        },
      },
    }),
  };
  const rpcPool = { executeWithRetry: async (fn) => await fn({}) };
  const rebalancer = new Rebalancer(rangeManager, {}, {}, wallet, rpcPool, secureBotModule);

  await rebalancer._simulateRebalance({
    chunkCount: 2n,
    decisionHash: '0x' + '11'.repeat(32),
  });

  assert.equal(progressiveCalls, 1);
  assert.equal(atomicCalls, 0);
});

test('a high-TVL plan does not allocate a stale off-chain chunk array', async () => {
  const rangeManager = {
    connect: () => ({
      initMultiSwapTvl: async () => 10n,
      config: async () => ({ token0Decimals: 0, token1Decimals: 0, maxSlippageBps: 100 }),
    }),
  };
  const rpcPool = { executeWithRetry: async (fn) => await fn({}) };
  const rebalancer = new Rebalancer(rangeManager, {}, {}, {}, rpcPool, {});
  const plan = await rebalancer._buildPlan(
    true,
    1_000n,
    { price0: 100_000_000n, price1: 100_000_000n },
    false
  );

  assert.equal(plan.chunkCount, 100n);
  assert.deepEqual(plan.swapAmounts, []);
  assert.deepEqual(plan.minOuts, []);
});

test('progressive rebalance recomputes the remaining plan after every confirmed chunk', async () => {
  const rebalancer = new Rebalancer({}, {}, {}, {}, {}, {});
  const methods = [];
  const remaining = [25n, 15n, 5n];
  let statusReads = 0;
  rebalancer.getProgressiveRebalanceStatus = async () => (++statusReads === 1 ? 0 : 2);
  rebalancer._sendProgressiveTransaction = async (method, args) => {
    methods.push({ method, amount: BigInt(args[0] || 0n) });
    return { hash: `0x${methods.length}` };
  };
  rebalancer._readProgressivePlan = async () => ({
    status: 2,
    plan: { swapNeeded: true, zeroForOne: true, amountIn: remaining.shift() },
    priceCache: { price0: 100_000_000n, price1: 100_000_000n },
    cfg: { token0Decimals: 0, token1Decimals: 0, maxSlippageBps: 100 },
    capUsd: 10n,
  });
  rebalancer._progressiveAmountCap = () => 10n;
  rebalancer._oracleMinOut = (_direction, amount) => amount;

  const result = await rebalancer._runProgressiveRebalance('0x' + '22'.repeat(32));

  assert.deepEqual(methods, [
    { method: 'beginProgressiveRebalance', amount: BigInt('0x' + '22'.repeat(32)) },
    { method: 'continueProgressiveRebalance', amount: 10n },
    { method: 'continueProgressiveRebalance', amount: 10n },
    { method: 'finalizeProgressiveRebalance', amount: 5n },
  ]);
  assert.equal(remaining.length, 0);
  assert.equal(result.success, true);
  assert.equal(result.txHashes.length, 4);
});

test('progressive chunks respect total and reverse-direction on-chain budgets', () => {
  const rebalancer = new Rebalancer({}, {}, {}, {}, {}, {});
  const usd8 = 100_000_000n;
  const base = {
    priceCache: { price0: usd8, price1: usd8 },
    cfg: { token0Decimals: 0, token1Decimals: 0 },
    capUsd: 10n,
    budgetUsd8: 5n * usd8,
    reverseBudgetUsd8: 1n * usd8,
    initialZeroForOne: true,
  };
  assert.equal(rebalancer._progressiveAmountCap({ ...base, plan: { zeroForOne: true } }), 5n);
  assert.equal(rebalancer._progressiveAmountCap({ ...base, plan: { zeroForOne: false } }), 1n);
  assert.throws(
    () => rebalancer._progressiveAmountCap({ ...base, reverseBudgetUsd8: 0n, plan: { zeroForOne: false } }),
    /budget exhausted/
  );
});

test('atomic action gas is buffered but never allowed to reach the block limit', async () => {
  const rebalancer = new Rebalancer({}, {}, {}, {}, {});
  const signer = { address: '0x0000000000000000000000000000000000000011' };
  const provider = {
    estimateGas: async () => 100n,
    getBlock: async () => ({ gasLimit: 1_000n }),
  };
  assert.equal((await rebalancer._boundTransactionGas(provider, signer, {}, 'rebalance')).gasLimit, 120n);
  provider.estimateGas = async () => 1_000n;
  await assert.rejects(rebalancer._boundTransactionGas(provider, signer, {}, 'rebalance'), /above block limit/);
});

test('failure threshold and recovery survive a restart', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'keeper-alerts-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const stateFile = path.join(dir, 'state.json');
  const messages = [];
  const sender = async (message) => { messages.push(message); return true; };

  const first = new PersistentActionAlerts({ poolName: 'POOL', stateFile, sender });
  await first.init();
  await first.failure('deposit', 'one');
  await first.failure('deposit', 'two');
  assert.equal(messages.length, 0);
  await first.failure('deposit', 'three');
  assert.equal(messages.length, 1);

  const restarted = new PersistentActionAlerts({ poolName: 'POOL', stateFile, sender });
  await restarted.init();
  await restarted.success('deposit', 'processed');
  assert.equal(messages.length, 2);
  assert.match(messages[1], /^\[POOL\] Keeper deposit recovered/);
});

function readJavaScriptTree(dir) {
  return fsSync.readdirSync(dir, { withFileTypes: true }).map((entry) => {
    const target = path.join(dir, entry.name);
    if (entry.isDirectory()) return readJavaScriptTree(target);
    return entry.name.endsWith('.js') ? fsSync.readFileSync(target, 'utf8') : '';
  }).join('\n');
}

test('community keeper source has no protocol Telegram, Tenderly or AWS secret transport', () => {
  const source = readJavaScriptTree(path.join(__dirname, '..', 'src'));
  assert.doesNotMatch(
    source,
    /TELEGRAM_|api\.telegram\.org|sendTelegram|TENDERLY_|tenderly\.co|aws-sdk|SecretsManager|secrets-manager|AWS_SECRET/i
  );
});

test('rebalance syncs fees before planning and refreshes only for a retryable rejection', async () => {
  const events = [];
  const wallet = { connect: () => wallet };
  const rangeManager = {
    connect: () => ({
      rebalance: {
        populateTransaction: async () => ({ to: '0x1' }),
      },
    }),
  };
  const rpcPool = {
    executeSignedTxWithRetry: async (prepare, label) => {
      events.push(`send:${label}`);
      await prepare({});
      return { hash: '0xabc' };
    },
  };
  const rebalancer = new Rebalancer(rangeManager, {}, {}, wallet, rpcPool);
  let buildCount = 0;
  let simulationCount = 0;
  rebalancer._readPriceCache = async () => ({ valid: true });
  rebalancer._readRebalanceDecision = async () => ({ decisionHash: '0x' + '11'.repeat(32) });
  rebalancer._buildRebalancePlan = async () => {
    events.push(`build:${++buildCount}`);
    return {
      decisionHash: '0x' + '11'.repeat(32),
      swapAmounts: [],
      minOuts: [],
      tokenIn: '0x1',
      tokenOut: '0x2',
      chunkCount: 0n,
    };
  };
  rebalancer._simulateRebalance = async () => {
    events.push(`simulate:${++simulationCount}`);
    if (simulationCount === 1) throw new Error('stale plan');
  };
  rebalancer._refreshPriceCacheForAction = async () => {
    events.push('refresh');
    return { valid: true };
  };
  rebalancer._syncFeesForActionPlan = async (action) => { events.push(`sync:${action}`); };
  rebalancer._boundTransactionGas = async (_provider, _signer, request) => request;
  rebalancer._logPlan = () => {};

  const result = await rebalancer.executeRebalance(1n);
  assert.equal(result.success, true);
  assert.deepEqual(events, [
    'build:1',
    'simulate:1',
    'refresh',
    'build:2',
    'simulate:2',
    'send:rebalance',
  ]);
});

test('unrelated rebalance revert does not trigger an isolated price refresh', async () => {
  const rebalancer = new Rebalancer({}, {}, {}, {}, {});
  let refreshCount = 0;
  rebalancer._readPriceCache = async () => ({ valid: true });
  rebalancer._readRebalanceDecision = async () => ({ decisionHash: '0x' + '11'.repeat(32) });
  rebalancer._syncFeesForActionPlan = async () => {};
  rebalancer._buildRebalancePlan = async () => ({ swapAmounts: [], minOuts: [] });
  rebalancer._simulateRebalance = async () => { throw new Error('E03 cooldown active'); };
  rebalancer._refreshPriceCacheForAction = async () => { refreshCount += 1; };

  const result = await rebalancer.executeRebalance(1n);
  assert.equal(result.success, false);
  assert.equal(refreshCount, 0);
});

test('router fill errors trigger one action-coupled refresh and plan recompute', () => {
  const rebalancer = new Rebalancer({}, {}, {}, {}, {});
  assert.equal(rebalancer._shouldRefreshForPlanError(new Error('Too little received')), true);
  assert.equal(rebalancer._shouldRefreshForPlanError(new Error('execution reverted: PartialFill()')), true);
});

test('rebalance no longer needed does not sync fees, refresh, or send a tx', async () => {
  const rebalancer = new Rebalancer({}, {}, {}, {}, {});
  let feeSyncCount = 0;
  let refreshCount = 0;
  rebalancer._readPriceCache = async () => ({ valid: true });
  rebalancer._readRebalanceDecision = async () => ({ decisionHash: '0x' + '11'.repeat(32) });
  rebalancer._buildRebalancePlan = async () => ({ swapAmounts: [], minOuts: [] });
  rebalancer._simulateRebalance = async () => { throw new Error('E90'); };
  rebalancer._syncFeesForActionPlan = async () => { feeSyncCount += 1; };
  rebalancer._refreshPriceCacheForAction = async () => { refreshCount += 1; };

  const result = await rebalancer.executeRebalance(1n);
  assert.equal(result.success, true);
  assert.equal(result.noAction, true);
  assert.equal(feeSyncCount, 0);
  assert.equal(refreshCount, 0);
});

test('deposit is deferred when the final on-chain instruction requires a rebalance', async () => {
  let feeSyncCount = 0;
  let signedTxCount = 0;
  const strategyEngine = {
    connect: () => ({
      previewDecision: async () => ({ action: 2n, dataFresh: true }),
    }),
  };
  const rpcPool = {
    executeWithRetry: async (fn) => await fn({}),
    executeSignedTxWithRetry: async () => { signedTxCount += 1; },
  };
  const rebalancer = new Rebalancer({}, {}, strategyEngine, {}, rpcPool);
  rebalancer._syncFeesForActionPlan = async () => { feeSyncCount += 1; };

  const result = await rebalancer.processDeposit();
  assert.equal(result.success, false);
  assert.equal(result.deferred, true);
  assert.equal(feeSyncCount, 0);
  assert.equal(signedTxCount, 0);
});
