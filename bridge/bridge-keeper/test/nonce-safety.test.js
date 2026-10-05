// SPDX-License-Identifier: MIT

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { ethers } = require('ethers');

process.env.KEEPER_MAX_GAS_PRICE_GWEI = '10';
process.env.NODE_PATH = [
    path.resolve(__dirname, '../node_modules'),
    process.env.NODE_PATH,
].filter(Boolean).join(path.delimiter);
require('node:module').Module._initPaths();

const { RpcPool, authenticateTreasuryUsdc } = require('../src/keeper');

const poolRpcModule = [
    path.resolve(__dirname, '../../uni-arb-weth-usdc/src/utils/rpc.js'),
    path.resolve(__dirname, '../../../pools/UNI-ARB-WETH-USDC/keeper-bot/src/utils/rpc.js'),
].find((candidate) => fs.existsSync(candidate));
if (!poolRpcModule) throw new Error('Unable to locate the pool keeper RPC implementation');
const { RPCPool: PoolRpcPool } = require(poolRpcModule);

test('bridge keeper has no protocol Telegram, Tenderly or AWS secret transport', () => {
    const source = fs.readFileSync(require.resolve('../src/keeper'), 'utf8');
    assert.doesNotMatch(
        source,
        /TELEGRAM_|api\.telegram\.org|sendTelegram|TENDERLY_|api\.tenderly|aws-sdk|SecretsManager|secrets-manager|AWS_SECRET/i
    );
});

test('configured USDC must match the Treasury immutable token', () => {
    const usdc = '0xaf88d065e77c8cC2239327C5EDb3A432268e5831';
    assert.equal(authenticateTreasuryUsdc(usdc, usdc.toLowerCase()), usdc);
    assert.throws(
        () => authenticateTreasuryUsdc(usdc, '0x0000000000000000000000000000000000000001'),
        /Treasury\.usdc\(\)/,
    );
});

async function withSignerContext(pool, operation) {
    const ownedDir = !pool.processLockFile && !pool.pendingTxFile
        ? fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-unit-lock-')) : null;
    const previousPath = pool.processLockFile;
    pool.processLockFile ||= path.join(ownedDir || path.dirname(pool.pendingTxFile), 'signer.lock');
    const helperPath = pool instanceof PoolRpcPool
        ? path.join(path.dirname(poolRpcModule), 'signer-file-lock.js')
        : '../src/utils/signer-file-lock';
    const { acquireSignerFileLock } = require(helperPath);
    const lock = await acquireSignerFileLock(pool.processLockFile);
    try { return await lock.run(operation); }
    finally {
        lock.release();
        if (ownedDir) { fs.rmSync(ownedDir, { recursive: true, force: true }); pool.processLockFile = previousPath; }
    }
}

function makePool(stateDir) {
    process.env.KEEPER_STATE_DIR = stateDir;
    return new RpcPool({
        name: 'test treasury',
        chainId: 42161,
        rpcUrls: ['http://127.0.0.1:8545', 'http://127.0.0.1:8546', 'http://127.0.0.1:8547'],
    });
}

function signedRequest(wallet, nonce) {
    return wallet.signTransaction({
        to: wallet.address,
        value: 0,
        nonce,
        gasLimit: 21_000,
        gasPrice: 1,
        chainId: 42161,
        type: 0,
    });
}

