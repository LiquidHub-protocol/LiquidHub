// SPDX-License-Identifier: MIT

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { ethers } = require('ethers');
const { Rebalancer } = require('../src/rebalancer');
const { RANGEMANAGER_ABI, SECURE_BOT_MODULE_ABI, syncCurrentBotModule } = require('../src/utils/contracts');

const RM = '0x1000000000000000000000000000000000000001';
const OLD = '0x2000000000000000000000000000000000000002';
const CURRENT = '0x3000000000000000000000000000000000000003';

function fixture() {
  const rmInterface = new ethers.Interface(RANGEMANAGER_ABI);
  const moduleInterface = new ethers.Interface(SECURE_BOT_MODULE_ABI);
  const state = { activeModule: OLD, locked: true, error: null, calls: [], resumed: 0 };
  const provider = {
    call: async (request) => {
      const target = ethers.getAddress(request.to);
      if (target === RM) {
        const method = rmInterface.parseTransaction(request).name;
        state.calls.push({ target, method });
        if (state.error) throw state.error;
        assert.equal(method, 'protocolBotAddress');
        return rmInterface.encodeFunctionResult(method, [state.activeModule]);
      }
      const method = moduleInterface.parseTransaction(request).name;
      state.calls.push({ target, method });
      assert.equal(method, 'progressiveRebalanceStatus');
      return moduleInterface.encodeFunctionResult(method, [target === OLD ? 2 : 0]);
    },
  };
  const rpcPool = { executeWithRetry: async (callback) => callback(provider) };
  const rangeManager = new ethers.Contract(RM, RANGEMANAGER_ABI, provider);
  const oldModule = new ethers.Contract(OLD, SECURE_BOT_MODULE_ABI, provider);
  const rebalancer = Object.create(Rebalancer.prototype);
  rebalancer.rpcPool = rpcPool;
  rebalancer.secureBotModule = oldModule;
  rebalancer.vault = { connect: () => ({ isRebalancing: async () => state.locked }) };
  rebalancer._runProgressiveRebalance = async () => {
    state.resumed += 1;
    assert.equal(await rebalancer.secureBotModule.getAddress(), CURRENT);
    return { success: true, txHashes: ['0xrecovered'] };
  };
  return { state, rpcPool, rangeManager, oldModule, rebalancer };
}

test('a rotated module replaces retired state 2 and permits ordinary actions once the Vault is unlocked', async () => {
  const { state, rpcPool, rangeManager, oldModule, rebalancer } = fixture();
  assert.equal(await rebalancer.getProgressiveRebalanceStatus(), 2);
  state.activeModule = CURRENT;
  state.locked = false;
  state.calls.length = 0;

  const currentModule = await syncCurrentBotModule(rpcPool, rangeManager, oldModule, rebalancer);
  assert.equal(await currentModule.getAddress(), CURRENT);
  assert.strictEqual(rebalancer.secureBotModule, currentModule);
  assert.equal(await rebalancer.getProgressiveRebalanceStatus(), 0);
  assert.equal(await rebalancer.resumeProgressiveRebalanceIfActive(), null,
    'the ordinary-action branch can run despite the retired module retaining state 2');
  assert.equal(state.resumed, 0);
  assert.equal(state.calls.some((call) => call.target === OLD), false, 'retired state is never consulted');
  assert.deepEqual(state.calls[0], { target: RM, method: 'protocolBotAddress' });
});

test('a new idle module still resumes a locked no-NFT cycle through the current rebalancer reference', async () => {
  const { state, rpcPool, rangeManager, oldModule, rebalancer } = fixture();
  state.activeModule = CURRENT;
  await syncCurrentBotModule(rpcPool, rangeManager, oldModule, rebalancer);
  assert.deepEqual(await rebalancer.resumeProgressiveRebalanceIfActive(), {
    success: true, txHashes: ['0xrecovered'],
  });
  assert.equal(state.resumed, 1);
});

test('an unchanged canonical module retains its existing contract instance', async () => {
  const { rpcPool, rangeManager, oldModule, rebalancer } = fixture();
  assert.strictEqual(await syncCurrentBotModule(rpcPool, rangeManager, oldModule, rebalancer), oldModule);
  assert.strictEqual(rebalancer.secureBotModule, oldModule);
});

test('an unreadable or zero canonical link fails before reading or using a retired module', async () => {
  const { state, rpcPool, rangeManager, oldModule, rebalancer } = fixture();
  state.error = new Error('RPC unavailable');
  await assert.rejects(syncCurrentBotModule(rpcPool, rangeManager, oldModule, rebalancer), /RPC unavailable/);
  state.error = null;
  state.activeModule = ethers.ZeroAddress;
  await assert.rejects(syncCurrentBotModule(rpcPool, rangeManager, oldModule, rebalancer), /no active bot module/);
  assert.strictEqual(rebalancer.secureBotModule, oldModule);
  assert.equal(state.calls.some((call) => call.target === OLD), false);
});

test('the running keeper refreshes the module before progressive state while preserving the DN safety lane', () => {
  const source = fs.readFileSync(path.join(__dirname, '../src/keeper.js'), 'utf8');
  const loop = source.slice(source.indexOf('while (true)'));
  const refresh = loop.indexOf('secureBotModule = await syncCurrentBotModule(');
  const status = loop.indexOf('const progressiveStatus =');
  assert.ok(refresh >= 0 && refresh < status);
  const safety = loop.indexOf('await runHfSafetyLane(');
  if (safety >= 0) assert.ok(safety < refresh, 'HF repair must precede ordinary module discovery');
});
