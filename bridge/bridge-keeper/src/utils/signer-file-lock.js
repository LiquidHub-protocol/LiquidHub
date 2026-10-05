// SPDX-License-Identifier: MIT
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { randomUUID, createHash } = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { AsyncLocalStorage } = require('node:async_hooks');

const context = new AsyncLocalStorage();
const MAX_LOCK_BYTES = 4096;

function lockError(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
}

function readProcessStartIdentity(pid) {
    if (!Number.isSafeInteger(pid) || pid <= 0) return null;
    try {
        if (process.platform === 'linux') {
            const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
            const fields = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/);
            const bootId = fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim();
            if (!/^\d+$/.test(fields[19] || '') || !/^[a-f0-9-]{36}$/.test(bootId)) return null;
            return `linux:${bootId}:${fields[19]}`;
        }
        const startedAt = execFileSync('ps', ['-p', String(pid), '-o', 'lstart='], {
            encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 2000,
            env: { ...process.env, LC_ALL: 'C', LANG: 'C' },
        }).trim().replace(/\s+/g, ' ');
        return startedAt ? `ps:${startedAt}` : null;
    } catch {
        return null;
    }
}

function isProcessAlive(pid) {
    try { process.kill(pid, 0); return true; }
    catch (error) { return error.code !== 'ESRCH'; }
}

function isSignerLockOwnerAlive(state) {
    if (!Number.isSafeInteger(state?.pid) || state.pid <= 0) return true;
    if (!isProcessAlive(state.pid)) return false;
    // Old locks did not bind the boot identity. Never evict a live legacy owner
    // or use an expired heartbeat as proof that a suspended process has died.
    if (state.version !== 2) return true;
    const identity = readProcessStartIdentity(state.pid);
    return !identity || identity === state.processStartIdentity;
}

function identityHash(identity) {
    return createHash('sha256').update(identity).digest('hex').slice(0, 32);
}

function regularFile(stat) {
    return stat.isFile() && !stat.isSymbolicLink()
        && (typeof process.getuid !== 'function' || stat.uid === process.getuid())
        && (stat.mode & 0o077) === 0;
}

function readLock(file) {
    const before = fs.lstatSync(file);
    if (!regularFile(before) || before.size <= 0 || before.size > MAX_LOCK_BYTES) {
        throw lockError('SIGNER_LOCK_UNSAFE', `Unreadable or unsafe signer lock: ${file}`);
    }
    const fd = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
    let stat, raw;
    try {
        stat = fs.fstatSync(fd);
        if (stat.dev !== before.dev || stat.ino !== before.ino) {
            throw lockError('SIGNER_LOCK_BUSY', 'Signer lock changed during inspection');
        }
        raw = fs.readFileSync(fd, 'utf8');
    } finally { fs.closeSync(fd); }
    let state;
    try { state = JSON.parse(raw); } catch {
        throw lockError('SIGNER_LOCK_UNSAFE', `Incomplete signer lock; owner cannot be identified: ${file}`);
    }
    if (!state || !Number.isSafeInteger(state.pid) || state.pid <= 0
        || typeof state.token !== 'string' || !state.token || state.token.length > 256
        || (state.version === 2 && (typeof state.processStartIdentity !== 'string'
            || !/^(?:linux:[a-f0-9-]{36}:\d+|ps:[\x20-\x7e]+)$/.test(state.processStartIdentity)))) {
        throw lockError('SIGNER_LOCK_UNSAFE', `Invalid signer lock identity: ${file}`);
    }
    return { state, raw, dev: stat.dev, ino: stat.ino, nlink: stat.nlink };
}

function sameFile(a, b) { return a.dev === b.dev && a.ino === b.ino && a.raw === b.raw; }