test('signed bridge transaction is journaled before broadcast and cleared after confirmation', async (t) => {
    const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-keeper-state-'));
    t.after(() => {
        delete process.env.KEEPER_STATE_DIR;
        fs.rmSync(stateDir, { recursive: true, force: true });
    });

    const wallet = ethers.Wallet.createRandom();
    wallet.populateTransaction = async (request) => request;
    const pool = makePool(stateDir);
    let broadcastSawJournal = false;
    const provider = {
        send: async () => '0xa4b1',
        getTransactionCount: async (_address, blockTag) => {
            assert.equal(blockTag, 'pending');
            return 0;
        },
        getTransactionReceipt: async () => null,
        broadcastTransaction: async (rawTx) => {
            broadcastSawJournal = fs.existsSync(pool.pendingTxFile);
            assert.equal(ethers.Transaction.from(rawTx).nonce, 0);
            return {};
        },
        waitForTransaction: async (hash) => ({
            status: 1,
            hash,
            logs: [],
            blockNumber: 1, blockHash: `0x${'ab'.repeat(32)}`,
        }),
    };
    pool.providers = [0, 1, 2].map(() => ({ provider: { ...provider }, chainMismatch: false, chainVerified: true }));

    const receipt = await pool.sendSigned(wallet.address, async () => ({
        wallet,
        request: {
            to: wallet.address,
            value: 0,
            gasLimit: 21_000,
            gasPrice: 1,
            chainId: 42161,
            type: 0,
        },
    }), 'bridge test');

    assert.equal(receipt.status, 1);
    assert.equal(broadcastSawJournal, true);
    assert.equal(fs.existsSync(pool.pendingTxFile), false);
});

test('pending nonce uses coherent observations from all authenticated RPCs', async (t) => {
    const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-keeper-nonce-'));
    t.after(() => {
        delete process.env.KEEPER_STATE_DIR;
        fs.rmSync(stateDir, { recursive: true, force: true });
    });

    const wallet = ethers.Wallet.createRandom();
    const pool = makePool(stateDir);
    pool._ensureSignerState(wallet.address);
    let excludedNonceReads = 0;
    pool.providers = [
        {
            provider: {
                send: async () => '0xa4b1',
                getTransactionCount: async (_address, tag) => {
                    assert.equal(tag, 'pending');
                    return 12;
                },
            },
            chainMismatch: false,
            chainVerified: true,
        },
        {
            provider: {
                send: async () => '0xa4b1',
                getTransactionCount: async (_address, tag) => {
                    assert.equal(tag, 'pending');
                    return 13;
                },
            },
            chainMismatch: false,
            chainVerified: true,
        },
        {
            provider: { getTransactionCount: async () => {
                excludedNonceReads++;
                return 99;
            } },
            chainMismatch: true,
            chainVerified: false,
        },
    ];

    await assert.rejects(pool._pendingSignerNonce(), { code: 'RPC_PENDING_NONCE_DIVERGENCE' });
    pool.providers.push({ ...pool.providers[0] });
    assert.equal(await pool._pendingSignerNonce(), 12);
    assert.equal(excludedNonceReads, 0);
});

test('abnormal authenticated pending nonce divergence is rejected before signing', async (t) => {
    const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-keeper-nonce-divergence-'));
    t.after(() => {
        delete process.env.KEEPER_STATE_DIR;
        fs.rmSync(stateDir, { recursive: true, force: true });
    });

    const wallet = ethers.Wallet.createRandom();
    const pool = makePool(stateDir);
    pool._ensureSignerState(wallet.address);
    pool.providers = [4, 9].map((nonce) => ({
        provider: {
            send: async () => '0xa4b1',
            getTransactionCount: async () => nonce,
        },
        chainMismatch: false,
        chainVerified: true,
    }));

    await assert.rejects(
        pool._pendingSignerNonce(),
        (error) => error.code === 'RPC_PENDING_NONCE_DIVERGENCE'
    );
});

test('gas cap covers legacy and EIP-1559 fee fields', () => {
    const pool = new RpcPool({
        name: 'test treasury',
        chainId: 42161,
        rpcUrls: ['http://127.0.0.1:8545', 'http://127.0.0.1:8546', 'http://127.0.0.1:8547'],
    });
    const cap = ethers.parseUnits('10', 'gwei');
    const aboveCap = cap + 1n;

    assert.doesNotThrow(() => pool._assertFeeCap({ gasPrice: cap }, 'legacy'));
    assert.doesNotThrow(() => pool._assertFeeCap({
        maxFeePerGas: cap,
        maxPriorityFeePerGas: ethers.parseUnits('1', 'gwei'),
    }, 'eip1559'));
    assert.throws(
        () => pool._assertFeeCap({ gasPrice: aboveCap }, 'legacy'),
        /above KEEPER_MAX_GAS_PRICE_GWEI=10\.0/
    );
    assert.throws(
        () => pool._assertFeeCap({ maxFeePerGas: cap, maxPriorityFeePerGas: aboveCap }, 'eip1559'),
        /above KEEPER_MAX_GAS_PRICE_GWEI=10\.0/
    );
});

