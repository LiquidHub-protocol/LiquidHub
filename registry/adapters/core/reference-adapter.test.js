// SPDX-License-Identifier: MIT

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
