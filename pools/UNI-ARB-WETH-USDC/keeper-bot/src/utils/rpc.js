const { ethers } = require('ethers');

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

  async executeWithRetry(fn, maxRetries = 3) {
    let lastError;
    const attempts = Math.max(maxRetries, this.providers.length);
    for (let attempt = 1; attempt <= attempts; attempt++) {
      const provider = this.getProvider();
      try {
        return await fn(provider);
      } catch (error) {
        lastError = error;
        if (this.isProviderError(error)) {
          this.markUnhealthy(provider, true);
        }
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
        const receipt = await tx.wait();
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
    }, maxRetries);
  }

  async executeSignedTxWithRetry(prepareFn, label = 'transaction', maxRetries = 3) {
    let txHash = null;
    let signedTx = null;
    return await this.executeWithRetry(async (provider) => {
      if (txHash) {
        const receipt = await provider.getTransactionReceipt(txHash);
        if (receipt) {
          if (receipt.status !== 1) throw new Error(`${label} failed on-chain: ${txHash}`);
          return receipt;
        }
        try {
          await provider.broadcastTransaction(signedTx);
          console.log(`${label} raw tx rebroadcast: ${txHash}`);
        } catch (error) {
          if (!this.isAlreadyKnownTx(error)) {
            error.message = `${error.message} (signed rebroadcast tx: ${txHash})`;
            throw error;
          }
        }
        const waited = await provider.waitForTransaction(txHash, 1, 60_000);
        if (waited) {
          if (waited.status !== 1) throw new Error(`${label} failed on-chain: ${txHash}`);
          return waited;
        }
        throw new Error(`${label} receipt pending after signed broadcast: ${txHash}`);
      }

      const prepared = await prepareFn(provider);
      if (!prepared?.wallet || !prepared?.request) {
        throw new Error(`${label}: prepareFn must return { wallet, request }`);
      }
      const populated = await prepared.wallet.populateTransaction(prepared.request);
      signedTx = await prepared.wallet.signTransaction(populated);
      txHash = ethers.keccak256(signedTx);
      if (prepared.log) prepared.log(txHash);
      const tx = await provider.broadcastTransaction(signedTx);
      try {
        const receipt = await tx.wait();
        if (receipt.status !== 1) throw new Error(`${label} failed on-chain: ${txHash}`);
        return receipt;
      } catch (error) {
        const receipt = await provider.getTransactionReceipt(txHash).catch(() => null);
        if (receipt) {
          if (receipt.status !== 1) throw new Error(`${label} failed on-chain: ${txHash}`);
          return receipt;
        }
        error.message = `${error.message} (signed broadcast tx: ${txHash})`;
        throw error;
      }
    }, maxRetries);
  }
}

module.exports = { RPCPool };
