// SPDX-License-Identifier: MIT

'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const deployments = require('./deployments.json');

test('deployment manifest distinguishes planned and deployed registries', () => {
    assert.equal(deployments.schemaVersion, 1);
    assert.ok(Array.isArray(deployments.registries));
    assert.ok(deployments.registries.length > 0);

    const chainIds = new Set();
    const networkNames = new Set();
    for (const entry of deployments.registries) {
        assert.equal(typeof entry.network, 'string');
        assert.notEqual(entry.network.trim(), '');
        assert.equal(networkNames.has(entry.network), false, `Duplicate network ${entry.network}`);
        networkNames.add(entry.network);
        assert.ok(Number.isSafeInteger(entry.chainId) && entry.chainId > 0);
        assert.equal(chainIds.has(entry.chainId), false, `Duplicate chain ID ${entry.chainId}`);
        chainIds.add(entry.chainId);
        assert.match(entry.explorerUrl, /^https:\/\//);
        assert.equal(entry.registryVersion, 1);
        assert.ok(entry.status === 'pending' || entry.status === 'deployed');

        if (entry.status === 'pending') {
            assert.equal(entry.registryAddress, null);
        } else {
            assert.match(entry.registryAddress, /^0x[a-fA-F0-9]{40}$/);
            assert.notEqual(entry.registryAddress.toLowerCase(), `0x${'0'.repeat(40)}`);
        }
    }
});
