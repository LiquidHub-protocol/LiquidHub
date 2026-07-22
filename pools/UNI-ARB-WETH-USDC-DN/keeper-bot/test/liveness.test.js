const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

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
