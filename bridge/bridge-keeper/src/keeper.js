#!/usr/bin/env node
const { durableWriteFileSync, durableUnlinkSync } = require('./durable-file');
// SPDX-License-Identifier: MIT

/**
 * Liquid Hub — Bridge Keeper Bot (Phase 2)
 *
 * Triggers bridgeToStakers() on Liquid Hub Treasury contracts when:
 *   - Phase 2 is active (bridgeEnabled + bridgeBountyEnabled)
 *   - The cooldown since the last paid bounty has elapsed
 *   - The Treasury holds enough USDC to satisfy the minRatio safeguard
 *   - The Stargate cross-chain fee is below the configured cap, using a live native/USD oracle
 *
 * Earns the on-chain BridgeBountyPaid bounty on every successful paid bridge.
 * The same keeper serves pool and frontend swap treasuries.
 *
 * Usage:
 *   1. cp config/.env.example config/.env
 *   2. fill in PRIVATE_KEY, RPC URLs, and TREASURIES
 *   3. node src/keeper.js
 *
 * Run under PM2/systemd. The keeper continuously polls every configured
 * Treasury using CHECK_INTERVAL_MIN until it receives SIGTERM/SIGINT.
 */

const { acquireSignerFileLock, assertSignerFileLock, isSignerLockOwnerAlive } = require('./utils/signer-file-lock');
const fsSync = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const fs = require('fs/promises');
require('dotenv').config({ path: path.join(__dirname, '..', 'config', '.env') });

const { ethers } = require('ethers');

// Only a locally corroborated receipt can classify a transaction as mined.
// RPC-controlled error text must never authorize removal of the recovery journal.
class ConfirmedTransactionRevert extends Error {}


// ===== ABI =====
const TREASURY_ABI = [
    'function usdc() view returns (address)',
    'function adminWithdrawEnabled() view returns (bool)',
    'function bridgeEnabled() view returns (bool)',
    'function bridgeDestinationEid() view returns (uint32)',
    'function bridgeDestinationAddress() view returns (address)',
    'function stakingRewardsAddress() view returns (address)',
    'function bridgeBountyEnabled() view returns (bool)',
    'function bridgeBountyAmount() view returns (uint256)',
    'function bridgeBountyCooldown() view returns (uint64)',
    'function lastBridgeBountyAt() view returns (uint64)',
    'function bridgeBountyMinRatio() view returns (uint16)',
    'function bridgeableUsdc() view returns (uint256)',
    'function estimateBridgeFee(uint256 amount) view returns (uint256 nativeFee, uint256 amountReceived)',
    'function bridgeToStakers(uint256 amount) payable',
    'function distributeToStakers(uint256 amount)',
    'event BridgeBountyPaid(address indexed keeper, uint256 amount)',
    'event BridgedToStakers(uint256 amountSent, uint256 amountReceived, uint32 dstEid, bytes32 guid)',
];

const ERC20_ABI = [
    'function balanceOf(address) view returns (uint256)',
    'function decimals() view returns (uint8)',
    'function symbol() view returns (string)',
];

const ORACLE_ABI = [
    'function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)',
    'function decimals() view returns (uint8)',
];

// Native token decimals (always 18 on EVM mainstream)
const NATIVE_DECIMALS = 18;
const RPC_READ_TIMEOUT_MS = 20_000;
const TX_RECEIPT_TIMEOUT_MS = 120_000;
const SIGNER_LOCK_TIMEOUT_MS = 5 * 60_000;
const SIGNER_LOCK_POLL_MS = 250;
const ALERT_STATE_FILE = path.join(__dirname, '..', '.bridge-keeper-alerts.json');

function treasuryRpcUrls(t) {
    const configured = Array.isArray(t.rpcUrls) ? t.rpcUrls : [t.rpcUrl, t.rpcBackup1, t.rpcBackup2];
    return [...new Set(configured.filter((url) => typeof url === 'string' && url.trim()).map(url => url.trim()))];
}