test('signed transactions are broadcast only through chain-verified RPCs', async () => {
    const wallet = ethers.Wallet.createRandom();
    const pool = new RpcPool({
        name: 'test treasury',
        chainId: 42161,
        rpcUrls: ['http://127.0.0.1:8545', 'http://127.0.0.1:8546', 'http://127.0.0.1:8547'],
    });
    const signedTx = await signedRequest(wallet, 2);
    const txHash = ethers.keccak256(signedTx);
    let unverifiedBroadcasts = 0;
    let verifiedBroadcasts = 0;
    pool.providers = [
        {
            provider: {
                send: async () => { throw new Error('RPC unavailable'); },
                broadcastTransaction: async () => { unverifiedBroadcasts++; },
            },
            chainMismatch: false,
            chainVerified: false,
        },
        {
            provider: {
                send: async () => '0xa4b1',
                getTransactionReceipt: async () => null,
                broadcastTransaction: async () => { verifiedBroadcasts++; },
                waitForTransaction: async () => ({ status: 1, hash: txHash, logs: [], blockNumber: 3, blockHash: `0x${'ab'.repeat(32)}` }),
            },
            chainMismatch: false,
            chainVerified: true,
        },
    ];

    await assert.rejects(withSignerContext(pool, () => pool._broadcastSignedTransaction(signedTx, txHash, 'verified broadcast')), { code: 'TIMEOUT' });
    assert.equal(unverifiedBroadcasts, 0);
    assert.equal(verifiedBroadcasts, 1);
});

test('ambiguous bridge raw blocks a new signature until the exact raw is reconciled', async (t) => {
    const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-keeper-recovery-'));
    t.after(() => {
        delete process.env.KEEPER_STATE_DIR;
        fs.rmSync(stateDir, { recursive: true, force: true });
    });

    const wallet = ethers.Wallet.createRandom();
    const pool = makePool(stateDir);
    pool._ensureSignerState(wallet.address);
    const rawTx = await signedRequest(wallet, 3);
    const txHash = ethers.keccak256(rawTx);
    await withSignerContext(pool, () => pool._persistSignedTx(rawTx, txHash, 'persisted bridge', 3));

    let prepareCalls = 0;
    const provider = {
        send: async () => '0xa4b1',
        getTransactionReceipt: async (hash) => hash === txHash
            ? { status: 1, hash, logs: [], blockNumber: 2, blockHash: `0x${'ab'.repeat(32)}` }
            : null,
        getTransactionCount: async () => 4,
        broadcastTransaction: async () => {
            throw new Error('the confirmed raw must not be rebroadcast');
        },
        waitForTransaction: async () => null,
    };
    pool.providers = [0, 1, 2].map(() => ({ provider: { ...provider }, chainMismatch: false, chainVerified: true }));

    await assert.rejects(
        pool.sendSigned(wallet.address, async () => {
            prepareCalls++;
            return { wallet, request: {} };
        }, 'new bridge'),
        (error) => error.code === 'KEEPER_STATE_REFRESH_REQUIRED'
    );
    assert.equal(prepareCalls, 0);
    assert.equal(fs.existsSync(pool.pendingTxFile), false);
});

