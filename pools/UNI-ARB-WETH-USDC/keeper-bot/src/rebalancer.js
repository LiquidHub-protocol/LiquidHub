const { ethers } = require('ethers');

/**
 * Splits a BigInt amount into `numChunks` as-equal-as-possible parts.
 */
function divideIntoChunks(totalAmount, numChunks) {
  if (numChunks <= 1) return [totalAmount];
  const chunks = [];
  const chunkSize = totalAmount / BigInt(numChunks);
  for (let i = 0; i < numChunks - 1; i++) chunks.push(chunkSize);
  chunks.push(totalAmount - chunkSize * BigInt(numChunks - 1));
  return chunks;
}

/**
 * Rebalancer — executes the atomic rebalance() function on the RangeManager.
 *
 * The single on-chain call performs: lock vault → burn old position → execute N swaps
 * → mint new position → unlock vault → pay keeper bounty. All in one tx.
 *
 * Permissionless: no keeper role required — anyone can trigger when needsRebalance is true.
 */
class Rebalancer {
  constructor(rangeManager, vault, wallet) {
    this.rangeManager = rangeManager;
    this.vault = vault;
    this.wallet = wallet;
    this.rmConnected = this.rangeManager.connect(wallet);
  }

  async executeRebalance(tokenId) {
    console.log(`\n=== Starting atomic rebalance for position #${tokenId} ===`);

    try {
      // 1. Read optimal swap params (what the contract would expect)
      const swapParams = await this.rangeManager.getOptimalSwapParams();

      let swapAmounts = [];
      let minOuts = [];
      let tokenIn = process.env.TOKEN0_ADDRESS;
      let tokenOut = process.env.TOKEN1_ADDRESS;

      if (swapParams.swapNeeded && swapParams.amountIn > 0n) {
        const token0 = process.env.TOKEN0_ADDRESS;
        const token1 = process.env.TOKEN1_ADDRESS;
        tokenIn = swapParams.zeroForOne ? token0 : token1;
        tokenOut = swapParams.zeroForOne ? token1 : token0;

        // Read on-chain chunk cap (initMultiSwapTvl in USD, contract value)
        const initMultiSwapTvl = await this.rangeManager.initMultiSwapTvl();
        const priceCache = await this.rangeManager.priceCache();
        const decimals = swapParams.zeroForOne
          ? parseInt(process.env.TOKEN0_DECIMALS || '18', 10)
          : parseInt(process.env.TOKEN1_DECIMALS || '6', 10);
        const price = swapParams.zeroForOne
          ? Number(priceCache.price0) / 1e8
          : Number(priceCache.price1) / 1e8;

        const amountUSD = parseFloat(ethers.formatUnits(swapParams.amountIn, decimals)) * price;
        const capUSD = Number(initMultiSwapTvl);

        // Number of chunks to stay under the on-chain per-chunk cap
        const numSwaps = capUSD > 0 ? Math.max(1, Math.ceil(amountUSD / capUSD)) : 1;
        swapAmounts = divideIntoChunks(swapParams.amountIn, numSwaps);
        // Contract handles per-pool slippage; 0 = use pool defaults
        minOuts = swapAmounts.map(() => 0n);

        console.log(`  Swap: ${numSwaps} chunk(s), ~$${amountUSD.toFixed(0)} total (cap $${capUSD}/chunk)`);
      } else {
        console.log('  No swap needed (already balanced)');
      }

      // 2. Single atomic call — contract does burn → swap(s) → mint → bounty
      console.log('  Executing rebalance() on-chain...');
      const tx = await this.rmConnected.rebalance(swapAmounts, minOuts, tokenIn, tokenOut);
      const receipt = await tx.wait();
      console.log(`  Rebalance complete: ${receipt.hash}`);

      return { success: true, txHashes: [receipt.hash] };
    } catch (error) {
      console.error(`Rebalance failed: ${error.message}`);
      return { success: false, error: error.message, txHashes: [] };
    }
  }
}

module.exports = { Rebalancer };