function clearDeadLinks(file) {
    const prefix = `${path.basename(file)}.`;
    for (const name of fs.readdirSync(path.dirname(file))) {
        if (!name.startsWith(prefix)) continue;
        const match = /^(?:publish|reclaim)\.(\d+)\.([a-f0-9]{32})\.([a-f0-9-]{36})$/.exec(name.slice(prefix.length));
        if (!match || !Number.isSafeInteger(Number(match[1])) || Number(match[1]) <= 0) continue;
        const pid = Number(match[1]);
        if (isProcessAlive(pid)) {
            const live = readProcessStartIdentity(pid);
            if (!live || identityHash(live) === match[2]) continue;
        }
        const link = path.join(path.dirname(file), name);
        try {
            if (!regularFile(fs.lstatSync(link))) throw lockError('SIGNER_LOCK_UNSAFE', `Unsafe signer recovery link: ${link}`);
            // A unique claimant name is never reused, so a cleaner cannot delete
            // a successor's claim after reading the dead claimant's identity.
            fs.unlinkSync(link);
        } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
}

function reclaimDeadLock(file, snapshot, suffix) {
    const claim = `${file}.reclaim.${suffix}`;
    try { fs.linkSync(file, claim); }
    catch (error) { if (error.code === 'ENOENT') return; throw error; }
    try {
        const linked = readLock(claim);
        const current = readLock(file);
        // While this link exists, every other recuperator sees at least three
        // links and must back off. Keep it until after the old path is removed.
        if (linked.nlink !== 2 || current.nlink !== 2
            || !sameFile(linked, snapshot) || !sameFile(current, snapshot)
            || isSignerLockOwnerAlive(current.state)) return;
        fs.unlinkSync(file);
    } finally {
        try { fs.unlinkSync(claim); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
}

async function acquireSignerFileLock(file, { timeoutMs = 300_000, pollMs = 250 } = {}) {
    file = path.resolve(file);
    const processStartIdentity = readProcessStartIdentity(process.pid);
    if (!processStartIdentity) throw lockError('SIGNER_LOCK_IDENTITY_UNAVAILABLE', 'Signer process start identity unavailable');
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    const state = { version: 2, pid: process.pid, processStartIdentity, token: randomUUID(), createdAt: new Date().toISOString() };
    const suffix = `${process.pid}.${identityHash(processStartIdentity)}.${randomUUID()}`;
    const publication = `${file}.publish.${suffix}`;
    const raw = `${JSON.stringify(state)}\n`;
    let snapshot;
    const deadline = Date.now() + timeoutMs;
    let lastError;
    try {
        // Publish only complete metadata. A crash leaves a uniquely named link
        // whose dead creator can be identified without trusting an age limit.
        fs.writeFileSync(publication, raw, { flag: 'wx', mode: 0o600 });
        snapshot = readLock(publication);
        do {
            clearDeadLinks(file);
            try {
                fs.linkSync(publication, file);
                let released = false;
                const lock = {
                    path: file, lockPath: file, token: state.token, state,
                    assertOwned() {
                        if (released) throw lockError('SIGNER_LOCK_LOST', 'Signer lock already released');
                        let current;
                        try { current = readLock(file); } catch {
                            throw lockError('SIGNER_LOCK_LOST', 'Signer lock ownership lost');
                        }
                        if (!sameFile(current, snapshot)) throw lockError('SIGNER_LOCK_LOST', 'Signer lock ownership lost');
                    },
                    run(fn) { lock.assertOwned(); return context.run(lock, fn); },
                    release() {
                        if (released) return;
                        lock.assertOwned();
                        fs.unlinkSync(file);
                        released = true;
                    },
                };
                return lock;
            } catch (error) { if (error.code !== 'EEXIST') throw error; }
            try {
                const existing = readLock(file);
                if (!isSignerLockOwnerAlive(existing.state)) reclaimDeadLock(file, existing, suffix);
            } catch (error) {
                if (!['ENOENT', 'SIGNER_LOCK_BUSY', 'SIGNER_LOCK_UNSAFE'].includes(error.code)) throw error;
                lastError = error;
            }
            if (Date.now() >= deadline) break;
            await new Promise(resolve => setTimeout(resolve, Math.min(pollMs, deadline - Date.now())));
        } while (Date.now() < deadline);
        throw lockError('SIGNER_LOCK_TIMEOUT', `Signer lock busy; no concurrent transaction signed${lastError ? ` (${lastError.message})` : ''}`);
    } finally {
        try { fs.unlinkSync(publication); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
}

function assertSignerFileLock(file) {
    const lock = context.getStore();
    if (!lock || (file && lock.path !== path.resolve(file))) {
        throw lockError('SIGNER_LOCK_LOST', 'No signer lock for this asynchronous operation');
    }
    lock.assertOwned();
}

module.exports = { acquireSignerFileLock, assertSignerFileLock, isSignerLockOwnerAlive, readProcessStartIdentity };