test('underpriced persisted bridge transaction is replaced with the same nonce and payload', async (t) => {
    const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-keeper-replacement-'));
    t.after(() => {
        delete process.env.KEEPER_STATE_DIR;
        fs.rmSync(stateDir, { recursive: true, force: true });
    });

    const wallet = ethers.Wallet.createRandom();
    process.env.KEEPER_STATE_DIR = stateDir;
    const pool = new RpcPool({
        name: 'test treasury',
        chainId: 42161,
        rpcUrls: ['http://127.0.0.1:8545', 'http://127.0.0.1:8546', 'http://127.0.0.1:8547'],
    }, ethers.parseUnits('10', 'gwei'), wallet);
    pool._ensureSignerState(wallet.address);
    const rawTx = await wallet.signTransaction({
        to: wallet.address,
        value: 7,
        data: '0x1234',
        nonce: 4,
        gasLimit: 50_000,
        gasPrice: ethers.parseUnits('1', 'gwei'),
        chainId: 42161,
        type: 0,
    });
    const txHash = ethers.keccak256(rawTx);
    await withSignerContext(pool, () => pool._persistSignedTx(rawTx, txHash, 'underpriced bridge', 4));

    let replacementRaw = null;
    const provider = {
        send: async () => '0xa4b1',
        getTransactionReceipt: async () => null,
        getTransactionCount: async (_address, tag) => {
            assert.equal(tag, 'latest');
            return 4;
        },
        getFeeData: async () => ({ gasPrice: ethers.parseUnits('2', 'gwei') }),
        broadcastTransaction: async (raw) => {
            const parsed = ethers.Transaction.from(raw);
            if (parsed.gasPrice === ethers.parseUnits('1', 'gwei')) {
                throw new Error('replacement transaction underpriced');
            }
            replacementRaw = raw;
            return {};
        },
        waitForTransaction: async (hash) => ({ status: 1, hash, logs: [], blockNumber: 12, blockHash: `0x${'ab'.repeat(32)}` }),
    };
    pool.providers = [0, 1, 2].map(() => ({ provider: { ...provider }, chainMismatch: false, chainVerified: true }));

    const result = await withSignerContext(pool, () => pool._reconcilePendingSignedTxLocked());
    const previous = ethers.Transaction.from(rawTx);
    const replacement = ethers.Transaction.from(replacementRaw);
    assert.equal(result.status, 'confirmed');
    assert.equal(result.replacedTxHash, txHash);
    assert.equal(replacement.nonce, previous.nonce);
    assert.equal(replacement.to, previous.to);
    assert.equal(replacement.data, previous.data);
    assert.equal(replacement.value, previous.value);
    assert.ok(replacement.gasPrice > previous.gasPrice);
    assert.ok(replacement.gasPrice <= ethers.parseUnits('10', 'gwei'));
    assert.equal(fs.existsSync(pool.pendingTxFile), false);
});

test('receipt timeout replaces a persisted bridge transaction with identical nonce and payload', async (t) => {
    const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-keeper-replacement-'));
    t.after(() => {
        delete process.env.KEEPER_STATE_DIR;
        fs.rmSync(stateDir, { recursive: true, force: true });
    });

    const wallet = ethers.Wallet.createRandom();
    process.env.KEEPER_STATE_DIR = stateDir;
    const pool = new RpcPool({
        name: 'test treasury',
        chainId: 42161,
        rpcUrls: ['http://127.0.0.1:8545', 'http://127.0.0.1:8546', 'http://127.0.0.1:8547'],
    }, ethers.parseUnits('10', 'gwei'), wallet);
    pool._ensureSignerState(wallet.address);
    const rawTx = await wallet.signTransaction({
        to: wallet.address,
        value: 7,
        data: '0x1234',
        nonce: 4,
        gasLimit: 50_000,
        gasPrice: ethers.parseUnits('1', 'gwei'),
        chainId: 42161,
        type: 0,
    });
    const txHash = ethers.keccak256(rawTx);
    await withSignerContext(pool, () => pool._persistSignedTx(rawTx, txHash, 'underpriced bridge', 4));

    let replacementRaw = null;
    const provider = {
        send: async () => '0xa4b1',
        getTransactionReceipt: async () => null,
        getTransactionCount: async (_address, tag) => {
            assert.equal(tag, 'latest');
            return 4;
        },
        getFeeData: async () => ({ gasPrice: ethers.parseUnits('2', 'gwei') }),
        broadcastTransaction: async (raw) => {
            const parsed = ethers.Transaction.from(raw);
            if (parsed.gasPrice === ethers.parseUnits('1', 'gwei')) {
                return {};
            }
            replacementRaw = raw;
            return {};
        },
        waitForTransaction: async (hash) => {
            if (hash === txHash) throw new Error('receipt timeout after 120s');
            return { status: 1, hash, logs: [], blockNumber: 12, blockHash: `0x${'ab'.repeat(32)}` };
        },
    };
    pool.providers = [0, 1, 2].map(() => ({ provider: { ...provider }, chainMismatch: false, chainVerified: true }));

    const result = await withSignerContext(pool, () => pool._reconcilePendingSignedTxLocked());
    const previous = ethers.Transaction.from(rawTx);
    const replacement = ethers.Transaction.from(replacementRaw);
    assert.equal(result.status, 'confirmed');
    assert.equal(result.replacedTxHash, txHash);
    assert.equal(replacement.nonce, previous.nonce);
    assert.equal(replacement.to, previous.to);
    assert.equal(replacement.data, previous.data);
    assert.equal(replacement.value, previous.value);
    assert.ok(replacement.gasPrice > previous.gasPrice);
    assert.ok(replacement.gasPrice <= ethers.parseUnits('10', 'gwei'));
    assert.equal(fs.existsSync(pool.pendingTxFile), false);
});

