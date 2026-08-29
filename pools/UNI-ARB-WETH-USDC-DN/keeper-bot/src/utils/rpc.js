// SPDX-License-Identifier: MIT

const { ethers } = require('ethers');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const RPC_READ_TIMEOUT_MS = 20_000;
const RPC_TX_TIMEOUT_MS = 90_000;
const SIGNER_LOCK_TIMEOUT_MS = 5 * 60_000;
const SIGNER_LOCK_POLL_MS = 250;
const HF_REPAIR_DATA = '0x30cbb735'; // repairHealthFactor()

function readPositiveGweiEnv(name) {
  const raw = String(process.env[name] || '').trim();
  if (!/^\d+(?:\.\d+)?$/.test(raw)) throw new Error(`${name} must be a positive gwei value`);
  const value = ethers.parseUnits(raw, 'gwei');
  if (value <= 0n) throw new Error(`${name} must be greater than zero`);
  return value;
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

function resolveStatePath(configured, fallback) {
  const value = String(configured || fallback);
  if (value === '~') return os.homedir();
  if (value.startsWith('~/')) return path.join(os.homedir(), value.slice(2));
  return path.resolve(value);
}

function sanitizeRpcError(error) {
  if (!error || typeof error !== 'object') return new Error(safeErrorMessage(error));
  const seen = new WeakSet();
  const scrub = (value, depth = 0) => {
    if (!value || typeof value !== 'object' || seen.has(value) || depth > 4) return;
    seen.add(value);
    const keys = new Set([...Object.keys(value).slice(0, 100), 'message', 'stack', 'shortMessage']);
    for (const key of keys) {
      let current;
      try { current = value[key]; } catch { continue; }
      if (typeof current === 'string') {
        try { value[key] = redactRpcErrorDetails(current); } catch {}
      } else if (current && typeof current === 'object') {
        scrub(current, depth + 1);
      }
    }
  };
  const cleanMessage = safeErrorMessage(error);
  scrub(error);
  if (error.message !== cleanMessage) {
    const replacement = new Error(cleanMessage);
    if (error.code !== undefined) replacement.code = error.code;
    return replacement;
  }
  return error;
}

class RPCPool {
  constructor() {
    const urls = [
      process.env.RPC_URL,
      process.env.RPC_BACKUP_1,
      process.env.RPC_BACKUP_2
    ].filter(Boolean);

    if (urls.length === 0) throw new Error('No RPC URL configured');

    this.providers = urls.map(url => ({
      url,
      provider: new ethers.JsonRpcProvider(url),
      healthy: true,
      errorCount: 0,
      chainVerified: false,
      chainMismatch: false
    }));
    this.currentIndex = 0;
    this.poolName = String(process.env.POOL_NAME || path.basename(process.cwd()));
    this.signerWallet = process.env.KEEPER_PRIVATE_KEY
      ? new ethers.Wallet(process.env.KEEPER_PRIVATE_KEY)
      : null;
    this.signerAddress = this.signerWallet?.address.toLowerCase() || null;
    this.maxGasPriceWei = readPositiveGweiEnv('KEEPER_MAX_GAS_PRICE_GWEI');
    const configuredHfRepairTarget = String(process.env.AAVE_HEDGE_MANAGER_ADDRESS || '').trim();
    if (configuredHfRepairTarget && !ethers.isAddress(configuredHfRepairTarget)) {
      throw new Error('AAVE_HEDGE_MANAGER_ADDRESS must be a valid address');
    }
    this.hfRepairTargetAddress = configuredHfRepairTarget
      ? configuredHfRepairTarget.toLowerCase()
      : null;
    const configuredChainId = process.env.CHAINID || process.env.CHAIN_ID;
    if (!configuredChainId || !/^\d+$/.test(configuredChainId) || BigInt(configuredChainId) === 0n) {
      throw new Error('CHAINID/CHAIN_ID must be a positive integer');
    }
    this.chainId = String(BigInt(configuredChainId));
    this.stateDir = resolveStatePath(
      process.env.KEEPER_STATE_DIR,
      path.join(os.homedir(), '.liquidhub-keeper-state')
    );
    // Legacy migration source only. New journals always use the canonical
    // chain+signer filename so every keeper family coordinates the same nonce.
    this.configuredPendingTxFile = process.env.KEEPER_PENDING_TX_FILE
      ? resolveStatePath(process.env.KEEPER_PENDING_TX_FILE)
      : null;
    this.pendingTxFile = null;
    this.processLockFile = null;
  }

  async _ensureSignerState(provider) {
    if (!this.signerAddress) {
      throw new Error('KEEPER_PRIVATE_KEY is required for signed keeper transactions');
    }
    const providerEntry = this.providers.find(entry => entry.provider === provider);
    if (!providerEntry?.chainVerified) await this._verifyProviderChain(providerEntry);
    if (!this.pendingTxFile) {
      const signerKey = `${this.chainId}-${this.signerAddress}`;
      this.pendingTxFile = path.join(this.stateDir, `pending-${signerKey}.json`);
      this.processLockFile = path.join(this.stateDir, `signer-${signerKey}.lock`);
      fs.mkdirSync(path.dirname(this.pendingTxFile), { recursive: true, mode: 0o700 });
      fs.mkdirSync(path.dirname(this.processLockFile), { recursive: true, mode: 0o700 });
    }
  }

  _migrateLegacyPendingTx() {
    const legacyFile = this.configuredPendingTxFile;
    if (!legacyFile || legacyFile === this.pendingTxFile || !fs.existsSync(legacyFile)) return;
    if (fs.existsSync(this.pendingTxFile)) {
      throw new Error('Both canonical and legacy keeper transaction journals exist; reconcile them manually');
    }
    const stat = fs.statSync(legacyFile);
    if (!stat.isFile()) throw new Error('Legacy keeper transaction journal is not a regular file');
    try {
      fs.renameSync(legacyFile, this.pendingTxFile);
    } catch (error) {
      if (error.code !== 'EXDEV') throw error;
      try {
        fs.copyFileSync(legacyFile, this.pendingTxFile, fs.constants.COPYFILE_EXCL);
      } catch (copyError) {
        throw new Error(`Unable to migrate legacy keeper transaction journal: ${safeErrorMessage(copyError)}`);
      }
      fs.unlinkSync(legacyFile);
    }
    fs.chmodSync(this.pendingTxFile, 0o600);
  }

  async _verifyProviderChain(entry) {
    if (!entry) throw new Error('Keeper RPC entry missing');
    let rawChainId;
    try {
      rawChainId = await this.withTimeout(
        () => entry.provider.send('eth_chainId', []),
        RPC_READ_TIMEOUT_MS,
        'keeper RPC chain authentication'
      );
    } catch (error) {
      throw sanitizeRpcError(error);
    }
    const actual = String(BigInt(rawChainId));
    if (actual !== this.chainId) {
      entry.healthy = false;
      entry.chainVerified = false;
      entry.chainMismatch = true;
      const error = new Error(`RPC chain mismatch: got ${actual}, expected ${this.chainId}`);
      error.code = 'RPC_CHAIN_MISMATCH';
      throw error;
    }
    entry.chainMismatch = false;
    entry.chainVerified = true;
    return actual;
  }

  async verifyProviderChains() {
    let authenticated = 0;
    for (const entry of this.providers) {
      try {
        await this._verifyProviderChain(entry);
        entry.healthy = true;
        authenticated++;
      } catch (error) {
        if (error.code === 'RPC_CHAIN_MISMATCH') {
          console.error(`Keeper RPC excluded: ${safeErrorMessage(error)}`);
          continue;
        }
        entry.healthy = false;
        console.warn(`Keeper RPC unavailable at startup: ${safeErrorMessage(error)}`);
      }
    }
    if (authenticated === 0) {
      throw new Error(`No RPC authenticated on expected chain ${this.chainId}`);
    }
  }

  async _authenticatedProviderEntries() {
    const authenticated = [];
    for (const entry of this.providers) {
      if (entry.chainMismatch) continue;
      if (!entry.chainVerified) {
        try {
          await this._verifyProviderChain(entry);
          entry.healthy = true;
        } catch (error) {
          entry.healthy = false;
          if (error.code === 'RPC_CHAIN_MISMATCH') {
            console.error(`Keeper RPC excluded: ${safeErrorMessage(error)}`);
          } else {
            console.warn(`Keeper RPC unavailable during signed reconciliation: ${safeErrorMessage(error)}`);
          }
          continue;
        }
      }
      if (entry.chainVerified && !entry.chainMismatch) authenticated.push(entry);
    }
    if (authenticated.length === 0) {
      throw new Error(`No RPC authenticated on expected chain ${this.chainId}`);
    }
    return authenticated;
  }

  _isLockOwnerAlive(lock) {
    if (!Number.isInteger(lock?.pid) || lock.pid <= 0) return false;
    try {
      process.kill(lock.pid, 0);
      return true;
    } catch (error) {
      return error.code === 'EPERM';
    }
  }

  async _withSignerLock(provider, fn) {
    await this._ensureSignerState(provider);
    const token = crypto.randomUUID();
    const deadline = Date.now() + SIGNER_LOCK_TIMEOUT_MS;
    while (Date.now() < deadline) {
      try {
        const fd = fs.openSync(this.processLockFile, 'wx', 0o600);
        fs.writeFileSync(fd, `${JSON.stringify({
          pid: process.pid,
          token,
          signer: this.signerAddress,
          chainId: this.chainId,
          acquiredAt: new Date().toISOString(),
        })}\n`);
        fs.closeSync(fd);
        try {
          this._migrateLegacyPendingTx();
          return await fn();
        } finally {
          try {
            const current = JSON.parse(fs.readFileSync(this.processLockFile, 'utf8'));
            if (current.token === token) fs.unlinkSync(this.processLockFile);
          } catch {
            // A dead-process recovery may already have removed the lock.
          }
        }
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
        let lock = null;
        try {
          lock = JSON.parse(fs.readFileSync(this.processLockFile, 'utf8'));
          if (!this._isLockOwnerAlive(lock)) {
            fs.rmSync(this.processLockFile, { force: true });
            continue;
          }
        } catch (probeError) {
          const ageMs = (() => {
            try {
              return Date.now() - fs.statSync(this.processLockFile).mtimeMs;
            } catch {
              return 0;
            }
          })();
          if (ageMs > 5_000) {
            fs.rmSync(this.processLockFile, { force: true });
            continue;
          }
        }
        await new Promise(resolve => setTimeout(resolve, SIGNER_LOCK_POLL_MS));
      }
    }
    throw new Error(
      `Keeper signer lock timeout for ${this.signerAddress} on chain ${this.chainId}`
    );
  }

  _readPendingSignedTx() {
    if (!this.pendingTxFile || !fs.existsSync(this.pendingTxFile)) return null;
    let parsed;
    try {
      parsed = JSON.parse(fs.readFileSync(this.pendingTxFile, 'utf8'));
    } catch (error) {
      throw new Error(`Invalid persisted keeper transaction: ${safeErrorMessage(error)}`);
    }
    let rawTransaction;
    try {
      rawTransaction = ethers.Transaction.from(parsed?.rawTx);
    } catch (error) {
      throw new Error(`Invalid persisted keeper raw transaction: ${safeErrorMessage(error)}`);
    }
    if (parsed?.schemaVersion === 1) {
      try {
        parsed = {
          ...parsed,
          schemaVersion: 2,
          poolName: parsed.poolName || 'legacy keeper',
          signer: rawTransaction.from?.toLowerCase(),
          chainId: String(rawTransaction.chainId),
          nonce: rawTransaction.nonce,
        };
      } catch (error) {
        throw new Error(`Invalid legacy persisted keeper transaction: ${safeErrorMessage(error)}`);
      }
    }
    if (
      parsed?.schemaVersion !== 2 ||
      typeof parsed.rawTx !== 'string' ||
      typeof parsed.txHash !== 'string' ||
      !Number.isSafeInteger(parsed.nonce) ||
      parsed.nonce < 0 ||
      String(parsed.chainId) !== String(this.chainId) ||
      String(parsed.signer).toLowerCase() !== this.signerAddress ||
      String(rawTransaction.chainId) !== String(this.chainId) ||
      rawTransaction.from?.toLowerCase() !== this.signerAddress ||
      rawTransaction.nonce !== parsed.nonce ||
      ethers.keccak256(parsed.rawTx).toLowerCase() !== parsed.txHash.toLowerCase()
    ) {
      throw new Error('Persisted keeper transaction identity/hash/raw payload mismatch');
    }
    if (parsed.feeCapExempt !== undefined && typeof parsed.feeCapExempt !== 'boolean') {
      throw new Error('Persisted keeper fee-cap exemption marker is invalid');
    }
    if (parsed.feeCapExempt === true) {
      const exemptTarget = String(parsed.feeCapExemptTarget || '').toLowerCase();
      if (
        !ethers.isAddress(exemptTarget) ||
        (this.hfRepairTargetAddress && exemptTarget !== this.hfRepairTargetAddress) ||
        rawTransaction.to?.toLowerCase() !== exemptTarget ||
        String(rawTransaction.data || '0x').toLowerCase() !== HF_REPAIR_DATA ||
        rawTransaction.value !== 0n
      ) {
        throw new Error('Persisted keeper fee-cap exemption is not bound to repairHealthFactor()');
      }
    }
    return parsed;
  }

  _persistSignedTx(rawTx, txHash, label, nonce, {
    feeCapExempt = false,
    feeCapExemptTarget = null,
  } = {}) {
    if (!this.pendingTxFile) return;
    if (!Number.isSafeInteger(nonce) || nonce < 0) {
      throw new Error(`${label}: signed transaction nonce is missing or invalid`);
    }
    fs.mkdirSync(path.dirname(this.pendingTxFile), { recursive: true, mode: 0o700 });
    const temp = `${this.pendingTxFile}.${process.pid}.tmp`;
    const journal = {
      schemaVersion: 2,
      rawTx,
      txHash,
      label,
      poolName: this.poolName,
      signer: this.signerAddress,
      chainId: this.chainId,
      nonce,
      createdAt: new Date().toISOString(),
    };
    if (feeCapExempt) {
      journal.feeCapExempt = true;
      journal.feeCapExemptTarget = String(feeCapExemptTarget || '').toLowerCase();
    }
    fs.writeFileSync(temp, `${JSON.stringify(journal, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
    fs.renameSync(temp, this.pendingTxFile);
  }

  _clearPersistedSignedTx(expectedHash) {
    if (!this.pendingTxFile || !fs.existsSync(this.pendingTxFile)) return;
    const pending = this._readPendingSignedTx();
    if (pending.txHash.toLowerCase() !== expectedHash.toLowerCase()) {
      throw new Error(`Refusing to clear unrelated persisted transaction ${pending.txHash}`);
    }
    fs.unlinkSync(this.pendingTxFile);
  }

  getProvider() {
    // Try current provider first
    if (this.providers[this.currentIndex].healthy) {
      return this.providers[this.currentIndex].provider;
    }
    // Find next healthy provider
    for (let i = 0; i < this.providers.length; i++) {
      const idx = (this.currentIndex + i + 1) % this.providers.length;
      if (this.providers[idx].healthy) {
        this.currentIndex = idx;
        return this.providers[idx].provider;
      }
    }
    // Reset all and return first
    this.providers.forEach(p => { p.healthy = !p.chainMismatch; p.errorCount = 0; });
    this.currentIndex = 0;
    const fallback = this.providers.find(p => !p.chainMismatch);
    return fallback?.provider || null;
  }

  markUnhealthy(provider, force = false) {
    const entry = this.providers.find(p => p.provider === provider);
    if (entry) {
      entry.errorCount++;
      if (force || entry.errorCount >= 3) {
        entry.healthy = false;
        this.currentIndex = (this.providers.indexOf(entry) + 1) % this.providers.length;
      }
    }
  }

  isProviderError(error) {
    const msg = `${error?.shortMessage || ''} ${error?.message || ''}`.toLowerCase();
    const code = `${error?.code || ''}`.toUpperCase();
    if (
      msg.includes('execution reverted') ||
      msg.includes('call_exception') ||
      msg.includes('insufficient funds') ||
      msg.includes('nonce too low') ||
      msg.includes('nonce has already been used')
    ) {
      return false;
    }
    return ['SERVER_ERROR', 'TIMEOUT', 'NETWORK_ERROR', 'UNKNOWN_ERROR', 'BAD_DATA'].includes(code) ||
      msg.includes('timeout') ||
      msg.includes('network') ||
      msg.includes('missing response') ||
      msg.includes('could not coalesce') ||
      msg.includes('econnreset') ||
      msg.includes('etimedout') ||
      msg.includes('enotfound') ||
      msg.includes('429') ||
      msg.includes('502') ||
      msg.includes('503') ||
      msg.includes('504') ||
      msg.includes('receipt pending after');
  }

  isAlreadyKnownTx(error) {
    const msg = `${error?.shortMessage || ''} ${error?.message || ''}`.toLowerCase();
    return msg.includes('already known') ||
      msg.includes('already imported') ||
      msg.includes('known transaction');
  }

  async withTimeout(fn, timeoutMs, label = 'RPC request') {
    let timeoutId;
    try {
      return await Promise.race([
        Promise.resolve().then(fn),
        new Promise((_, reject) => {
          timeoutId = setTimeout(() => {
            const error = new Error(`${label} timeout after ${timeoutMs}ms`);
            error.code = 'TIMEOUT';
            reject(error);
          }, timeoutMs);
        })
      ]);
    } finally {
      if (timeoutId) clearTimeout(timeoutId);
    }
  }

  async executeWithRetry(fn, maxRetries = 3, timeoutMs = RPC_READ_TIMEOUT_MS) {
    let lastError;
    const attempts = Math.max(maxRetries, this.providers.length);
    for (let attempt = 1; attempt <= attempts; attempt++) {
      const provider = this.getProvider();
      try {
        if (!provider) throw new Error('No keeper RPC available on the expected chain');
        const entry = this.providers.find(candidate => candidate.provider === provider);
        if (!entry?.chainVerified) await this._verifyProviderChain(entry);
        return await this.withTimeout(() => fn(provider), timeoutMs, `RPC attempt ${attempt}`);
      } catch (error) {
        lastError = error;
        if (error.code === 'RPC_CHAIN_MISMATCH') {
          console.error(`Keeper RPC excluded: ${safeErrorMessage(error)}`);
          continue;
        }
        if (!this.isProviderError(error)) throw sanitizeRpcError(error);
        this.markUnhealthy(provider, true);
        console.warn(`RPC attempt ${attempt}/${attempts} failed: ${safeErrorMessage(error)}`);
      }
    }
    throw sanitizeRpcError(lastError);
  }

  async _latestSignerNonce() {
    const entries = await this._authenticatedProviderEntries();
    const counts = new Map();
    for (const entry of entries) {
      const nonce = await this.withTimeout(
        () => entry.provider.getTransactionCount(this.signerAddress, 'latest'),
        RPC_READ_TIMEOUT_MS,
        'keeper signer nonce reconciliation'
      ).catch(() => null);
      if (nonce !== null) counts.set(nonce, (counts.get(nonce) || 0) + 1);
    }
    const expectedProviders = Array.isArray(this.providers)
      ? this.providers.filter((entry) => !entry.chainMismatch).length
      : entries.length;
    const quorum = expectedProviders === 1 ? 1 : 2;
    const confirmed = [...counts.entries()]
      .filter(([, count]) => count >= quorum)
      .map(([nonce]) => nonce);
    return confirmed.length > 0 ? Math.max(...confirmed) : null;
  }

  _assertFeeCap(transaction, label) {
    if (!this.maxGasPriceWei) throw new Error('KEEPER_MAX_GAS_PRICE_GWEI is not configured');
    for (const [field, value] of [
      ['gasPrice', transaction.gasPrice],
      ['maxFeePerGas', transaction.maxFeePerGas],
      ['maxPriorityFeePerGas', transaction.maxPriorityFeePerGas],
    ]) {
      if (value !== null && value !== undefined && BigInt(value) > this.maxGasPriceWei) {
        throw new Error(
          `${label}: provider proposed ${field}=${ethers.formatUnits(value, 'gwei')} gwei, ` +
          `above KEEPER_MAX_GAS_PRICE_GWEI=${ethers.formatUnits(this.maxGasPriceWei, 'gwei')}`
        );
      }
    }
  }

  _isConfiguredHfRepairTransaction(transaction) {
    return !!this.hfRepairTargetAddress &&
      String(transaction?.to || '').toLowerCase() === this.hfRepairTargetAddress &&
      String(transaction?.data || '0x').toLowerCase() === HF_REPAIR_DATA &&
      BigInt(transaction?.value || 0n) === 0n;
  }

  _applyFeeCapPolicy(transaction, label, bypassFeeCap) {
    if (!bypassFeeCap) {
      this._assertFeeCap(transaction, label);
      return false;
    }
    if (!this._isConfiguredHfRepairTransaction(transaction)) {
      throw new Error(`${label}: fee-cap exemption is restricted to configured repairHealthFactor()`);
    }
    console.warn(`${label}: critical HF_REPAIR bypasses KEEPER_MAX_GAS_PRICE_GWEI`);
    return true;
  }

  _isReplacementCandidate(error) {
    const message = `${error?.shortMessage || ''} ${error?.message || ''}`.toLowerCase();
    return message.includes('replacement transaction underpriced') ||
      message.includes('transaction underpriced') ||
      message.includes('fee too low') ||
      message.includes('receipt pending after') ||
      message.includes('receipt unavailable');
  }

  async _replacePendingSignedTx(pending, maxRetries) {
    if (!this.signerWallet) throw new Error('KEEPER_PRIVATE_KEY is required to replace a pending transaction');
    const previous = ethers.Transaction.from(pending.rawTx);
    const entries = await this._authenticatedProviderEntries();
    let feeData = null;
    for (const entry of entries) {
      feeData = await this.withTimeout(
        () => entry.provider.getFeeData(), RPC_READ_TIMEOUT_MS, 'keeper replacement fee data'
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
    const feeCapExempt = pending.feeCapExempt === true;
    if (feeCapExempt) {
      if (
        previous.to?.toLowerCase() !== String(pending.feeCapExemptTarget || '').toLowerCase() ||
        (this.hfRepairTargetAddress
          && previous.to?.toLowerCase() !== this.hfRepairTargetAddress) ||
        String(previous.data || '0x').toLowerCase() !== HF_REPAIR_DATA ||
        previous.value !== 0n
      ) {
        throw new Error(`${pending.label}: invalid persisted HF_REPAIR fee-cap exemption`);
      }
      console.warn(`${pending.label} replacement: critical HF_REPAIR bypasses the fee cap`);
    } else {
      this._assertFeeCap(request, `${pending.label} replacement`);
    }

    const replacementRaw = await this.signerWallet.signTransaction(request);
    const replacementHash = ethers.keccak256(replacementRaw);
    this._persistSignedTx(replacementRaw, replacementHash, pending.label, pending.nonce, {
      feeCapExempt,
      feeCapExemptTarget: pending.feeCapExemptTarget,
    });
    console.warn(`Replacing pending ${pending.label}: ${pending.txHash} -> ${replacementHash}`);
    const receipt = await this._broadcastSignedTransaction(
      replacementRaw, replacementHash, `${pending.label} replacement`, 0, maxRetries
    );
    this._clearPersistedSignedTx(replacementHash);
    return { ...pending, status: 'confirmed', receipt, replacedTxHash: pending.txHash, txHash: replacementHash };
  }

  async _reconcilePendingSignedTxLocked(maxRetries = 3) {
    const pending = this._readPendingSignedTx();
    if (!pending) return null;

    console.warn(
      `Recovering persisted ${pending.label || 'keeper transaction'} ` +
      `for ${pending.poolName || 'unknown pool'}: ${pending.txHash}`
    );

    const entries = await this._authenticatedProviderEntries();
    for (const entry of entries) {
      const receipt = await this.withTimeout(
        () => entry.provider.getTransactionReceipt(pending.txHash),
        RPC_READ_TIMEOUT_MS,
        'persisted keeper receipt lookup'
      ).catch(() => null);
      if (receipt) {
        this._clearPersistedSignedTx(pending.txHash);
        return {
          status: receipt.status === 1 ? 'confirmed' : 'failed',
          receipt,
          ...pending,
        };
      }
    }

    const latestNonceBefore = await this._latestSignerNonce();
    if (latestNonceBefore !== null && latestNonceBefore > pending.nonce) {
      this._clearPersistedSignedTx(pending.txHash);
      return { status: 'replaced', receipt: null, ...pending };
    }

    try {
      const receipt = await this._broadcastSignedTransaction(
        pending.rawTx,
        pending.txHash,
        pending.label || 'recovered transaction',
        0,
        maxRetries
      );
      this._clearPersistedSignedTx(pending.txHash);
      return { status: 'confirmed', receipt, ...pending };
    } catch (error) {
      if (String(error.message || '').includes('failed on-chain')) {
        this._clearPersistedSignedTx(pending.txHash);
        return { status: 'failed', receipt: null, error: safeErrorMessage(error), ...pending };
      }
      const latestNonceAfter = await this._latestSignerNonce();
      if (latestNonceAfter !== null && latestNonceAfter > pending.nonce) {
        this._clearPersistedSignedTx(pending.txHash);
        return { status: 'replaced', receipt: null, ...pending };
      }
      if (this._isReplacementCandidate(error)) {
        return await this._replacePendingSignedTx(pending, maxRetries);
      }
      error.pendingLabel = pending.label;
      error.pendingPoolName = pending.poolName;
      throw sanitizeRpcError(error);
    }
  }

  async _replacePendingWithCriticalRepair(pending, preparedBundle, label, maxRetries) {
    const { provider, prepared, populated, feeCapExempt } = preparedBundle;
    if (!feeCapExempt || !this._isConfiguredHfRepairTransaction(populated)) {
      throw new Error(`${label}: critical preemption requires exact configured repairHealthFactor()`);
    }

    const previous = ethers.Transaction.from(pending.rawTx);
    const bump = (value) => value > 0n ? (value * 1125n) / 1000n + 1n : 0n;
    const type = previous.type === 2 || populated.type === 2 ? 2 : (previous.type || 0);
    const request = {
      type,
      chainId: previous.chainId,
      nonce: previous.nonce,
      gasLimit: populated.gasLimit || previous.gasLimit,
      to: populated.to,
      value: populated.value || 0n,
      data: populated.data,
      accessList: populated.accessList || [],
    };
    if (type === 2) {
      request.maxPriorityFeePerGas = [
        bump(previous.maxPriorityFeePerGas || 0n),
        BigInt(populated.maxPriorityFeePerGas || 0n),
      ].reduce((highest, value) => value > highest ? value : highest, 0n);
      request.maxFeePerGas = [
        bump(previous.maxFeePerGas || previous.gasPrice || 0n),
        BigInt(populated.maxFeePerGas || populated.gasPrice || 0n),
        request.maxPriorityFeePerGas,
      ].reduce((highest, value) => value > highest ? value : highest, 0n);
    } else {
      request.gasPrice = [
        bump(previous.gasPrice || previous.maxFeePerGas || 0n),
        BigInt(populated.gasPrice || populated.maxFeePerGas || 0n),
      ].reduce((highest, value) => value > highest ? value : highest, 0n);
    }

    const replacementRaw = await this.withTimeout(
      () => prepared.wallet.signTransaction(request), RPC_TX_TIMEOUT_MS, `${label} critical preemption signing`
    );
    const replacementHash = ethers.keccak256(replacementRaw);
    if (prepared.log) prepared.log(replacementHash);
    this._persistSignedTx(replacementRaw, replacementHash, label, previous.nonce, {
      feeCapExempt: true,
      feeCapExemptTarget: populated.to,
    });
    console.warn(
      `${label} preempts pending ${pending.label} at nonce ${previous.nonce}: ` +
      `${pending.txHash} -> ${replacementHash}`
    );
    const startIndex = Math.max(
      0,
      this.providers.findIndex((entry) => entry.provider === provider)
    );
    try {
      const receipt = await this._broadcastSignedTransaction(
        replacementRaw, replacementHash, `${label} critical preemption`, startIndex, maxRetries
      );
      this._clearPersistedSignedTx(replacementHash);
      return receipt;
    } catch (error) {
      if (String(error.message || '').includes('failed on-chain')) {
        this._clearPersistedSignedTx(replacementHash);
      }
      throw error;
    }
  }

  async reconcilePendingSignedTx(maxRetries = 3) {
    if (!this.signerAddress) return null;
    const provider = this.getProvider();
    await this._ensureSignerState(provider);
    return await this._withSignerLock(provider, async () => {
      return await this._reconcilePendingSignedTxLocked(maxRetries);
    });
  }

  async executeSignedTxWithRetry(
    prepareFn,
    label = 'transaction',
    maxRetries = 3,
    { bypassFeeCap = false } = {}
  ) {
    const provider = this.getProvider();
    await this._ensureSignerState(provider);
    return await this._withSignerLock(provider, async () => {
      const prepareBundle = async () => await this.executeWithRetry(async (currentProvider) => {
        const prepared = await prepareFn(currentProvider);
        if (!prepared?.wallet || !prepared?.request) {
          throw new Error(`${label}: prepareFn must return { wallet, request }`);
        }
        const populated = await prepared.wallet.populateTransaction(prepared.request);
        const feeCapExempt = this._applyFeeCapPolicy(populated, label, bypassFeeCap === true);
        return { provider: currentProvider, prepared, populated, feeCapExempt };
      }, maxRetries, RPC_TX_TIMEOUT_MS);

      let preparedBundle = null;
      if (bypassFeeCap === true) {
        const pending = this._readPendingSignedTx();
        if (pending) {
          const entries = await this._authenticatedProviderEntries();
          let settled = false;
          for (const entry of entries) {
            const receipt = await this.withTimeout(
              () => entry.provider.getTransactionReceipt(pending.txHash),
              RPC_READ_TIMEOUT_MS,
              'critical preemption receipt lookup'
            ).catch(() => null);
            if (receipt) {
              settled = true;
              break;
            }
          }
          if (!settled) {
            const latestNonce = await this._latestSignerNonce();
            settled = latestNonce !== null && latestNonce > pending.nonce;
          }
          if (settled) {
            this._clearPersistedSignedTx(pending.txHash);
          } else {
            preparedBundle = await prepareBundle();
            return await this._replacePendingWithCriticalRepair(
              pending, preparedBundle, label, maxRetries
            );
          }
        }
      }

      const recovered = await this._reconcilePendingSignedTxLocked(maxRetries);
      if (recovered) {
        const error = new Error(
          `${label}: signer state changed while waiting for the shared nonce lock; ` +
          'recompute the action from fresh on-chain state'
        );
        error.code = 'KEEPER_STATE_REFRESH_REQUIRED';
        error.recoveredTransaction = recovered;
        throw sanitizeRpcError(error);
      }

      preparedBundle = preparedBundle || await prepareBundle();
      const { provider: preparationProvider, prepared, populated, feeCapExempt } = preparedBundle;

      // Sign exactly once. Every provider only sees this immutable raw transaction.
      const signedTx = await this.withTimeout(
        () => prepared.wallet.signTransaction(populated), RPC_TX_TIMEOUT_MS, `${label} signing`
      );
      const parsedSignedTx = ethers.Transaction.from(signedTx);
      const txHash = ethers.keccak256(signedTx);
      if (prepared.log) prepared.log(txHash);
      this._persistSignedTx(signedTx, txHash, label, parsedSignedTx.nonce, {
        feeCapExempt,
        feeCapExemptTarget: populated.to,
      });

      const startIndex = Math.max(
        0,
        this.providers.findIndex((entry) => entry.provider === preparationProvider)
      );
      try {
        const receipt = await this._broadcastSignedTransaction(
          signedTx,
          txHash,
          label,
          startIndex,
          maxRetries
        );
        this._clearPersistedSignedTx(txHash);
        return receipt;
      } catch (error) {
        if (String(error.message || '').includes('failed on-chain')) {
          this._clearPersistedSignedTx(txHash);
        }
        throw error;
      }
    });
  }

  async _broadcastSignedTransaction(signedTx, txHash, label, startIndex, maxRetries) {
    const entries = await this._authenticatedProviderEntries();
    const preferredProvider = this.providers[startIndex]?.provider;
    const authenticatedStartIndex = Math.max(
      0,
      entries.findIndex((entry) => entry.provider === preferredProvider)
    );
    const attempts = Math.max(maxRetries, entries.length);
    let lastError = null;

    for (let attempt = 1; attempt <= attempts; attempt++) {
      const entry = entries[(authenticatedStartIndex + attempt - 1) % entries.length];
      const provider = entry.provider;
      try {
        const existing = await this.withTimeout(
          () => provider.getTransactionReceipt(txHash), RPC_READ_TIMEOUT_MS, `${label} receipt lookup`
        );
        if (existing) {
          if (existing.status !== 1) throw new Error(`${label} failed on-chain: ${txHash}`);
          return existing;
        }

        try {
          await this.withTimeout(
            () => provider.broadcastTransaction(signedTx), RPC_READ_TIMEOUT_MS, `${label} broadcast`
          );
          console.log(`${label} raw tx ${attempt === 1 ? 'broadcast' : 'rebroadcast'}: ${txHash}`);
        } catch (error) {
          if (!this.isAlreadyKnownTx(error)) throw error;
        }

        const receipt = await this.withTimeout(
          () => provider.waitForTransaction(txHash, 1, 60_000), RPC_TX_TIMEOUT_MS, `${label} receipt wait`
        );
        if (receipt) {
          if (receipt.status !== 1) throw new Error(`${label} failed on-chain: ${txHash}`);
          return receipt;
        }
        const pendingError = new Error(`${label} receipt pending after signed broadcast: ${txHash}`);
        pendingError.code = 'TIMEOUT';
        throw pendingError;
      } catch (error) {
        const receipt = await this.withTimeout(
          () => provider.getTransactionReceipt(txHash), RPC_READ_TIMEOUT_MS, `${label} receipt reconciliation`
        ).catch(() => null);
        if (receipt) {
          if (receipt.status !== 1) throw new Error(`${label} failed on-chain: ${txHash}`);
          return receipt;
        }
        if (!this.isProviderError(error) && !this.isAlreadyKnownTx(error)) {
          error = sanitizeRpcError(error);
          error.message = `${safeErrorMessage(error)} (signed tx: ${txHash})`;
          throw error;
        }
        lastError = error;
        this.markUnhealthy(provider, true);
        console.warn(`RPC signed tx attempt ${attempt}/${attempts} failed: ${safeErrorMessage(error)}`);
      }
    }

    // One final sequential reconciliation across the configured tier. No provider
    // outside this RPCPool is ever introduced by the signed transaction path.
    for (const entry of entries) {
      const receipt = await this.withTimeout(
        () => entry.provider.getTransactionReceipt(txHash), RPC_READ_TIMEOUT_MS, `${label} final receipt reconciliation`
      ).catch(() => null);
      if (receipt) {
        if (receipt.status !== 1) throw new Error(`${label} failed on-chain: ${txHash}`);
        return receipt;
      }
    }
    const error = lastError || new Error(`${label} receipt unavailable`);
    error.message = `${safeErrorMessage(error)} (signed tx: ${txHash})`;
    throw sanitizeRpcError(error);
  }
}

module.exports = { RPCPool, RPC_READ_TIMEOUT_MS, RPC_TX_TIMEOUT_MS };
