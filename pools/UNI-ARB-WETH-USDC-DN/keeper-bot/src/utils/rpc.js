const { ethers } = require('ethers');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const RPC_READ_TIMEOUT_MS = 20_000;
const RPC_TX_TIMEOUT_MS = 90_000;
const SIGNER_LOCK_TIMEOUT_MS = 5 * 60_000;
const SIGNER_LOCK_POLL_MS = 250;

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
      errorCount: 0
    }));
    this.currentIndex = 0;
    this.poolName = String(process.env.POOL_NAME || path.basename(process.cwd()));
    this.signerAddress = process.env.KEEPER_PRIVATE_KEY
      ? new ethers.Wallet(process.env.KEEPER_PRIVATE_KEY).address.toLowerCase()
      : null;
    const configuredChainId = process.env.CHAINID || process.env.CHAIN_ID;
    this.chainId = configuredChainId && /^\d+$/.test(configuredChainId)
      ? String(BigInt(configuredChainId))
      : null;
    this.stateDir = process.env.KEEPER_STATE_DIR
      ? path.resolve(process.env.KEEPER_STATE_DIR)
      : path.join(os.homedir(), '.liquidhub-keeper-state');
    this.configuredPendingTxFile = process.env.KEEPER_PENDING_TX_FILE
      ? path.resolve(process.env.KEEPER_PENDING_TX_FILE)
      : null;
    this.pendingTxFile = null;
    this.processLockFile = null;
  }

  async _ensureSignerState(provider) {
    if (!this.signerAddress) {
      throw new Error('KEEPER_PRIVATE_KEY is required for signed keeper transactions');
    }
    if (!this.chainId) {
      const network = await this.withTimeout(
        () => provider.getNetwork(),
        RPC_READ_TIMEOUT_MS,
        'keeper signer network'
      );
      this.chainId = String(network.chainId);
    }
    if (!this.pendingTxFile) {
      const signerKey = `${this.chainId}-${this.signerAddress}`;
      this.pendingTxFile = this.configuredPendingTxFile ||
        path.join(this.stateDir, `pending-${signerKey}.json`);
      this.processLockFile = path.join(this.stateDir, `signer-${signerKey}.lock`);
      fs.mkdirSync(path.dirname(this.pendingTxFile), { recursive: true, mode: 0o700 });
      fs.mkdirSync(path.dirname(this.processLockFile), { recursive: true, mode: 0o700 });
    }
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
      throw new Error(`Invalid persisted keeper transaction: ${error.message}`);
    }
    if (parsed?.schemaVersion === 1) {
      try {
        const legacyTx = ethers.Transaction.from(parsed.rawTx);
        parsed = {
          ...parsed,
          schemaVersion: 2,
          poolName: parsed.poolName || 'legacy keeper',
          signer: legacyTx.from?.toLowerCase(),
          chainId: String(legacyTx.chainId),
          nonce: legacyTx.nonce,
        };
      } catch (error) {
        throw new Error(`Invalid legacy persisted keeper transaction: ${error.message}`);
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
      ethers.keccak256(parsed.rawTx).toLowerCase() !== parsed.txHash.toLowerCase()
    ) {
      throw new Error('Persisted keeper transaction identity/hash/raw payload mismatch');
    }
    return parsed;
  }

  _persistSignedTx(rawTx, txHash, label, nonce) {
    if (!this.pendingTxFile) return;
    if (!Number.isSafeInteger(nonce) || nonce < 0) {
      throw new Error(`${label}: signed transaction nonce is missing or invalid`);
    }
    fs.mkdirSync(path.dirname(this.pendingTxFile), { recursive: true, mode: 0o700 });
    const temp = `${this.pendingTxFile}.${process.pid}.tmp`;
    fs.writeFileSync(temp, `${JSON.stringify({
      schemaVersion: 2,
      rawTx,
      txHash,
      label,
      poolName: this.poolName,
      signer: this.signerAddress,
      chainId: this.chainId,
      nonce,
      createdAt: new Date().toISOString(),
    }, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
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
    this.providers.forEach(p => { p.healthy = true; p.errorCount = 0; });
    this.currentIndex = 0;
    return this.providers[0].provider;
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
      msg.includes('known transaction') ||
      msg.includes('nonce too low') ||
      msg.includes('nonce has already been used');
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
        return await this.withTimeout(() => fn(provider), timeoutMs, `RPC attempt ${attempt}`);
      } catch (error) {
        lastError = error;
        if (!this.isProviderError(error)) throw error;
        this.markUnhealthy(provider, true);
        console.warn(`RPC attempt ${attempt}/${attempts} failed: ${error.message}`);
      }
    }
    throw lastError;
  }

  async _latestSignerNonce() {
    let latestNonce = null;
    for (const entry of this.providers) {
      const nonce = await this.withTimeout(
        () => entry.provider.getTransactionCount(this.signerAddress, 'latest'),
        RPC_READ_TIMEOUT_MS,
        'keeper signer nonce reconciliation'
      ).catch(() => null);
      if (nonce !== null && (latestNonce === null || nonce > latestNonce)) {
        latestNonce = nonce;
      }
    }
    return latestNonce;
  }

  async _reconcilePendingSignedTxLocked(maxRetries = 3) {
    const pending = this._readPendingSignedTx();
    if (!pending) return null;

    console.warn(
      `Recovering persisted ${pending.label || 'keeper transaction'} ` +
      `for ${pending.poolName || 'unknown pool'}: ${pending.txHash}`
    );

    for (const entry of this.providers) {
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
        return { status: 'failed', receipt: null, error: error.message, ...pending };
      }
      const latestNonceAfter = await this._latestSignerNonce();
      if (latestNonceAfter !== null && latestNonceAfter > pending.nonce) {
        this._clearPersistedSignedTx(pending.txHash);
        return { status: 'replaced', receipt: null, ...pending };
      }
      error.pendingLabel = pending.label;
      error.pendingPoolName = pending.poolName;
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

  async executeSignedTxWithRetry(prepareFn, label = 'transaction', maxRetries = 3) {
    const provider = this.getProvider();
    await this._ensureSignerState(provider);
    return await this._withSignerLock(provider, async () => {
      const recovered = await this._reconcilePendingSignedTxLocked(maxRetries);
      if (recovered) {
        const error = new Error(
          `${label}: signer state changed while waiting for the shared nonce lock; ` +
          'recompute the action from fresh on-chain state'
        );
        error.code = 'KEEPER_STATE_REFRESH_REQUIRED';
        error.recoveredTransaction = recovered;
        throw error;
      }

      const preparedBundle = await this.executeWithRetry(async (currentProvider) => {
        const prepared = await prepareFn(currentProvider);
        if (!prepared?.wallet || !prepared?.request) {
          throw new Error(`${label}: prepareFn must return { wallet, request }`);
        }
        const populated = await prepared.wallet.populateTransaction(prepared.request);
        return { provider: currentProvider, prepared, populated };
      }, maxRetries, RPC_TX_TIMEOUT_MS);
      const { provider: preparationProvider, prepared, populated } = preparedBundle;

      // Sign exactly once. Every provider only sees this immutable raw transaction.
      const signedTx = await this.withTimeout(
        () => prepared.wallet.signTransaction(populated), RPC_TX_TIMEOUT_MS, `${label} signing`
      );
      const parsedSignedTx = ethers.Transaction.from(signedTx);
      const txHash = ethers.keccak256(signedTx);
      if (prepared.log) prepared.log(txHash);
      this._persistSignedTx(signedTx, txHash, label, parsedSignedTx.nonce);

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
    const attempts = Math.max(maxRetries, this.providers.length);
    let lastError = null;

    for (let attempt = 1; attempt <= attempts; attempt++) {
      const entry = this.providers[(startIndex + attempt - 1) % this.providers.length];
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
          error.message = `${error.message} (signed tx: ${txHash})`;
          throw error;
        }
        lastError = error;
        this.markUnhealthy(provider, true);
        console.warn(`RPC signed tx attempt ${attempt}/${attempts} failed: ${error.message}`);
      }
    }

    // One final sequential reconciliation across the configured tier. No provider
    // outside this RPCPool is ever introduced by the signed transaction path.
    for (const entry of this.providers) {
      const receipt = await this.withTimeout(
        () => entry.provider.getTransactionReceipt(txHash), RPC_READ_TIMEOUT_MS, `${label} final receipt reconciliation`
      ).catch(() => null);
      if (receipt) {
        if (receipt.status !== 1) throw new Error(`${label} failed on-chain: ${txHash}`);
        return receipt;
      }
    }
    const error = lastError || new Error(`${label} receipt unavailable`);
    error.message = `${error.message} (signed tx: ${txHash})`;
    throw error;
  }
}

module.exports = { RPCPool, RPC_READ_TIMEOUT_MS, RPC_TX_TIMEOUT_MS };
