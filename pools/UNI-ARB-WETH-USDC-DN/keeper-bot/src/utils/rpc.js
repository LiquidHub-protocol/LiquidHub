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

  markUnhealthy(provider) {
    const entry = this.providers.find(p => p.provider === provider);
    if (entry) {
      entry.errorCount++;
      if (entry.errorCount >= 3) entry.healthy = false;
    }
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
        this.markUnhealthy(provider);
        console.warn(`RPC attempt ${attempt}/${attempts} failed: ${error.message}`);
      }
    }
    throw lastError;
  }
}

module.exports = { RPCPool };
