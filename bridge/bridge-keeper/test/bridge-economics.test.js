const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const { ethers } = require('ethers');

function affordability(overrides = {}, oracleAddress = 'configured') {
    const source = fs.readFileSync(path.join(__dirname, '../src/keeper.js'), 'utf8');
    const start = source.indexOf('    async function estimateFee(bridgeAmount)');
    const end = source.indexOf('    async function finalizeReceipt(receipt)', start);
    assert.ok(start >= 0 && end > start);
    let oracleReads = 0;
    const check = vm.runInNewContext(`${source.slice(start, end)}; ensureFeeAffordable;`, {
        ethers: { ...ethers, Contract: class {
            async estimateBridgeFee() { return [1_000_000_000_000_000n, 100n]; }
        } },
        TREASURY_ABI: [], t: { address: ethers.ZeroAddress },
        cfg: { maxStargateFeeUsd: 0, allowSubsidizedBridge: false,
            minBridgeNetUsd: 0.10, nativeOracleMaxAgeSec: 7200, ...overrides },
        state: { bountyAmount: 1_000_000n, usdcDecimals: 6 }, tag: '[test]',
        rpcPool: { execute: operation => operation({ getBalance: async () => 10n ** 18n }) },
        nativeOracleAddress: () => oracleAddress,
        readUsdOraclePrice: async () => { oracleReads++; return 2000; },
        NATIVE_DECIMALS: 18, walletAddress: ethers.ZeroAddress,
        safeErrorMessage: error => error.message, fmt: String, console: { log() {} },
    });
    return { check: () => check(100n), oracleReads: () => oracleReads };
}

test('disabling the fee ceiling preserves the bridge subsidy guard', async () => {
    const fixture = affordability();
    assert.equal((await fixture.check()).skipped, 'uneconomic_bridge');
    assert.equal(fixture.oracleReads(), 1);
});

test('a bridge without a fee ceiling still requires an oracle unless subsidy is explicit', async () => {
    assert.equal((await affordability({}, null).check()).error, 'estimate_failed');
    const voluntary = affordability({ allowSubsidizedBridge: true }, null);
    assert.ok((await voluntary.check()).estimate);
    assert.equal(voluntary.oracleReads(), 0);
});

test('the explicit Stargate fee ceiling still applies to subsidized bridges', async () => {
    const fixture = affordability({ allowSubsidizedBridge: true, maxStargateFeeUsd: 1 });
    assert.equal((await fixture.check()).skipped, 'fee_too_high');
});
