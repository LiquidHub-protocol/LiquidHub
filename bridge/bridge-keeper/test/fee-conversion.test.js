'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
// Exercise the real optional conversion cycle with mocked RPC/contract boundaries, without signing.
function cycle({ enabled = true, previewAmount = 100n, gas = 100n, failFirst = false } = {}) {
    const source = fs.readFileSync(path.join(__dirname, '../src/keeper.js'), 'utf8');
    const start = source.indexOf('    // Conversion is a separate, explicitly subsidized action');
    const end = source.indexOf('\n    try {\n        state.bridgeable', start);
    assert.ok(start > 0 && end > start);
    const submitted = []; const estimates = []; const previews = []; const logs = [];
    class Treasury {
        async previewFeeConversion(token) {
            previews.push(token);
            if (failFirst && token === 'tokenA') throw new Error('Stale oracle');
            return [previewAmount, 1n, 0n];
        }
        convertFeeChunk = { populateTransaction: async (token, amount) => ({ to:'treasury',data:token,amount }) };
    }
    const provider = { call: async () => { throw new Error('Swap Treasury'); }, estimateGas: async request => { estimates.push(request); return gas; } };
    const run = vm.runInNewContext(`(async () => { ${source.slice(start, end)} })`, {
        ethers: { Contract: Treasury, Wallet: class {}, Interface:class { encodeFunctionData(){return '0x';} } },
        prepareFeeConversion:require('../src/revenue-maintenance').prepareFeeConversion, TREASURY_ABI: [], walletAddress: 'keeper',
        state: {}, cfg: { enableUnpaidFeeConversions: enabled, privateKey: 'unused', conversionMaxGas: 300_000n },
        t: { address: 'treasury', tokens: ['tokenA', 'tokenB'] }, tag: '[test]',
        rpcPool: { execute: operation => operation(provider), sendSigned: async (_, prepare) => {
            const result = await prepare(provider); submitted.push(result.request); return { status: 1 };
        } }, safeErrorMessage: error => error.message, console: { log: message => logs.push(message) },
    });
    return { run, submitted, estimates, previews, logs };
}
test('the configured opt-out never submits fee conversions', async () => {
    for (const options of [{ enabled: false }]) {
        const fixture = cycle(options); await fixture.run(); assert.equal(fixture.previews.length, 0);
        assert.equal(fixture.submitted.length, 0);
    }
});
test('a public conversion accepts only the configured token, with no caller route or minimum', async () => {
    const fixture = cycle(); await fixture.run();
    assert.deepEqual(fixture.submitted.map(r => r.data), ['tokenA', 'tokenB']);
    for (const request of fixture.estimates) assert.equal(request.from, 'keeper');
});
test('unavailable or over-budget conversion never submits a transaction', async () => {
    for (const options of [{ previewAmount: 0n }, { gas: 300_001n }]) {
        const fixture = cycle(options); await fixture.run(); assert.equal(fixture.submitted.length, 0);
    }
});
test('one stale conversion does not block other tokens or the subsequent USDC bridge cycle', async () => {
    const fixture = cycle({ failFirst: true }); await fixture.run();
    assert.deepEqual(fixture.submitted.map(r => r.data), ['tokenB']);
    assert.ok(fixture.logs.some(message => message.includes('Stale oracle')));
});