function redactRpcErrorDetails(value) {
    return String(value ?? 'unknown error')
        .replace(/\b(?:https?|wss?):\\\/\\\/[^\s"'`<>]+/gi, '[REDACTED_RPC_URL]')
        .replace(/\b(?:https?|wss?):\/\/[^\s"'`<>]+/gi, '[REDACTED_RPC_URL]')
        .replace(/\b(Bearer)\s+[A-Za-z0-9._~+/=-]+/gi, '$1 [REDACTED_CREDENTIAL]')
        .replace(
            /((?:authorization|proxy-authorization|x-api-key|api[-_]?key|access[-_]?token)\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}]+)/gi,
            '$1[REDACTED_CREDENTIAL]'
        );
}

function safeErrorMessage(error) {
    return redactRpcErrorDetails(error?.message ?? error);
}

function sanitizeRpcError(error) {
    const sanitized = new Error(safeErrorMessage(error));
    if (error?.code !== undefined) sanitized.code = error.code;
    return sanitized;
}

function resolveStatePath(configured, fallback) {
    const value = String(configured || fallback);
    if (value === '~') return os.homedir();
    if (value.startsWith('~/')) return path.join(os.homedir(), value.slice(2));
    return path.resolve(value);
}

function readPositiveGweiEnv(name) {
    const raw = String(process.env[name] || '').trim();
    if (!/^\d+(?:\.\d+)?$/.test(raw)) throw new Error(`${name} must be a positive gwei value`);
    const value = ethers.parseUnits(raw, 'gwei');
    if (value <= 0n) throw new Error(`${name} must be greater than zero`);
    return value;
}

function treasuryLabel(t) {
    if (typeof t?.name === 'string' && t.name.trim()) return t.name.trim();
    if (typeof t?.address === 'string' && t.address.length >= 10) return `${t.address.slice(0, 8)}...`;
    return 'unnamed Treasury';
}

function isConfirmedEvmRevert(error) {
  if (error?.code !== 'CALL_EXCEPTION' || !['call', 'estimateGas'].includes(error.action)) return false;
  // ethers also wraps JSON-RPC infrastructure errors in CALL_EXCEPTION. Its
  // generated message (including "missing revert data") is not EVM evidence.
  const rpcError = error.info?.error;
  const rpcMessage = typeof rpcError?.message === 'string' ? rpcError.message : '';
  const explicitRevert = /^(?:execution reverted\b|VM Exception while processing transaction:\s*revert\b)/i.test(rpcMessage.trim());
  if (!explicitRevert && rpcError && (
    [-32700, -32600, -32601, -32602, -32603, -32002, -32005, 429, 500, 502, 503, 504].includes(Number(rpcError.code))
    || /\b(?:internal (?:server )?error|timeout|timed out|rate limit|too many requests|unavailable)\b/i.test(rpcMessage)
  )) return false;
  if (typeof error.data === 'string' && /^0x(?:[0-9a-f]{2})+$/i.test(error.data)) return true;
  // An empty Solidity revert remains usable when the RPC explicitly reports it.
  return (error.data == null || error.data === '0x')
    && Boolean(rpcError && (Number(rpcError.code) === 3 || explicitRevert));
}

function isProviderError(error) {
    if (error?.code === 'CALL_EXCEPTION') return !isConfirmedEvmRevert(error);
    const message = `${error?.shortMessage || ''} ${error?.message || ''}`.toLowerCase();
    const code = `${error?.code || ''}`.toUpperCase();
    if (message.includes('execution reverted') || message.includes('call_exception') || message.includes('insufficient funds')) {
        return false;
    }
    return ['SERVER_ERROR', 'TIMEOUT', 'NETWORK_ERROR', 'UNKNOWN_ERROR', 'BAD_DATA'].includes(code) ||
        /timeout|network|missing response|could not coalesce|econnreset|etimedout|enotfound|\b429\b|\b502\b|\b503\b|\b504\b|receipt pending/.test(message);
}

function isAlreadyKnownTx(error) {
    const message = `${error?.shortMessage || ''} ${error?.message || ''}`.toLowerCase();
    return /already known|already imported|known transaction/.test(message);
}

async function withTimeout(operation, timeoutMs, label) {
    let timer;
    try {
        return await Promise.race([
            Promise.resolve().then(operation),
            new Promise((_, reject) => {
                timer = setTimeout(() => {
                    const error = new Error(`${label} timeout after ${timeoutMs}ms`);
                    error.code = 'TIMEOUT';
                    reject(error);
                }, timeoutMs);
            }),
        ]);
    } finally {
        if (timer) clearTimeout(timer);
    }
}

class RpcPool {
    constructor(t, maxGasPriceWei = null, signerWallet = null) {
        const urls = treasuryRpcUrls(t);
        if (urls.length < 3) throw new Error(`Treasury ${t.name || t.address} requires three distinct RPC sources`);
        if (!Number.isSafeInteger(Number(t.chainId)) || Number(t.chainId) <= 0) {
            throw new Error(`Treasury ${t.name || t.address} has an invalid chainId`);
        }
        this.expectedChainId = BigInt(t.chainId);
        this.maxGasPriceWei = maxGasPriceWei ?? readPositiveGweiEnv('KEEPER_MAX_GAS_PRICE_GWEI');
        this.providers = urls.map((url) => ({
            url,
            provider: new ethers.JsonRpcProvider(url),
            chainVerified: false,
            chainMismatch: false,
        }));
        this.nextIndex = 0;
        this.signerWallet = signerWallet;
        this.signerAddress = null;
        this.stateDir = resolveStatePath(
            process.env.KEEPER_STATE_DIR,
            path.join(os.homedir(), '.liquidhub-keeper-state')
        );
        const oldDefaultStateDir = path.join(os.homedir(), '.liquidhub-bridge-keeper-state');
        this.legacyStateDirs = [process.env.BRIDGE_KEEPER_STATE_DIR, oldDefaultStateDir]
            .filter(Boolean)
            .map((value) => resolveStatePath(value))
            .filter((value, index, values) => value !== this.stateDir && values.indexOf(value) === index);
        this.pendingTxFile = null;
        this.processLockFile = null;
        this.legacyPendingTxFiles = [];
    }

    async _authenticateEntry(entry, force = false) {
        if (!entry) throw new Error('Bridge keeper RPC entry missing');
        if (entry.chainMismatch) {
            const error = new Error(`RPC previously excluded from chain ${this.expectedChainId}`);
            error.code = 'RPC_CHAIN_MISMATCH';
            throw error;
        }
        if (entry.chainVerified && !force) return;

        const rawChainId = await withTimeout(
            () => entry.provider.send('eth_chainId', []),
            RPC_READ_TIMEOUT_MS,
            'bridge keeper RPC chain authentication'
        );
        const actual = BigInt(rawChainId);
        if (actual !== this.expectedChainId) {
            entry.chainVerified = false;
            entry.chainMismatch = true;
            const error = new Error(`RPC chain mismatch: got ${actual}, expected ${this.expectedChainId}`);
            error.code = 'RPC_CHAIN_MISMATCH';
            throw error;
        }
        entry.chainMismatch = false;
        entry.chainVerified = true;
    }

    async _authenticatedProviderEntries(force = false) {
        const authenticated = [];
        for (const entry of this.providers) {
            if (entry.chainMismatch) continue;
            try {
                await this._authenticateEntry(entry, force);
                authenticated.push(entry);
            } catch (error) {
                if (error.code === 'RPC_CHAIN_MISMATCH') {
                    console.error(`Bridge keeper RPC excluded: ${safeErrorMessage(error)}`);
                } else {
                    console.warn(`Bridge keeper RPC unavailable during authentication: ${safeErrorMessage(error)}`);
                }
            }
        }
        if (authenticated.length === 0) {
            throw new Error(`No RPC authenticated on chain ${this.expectedChainId}`);
        }
        return authenticated;
    }

    async verifyChains() {
        let available = 0;
        for (const entry of this.providers) {
            try {
                await this._authenticateEntry(entry);
                available++;
            } catch (error) {
                if (error.code === 'RPC_CHAIN_MISMATCH') {
                    console.error(`Bridge keeper RPC excluded: ${safeErrorMessage(error)}`);
                    continue;
                }
                console.warn(`Bridge keeper RPC unavailable at startup: ${safeErrorMessage(error)}`);
            }
        }
        if (available === 0) throw new Error(`No RPC authenticated on chain ${this.expectedChainId}`);
    }

    _ensureSignerState(signerAddress) {
        const normalized = ethers.getAddress(signerAddress).toLowerCase();
        if (this.signerAddress && this.signerAddress !== normalized) {
            throw new Error(`Bridge keeper signer changed for chain ${this.expectedChainId}`);
        }
        this.signerAddress = normalized;
        const signerKey = `${this.expectedChainId}-${normalized}`;
        this.pendingTxFile = path.join(this.stateDir, `pending-${signerKey}.json`);
        this.processLockFile = path.join(this.stateDir, `signer-${signerKey}.lock`);
        this.legacyPendingTxFiles = [
            path.join(this.stateDir, `pending-bridge-${signerKey}.json`),
            ...this.legacyStateDirs.map((dir) => path.join(dir, `pending-bridge-${signerKey}.json`)),
        ].filter((value, index, values) => value !== this.pendingTxFile && values.indexOf(value) === index);
        fsSync.mkdirSync(this.stateDir, { recursive: true, mode: 0o700 });
        fsSync.chmodSync(this.stateDir, 0o700);
    }

    _migrateLegacyPendingTx() {
        this._assertSignerLock();
        const existingLegacyFiles = this.legacyPendingTxFiles.filter((file) => fsSync.existsSync(file));
        if (existingLegacyFiles.length === 0) return;
        if (fsSync.existsSync(this.pendingTxFile) || existingLegacyFiles.length > 1) {
            throw new Error('Multiple bridge/keeper transaction journals exist; reconcile them manually');
        }
        const legacyFile = existingLegacyFiles[0];
        const stat = fsSync.statSync(legacyFile);
        if (!stat.isFile()) throw new Error('Legacy bridge transaction journal is not a regular file');
        try {
            fsSync.renameSync(legacyFile, this.pendingTxFile);
        } catch (error) {
            if (error.code !== 'EXDEV') throw error;
            try {
                fsSync.copyFileSync(legacyFile, this.pendingTxFile, fsSync.constants.COPYFILE_EXCL);
            } catch (copyError) {
                throw new Error(`Unable to migrate legacy bridge journal: ${safeErrorMessage(copyError)}`);
            }
            fsSync.unlinkSync(legacyFile);
        }
        fsSync.chmodSync(this.pendingTxFile, 0o600);
    }

    _isLockOwnerAlive(lock) {
        return isSignerLockOwnerAlive(lock);
    }

    _assertSignerLock() {
        assertSignerFileLock(this.processLockFile);
    }

    async _withSignerLock(signerAddress, operation) {
        this._ensureSignerState(signerAddress);
        const lock = await acquireSignerFileLock(this.processLockFile, {
            timeoutMs: SIGNER_LOCK_TIMEOUT_MS, pollMs: SIGNER_LOCK_POLL_MS,
        });
        try {
            return await lock.run(async () => {
                this._migrateLegacyPendingTx();
                return await operation();
            });
        } finally {
            lock.release();
        }
    }

    _readPendingSignedTx() {
        if (!this.pendingTxFile || !fsSync.existsSync(this.pendingTxFile)) return null;
        let pending;
        try {
            pending = JSON.parse(fsSync.readFileSync(this.pendingTxFile, 'utf8'));
        } catch (error) {
            throw new Error(`Invalid persisted bridge transaction: ${safeErrorMessage(error)}`);
        }

        let parsed;
        try {
            parsed = ethers.Transaction.from(pending.rawTx);
        } catch (error) {
            throw new Error(`Invalid persisted bridge raw transaction: ${safeErrorMessage(error)}`);
        }
        if (pending?.schemaVersion === 1) {
            pending = {
                ...pending,
                schemaVersion: 2,
                poolName: pending.poolName || 'legacy bridge keeper',
                signer: parsed.from?.toLowerCase(),
                chainId: String(parsed.chainId),
                nonce: parsed.nonce,
            };
        }
        if (
            pending?.schemaVersion !== 2 ||
            typeof pending.rawTx !== 'string' ||
            typeof pending.txHash !== 'string' ||
            !Number.isSafeInteger(pending.nonce) ||
            pending.nonce < 0 ||
            String(pending.chainId) !== String(this.expectedChainId) ||
            String(pending.signer).toLowerCase() !== this.signerAddress ||
            String(parsed.chainId) !== String(this.expectedChainId) ||
            parsed.from?.toLowerCase() !== this.signerAddress ||
            parsed.nonce !== pending.nonce ||
            ethers.keccak256(pending.rawTx).toLowerCase() !== pending.txHash.toLowerCase()
        ) {
            throw new Error('Persisted bridge transaction identity/hash/raw payload mismatch');
        }
        return pending;
    }

    _persistSignedTx(rawTx, txHash, label, nonce) {
        this._assertSignerLock();
        if (!Number.isSafeInteger(nonce) || nonce < 0) {
            throw new Error(`${label}: signed bridge transaction nonce is missing or invalid`);
        }

        durableWriteFileSync(this.pendingTxFile, `${JSON.stringify({
            schemaVersion: 2,
            rawTx,
            txHash,
            label,
            poolName: 'bridge keeper',
            signer: this.signerAddress,
            chainId: String(this.expectedChainId),
            nonce,
            createdAt: new Date().toISOString(),
        }, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
    }

    _clearPersistedSignedTx(expectedHash) {
        this._assertSignerLock();
        if (!this.pendingTxFile || !fsSync.existsSync(this.pendingTxFile)) return;
        const pending = this._readPendingSignedTx();
        if (pending.txHash.toLowerCase() !== expectedHash.toLowerCase()) {
            throw new Error(`Refusing to clear unrelated persisted bridge transaction ${pending.txHash}`);
        }
        durableUnlinkSync(this.pendingTxFile);
    }

    async _allObservedNoncesAdvanced(nonce) {
        const entries = await this._authenticatedProviderEntries(true);
        const observed = [];
        for (const entry of entries) {
            const latest = await withTimeout(
                () => entry.provider.getTransactionCount(this.signerAddress, 'latest'),
                RPC_READ_TIMEOUT_MS,
                'bridge signer nonce reconciliation'
            ).catch(() => null);
            if (latest !== null) observed.push(latest);
        }
        const quorum = this._receiptQuorumSize();
        return observed.filter((latest) => latest > nonce).length >= quorum;
    }

    async _pendingSignerNonce() {
        const entries = await this._authenticatedProviderEntries(true);
        const observations = await Promise.all(entries.map(async (entry) => {
            const nonce = await withTimeout(
                () => entry.provider.getTransactionCount(this.signerAddress, 'pending'),
                RPC_READ_TIMEOUT_MS,
                'bridge signer pending nonce'
            ).catch(() => null);
            return Number.isSafeInteger(nonce) && nonce >= 0 ? nonce : null;
        }));
        const counts = new Map();
        for (const nonce of observations) if (nonce !== null) counts.set(nonce, (counts.get(nonce) || 0) + 1);
        const quorum = this._receiptQuorumSize();
        const agreed = [...counts].filter(([, count]) => count >= quorum);
        if (agreed.length === 1) return agreed[0][0];
        const error = new Error('Authenticated RPC pending nonce divergence or quorum unavailable');
        error.code = 'RPC_PENDING_NONCE_DIVERGENCE';
        throw error;
    }

    _assertFeeCap(transaction, label) {
        if (!this.maxGasPriceWei) throw new Error('KEEPER_MAX_GAS_PRICE_GWEI is not configured');
        const feeFields = [
            ['gasPrice', transaction.gasPrice],
            ['maxFeePerGas', transaction.maxFeePerGas],
            ['maxPriorityFeePerGas', transaction.maxPriorityFeePerGas],
        ];
        if (!feeFields.some(([, value]) => value !== null && value !== undefined)) {
            throw new Error(`${label}: populated transaction has no gas fee fields`);
        }
        for (const [field, value] of feeFields) {
            if (value !== null && value !== undefined && BigInt(value) > this.maxGasPriceWei) {
                throw new Error(
                    `${label}: provider proposed ${field}=${ethers.formatUnits(value, 'gwei')} gwei, ` +
                    `above KEEPER_MAX_GAS_PRICE_GWEI=${ethers.formatUnits(this.maxGasPriceWei, 'gwei')}`
                );
            }
        }
    }

    _isReplacementCandidate(error) {
        const message = `${error?.shortMessage || ''} ${error?.message || ''}`.toLowerCase();
        return message.includes('replacement transaction underpriced') ||
            message.includes('transaction underpriced') ||
            message.includes('fee too low') ||
            message.includes('receipt timeout after') ||
            message.includes('receipt pending after') ||
            message.includes('receipt unavailable');
    }

    async _replacePendingSignedTx(pending) {
        if (!this.signerWallet) throw new Error('PRIVATE_KEY is required to replace a pending bridge transaction');
        if (this.signerWallet.address.toLowerCase() !== this.signerAddress) {
            throw new Error(`${pending.label}: replacement signer does not match the persisted bridge signer`);
        }

        const previous = ethers.Transaction.from(pending.rawTx);
        const entries = await this._authenticatedProviderEntries(true);
        let feeData = null;
        for (const entry of entries) {
            feeData = await withTimeout(
                () => entry.provider.getFeeData(),
                RPC_READ_TIMEOUT_MS,
                'bridge replacement fee data'
            ).catch(() => null);
            if (feeData) break;
        }
        if (!feeData) throw new Error(`${pending.label}: no authenticated RPC returned replacement fee data`);

        const bump = (value) => value > 0n ? (value * 1125n) / 1000n + 1n : 0n;
        const request = {
            type: previous.type,
            chainId: previous.chainId,
            nonce: previous.nonce,
            gasLimit: previous.gasLimit,
            to: previous.to,
            value: previous.value,
            data: previous.data,
            accessList: previous.accessList,
        };
        if (previous.type === 2) {
            request.maxPriorityFeePerGas = [
                bump(previous.maxPriorityFeePerGas || 0n),
                feeData.maxPriorityFeePerGas || 0n,
            ].reduce((highest, value) => value > highest ? value : highest, 0n);
            request.maxFeePerGas = [
                bump(previous.maxFeePerGas || 0n),
                feeData.maxFeePerGas || 0n,
                request.maxPriorityFeePerGas,
            ].reduce((highest, value) => value > highest ? value : highest, 0n);
        } else {
            request.gasPrice = [
                bump(previous.gasPrice || 0n),
                feeData.gasPrice || 0n,
            ].reduce((highest, value) => value > highest ? value : highest, 0n);
        }
        this._assertFeeCap(request, `${pending.label} replacement`);

        this._assertSignerLock();
        const replacementRaw = await this.signerWallet.signTransaction(request);
        this._assertSignerLock();
        const replacementHash = ethers.keccak256(replacementRaw);
        this._persistSignedTx(replacementRaw, replacementHash, pending.label, pending.nonce);
        console.warn(`Replacing pending ${pending.label}: ${pending.txHash} -> ${replacementHash}`);
        const receipt = await this._broadcastSignedTransaction(
            replacementRaw,
            replacementHash,
            `${pending.label} replacement`
        );
        this._clearPersistedSignedTx(replacementHash);
        return { ...pending, status: 'confirmed', receipt, replacedTxHash: pending.txHash, txHash: replacementHash };
    }

    async execute(operation, timeoutMs = RPC_READ_TIMEOUT_MS) {
        let lastError;
        for (let offset = 0; offset < this.providers.length; offset++) {
            const index = (this.nextIndex + offset) % this.providers.length;
            const entry = this.providers[index];
            if (entry.chainMismatch) continue;
            const provider = entry.provider;
            try {
                await this._authenticateEntry(entry);
                const result = await withTimeout(() => operation(provider), timeoutMs, `RPC attempt ${offset + 1}`);
                this.nextIndex = index;
                return result;
            } catch (error) {
                lastError = error;
                if (error.code === 'RPC_CHAIN_MISMATCH') {
                    console.error(`Bridge keeper RPC excluded: ${safeErrorMessage(error)}`);
                    continue;
                }
                if (!isProviderError(error)) throw sanitizeRpcError(error);
                console.warn(`RPC attempt ${offset + 1}/${this.providers.length} failed: ${safeErrorMessage(error)}`);
            }
        }
        throw sanitizeRpcError(lastError);
    }

  _receiptQuorumSize() {
    // Silence is not confirmation. Only an explicitly single-provider keeper uses quorum one.
    return 2;
  }

  async _readReceiptQuorum(entries, txHash, label, wait = false) {
    const groups = new Map();
    const quorum = this._receiptQuorumSize();
    // Resolve as soon as a quorum confirms; an unavailable third RPC must not
    // delay confirmation. Every outstanding read retains its own timeout.
    return new Promise(resolve => {
      let remaining = entries.length;
      if (!remaining) return resolve(null);
      for (const entry of entries) {
        const read = wait
          ? () => waitForReceipt(entry.provider, txHash)
          : () => entry.provider.getTransactionReceipt(txHash);
        withTimeout(read, wait ? 125_000 : RPC_READ_TIMEOUT_MS, `${label} receipt quorum`)
          .then(receipt => {
            if (!receipt) return;
            const hash = String(receipt.hash || receipt.transactionHash || '').toLowerCase();
            const blockHash = String(receipt.blockHash || '').toLowerCase();
            const blockNumber = Number(receipt.blockNumber);
            if (hash !== String(txHash).toLowerCase() || !Number.isSafeInteger(blockNumber)) return;
            if (!/^0x[0-9a-f]{64}$/.test(blockHash) || blockNumber < 0 || ![0, 1].includes(receipt.status)) return;
            const key = `${hash}:${blockHash}:${blockNumber}:${receipt.status}`;
            const count = (groups.get(key) || 0) + 1;
            groups.set(key, count);
            if (count >= quorum) resolve(receipt);
          }).catch(() => {}).finally(() => { if (--remaining === 0) resolve(null); });
      }
    });
  }

    async _broadcastSignedTransaction(signedTx, txHash, label) {
        const entries = await this._authenticatedProviderEntries(true);
        const existing = await this._readReceiptQuorum(entries, txHash, label);
        if (existing) {
            if (existing.status !== 1) throw new ConfirmedTransactionRevert(`${label} failed on-chain: ${txHash}`);
            return existing;
        }
        // Identical signed bytes go to every authenticated endpoint. A lone receipt
        // must never suppress propagation to honest peers.
        let acknowledged = false;
        let replacementError;
        await Promise.all(entries.map(async entry => {
            try {
                await withTimeout(() => { this._assertSignerLock(); return entry.provider.broadcastTransaction(signedTx); },
                    RPC_READ_TIMEOUT_MS, `${label} broadcast`);
                acknowledged = true;
            } catch (error) {
                this._assertSignerLock();
                if (isAlreadyKnownTx(error)) acknowledged = true;
                else {
                    if (this._isReplacementCandidate(error)) replacementError = error;
                    console.warn(`${label}: broadcast not acknowledged`);
                }
            }
        }));
        if (!acknowledged && replacementError) throw replacementError;
        const receipt = await this._readReceiptQuorum(entries, txHash, label, true);
        if (receipt) {
            if (receipt.status !== 1) throw new ConfirmedTransactionRevert(`${label} failed on-chain: ${txHash}`);
            return receipt;
        }
        const error = new Error(`${label} receipt pending after signed broadcast (signed tx: ${txHash})`);
        error.code = 'TIMEOUT';
        throw error;
    }

    async _reconcilePendingSignedTxLocked() {
        const pending = this._readPendingSignedTx();
        if (!pending) return null;

        console.warn(`Recovering persisted bridge transaction ${pending.txHash}`);
        const entries = await this._authenticatedProviderEntries(true);
        const receipt = await this._readReceiptQuorum(entries, pending.txHash, 'persisted bridge receipt');
        if (receipt) {
            this._clearPersistedSignedTx(pending.txHash);
            return { status: receipt.status === 1 ? 'confirmed' : 'failed', receipt, ...pending };
        }

        if (await this._allObservedNoncesAdvanced(pending.nonce)) {
            this._clearPersistedSignedTx(pending.txHash);
            return { status: 'replaced', receipt: null, ...pending };
        }

        try {
            const receipt = await this._broadcastSignedTransaction(
                pending.rawTx,
                pending.txHash,
                pending.label || 'recovered bridge transaction'
            );
            this._clearPersistedSignedTx(pending.txHash);
            return { status: 'confirmed', receipt, ...pending };
        } catch (error) {
            if (error instanceof ConfirmedTransactionRevert) {
                this._clearPersistedSignedTx(pending.txHash);
                return { status: 'failed', receipt: null, error: safeErrorMessage(error), ...pending };
            }
            if (await this._allObservedNoncesAdvanced(pending.nonce)) {
                this._clearPersistedSignedTx(pending.txHash);
                return { status: 'replaced', receipt: null, ...pending };
            }
            if (this._isReplacementCandidate(error)) {
                return await this._replacePendingSignedTx(pending);
            }
            throw sanitizeRpcError(error);
        }
    }

    async sendSigned(signerAddress, prepare, label) {
        return await this._withSignerLock(signerAddress, async () => {
            const recovered = await this._reconcilePendingSignedTxLocked();
            if (recovered) {
                const error = new Error(
                    `${label}: signer state changed while waiting for the shared nonce lock; ` +
                    'the action will be recomputed from fresh on-chain state'
                );
                error.code = 'KEEPER_STATE_REFRESH_REQUIRED';
                error.recoveredTransaction = recovered;
                throw error;
            }

            const pendingNonce = await this._pendingSignerNonce();
            const preparedBundle = await this.execute(async (provider) => {
                const prepared = await prepare(provider);
                if (!prepared?.wallet || !prepared?.request) {
                    throw new Error(`${label}: prepare must return { wallet, request }`);
                }
                if (prepared.wallet.address.toLowerCase() !== this.signerAddress) {
                    throw new Error(`${label}: prepared wallet does not match the locked signer`);
                }
                if (
                    prepared.request.nonce !== null &&
                    prepared.request.nonce !== undefined &&
                    Number(prepared.request.nonce) !== pendingNonce
                ) {
                    throw new Error(`${label}: prepared nonce does not match authenticated pending nonce ${pendingNonce}`);
                }
                const populated = await prepared.wallet.populateTransaction({
                    ...prepared.request,
                    nonce: pendingNonce,
                });
                if (Number(populated.nonce) !== pendingNonce) {
                    throw new Error(`${label}: populated nonce changed unexpectedly`);
                }
                this._assertFeeCap(populated, label);
                return { provider, prepared, populated };
            }, TX_RECEIPT_TIMEOUT_MS);
            const { provider: preparationProvider, prepared, populated } = preparedBundle;
            const signedTx = await withTimeout(
                () => { this._assertSignerLock(); return prepared.wallet.signTransaction(populated); },
                TX_RECEIPT_TIMEOUT_MS,
                `${label} signing`
            );
            this._assertSignerLock();
            const parsed = ethers.Transaction.from(signedTx);
            const txHash = ethers.keccak256(signedTx);
            if (
                parsed.from?.toLowerCase() !== this.signerAddress ||
                String(parsed.chainId) !== String(this.expectedChainId)
            ) {
                throw new Error(`${label}: signed bridge transaction identity mismatch`);
            }
            if (parsed.nonce !== pendingNonce) throw new Error(`${label}: signed nonce mismatch`);
            this._assertFeeCap(parsed, label);
            this._persistSignedTx(signedTx, txHash, label, parsed.nonce);

            const startIndex = Math.max(
                0,
                this.providers.findIndex((entry) => entry.provider === preparationProvider)
            );
            try {
                const receipt = await this._broadcastSignedTransaction(
                    signedTx,
                    txHash,
                    label,
                    startIndex
                );
                this._clearPersistedSignedTx(txHash);
                return receipt;
            } catch (error) {
                if (error instanceof ConfirmedTransactionRevert) {
                    this._clearPersistedSignedTx(txHash);
                }
                throw error;
            }
        });
    }
}

// ===== Config =====
function loadConfig() {
    const cfg = {
        privateKey: process.env.PRIVATE_KEY,
        // Maximum acceptable Stargate fee (in USD, evaluated against a live native/USD oracle).
        // Defaults to $5 to leave a margin over the typical $1–3 fee.
        maxStargateFeeUsd: parseEnvNumber('MAX_STARGATE_FEE_USD', '5', 0),
        maxGasPriceWei: readPositiveGweiEnv('KEEPER_MAX_GAS_PRICE_GWEI'),
        nativeOracleMaxAgeSec: parseIntEnv('NATIVE_ORACLE_MAX_AGE_SEC', '7200', 60),
        alertAfterCycles: parseIntEnv('ALERT_AFTER_CYCLES', '3', 1),
        // Same-chain distribution has no protocol bounty. Community operators
        // can opt in, while the main bot remains its funded fallback.
        unpaidSameChainDistribution: process.env.ENABLE_UNPAID_SAME_CHAIN_DISTRIBUTION === 'true',
        sameChainMinUsdc: parseEnvNumber('BRIDGE_MIN_USDC', '50', 0),
        // Treasuries to monitor (read from TREASURIES env var, JSON-encoded).
        // Format: [{ "name": "LP Arbitrum", "address": "0x...", "usdc": "0x...", "chainId": 42161, "rpcUrls": ["https://..."] }, ...]
        treasuries: [],
    };

    if (process.env.ENABLE_UNPAID_SAME_CHAIN_DISTRIBUTION
        && !['true', 'false'].includes(process.env.ENABLE_UNPAID_SAME_CHAIN_DISTRIBUTION)) {
        throw new Error('ENABLE_UNPAID_SAME_CHAIN_DISTRIBUTION must be true or false');
    }

    if (!cfg.privateKey || !cfg.privateKey.startsWith('0x') || cfg.privateKey.length !== 66) {
        throw new Error('PRIVATE_KEY missing or malformed in config/.env (must be 0x + 64 hex chars)');
    }

    let raw = process.env.TREASURIES;
    if (!raw) throw new Error('TREASURIES missing in config/.env (JSON array required)');
    try {
        cfg.treasuries = JSON.parse(raw);
    } catch (e) {
        throw new Error('TREASURIES is not valid JSON: ' + e.message);
    }
    if (!Array.isArray(cfg.treasuries) || cfg.treasuries.length === 0) {
        throw new Error('TREASURIES must be a non-empty JSON array');
    }
    for (const t of cfg.treasuries) {
        if (!t.address || !t.usdc || !t.chainId || treasuryRpcUrls(t).length < 3) {
            throw new Error(`Treasury ${treasuryLabel(t)} is missing required address/usdc/chainId/RPC fields`);
        }
        ethers.getAddress(t.address);
        ethers.getAddress(t.usdc);
        if (!Number.isInteger(Number(t.chainId)) || Number(t.chainId) <= 0) {
            throw new Error(`Treasury ${t.name || t.address} has invalid chainId`);
        }
        // A same-chain distribution has no Stargate native fee; its Treasury
        // need not configure a native/USD oracle. The cross-chain path checks it.
        if ((t.tokens || []).length > 0) {
            throw new Error(
                `Treasury ${t.name || t.address}: token conversion is governance-only; ` +
                'remove tokens from TREASURIES and call swapToUSDC through the Safe/timelock first'
            );
        }
    }
    return cfg;
}

function authenticateTreasuryUsdc(configuredAddress, treasuryAddress) {
    const configuredUsdc = ethers.getAddress(configuredAddress);
    const treasuryUsdc = ethers.getAddress(treasuryAddress);
    if (treasuryUsdc !== configuredUsdc) {
        throw new Error(`Treasury.usdc()=${treasuryUsdc}, configured usdc=${configuredUsdc}`);
    }
    return treasuryUsdc;
}

function parseEnvNumber(name, fallback, min) {
    const value = Number(process.env[name] ?? fallback);
    if (!Number.isFinite(value) || value < min) {
        throw new Error(`${name} must be a finite number >= ${min}`);
    }
    return value;
}

function parseIntEnv(name, fallback, min, max = Number.MAX_SAFE_INTEGER) {
    const raw = String(process.env[name] ?? fallback);
    const value = Number(raw);
    if (!/^\d+$/.test(raw) || !Number.isSafeInteger(value) || value < min || value > max) {
        throw new Error(`${name} must be an integer >= ${min}`);
    }
    return value;
}

function nativeOracleAddress(t) {
    const raw = t.nativeOracle || process.env[`NATIVE_USD_ORACLE_${t.chainId}`];
    if (!raw) return null;
    return ethers.getAddress(raw);
}

async function readUsdOraclePrice(provider, oracleAddress, maxAgeSec, tag, label) {
    const oracle = new ethers.Contract(oracleAddress, ORACLE_ABI, provider);
    const [roundId, answer,, updatedAt, answeredInRound] = await oracle.latestRoundData();
    const feedDecimals = Number(await oracle.decimals());
    if (BigInt(answer) <= 0n || BigInt(answeredInRound) < BigInt(roundId)) {
        throw new Error(`${label} oracle bad round`);
    }
    const age = Math.floor(Date.now() / 1000) - Number(updatedAt);
    if (Number(updatedAt) <= 0 || age < 0 || age > maxAgeSec) {
        throw new Error(`${label} oracle stale (${age}s > ${maxAgeSec}s)`);
    }
    const price = Number(answer) / Math.pow(10, feedDecimals);
    if (!Number.isFinite(price) || price <= 0) {
        throw new Error(`${label} oracle invalid price`);
    }
    console.log(`${tag} ${label} oracle price=$${price.toFixed(4)} age=${age}s`);
    return price;
}

function fmt(amount, decimals = 6) {
    return (Number(amount) / Math.pow(10, decimals)).toFixed(decimals === 18 ? 4 : 2);
}

async function readBridgeableUsdc(treasury, state, tag) {
    try {
        return BigInt(await treasury.bridgeableUsdc());
    } catch (error) {
        throw new Error(`bridgeableUsdc() unavailable; refusing an approximate bridge amount: ${error.shortMessage || error.message}`);
    }
}

function decodeBridgeBounty(receipt, treasury, keeperAddress) {
    let bountyEarned = 0n;
    for (const log of receipt.logs) {
        try {
            const parsed = treasury.interface.parseLog(log);
            if (parsed?.name === 'BridgeBountyPaid' && parsed.args[0].toLowerCase() === keeperAddress.toLowerCase()) {
                bountyEarned = BigInt(parsed.args[1]);
            }
        } catch {}
    }
    return bountyEarned;
}

async function waitForReceipt(provider, txHash) {
    let timeoutId;
    try {
        const receipt = await Promise.race([
            provider.waitForTransaction(txHash, 1),
            new Promise((_, reject) => {
                timeoutId = setTimeout(() => reject(new Error(`receipt timeout after ${TX_RECEIPT_TIMEOUT_MS / 1000}s`)), TX_RECEIPT_TIMEOUT_MS);
            }),
        ]);
        if (!receipt) throw new Error(`receipt unavailable for ${txHash}`);
        return receipt;
    } finally {
        if (timeoutId) clearTimeout(timeoutId);
    }
}

class PersistentBridgeAlerts {
    constructor(threshold) {
        this.threshold = threshold;
        this.state = { version: 1, actions: {} };
    }

    async init() {
        try {
            const parsed = JSON.parse(await fs.readFile(ALERT_STATE_FILE, 'utf8'));
            if (parsed?.version === 1 && parsed.actions && typeof parsed.actions === 'object') this.state = parsed;
        } catch (error) {
            if (error.code !== 'ENOENT') console.log(`Bridge alert state ignored: ${safeErrorMessage(error)}`);
        }
    }

    async failure(t, message) {
        const key = `${t.chainId}:${t.address.toLowerCase()}`;
        const previous = this.state.actions[key] || { consecutiveFailures: 0, alerted: false };
        const next = {
            name: t.name || t.address,
            consecutiveFailures: previous.consecutiveFailures + 1,
            alerted: previous.alerted,
            lastError: safeErrorMessage(message).slice(0, 600),
            updatedAt: new Date().toISOString(),
        };
        this.state.actions[key] = next;
        await this.persist();
        if (next.consecutiveFailures >= this.threshold && !next.alerted) {
            console.log(
                `[${next.name}] Bridge keeper incident after ${next.consecutiveFailures} consecutive cycles: ` +
                next.lastError
            );
            next.alerted = true;
            await this.persist();
        }
    }

    async success(t) {
        const key = `${t.chainId}:${t.address.toLowerCase()}`;
        const previous = this.state.actions[key];
        if (!previous) return;
        if (previous.alerted) {
            console.log(
                `[${previous.name}] Bridge keeper recovered after ${previous.consecutiveFailures} failed cycles.`
            );
        }
        delete this.state.actions[key];
        await this.persist();
    }

    async persist() {
        const temp = `${ALERT_STATE_FILE}.tmp`;
        await fs.writeFile(temp, `${JSON.stringify(this.state, null, 2)}\n`, { mode: 0o600 });
        await fs.rename(temp, ALERT_STATE_FILE);
    }
}

// ===== Per-treasury logic =====
async function processTreasury(t, cfg) {
    const tag = `[${t.name || t.address.slice(0, 8) + '…'}]`;
    console.log(`\n${tag} chain=${t.chainId}`);

    const signerWallet = new ethers.Wallet(cfg.privateKey);
    const rpcPool = new RpcPool(t, cfg.maxGasPriceWei, signerWallet);
    await rpcPool.verifyChains();
    const walletAddress = signerWallet.address;
    const treasuryParser = new ethers.Contract(t.address, TREASURY_ABI);

    // 1. Read on-chain state
    let state;
    try {
        const values = await rpcPool.execute(async (provider) => {
            const treasury = new ethers.Contract(t.address, TREASURY_ABI, provider);
            const treasuryUsdc = authenticateTreasuryUsdc(t.usdc, await treasury.usdc());
            const usdc = new ethers.Contract(treasuryUsdc, ERC20_ABI, provider);
            return await Promise.all([
                treasury.adminWithdrawEnabled(),
                treasury.bridgeEnabled(),
                treasury.bridgeBountyEnabled(),
                treasury.bridgeBountyAmount(),
                treasury.bridgeBountyCooldown(),
                treasury.lastBridgeBountyAt(),
                treasury.bridgeBountyMinRatio(),
                treasury.bridgeDestinationEid(),
                treasury.bridgeDestinationAddress(),
                usdc.balanceOf(t.address),
                usdc.decimals(),
                treasury.stakingRewardsAddress(),
            ]);
        });
        const [
            adminEnabled, bridgeEnabled, bridgeBountyEnabled,
            bountyAmount, cooldown, lastAt, minRatio,
            destEid, destAddr, usdcBalance, usdcDecimals, stakingAddress,
        ] = values;
        state = {
            phase: adminEnabled ? 1 : 2,
            bridgeEnabled, bridgeBountyEnabled,
            bountyAmount: BigInt(bountyAmount), cooldown: Number(cooldown),
            lastAt: Number(lastAt), minRatio: Number(minRatio),
            destEid: Number(destEid), destAddr,
            stakingAddress,
            usdcBalance: BigInt(usdcBalance),
            usdcDecimals: Number(usdcDecimals),
        };
    } catch (e) {
        const message = safeErrorMessage(e);
        console.log(`${tag} ⚠  Read failed: ${message}`);
        return { error: 'read_failed', message };
    }

    try {
        state.bridgeable = await rpcPool.execute(async (provider) => {
            const treasury = new ethers.Contract(t.address, TREASURY_ABI, provider);
            return await readBridgeableUsdc(treasury, state, tag);
        });
    } catch (e) {
        const message = safeErrorMessage(e);
        console.log(`${tag} ⚠  ${message}`);
        return { error: 'bridgeable_read_failed', message };
    }
    console.log(`${tag} phase=${state.phase} bridgeEnabled=${state.bridgeEnabled} bountyEnabled=${state.bridgeBountyEnabled}`);
    console.log(`${tag} usdcBalance=${fmt(state.usdcBalance, state.usdcDecimals)} bridgeable=${fmt(state.bridgeable, state.usdcDecimals)} bounty=${fmt(state.bountyAmount, state.usdcDecimals)} cooldown=${state.cooldown}s minRatio=${state.minRatio}×`);

    // 2. Eligibility checks (mirror the on-chain anti-drain logic)
    if (state.phase !== 2) {
        console.log(`${tag} ⏭  Treasury still in Phase 1, no bridge yet`);
        return { skipped: 'phase_1' };
    }
    if (!state.bridgeEnabled) {
        if (!cfg.unpaidSameChainDistribution) return { skipped: 'unpaid_same_chain_not_enabled' };
        if (!state.stakingAddress || state.stakingAddress === ethers.ZeroAddress) return { skipped: 'no_staking_destination' };
        const minimum = ethers.parseUnits(String(cfg.sameChainMinUsdc), state.usdcDecimals);
        if (state.bridgeable < minimum) return { skipped: 'insufficient_balance' };
        const receipt = await rpcPool.sendSigned(walletAddress, async provider => {
            const wallet = new ethers.Wallet(cfg.privateKey, provider);
            const treasury = new ethers.Contract(t.address, TREASURY_ABI, wallet);
            return { wallet, request: await treasury.distributeToStakers.populateTransaction(state.bridgeable) };
        }, `${tag} distributeToStakers`);
        if (receipt.status !== 1) return { error: 'tx_reverted', message: 'same-chain distribution reverted' };
        return { success: true, bounty: 0n };
    }
    if (!state.bridgeBountyEnabled) {
        console.log(`${tag} ⏭  bridgeBountyEnabled is false (call still possible but no bounty)`);
        return { skipped: 'bounty_disabled' };
    }
    const now = Math.floor(Date.now() / 1000);
    const nextPaidAt = state.lastAt + state.cooldown;
    if (now < nextPaidAt) {
        const waitS = nextPaidAt - now;
        console.log(`${tag} ⏭  Cooldown active, ${Math.floor(waitS / 60)}m ${waitS % 60}s left`);
        return { skipped: 'cooldown' };
    }
    const minBridgeAmount = state.minRatio > 0
        ? state.bountyAmount * BigInt(state.minRatio)
        : 1n;
    if (state.usdcBalance < minBridgeAmount) {
        console.log(`${tag} ⏭  USDC balance ${fmt(state.usdcBalance, state.usdcDecimals)} < min ${fmt(minBridgeAmount, state.usdcDecimals)} required for bounty`);
        return { skipped: 'insufficient_balance' };
    }
    if (!state.destAddr || state.destAddr === ethers.ZeroAddress) {
        console.log(`${tag} ⏭  No bridge destination configured`);
        return { skipped: 'no_destination' };
    }

    async function estimateFee(bridgeAmount) {
        const [nativeFee, amountReceived] = await rpcPool.execute(async (provider) => {
            const treasury = new ethers.Contract(t.address, TREASURY_ABI, provider);
            return await treasury.estimateBridgeFee(bridgeAmount);
        });
        const fee = { native: BigInt(nativeFee), recv: BigInt(amountReceived) };
        let feeUsd = 0;
        if (cfg.maxStargateFeeUsd > 0) {
            const oracleAddress = nativeOracleAddress(t);
            if (!oracleAddress) throw new Error('Native/USD oracle required for cross-chain bridge fee');
            const nativeUsd = await rpcPool.execute((provider) =>
                readUsdOraclePrice(provider, oracleAddress, cfg.nativeOracleMaxAgeSec, tag, 'native/USD')
            );
            feeUsd = (Number(fee.native) / Math.pow(10, NATIVE_DECIMALS)) * nativeUsd;
        }
        return { fee, feeUsd };
    }

    async function ensureFeeAffordable(bridgeAmount) {
        let estimate;
        try {
            estimate = await estimateFee(bridgeAmount);
        } catch (e) {
            const message = safeErrorMessage(e);
            console.log(`${tag} ⚠  estimateBridgeFee failed: ${message}`);
            return { error: 'estimate_failed', message };
        }
        const feeUsdLabel = cfg.maxStargateFeeUsd > 0 ? `≈$${estimate.feeUsd.toFixed(2)}` : 'USD cap disabled';
        console.log(`${tag} bridgeAmount=${fmt(bridgeAmount, state.usdcDecimals)} stargateFee=${fmt(estimate.fee.native, NATIVE_DECIMALS)} (${feeUsdLabel})`);
        if (cfg.maxStargateFeeUsd > 0 && estimate.feeUsd > cfg.maxStargateFeeUsd) {
            console.log(`${tag} ⏭  Stargate fee $${estimate.feeUsd.toFixed(2)} > cap $${cfg.maxStargateFeeUsd}, skipping`);
            return { skipped: 'fee_too_high' };
        }
        const walletBalance = await rpcPool.execute((provider) => provider.getBalance(walletAddress));
        if (walletBalance < estimate.fee.native * 2n) {
            console.log(`${tag} ⚠  Wallet ${fmt(walletBalance, NATIVE_DECIMALS)} native, need at least 2× fee ${fmt(estimate.fee.native * 2n, NATIVE_DECIMALS)}`);
            return { error: 'low_native_balance', message: 'keeper native balance below 2x estimated bridge fee' };
        }
        return { estimate };
    }

    async function finalizeReceipt(receipt) {
        if (receipt.status !== 1) {
            console.log(`${tag} ❌  Bridge tx reverted`);
            return { error: 'tx_reverted', message: `bridge transaction reverted: ${receipt.hash}` };
        }
        const bountyEarned = decodeBridgeBounty(receipt, treasuryParser, walletAddress);
        let guid = null;
        for (const log of receipt.logs || []) {
            if (String(log.address).toLowerCase() !== t.address.toLowerCase()) continue;
            try {
                const event = treasuryParser.parseLog(log);
                if (event?.name === 'BridgedToStakers') guid = String(event.args.guid);
            } catch { /* Another Treasury event. */ }
        }
        if (!guid) throw new Error('Source receipt has no BridgedToStakers GUID; investigate before marking the source transfer');
        if (bountyEarned > 0n) {
            console.log(`${tag} Source confirmed, destination delivery pending: ${guid}; bounty ${fmt(bountyEarned, state.usdcDecimals)} USDC (block ${receipt.blockNumber})`);
            return { success: true, sourceConfirmed: true, destinationConfirmed: false, guid, bounty: bountyEarned };
        }
        console.log(`${tag} Source confirmed, destination delivery pending: ${guid}; no bounty paid. Block ${receipt.blockNumber}`);
        return { success: true, sourceConfirmed: true, destinationConfirmed: false, guid, bounty: 0n };
    }

    if (state.bridgeable >= minBridgeAmount) {
        const checked = await ensureFeeAffordable(state.bridgeable);
        if (checked.error || checked.skipped) return checked;
        console.log(`${tag} 🚀  Sending bridgeToStakers(${fmt(state.bridgeable, state.usdcDecimals)}) value=${fmt(checked.estimate.fee.native, NATIVE_DECIMALS)}`);
        try {
            const receipt = await rpcPool.sendSigned(walletAddress, async (provider) => {
                const wallet = new ethers.Wallet(cfg.privateKey, provider);
                const treasury = new ethers.Contract(t.address, TREASURY_ABI, wallet);
                return {
                    wallet,
                    request: await treasury.bridgeToStakers.populateTransaction(state.bridgeable, { value: checked.estimate.fee.native }),
                };
            }, `${tag} bridgeToStakers`);
            console.log(`${tag} txHash=${receipt.hash}`);
            return await finalizeReceipt(receipt);
        } catch (e) {
            const message = safeErrorMessage(e.shortMessage || e);
            console.log(`${tag} ❌  Bridge tx failed: ${message}`);
            return { error: 'tx_failed', message };
        }
    }

    console.log(`${tag} USDC bridgeable ${fmt(state.bridgeable, state.usdcDecimals)} < min ${fmt(minBridgeAmount, state.usdcDecimals)} required for bounty`);
    console.log(`${tag} ⏭  Non-USDC conversion is governance-only; the keeper will retry after swapToUSDC is executed`);
    return { skipped: 'insufficient_balance' };
}

// ===== One polling pass over all treasuries =====
async function trackBridgeAlert(alerts, method, ...args) {
    try {
        await alerts[method](...args);
    } catch (error) {
        console.log(`Bridge alert state error: ${safeErrorMessage(error)}`);
    }
}

async function runOnce(cfg, alerts) {
    const t0 = Date.now();
    let earned = 0;
    let processed = 0;
    let skipped = 0;
    let errors = 0;
    let totalBounty = 0n;

    for (const t of cfg.treasuries) {
        try {
            const r = await processTreasury(t, cfg);
            processed += 1;
            if (r.success) {
                earned += 1;
                totalBounty += r.bounty || 0n;
                await trackBridgeAlert(alerts, 'success', t);
            } else if (r.skipped) {
                skipped += 1;
                await trackBridgeAlert(alerts, 'success', t);
            } else if (r.error) {
                errors += 1;
                await trackBridgeAlert(alerts, 'failure', t, r.message || r.error);
            }
        } catch (e) {
            const message = safeErrorMessage(e);
            console.error(`[${treasuryLabel(t)}] crash:`, message);
            errors += 1;
            await trackBridgeAlert(alerts, 'failure', t, message);
        }
    }

    const dt = ((Date.now() - t0) / 1000).toFixed(1);
    console.log(`\n=== Cycle summary (${dt}s) ===`);
    console.log(`Processed: ${processed} | Bridges sent: ${earned} | Skipped: ${skipped} | Errors: ${errors}`);
    if (totalBounty > 0n) {
        console.log(`Total bounty earned this cycle: ${fmt(totalBounty)} USDC`);
    }
}

// ===== Main loop =====
// Long-running process. Polls all configured treasuries on CHECK_INTERVAL_MIN
// (default 15 min). Stop the process to halt the loop (SIGTERM/SIGINT).
async function main() {
    let cfg;
    try {
        cfg = loadConfig();
    } catch (e) {
        console.error('Configuration error:', safeErrorMessage(e));
        process.exit(1);
    }

    const intervalMin = parseIntEnv('CHECK_INTERVAL_MIN', '15', 1, 1440);
    const intervalMs = Math.max(60_000, intervalMin * 60_000);

    console.log(`Liquid Hub Bridge Keeper — ${new Date().toISOString()}`);
    console.log(`Wallet: ${new ethers.Wallet(cfg.privateKey).address}`);
    console.log(`${cfg.treasuries.length} treasury contract(s) to scan`);
    console.log(`Maximum gas price: ${ethers.formatUnits(cfg.maxGasPriceWei, 'gwei')} gwei`);
    console.log(`Polling interval: ${intervalMin} min`);

    const alerts = new PersistentBridgeAlerts(cfg.alertAfterCycles);
    await alerts.init();

    let shuttingDown = false;
    const onShutdown = (signal) => {
        if (shuttingDown) return;
        shuttingDown = true;
        console.log(`\nReceived ${signal} — exiting cleanly`);
        process.exit(0);
    };
    process.on('SIGTERM', () => onShutdown('SIGTERM'));
    process.on('SIGINT', () => onShutdown('SIGINT'));

    while (!shuttingDown) {
        try {
            await runOnce(cfg, alerts);
        } catch (e) {
            console.error('Cycle crashed:', safeErrorMessage(e));
        }
        if (shuttingDown) break;
        await new Promise(r => setTimeout(r, intervalMs));
    }
}

if (require.main === module) {
    main().catch((error) => {
        console.error('Bridge keeper fatal error:', safeErrorMessage(error));
        process.exit(1);
    });
}

module.exports = {
    RpcPool,
    authenticateTreasuryUsdc,
    isAlreadyKnownTx,
    isProviderError,
};