test('same chain and signer share one process lock across treasury instances', async (t) => {
    const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-keeper-lock-'));
    t.after(() => {
        delete process.env.KEEPER_STATE_DIR;
        fs.rmSync(stateDir, { recursive: true, force: true });
    });

    const wallet = ethers.Wallet.createRandom();
    const first = makePool(stateDir);
    const second = makePool(stateDir);
    const order = [];

    await Promise.all([
        first._withSignerLock(wallet.address, async () => {
            order.push('first-start');
            await new Promise((resolve) => setTimeout(resolve, 80));
            order.push('first-end');
        }),
        new Promise((resolve) => setTimeout(resolve, 10)).then(() =>
            second._withSignerLock(wallet.address, async () => {
                order.push('second');
            })
        ),
    ]);

    assert.deepEqual(order, ['first-start', 'first-end', 'second']);
});

test('a stale bridge signer lock is reclaimed even when its PID has been reused', async (t) => {
    const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-keeper-stale-lock-'));
    t.after(() => {
        delete process.env.KEEPER_STATE_DIR;
        fs.rmSync(stateDir, { recursive: true, force: true });
    });
    const wallet = ethers.Wallet.createRandom();
    const pool = makePool(stateDir);
    pool._ensureSignerState(wallet.address);
    fs.writeFileSync(pool.processLockFile, `${JSON.stringify({ version: 2, pid: process.pid, token: 'stale', processStartIdentity: 'ps:Mon Jan 1 00:00:00 1900' })}\n`, { mode: 0o600 });
    const staleAt = new Date(Date.now() - 3 * 60_000);
    fs.utimesSync(pool.processLockFile, staleAt, staleAt);

    let executed = false;
    await pool._withSignerLock(wallet.address, async () => { executed = true; });
    assert.equal(executed, true);
    assert.equal(fs.existsSync(pool.processLockFile), false);
});

