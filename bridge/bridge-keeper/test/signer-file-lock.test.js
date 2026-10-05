'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { execFile, execFileSync } = require('node:child_process');
const { promisify } = require('node:util');
const helperPath = fs.existsSync(path.join(__dirname, 'signer-file-lock.js'))
    ? path.join(__dirname, 'signer-file-lock.js')
    : path.join(__dirname, '../src/utils/signer-file-lock.js');
const { acquireSignerFileLock, assertSignerFileLock, isSignerLockOwnerAlive } = require(helperPath);
const runNode = promisify(execFile);

function fixture(t) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'liquidhub-signer-lock-test-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    return { dir, file: path.join(dir, 'signer.lock') };
}

function abandonedLock(file, extraLinks = false) {
    const script = `
        const fs = require('node:fs');
        const { createHash, randomUUID } = require('node:crypto');
        const { acquireSignerFileLock } = require(${JSON.stringify(helperPath)});
        acquireSignerFileLock(${JSON.stringify(file)}).then(lock => {
            if (${extraLinks}) {
                const identity = createHash('sha256').update(lock.state.processStartIdentity).digest('hex').slice(0, 32);
                for (const kind of ['publish', 'reclaim']) {
                    fs.linkSync(lock.path, lock.path + '.' + kind + '.' + process.pid + '.' + identity + '.' + randomUUID());
                }
            }
            process.exit(0);
        }).catch(error => { console.error(error); process.exit(1); });
    `;
    execFileSync(process.execPath, ['-e', script], { timeout: 5000, stdio: 'pipe' });
}

test('only complete metadata is published to the shared lock path', async (t) => {
    const { file, dir } = fixture(t);
    const link = fs.linkSync;
    let publications = 0;
    fs.linkSync = function (from, to) {
        if (to === file) {
            const data = JSON.parse(fs.readFileSync(from, 'utf8'));
            assert.equal(data.version, 2);
            assert.equal(data.pid, process.pid);
            assert.ok(data.processStartIdentity);
            assert.equal(fs.existsSync(file), false);
            publications++;
        }
        return link.call(fs, from, to);
    };
    let lock;
    try { lock = await acquireSignerFileLock(file); }
    finally { fs.linkSync = link; }
    lock.assertOwned();
    assert.equal(publications, 1);
    assert.deepEqual(fs.readdirSync(dir), ['signer.lock']);
    lock.release();
    assert.deepEqual(fs.readdirSync(dir), []);
});

test('a living owner retains its lock regardless of heartbeat age', async (t) => {
    const { file } = fixture(t);
    const lock = await acquireSignerFileLock(file);
    const old = new Date(Date.now() - 121_000);
    fs.utimesSync(file, old, old);
    assert.equal(isSignerLockOwnerAlive(lock.state), true);
    await assert.rejects(acquireSignerFileLock(file, { timeoutMs: 25, pollMs: 5 }), { code: 'SIGNER_LOCK_TIMEOUT' });
    lock.assertOwned();
    lock.release();
});

test('a legacy live owner and an incomplete legacy publication cannot be evicted', async (t) => {
    const { file } = fixture(t);
    const fd = fs.openSync(file, 'wx', 0o600);
    try {
        await assert.rejects(acquireSignerFileLock(file, { timeoutMs: 20, pollMs: 5 }), { code: 'SIGNER_LOCK_TIMEOUT' });
        assert.equal(fs.fstatSync(fd).nlink, 1);
        fs.writeFileSync(fd, JSON.stringify({ pid: process.pid, token: 'legacy-owner' }));
        const old = new Date(Date.now() - 600_000);
        fs.utimesSync(file, old, old);
        await assert.rejects(acquireSignerFileLock(file, { timeoutMs: 20, pollMs: 5 }), { code: 'SIGNER_LOCK_TIMEOUT' });
        assert.equal(fs.fstatSync(fd).nlink, 1);
    } finally { fs.closeSync(fd); }
});

test('late asynchronous work cannot inherit a successor lock', async (t) => {
    const { file } = fixture(t);
    const first = await acquireSignerFileLock(file);
    let resume;
    const gate = new Promise(resolve => { resume = resolve; });
    const late = first.run(async () => { await gate; assertSignerFileLock(file); });
    first.release();
    const second = await acquireSignerFileLock(file);
    await second.run(async () => {
        resume();
        await assert.rejects(late, { code: 'SIGNER_LOCK_LOST' });
        assertSignerFileLock(file);
    });
    second.release();
});

