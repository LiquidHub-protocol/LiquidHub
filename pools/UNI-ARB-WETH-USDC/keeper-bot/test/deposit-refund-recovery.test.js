'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Interface } = require('ethers');
const { markDepositSimulationError, processDepositWithRecovery, readRecoverySnapshot, sendDepositRefund } = require('../src/utils/deposit-refund-recovery');
function fixture() {
  const state = {}, snapshot = { key: 'alice:1:100:0', user: 'alice', now: 22000, eligible: true };
  let mode = 'revert', sent = 0, attempted = 0;
  const revert = () => markDepositSimulationError(Object.assign(new Error('execution reverted'), { code: 'CALL_EXCEPTION', action: 'call' }));
  const options = { state, readSnapshot: async () => ({ ...snapshot }),
    attempt: async () => { attempted++; if (mode === 'ok') return { success: true }; if (mode === 'rpc') throw new Error('RPC unavailable'); throw revert(); },
    simulate: async () => { if (mode === 'revert') throw revert(); },
    sendRefund: async (user, guard) => { assert.equal(user, 'alice'); await guard(); sent++; return { hash: 'refund' }; },
  };
  const run = async () => { try { return await processDepositWithRecovery(options); } catch (error) { return { error }; } };
  return { options, state, snapshot, run, mode: v => { mode = v; }, sent: () => sent, attempted: () => attempted };
}
test('maturity alone never refunds; persistent reverts across ten minutes trigger one guarded refund', async () => {
  const f = fixture(); await f.run(); assert.equal(f.sent(), 0);
  await f.run(); assert.equal(f.state.failures, 1);
  f.snapshot.now += 60; await f.run(); assert.equal(f.sent(), 0);
  f.snapshot.now += 540; const result = await f.run();
  assert.equal(result.refunded, true); assert.equal(f.sent(), 1); assert.equal(f.attempted(), 4); assert.equal(f.state.key, undefined);
});
for (const stop of ['rpc', 'ok', 'maintenance', 'head']) {
  test(`deposit recovery resets evidence after ${stop}`, async () => {
    const f = fixture(); await f.run(); f.snapshot.now += 60; await f.run(); f.snapshot.now += 600;
    if (stop === 'rpc' || stop === 'ok') f.mode(stop);
    if (stop === 'maintenance') f.snapshot.eligible = false;
    if (stop === 'head') f.snapshot.key = 'bob:2:100:0';
    await f.run(); assert.equal(f.sent(), 0);
  });
}
test('a processable deposit or changed head at signing cancels the refund', async () => {
  for (const change of ['success', 'head', 'maintenance']) {
    const f = fixture(); await f.run(); f.snapshot.now += 60; await f.run(); f.snapshot.now += 600;
    f.options.sendRefund = async (_, guard) => {
      if (change === 'success') f.mode('ok');
      if (change === 'head') f.snapshot.key = 'bob';
      if (change === 'maintenance') f.snapshot.eligible = false;
      await guard(); assert.fail('must not send');
    };
    const result = await f.run(); assert.equal(result.deferred, true);
  }
});
test('unavailable monitoring preserves deposits; broadcast or RPC uncertainty never refunds', async () => {
  const f = fixture(); f.mode('ok'); f.options.readSnapshot = async () => { throw new Error('read unavailable'); };
  assert.equal((await f.run()).success, true); assert.equal(f.attempted(), 1);
  const g = fixture(); g.options.attempt = async () => ({ success: false, simulationReverted: true, stateMayHaveChanged: true });
  for (let i = 0; i < 4; i++) { g.snapshot.now += 600; await g.run(); }
  assert.equal(g.sent(), 0);
  assert.equal(markDepositSimulationError({ code: 'CALL_EXCEPTION', action: 'estimateGas' }).depositSimulationReverted, undefined);
});