test('bridge and pool keepers share one journal and reconcile each other before signing', async (t) => {
    const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'cross-keeper-state-'));
    const previous = {
        KEEPER_STATE_DIR: process.env.KEEPER_STATE_DIR,
        KEEPER_PENDING_TX_FILE: process.env.KEEPER_PENDING_TX_FILE,
        KEEPER_PRIVATE_KEY: process.env.KEEPER_PRIVATE_KEY,
        CHAINID: process.env.CHAINID,
        RPC_URL: process.env.RPC_URL,
        RPC_BACKUP_1: process.env.RPC_BACKUP_1, RPC_BACKUP_2: process.env.RPC_BACKUP_2,
    };
    const wallet = ethers.Wallet.createRandom();
    process.env.KEEPER_STATE_DIR = stateDir;
    delete process.env.KEEPER_PENDING_TX_FILE;
    process.env.KEEPER_PRIVATE_KEY = wallet.privateKey;
    process.env.CHAINID = '42161';
    process.env.RPC_URL = 'http://127.0.0.1:8545';
    process.env.RPC_BACKUP_1 = 'http://127.0.0.1:8546'; process.env.RPC_BACKUP_2 = 'http://127.0.0.1:8547';
    t.after(() => {
        for (const [key, value] of Object.entries(previous)) {
            if (value === undefined) delete process.env[key];
            else process.env[key] = value;
        }
        fs.rmSync(stateDir, { recursive: true, force: true });
    });

    const bridge = makePool(stateDir);
    const pool = new PoolRpcPool();
    let expectedHash = null;
    const provider = {
        send: async () => '0xa4b1',
        getTransactionReceipt: async (hash) => hash === expectedHash
            ? { status: 1, hash, logs: [], blockNumber: 10, blockHash: `0x${'ab'.repeat(32)}` }
            : null,
        getTransactionCount: async () => 99,
        broadcastTransaction: async () => { throw new Error('confirmed raw must not be rebroadcast'); },
        waitForTransaction: async () => null,
    };
    bridge.providers = [0, 1, 2].map(() => ({ provider: { ...provider }, chainMismatch: false, chainVerified: true }));
    pool.providers = [{
        provider,
        healthy: true,
        errorCount: 0,
        chainMismatch: false,
        chainVerified: true,
    }];
    pool.currentIndex = 0;
    await pool._ensureSignerState(provider);
    bridge._ensureSignerState(wallet.address);

    assert.equal(bridge.pendingTxFile, pool.pendingTxFile);
    assert.equal(bridge.processLockFile, pool.processLockFile);
    let releaseBridge, enteredBridge, poolEntered = false;
    const gate = new Promise(r => { releaseBridge = r; }), ready = new Promise(r => { enteredBridge = r; });
    const bridgeWork = bridge._withSignerLock(wallet.address, async () => { enteredBridge(); await gate; });
    await ready;
    const old = new Date(Date.now() - 121_000); fs.utimesSync(bridge.processLockFile, old, old);
    assert.equal(pool._isLockOwnerAlive(JSON.parse(fs.readFileSync(bridge.processLockFile, 'utf8'))), true);
    const poolWork = pool._withSignerLock(provider, async () => { poolEntered = true; });
    await new Promise(r => setTimeout(r, 25)); assert.equal(poolEntered, false);
    releaseBridge(); await Promise.all([bridgeWork, poolWork]); assert.equal(poolEntered, true);

    const bridgeRaw = await signedRequest(wallet, 7);
    expectedHash = ethers.keccak256(bridgeRaw);
    await withSignerContext(bridge, () => bridge._persistSignedTx(bridgeRaw, expectedHash, 'bridge action', 7));
    let poolPrepareCalls = 0;
    await assert.rejects(
        pool.executeSignedTxWithRetry(async () => {
            poolPrepareCalls++;
            return { wallet, request: {} };
        }, 'pool action'),
        (error) => error.code === 'KEEPER_STATE_REFRESH_REQUIRED'
    );
    assert.equal(poolPrepareCalls, 0);
    assert.equal(fs.existsSync(bridge.pendingTxFile), false);

    const poolRaw = await signedRequest(wallet, 8);
    expectedHash = ethers.keccak256(poolRaw);
    await withSignerContext(pool, () => pool._persistSignedTx(poolRaw, expectedHash, 'pool action', 8));
    let bridgePrepareCalls = 0;
    await assert.rejects(
        bridge.sendSigned(wallet.address, async () => {
            bridgePrepareCalls++;
            return { wallet, request: {} };
        }, 'bridge action'),
        (error) => error.code === 'KEEPER_STATE_REFRESH_REQUIRED'
    );
    assert.equal(bridgePrepareCalls, 0);
    assert.equal(fs.existsSync(pool.pendingTxFile), false);
});

