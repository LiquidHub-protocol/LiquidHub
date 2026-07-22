const { ethers } = require('ethers');

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

  async executeTxWithRetry(sendFn, label = 'transaction', maxRetries = 3) {
    let txHash = null;
    return await this.executeWithRetry(async (provider) => {
      if (txHash) {
        const receipt = await provider.getTransactionReceipt(txHash);
        if (receipt) {
          if (receipt.status !== 1) throw new Error(`${label} failed on-chain: ${txHash}`);
          return receipt;
        }
        const waited = await provider.waitForTransaction(txHash, 1, 60_000);
        if (waited) {
          if (waited.status !== 1) throw new Error(`${label} failed on-chain: ${txHash}`);
          return waited;
        }
        throw new Error(`${label} receipt pending after broadcast: ${txHash}`);
      }

      const tx = await sendFn(provider);
      txHash = tx.hash;
      try {
        const receipt = await provider.waitForTransaction(txHash, 1, 60_000);
        if (!receipt) throw new Error(`${label} receipt pending after broadcast: ${txHash}`);
        if (receipt.status !== 1) throw new Error(`${label} failed on-chain: ${txHash}`);
        return receipt;
      } catch (error) {
        const receipt = await provider.getTransactionReceipt(txHash).catch(() => null);
        if (receipt) {
          if (receipt.status !== 1) throw new Error(`${label} failed on-chain: ${txHash}`);
          return receipt;
        }
        error.message = `${error.message} (broadcast tx: ${txHash})`;
        throw error;
      }
    }, maxRetries, RPC_TX_TIMEOUT_MS);
  }

  async executeSignedTxWithRetry(prepareFn, label = 'transaction', maxRetries = 3) {
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

    const startIndex = Math.max(
      0,
      this.providers.findIndex((entry) => entry.provider === preparationProvider)
    );
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
