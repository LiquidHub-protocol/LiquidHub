'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { ethers } = require('ethers');
const {
    NAV_DECIMALS,
    calculateUserValue,
    createPositionId,
    decodeRegistryId,
    requireMatchingChain,
    requireSupportedInterfaceVersion,
} = require('./reference-adapter');

test('calculates a user pro-rata NAV with integer rounding down', () => {
    const nav = 1_000_000n * 10n ** BigInt(NAV_DECIMALS);
    assert.equal(calculateUserValue(nav, 25n, 100n), 250_000n * 10n ** BigInt(NAV_DECIMALS));
    assert.equal(calculateUserValue(10n, 1n, 3n), 3n);
});

test('returns zero for an address without shares and rejects inconsistent supply', () => {
    assert.equal(calculateUserValue(10n, 0n, 0n), 0n);
    assert.throws(() => calculateUserValue(10n, 1n, 0n), /totalShares is zero/);
});

test('decodes readable registry ids and preserves unknown bytes32 values', () => {
    assert.equal(decodeRegistryId(ethers.encodeBytes32String('DELTA_NEUTRAL')), 'DELTA_NEUTRAL');
    const opaque = `0x${'ff'.repeat(32)}`;
    assert.equal(decodeRegistryId(opaque), opaque);
});

test('rejects unknown vault ABIs instead of applying the version 1 decoder', () => {
    assert.equal(requireSupportedInterfaceVersion(1n), 1);
    assert.throws(() => requireSupportedInterfaceVersion(2n), /Unsupported Liquid Hub vault interface version/);
});

test('rejects a registry configured for another provider chain', () => {
    assert.equal(requireMatchingChain(42161n, 42161n), 42161n);
    assert.throws(() => requireMatchingChain(42161n, 8453n), /does not match provider chain/);
});

test('namespaces position ids by chain to prevent cross-chain collisions', () => {
    const vault = '0x0000000000000000000000000000000000000001';
    const user = '0x0000000000000000000000000000000000000002';
    assert.equal(createPositionId(42161n, vault, user), `liquidhub:42161:${vault}:${user}`);
    assert.equal(createPositionId(8453n, vault, user), `liquidhub:8453:${vault}:${user}`);
    assert.throws(() => createPositionId(0n, vault, user), /chainId must be positive/);
});

// Use real ethers ABI encoding/decoding, with a chain advancing on every RPC call.
function snapshotProvider({ brokenVault = false, brokenPage = false } = {}) {
    const { REGISTRY_ABI, VAULT_ABI } = require('./reference-adapter');
    const registry = '0x0000000000000000000000000000000000000010';
    const user = '0x0000000000000000000000000000000000000020';
    const iface = new ethers.Interface([...REGISTRY_ABI, ...VAULT_ABI]);
    let head = 100;
    const reads = [];
    const provider = {
        getBlockNumber: async () => head,
        getNetwork: async () => ({ chainId: 42161n }),
        call: async (tx) => {
            const call = iface.parseTransaction(tx);
            reads.push({ method: call.name, blockTag: tx.blockTag });
            head++;
            assert.equal(tx.blockTag, 100, 'every read must use the initial block despite a changing head');
            let result;
            if (call.name === 'deploymentChainId') result = [42161n];
            if (call.name === 'vaultCount') result = [3n];
            if (call.name === 'getVaults') {
                const index = Number(call.args[0]);
                if (brokenPage && index === 1) throw new Error('historical page unavailable');
                result = [[{
                    vault: ethers.getAddress('0x' + (index + 1).toString(16).padStart(40, '0')),
                    rangeManager: registry, dexPool: registry, token0: registry, token1: user,
                    protocolId: ethers.encodeBytes32String('UNISWAP'), strategyId: ethers.encodeBytes32String('STANDARD'),
                    interfaceVersion: 1, registeredAtBlock: 1, updatedAtBlock: 2, active: index !== 2,
                }]];
            }
            if (call.name === 'userInfo') {
                if (brokenVault && tx.to.toLowerCase().endsWith('02')) throw new Error('vault read failed');
                result = [25n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n];
            }
            if (call.name === 'totalShares') result = [100n];
            if (call.name === 'getCurrentPortfolioValue') result = [1000n * 10n ** 8n];
            return iface.encodeFunctionResult(call.fragment, result);
        },
    };
    return { provider, user, registryAddress: registry, pageSize: 1, reads };
}
test('pins discovery, pagination and all valuations to one block as the provider advances', async () => {
    const fixture = snapshotProvider();
    const result = await require('./reference-adapter').getLiquidHubPositions(fixture);
    assert.equal(result.blockNumber, 100);
    assert.equal(result.positions.length, 2);
    assert.equal(result.positions[0].valueUsdRaw, 250n * 10n ** 8n);
    assert.deepEqual(result.failures, []);
    assert.equal(fixture.reads.filter((read) => read.method === 'getVaults').length, 3);
    assert.equal(fixture.reads.filter((read) => read.method === 'userInfo').length, 2);
});
test('keeps per-vault failures explicit, but never returns a silently incomplete discovery', async () => {
    const { getLiquidHubPositions } = require('./reference-adapter');
    const result = await getLiquidHubPositions(snapshotProvider({ brokenVault: true }));
    assert.equal(result.positions.length, 1);
    assert.equal(result.failures.length, 1);
    await assert.rejects(getLiquidHubPositions(snapshotProvider({ brokenPage: true })), /historical page unavailable/);
});