test('legacy bridge journal migrates to the shared canonical file with restrictive permissions', async (t) => {
    const canonicalDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-canonical-state-'));
    const legacyDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-legacy-state-'));
    process.env.KEEPER_STATE_DIR = canonicalDir;
    process.env.BRIDGE_KEEPER_STATE_DIR = legacyDir;
    t.after(() => {
        delete process.env.KEEPER_STATE_DIR;
        delete process.env.BRIDGE_KEEPER_STATE_DIR;
        fs.rmSync(canonicalDir, { recursive: true, force: true });
        fs.rmSync(legacyDir, { recursive: true, force: true });
    });

    const wallet = ethers.Wallet.createRandom();
    const bridge = new RpcPool({
        name: 'test treasury',
        chainId: 42161,
        rpcUrls: ['http://127.0.0.1:8545', 'http://127.0.0.1:8546', 'http://127.0.0.1:8547'],
    });
    bridge._ensureSignerState(wallet.address);
    const rawTx = await signedRequest(wallet, 11);
    const txHash = ethers.keccak256(rawTx);
    const legacyFile = path.join(legacyDir, `pending-bridge-42161-${wallet.address.toLowerCase()}.json`);
    fs.writeFileSync(legacyFile, `${JSON.stringify({
        schemaVersion: 1,
        rawTx,
        txHash,
        label: 'legacy bridge',
        signer: wallet.address.toLowerCase(),
        chainId: '42161',
        nonce: 11,
        createdAt: new Date().toISOString(),
    })}\n`, { mode: 0o600 });

    const migrated = await bridge._withSignerLock(wallet.address, async () => bridge._readPendingSignedTx());
    assert.equal(migrated.schemaVersion, 2);
    assert.equal(migrated.txHash, txHash);
    assert.equal(fs.existsSync(legacyFile), false);
    assert.equal(fs.existsSync(bridge.pendingTxFile), true);
    assert.equal(fs.statSync(bridge.pendingTxFile).mode & 0o777, 0o600);
});

test('bridge RPC failures redact complete endpoints and credentials from logs', async () => {
    const secretUrl = 'https://rpc.vendor.example/account/SECRET_TOKEN?api-key=TOP_SECRET';
    const pool = new RpcPool({ name: 'test', chainId: 42161, rpcUrls: [secretUrl, 'http://127.0.0.1:8546', 'http://127.0.0.1:8547'] });
    pool.providers[0].provider = {
        send: async () => {
            const error = new Error(`request failed at ${secretUrl} Authorization: Bearer VERY_SECRET`);
            error.code = 'NETWORK_ERROR';
            throw error;
        },
    };
    pool.providers = [0, 1, 2].map(() => ({ ...pool.providers[0], provider: { ...pool.providers[0].provider } }));
    const logs = [];
    const originalWarn = console.warn;
    console.warn = (...args) => logs.push(args.join(' '));
    try {
        await assert.rejects(pool.verifyChains(), /No RPC authenticated/);
    } finally {
        console.warn = originalWarn;
    }
    const output = logs.join('\n');
    assert.match(output, /\[REDACTED_RPC_URL\]/);
    assert.doesNotMatch(output, /SECRET_TOKEN|TOP_SECRET|VERY_SECRET|rpc\.vendor\.example/);
});


test('late bridge receipt lookup cannot broadcast after the original lock has been released', async t => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-late-broadcast-'));
    t.after(() => { delete process.env.KEEPER_STATE_DIR; fs.rmSync(dir, { recursive: true, force: true }); });
    const pool = makePool(dir), wallet = ethers.Wallet.createRandom(); pool._ensureSignerState(wallet.address);
    const { acquireSignerFileLock } = require('../src/utils/signer-file-lock');
    let resume, entered, broadcasts = 0;
    const gate = new Promise(r => { resume = r; }), ready = new Promise(r => { entered = r; });
    const provider = { getTransactionReceipt: async () => { entered(); await gate; return null; }, broadcastTransaction: async () => { broadcasts++; } };
    pool.providers = [{ provider, chainVerified: true }];
    pool._authenticatedProviderEntries = async () => pool.providers;
    const lock = await acquireSignerFileLock(pool.processLockFile);
    const late = lock.run(() => pool._broadcastSignedTransaction('0x', '0x01', 'late'));
    await ready; lock.release(); const next = await acquireSignerFileLock(pool.processLockFile);
    await next.run(async () => { resume(); await assert.rejects(late, { code: 'SIGNER_LOCK_LOST' }); });
    assert.equal(broadcasts, 0); next.release();
});

