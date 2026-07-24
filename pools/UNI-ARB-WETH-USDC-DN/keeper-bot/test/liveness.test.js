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

function configureSignerState(pool, { dir, wallet, poolName = 'POOL' }) {
  pool.stateDir = dir;
  pool.configuredPendingTxFile = null;
  pool.pendingTxFile = null;
  pool.processLockFile = null;
  pool.signerAddress = wallet.address.toLowerCase();
  pool.chainId = '42161';
  pool.poolName = poolName;
}

test('signed transaction failover prepares and signs once, then rebroadcasts the same raw tx', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'keeper-shared-signer-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const pool = Object.create(RPCPool.prototype);
  const broadcasts = [];
  const first = {
    getTransactionReceipt: async () => null,
    broadcastTransaction: async (rawTx) => {
      broadcasts.push(rawTx);
      const error = new Error('primary network unavailable');
      error.code = 'NETWORK_ERROR';
      throw error;
    },
  };
  const second = {
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

test('same signer on two pools shares state and serializes signed actions', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'keeper-signer-lock-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const wallet = ethers.Wallet.createRandom();
  const first = Object.create(RPCPool.prototype);
  const second = Object.create(RPCPool.prototype);
  configureSignerState(first, { dir, wallet, poolName: 'STANDARD' });
  configureSignerState(second, { dir, wallet, poolName: 'DN' });
  const provider = {};
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

test('persisted transaction is cleared when its nonce was mined by a replacement', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'keeper-replaced-nonce-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const wallet = ethers.Wallet.createRandom();
  const pool = Object.create(RPCPool.prototype);
  configureSignerState(pool, { dir, wallet });
  const provider = {
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
  rebalancer._buildRebalancePlan = async () => {
    events.push(`build:${++buildCount}`);
    return { swapAmounts: [], minOuts: [], tokenIn: '0x1', tokenOut: '0x2', chunkCount: 0n };
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
    'sync:rebalance',
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
  rebalancer._syncFeesForActionPlan = async () => {};
  rebalancer._buildRebalancePlan = async () => ({ swapAmounts: [], minOuts: [] });
  rebalancer._simulateRebalance = async () => { throw new Error('E03 cooldown active'); };
  rebalancer._refreshPriceCacheForAction = async () => { refreshCount += 1; };

  const result = await rebalancer.executeRebalance(1n);
  assert.equal(result.success, false);
  assert.equal(refreshCount, 0);
});

test('deposit is deferred when the final on-chain instruction requires a rebalance', async () => {
  let feeSyncCount = 0;
  let signedTxCount = 0;
  const rangeManager = {
    connect: () => ({
      getBotInstructions: async () => [true, 1n, true, 'REBALANCE', 'dynamic range changed'],
    }),
  };
  const rpcPool = {
    executeWithRetry: async (fn) => await fn({}),
    executeSignedTxWithRetry: async () => { signedTxCount += 1; },
  };
  const rebalancer = new Rebalancer(rangeManager, {}, {}, {}, rpcPool);
  rebalancer._syncFeesForActionPlan = async () => { feeSyncCount += 1; };

  const result = await rebalancer.processDeposit();
  assert.equal(result.success, false);
  assert.equal(result.deferred, true);
  assert.equal(feeSyncCount, 0);
  assert.equal(signedTxCount, 0);
});

test('critical hedge fallback refreshes and recomputes a stale rebalance plan once', async () => {
  const rebalancer = new Rebalancer({}, {}, {}, {}, {});
  const events = [];
  let simulationCount = 0;
  rebalancer._readPriceCache = async () => ({ valid: true });
  rebalancer._buildRebalancePlan = async () => {
    events.push('build');
    return { swapAmounts: [], minOuts: [] };
  };
  rebalancer._simulateRebalance = async () => {
    events.push('simulate');
    simulationCount += 1;
    if (simulationCount === 1) throw new Error('stale price cache');
  };
  rebalancer._refreshPriceCacheForAction = async () => {
    events.push('refresh');
    return { valid: true };
  };

  assert.equal(await rebalancer.canExecuteCriticalHedgeRebalance(), true);
  assert.deepEqual(events, ['build', 'simulate', 'refresh', 'build', 'simulate']);
});

test('DN deposit plan errors E72 and E73 trigger refresh and recompute', () => {
  const rebalancer = new Rebalancer({}, {}, {}, {}, {});
  assert.equal(rebalancer._shouldRefreshForPlanError(new Error('execution reverted: E72')), true);
  assert.equal(rebalancer._shouldRefreshForPlanError(new Error('execution reverted: E73')), true);
});
