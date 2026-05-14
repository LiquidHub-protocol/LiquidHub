require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });

const { ethers } = require('ethers');
const { RPCPool } = require('./utils/rpc');
const { createContracts, TREASURY_ABI } = require('./utils/contracts');
const { Rebalancer } = require('./rebalancer');

const CHECK_INTERVAL_MS = (parseInt(process.env.CHECK_INTERVAL_MIN || '10', 10)) * 60 * 1000;
const CHECK_ONLY = process.argv.includes('--check-only');

async function main() {
  console.log('=== Liquid Hub Keeper Bot (Standard Pool) ===');
  console.log(`RangeManager: ${process.env.RANGEMANAGER_ADDRESS}`);
  console.log(`Vault: ${process.env.VAULT_ADDRESS}`);
  console.log(`Check interval: ${CHECK_INTERVAL_MS / 60000} minutes`);
  console.log(`Mode: ${CHECK_ONLY ? 'CHECK ONLY' : 'ACTIVE'}\n`);

  // Validate required env vars (VAULT_ADDRESS kept for Treasury discovery)
  const required = ['RPC_URL', 'RANGEMANAGER_ADDRESS', 'VAULT_ADDRESS', 'TOKEN0_ADDRESS', 'TOKEN1_ADDRESS'];
  if (!CHECK_ONLY) required.push('KEEPER_PRIVATE_KEY');
  for (const key of required) {
    if (!process.env[key]) {
      console.error(`Missing required env var: ${key}`);
      process.exit(1);
    }
  }

  const rpcPool = new RPCPool();
  const provider = rpcPool.getProvider();
  const { rangeManager, vault } = createContracts(provider);

  // Check bounty info
  try {
    const treasuryAddr = await vault.treasuryAddress();
    const treasury = new ethers.Contract(treasuryAddr, TREASURY_ABI, provider);
    const bountyEnabled = await treasury.keeperBountyEnabled();
    const bountyAmount = await treasury.keeperBountyAmount();
    console.log(`Treasury: ${treasuryAddr}`);
    console.log(`Keeper bounty: ${bountyEnabled ? ethers.formatUnits(bountyAmount, 6) + ' USDC' : 'disabled'}\n`);
  } catch (e) {
    console.log(`Treasury info unavailable: ${e.message}\n`);
  }

  let wallet, rebalancer;
  if (!CHECK_ONLY) {
    wallet = new ethers.Wallet(process.env.KEEPER_PRIVATE_KEY, provider);
    rebalancer = new Rebalancer(rangeManager, vault, wallet);
    console.log(`Keeper wallet: ${wallet.address}\n`);
  }

  // Main loop
  while (true) {
    try {
      console.log(`[${new Date().toISOString()}] Checking bot instructions...`);

      const [hasPosition, tokenId, needsRebalance, action, reason] = await rpcPool.executeWithRetry(
        async (p) => {
          const rm = rangeManager.connect(p);
          return await rm.getBotInstructions();
        }
      );

      console.log(`  Position: ${hasPosition ? '#' + tokenId.toString() : 'none'}`);
      if (hasPosition) {
        console.log(`  Needs rebalance: ${needsRebalance}`);
      }

      // Public keepers can ONLY call rebalance() — it is the only public function
      // on the RangeManager. Other actions (MINT_INITIAL, etc.) are gated on-chain
      // by `onlyAuthorized` and reserved for the protocol bot / Safe, so we just
      // wait silently for the next cycle.
      if (!needsRebalance || action !== 'REBALANCE') {
        console.log('  -> No action needed\n');
      } else if (CHECK_ONLY) {
        console.log('  -> Rebalance needed (check-only mode, skipping)\n');
      } else {
        console.log('  -> Executing REBALANCE...');
        const result = await rebalancer.executeRebalance(tokenId);
        if (result.success) {
          console.log(`  -> Success (${result.txHashes.length} txs)\n`);
        } else {
          console.error(`  -> Failed: ${result.error}\n`);
        }
      }

    } catch (error) {
      console.error(`Error: ${error.message}\n`);
    }

    if (CHECK_ONLY) break;
    await new Promise(resolve => setTimeout(resolve, CHECK_INTERVAL_MS));
  }
}

main().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});