test('recovery snapshots decode real ABI responses at one block and enforce each maintenance gate', async () => {
  const vaultAddress = '0x0000000000000000000000000000000000000011';
  const user = '0x0000000000000000000000000000000000000022';
  const pauseAddress = '0x0000000000000000000000000000000000000033';
  const abi = new Interface([
    'function getNextPendingDeposit() view returns(address,uint256,uint256,uint256,bool)',
    'function depositRefundDelay() view returns(uint256)', 'function dnDepositRefundDelay() view returns(uint256)',
    'function initialPositionEstablished() view returns(bool)', 'function isRebalancing() view returns(bool)',
    'function pauseController() view returns(address)', 'function inflowsPaused() view returns(bool)',
  ]);
  for (const isDn of [false, true]) {
    const values = { getNextPendingDeposit: [user, 100n, 0n, 1n, true], depositRefundDelay: [21600n],
      dnDepositRefundDelay: [21600n], initialPositionEstablished: [true], isRebalancing: [false],
      pauseController: [pauseAddress], inflowsPaused: [false] };
    let action = 0, due = false, dataFresh = true, now = 22000;
    const calls = [];
    const provider = { getBlock: async () => ({ number: 123, timestamp: now }), call: async tx => {
      assert.equal(tx.blockTag, 123);
      const fn = abi.parseTransaction(tx).name; calls.push(fn);
      assert.equal(tx.to.toLowerCase(), fn === 'inflowsPaused' ? pauseAddress : vaultAddress);
      return abi.encodeFunctionResult(fn, values[fn]);
    } };
    const strategyEngine = { connect: p => { assert.equal(p, provider); return {
      previewDecision: async at => { assert.equal(at.blockTag, 123); return { action, dataFresh }; },
      checkpointDue: async at => { assert.equal(at.blockTag, 123); return due; },
    }; } };
    // Exercise the production retry signature: a label in the numeric retry slot must not go unnoticed.
    const { RPCPool } = require('../src/utils/rpc');
    const rpcPool = Object.assign(Object.create(RPCPool.prototype), {
      providers: [{ provider, chainVerified: true }], getProvider: () => provider,
    });
    const read = () => readRecoverySnapshot({ rpcPool, vaultAddress, strategyEngine, isDn });
    assert.equal((await read()).eligible, true);
    assert.ok(calls.includes(isDn ? 'dnDepositRefundDelay' : 'depositRefundDelay'));
    for (action of [2, 3, 4, 5]) assert.equal((await read()).eligible, false);
    action = 1; assert.equal((await read()).eligible, true);
    due = true; assert.equal((await read()).eligible, false); due = false;
    dataFresh = false; assert.equal((await read()).eligible, false); dataFresh = true;
    for (const key of ['isRebalancing', 'inflowsPaused', 'initialPositionEstablished']) {
      values[key][0] = !values[key][0]; assert.equal((await read()).eligible, false); values[key][0] = !values[key][0];
    }
    calls.length = 0; now = 100;
    assert.equal((await read()).eligible, false); assert.equal(calls.length, 2);
  }
});

test('refund transaction binds the depositor, simulates before preparation and bounds operator gas', async () => {
  const vaultAddress = '0x0000000000000000000000000000000000000011';
  const user = '0x0000000000000000000000000000000000000022';
  const operator = '0x0000000000000000000000000000000000000033';
  const abi = new Interface(['function refundStaleDeposit(address)']);
  let guarded = 0, simulated = 0, estimate = 100n;
  const provider = { getBlock: async () => ({ gasLimit: 1000n }), estimateGas: async tx => {
    assert.equal(tx.from, operator); assert.equal(abi.parseTransaction(tx).args[0], user); return estimate;
  } };
  const wallet = { address: operator, provider, call: async tx => {
    assert.ok(guarded > simulated); assert.equal(tx.to, vaultAddress);
    assert.equal(abi.parseTransaction(tx).args[0], user); simulated++; return '0x';
  } };
  const options = { vaultAddress, walletForProvider: p => { assert.equal(p, provider); return wallet; },
    rpcPool: { executeSignedTxWithRetry: async (prepare, label) => {
      assert.equal(label, 'refundStaleDeposit'); const result = await prepare(provider);
      assert.equal(result.wallet, wallet); assert.equal(result.request.to, vaultAddress);
      assert.equal(result.request.gasLimit, estimate === 100n ? 120n : 999n);
      return { hash: 'refund' };
    } },
  };
  const guard = async () => { guarded++; };
  assert.equal((await sendDepositRefund(options, user, guard)).hash, 'refund');
  estimate = 900n; await sendDepositRefund(options, user, guard);
  estimate = 1000n; await assert.rejects(sendDepositRefund(options, user, guard), /block gas limit/);
  assert.equal(simulated, 3);
});

test('persisted evidence survives restart; corrupt evidence starts a new observation period', async () => {
  const f = fixture(); await f.run(); f.snapshot.now += 60; await f.run();
  f.options.state = JSON.parse(JSON.stringify(f.state));
  f.snapshot.now += 600; assert.equal((await f.run()).refunded, true);
  const g = fixture(); Object.assign(g.state, { key: g.snapshot.key, first: 1, last: 2, failures: '99' });
  await g.run(); assert.equal(g.sent(), 0); assert.equal(g.state.failures, 1); assert.equal(g.state.first, g.snapshot.now);
});