test('a forged receipt cannot suppress bridge broadcast or retire its journal on restart',async t=>{
    const dir=fs.mkdtempSync(path.join(os.tmpdir(),'bridge-quorum-'));
    t.after(()=>{delete process.env.KEEPER_STATE_DIR;fs.rmSync(dir,{recursive:true,force:true});});
    const pool=makePool(dir),wallet=ethers.Wallet.createRandom();
    pool._ensureSignerState(wallet.address);
    const raw=await signedRequest(wallet,0),hash=ethers.keccak256(raw);
    const receipt={hash,status:1,blockNumber:20,blockHash:`0x${'ab'.repeat(32)}`,logs:[]};
    let sends=0;
    pool.providers=[true,false,false].map(forged=>({chainVerified:true,chainMismatch:false,provider:{
        send:async()=> '0xa4b1',getTransactionCount:async()=>0,
        getTransactionReceipt:async()=>forged?receipt:null,
        broadcastTransaction:async()=>{sends++;},
        waitForTransaction:async()=>forged?receipt:null,
    }}));
    await withSignerContext(pool,()=>pool._persistSignedTx(raw,hash,'fixture',0));
    await assert.rejects(withSignerContext(pool,()=>pool._reconcilePendingSignedTxLocked()),/pending|receipt|wallet|signer/i);
    assert.equal(sends,3,'every authenticated endpoint received identical signed bytes');
    assert.equal(fs.existsSync(pool.pendingTxFile),true,'lack of majority preserves recovery state');
    pool.providers[1].provider.getTransactionReceipt=async()=>({...receipt,status:2});
    assert.equal(await pool._readReceiptQuorum(pool.providers,hash,'invalid status'),null);
    pool.providers[1].provider.getTransactionReceipt=async()=>receipt;
    const recovered=await withSignerContext(pool,()=>pool._reconcilePendingSignedTxLocked());
    assert.equal(recovered.status,'confirmed');assert.equal(fs.existsSync(pool.pendingTxFile),false);
});


test('bridge journal retirement never trusts a failed-on-chain error string', async () => {
  const pool=Object.create(RpcPool.prototype);let cleared=0;
  pool.providers=[];
  pool._readPendingSignedTx=()=>({nonce:0,txHash:'0x1234',rawTx:'0x00',label:'fixture'});
  pool._authenticatedProviderEntries=async()=>[];
  pool._readReceiptQuorum=async()=>null;
  pool._allObservedNoncesAdvanced=async()=>false;
  pool._clearPersistedSignedTx=()=>{cleared++;};
  pool._broadcastSignedTransaction=async()=>{throw Error('untrusted RPC: failed on-chain');};
  await assert.rejects(pool._reconcilePendingSignedTxLocked(),/failed on-chain/);
  assert.equal(cleared,0);
  let reads=0;
  pool._readReceiptQuorum=async()=>++reads===1?null:{status:0};
  pool._broadcastSignedTransaction=RpcPool.prototype._broadcastSignedTransaction;
  const result=await pool._reconcilePendingSignedTxLocked();
  assert.equal(result.status,'failed');assert.equal(cleared,1);
});


test('bridge requires three independent configured sources and never lowers receipt quorum', () => {
  assert.throws(() => new RpcPool({ name: 'fixture', chainId: 42161, rpcUrls: ['http://localhost:8545'] }), /three distinct/);
  assert.throws(() => new RpcPool({ name: 'fixture', chainId: 42161, rpcUrls: ['http://localhost:8545', ' http://localhost:8545 ', 'http://localhost:8546'] }), /three distinct/);
  assert.equal(RpcPool.prototype._receiptQuorumSize.call({providers: [{}]}), 2);
});