test('replacement of a lock inode revokes every old handle without deleting the successor', async (t) => {
    const { file } = fixture(t);
    const first = await acquireSignerFileLock(file);
    fs.unlinkSync(file); // Deterministic simulation of ownership loss, not normal recovery.
    const second = await acquireSignerFileLock(file);
    assert.throws(() => first.assertOwned(), { code: 'SIGNER_LOCK_LOST' });
    assert.throws(() => first.release(), { code: 'SIGNER_LOCK_LOST' });
    second.assertOwned();
    second.release();
});

for (const extraLinks of [false, true]) {
    test(`a real process crash is recovered${extraLinks ? ' with interrupted publication/recovery links' : ''}`, async (t) => {
        const { file, dir } = fixture(t);
        abandonedLock(file, extraLinks);
        assert.equal(isSignerLockOwnerAlive(JSON.parse(fs.readFileSync(file, 'utf8'))), false);
        const next = await acquireSignerFileLock(file, { timeoutMs: 2000, pollMs: 5 });
        next.assertOwned();
        next.release();
        assert.deepEqual(fs.readdirSync(dir), []);
    });
}

test('concurrent processes recovering the same dead owner remain exclusive', async (t) => {
    const { file, dir } = fixture(t);
    abandonedLock(file);
    const events = path.join(dir, 'events');
    await Promise.all([0, 1, 2].map(id => runNode(process.execPath, ['-e', `
        const fs = require('node:fs');
        const { acquireSignerFileLock, assertSignerFileLock } = require(${JSON.stringify(helperPath)});
        (async () => {
            const lock = await acquireSignerFileLock(${JSON.stringify(file)}, { timeoutMs: 4000, pollMs: 5 });
            try { await lock.run(async () => {
                assertSignerFileLock(${JSON.stringify(file)});
                fs.appendFileSync(${JSON.stringify(events)}, 'start:${id}\\n');
                await new Promise(r => setTimeout(r, 25));
                assertSignerFileLock(${JSON.stringify(file)});
                fs.appendFileSync(${JSON.stringify(events)}, 'end:${id}\\n');
            }); } finally { lock.release(); }
        })().catch(error => { console.error(error); process.exitCode = 1; });
    `], { timeout: 6000 })));
    const order = fs.readFileSync(events, 'utf8').trim().split('\n');
    assert.equal(order.length, 6);
    for (let i = 0; i < order.length; i += 2) {
        assert.ok(order[i].startsWith('start:'));
        assert.equal(order[i + 1], order[i].replace('start:', 'end:'));
    }
});

test('a reused PID is distinguished by its process start identity', async (t) => {
    const { file } = fixture(t);
    fs.writeFileSync(file, JSON.stringify({ version: 2, pid: process.pid, token: 'old', processStartIdentity: 'ps:historical-owner' }), { mode: 0o600 });
    const lock = await acquireSignerFileLock(file, { timeoutMs: 1000, pollMs: 5 });
    lock.assertOwned();
    lock.release();
});

test('Linux identity binds both boot ID and /proc starttime; unknown identity protects a live owner', () => {
    const boot = '11111111-1111-1111-1111-111111111111';
    const fields = Array(20).fill('0'); fields[19] = '456';
    const fakeFs = { ...fs, readFileSync: file => {
        if (file.endsWith('/stat')) return `123 (worker (with spaces)) ${fields.join(' ')}`;
        if (file.endsWith('/boot_id')) return boot;
        throw new Error('unexpected read');
    } };
    const box = { module: { exports: {} }, process: { ...process, platform: 'linux', kill() {} },
        require: name => name === 'node:fs' ? fakeFs : require(name) };
    vm.runInNewContext(fs.readFileSync(helperPath, 'utf8'), box);
    const api = box.module.exports;
    assert.equal(api.readProcessStartIdentity(123), `linux:${boot}:456`);
    assert.equal(api.isSignerLockOwnerAlive({ version: 2, pid: 123, processStartIdentity: `linux:${boot}:456` }), true);
    assert.equal(api.isSignerLockOwnerAlive({ version: 2, pid: 123, processStartIdentity: `linux:${boot}:999` }), false);
    fakeFs.readFileSync = () => { throw new Error('identity temporarily unavailable'); };
    assert.equal(api.isSignerLockOwnerAlive({ version: 2, pid: 123, processStartIdentity: `linux:${boot}:999` }), true);
});
