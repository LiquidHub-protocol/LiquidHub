const { ethers } = require('ethers');
const fs = require('node:fs');
const path = require('node:path');

const RPC_READ_TIMEOUT_MS = 20_000;
const RPC_TX_TIMEOUT_MS = 90_000;

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
    const poolSlug = String(process.env.POOL_NAME || path.basename(process.cwd()))
      .replace(/[^a-zA-Z0-9_-]/g, '_');
    this.pendingTxFile = process.env.KEEPER_PENDING_TX_FILE
      ? path.resolve(process.env.KEEPER_PENDING_TX_FILE)
      : path.resolve(process.cwd(), `.keeper-pending-tx-${poolSlug}.json`);
    fs.mkdirSync(path.dirname(this.pendingTxFile), { recursive: true, mode: 0o700 });
    this._acquireProcessLock();
  }

  _acquireProcessLock() {
    this.processLockFile = `${this.pendingTxFile}.lock`;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const fd = fs.openSync(this.processLockFile, 'wx', 0o600);
        fs.writeFileSync(fd, `${process.pid}\n`);
        fs.closeSync(fd);
        process.once('exit', () => {
          try {
            if (fs.readFileSync(this.processLockFile, 'utf8').trim() === String(process.pid)) {
              fs.unlinkSync(this.processLockFile);
            }
          } catch {
            // The lock may already have been cleaned up.
          }
        });
        return;
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
        let activePid = 0;
        try {
          activePid = Number(fs.readFileSync(this.processLockFile, 'utf8').trim());
          if (!Number.isInteger(activePid) || activePid <= 0) {
            fs.rmSync(this.processLockFile, { force: true });
            continue;
          }
          process.kill(activePid, 0);
        } catch (probeError) {
          if (probeError.code === 'EPERM') {
            throw new Error(`Keeper signer lock is held by PID ${activePid}`);
          }
          fs.rmSync(this.processLockFile, { force: true });
          continue;
        }
        throw new Error(`Keeper signer lock is already held by PID ${activePid}`);
      }
    }
    throw new Error('Unable to acquire keeper signer lock');
  }

  _readPendingSignedTx() {
    if (!this.pendingTxFile || !fs.existsSync(this.pendingTxFile)) return null;
    let parsed;
    try {
      parsed = JSON.parse(fs.readFileSync(this.pendingTxFile, 'utf8'));
    } catch (error) {
      throw new Error(`Invalid persisted keeper transaction: ${error.message}`);
    }
    if (
      parsed?.schemaVersion !== 1 ||
      typeof parsed.rawTx !== 'string' ||
      typeof parsed.txHash !== 'string' ||
      ethers.keccak256(parsed.rawTx).toLowerCase() !== parsed.txHash.toLowerCase()
    ) {
      throw new Error('Persisted keeper transaction hash/raw payload mismatch');
    }
    return parsed;
  }

  _persistSignedTx(rawTx, txHash, label) {
    if (!this.pendingTxFile) return;
    fs.mkdirSync(path.dirname(this.pendingTxFile), { recursive: true, mode: 0o700 });
    const temp = `${this.pendingTxFile}.${process.pid}.tmp`;
    fs.writeFileSync(temp, `${JSON.stringify({
      schemaVersion: 1,
      rawTx,
      txHash,
      label,
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

  async executeSignedTxWithRetry(prepareFn, label = 'transaction', maxRetries = 3) {
    const pending = this._readPendingSignedTx();
    if (pending) {
      console.warn(`Recovering persisted ${pending.label || 'keeper transaction'}: ${pending.txHash}`);
      try {
        await this._broadcastSignedTransaction(
          pending.rawTx,
          pending.txHash,
          pending.label || 'recovered transaction',
          0,
          maxRetries
        );
        this._clearPersistedSignedTx(pending.txHash);
      } catch (error) {
        if (String(error.message || '').includes('failed on-chain')) {
          this._clearPersistedSignedTx(pending.txHash);
        }
        throw error;
      }
    }

    const preparedBundle = await this.executeWithRetry(async (provider) => {
      const prepared = await prepareFn(provider);
      if (!prepared?.wallet || !prepared?.request) {
        throw new Error(`${label}: prepareFn must return { wallet, request }`);
      }
      const populated = await prepared.wallet.populateTransaction(prepared.request);
      return { provider, prepared, populated };
    }, maxRetries, RPC_TX_TIMEOUT_MS);
    const { provider: preparationProvider, prepared, populated } = preparedBundle;

    // Sign exactly once. Every provider only sees this immutable raw transaction.
    const signedTx = await this.withTimeout(
      () => prepared.wallet.signTransaction(populated), RPC_TX_TIMEOUT_MS, `${label} signing`
    );
    const txHash = ethers.keccak256(signedTx);
    if (prepared.log) prepared.log(txHash);
    this._persistSignedTx(signedTx, txHash, label);

    const startIndex = Math.max(
      0,
      this.providers.findIndex((entry) => entry.provider === preparationProvider)
    );
    try {
      const receipt = await this._broadcastSignedTransaction(signedTx, txHash, label, startIndex, maxRetries);
      this._clearPersistedSignedTx(txHash);
      return receipt;
    } catch (error) {
      if (String(error.message || '').includes('failed on-chain')) {
        this._clearPersistedSignedTx(txHash);
      }
      throw error;
    }
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
