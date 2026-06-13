# Safe Post-Deployment Setup

## Overview

After deploying all Liquid Hub contracts, the following Gnosis Safe multisig transactions must be executed to configure the system. Each step requires 2-of-3 signer approval.

Use the **Transaction Builder** app in the Gnosis Safe UI. For each step, paste the contract address, the JSON ABI, select the function, and fill in the parameters. The deployed contract addresses are published on the Contracts page: **http://liquidhub.app/docs#contracts-addresses**.

## Prerequisites

- All contracts deployed (MultiUserVault, RangeManager, Treasury, SecureBotModule, AaveHedgeManager if DN).
- All contract addresses recorded.
- Gnosis Safe multisig operational with 2/3 signers.

---

## Step 1: Enable SecureBotModule on Safe

Enable the bot module so it can execute whitelisted transactions through the Safe.

**Contract:** Safe (your multisig address)

```
Safe.enableModule(SAFE_MODULE_ADDRESS)
```

**ABI:**
```json
[{"inputs":[{"internalType":"address","name":"module","type":"address"}],"name":"enableModule","outputs":[],"stateMutability":"nonpayable","type":"function"}]
```

---

## Step 2: Set Bot Module on Vault

Register the module address on the vault so it can be recognized as an authorized bot.

**Contract:** MultiUserVault (`VAULT_ADDRESS`)

```
MultiUserVault.setBotModule(SAFE_MODULE_ADDRESS)
```

**ABI:**
```json
[{"inputs":[{"internalType":"address","name":"_botModule","type":"address"}],"name":"setBotModule","outputs":[],"stateMutability":"nonpayable","type":"function"}]
```

---

## Step 3: Authorize Module as Executor on RangeManager

Allow the module to call authorized functions on the RangeManager through the vault.

**Contract:** MultiUserVault (`VAULT_ADDRESS`)

```
MultiUserVault.authorizeExecutorOnRangeManager(SAFE_MODULE_ADDRESS, true)
```

**ABI:**
```json
[{"inputs":[{"internalType":"address","name":"executor","type":"address"},{"internalType":"bool","name":"authorized","type":"bool"}],"name":"authorizeExecutorOnRangeManager","outputs":[],"stateMutability":"nonpayable","type":"function"}]
```

---

## Step 4: Setup RangeManager Safe Authorization

Configure the RangeManager to recognize the Safe as an authorized caller.

**Contract:** MultiUserVault (`VAULT_ADDRESS`)

```
MultiUserVault.setupRangeManagerSafeAuthorization()
```

**ABI:**
```json
[{"inputs":[],"name":"setupRangeManagerSafeAuthorization","outputs":[],"stateMutability":"nonpayable","type":"function"}]
```

---

## Step 5: Authorize RangeManager on Treasury

Allow the RangeManager to trigger keeper bounty payments from the Treasury.

**Contract:** Treasury (`TREASURY_ADDRESS`)

```
Treasury.authorizeRangeManager(RANGEMANAGER_ADDRESS, true)
```

**ABI:**
```json
[{"inputs":[{"internalType":"address","name":"_rangeManager","type":"address"},{"internalType":"bool","name":"_authorized","type":"bool"}],"name":"authorizeRangeManager","outputs":[],"stateMutability":"nonpayable","type":"function"}]
```

---

## Step 6: Configure Price Oracles

Set the Chainlink price feed addresses used by the RangeManager for position calculations.

**Contract:** RangeManager (`RANGEMANAGER_ADDRESS`)

```
RangeManager.configurePriceFeeds(TOKEN0_ORACLE, TOKEN1_ORACLE, ETH_ORACLE)
```

**ABI:**
```json
[{"inputs":[{"internalType":"address","name":"_token0Oracle","type":"address"},{"internalType":"address","name":"_token1Oracle","type":"address"},{"internalType":"address","name":"_ethPriceOracle","type":"address"}],"name":"configurePriceFeeds","outputs":[],"stateMutability":"nonpayable","type":"function"}]
```

---

## Step 7: Configure Initial Ranges

Set the initial range percentages for the LP position (e.g., 500 = 5% up, 500 = 5% down from current price). Values are in basis points of percent (100 = 1%).

**Contract:** RangeManager (`RANGEMANAGER_ADDRESS`)

```
RangeManager.configureRanges(rangeUpPercent, rangeDownPercent)
```

**ABI:**
```json
[{"inputs":[{"internalType":"uint16","name":"_rangeUpPercent","type":"uint16"},{"internalType":"uint16","name":"_rangeDownPercent","type":"uint16"}],"name":"configureRanges","outputs":[],"stateMutability":"nonpayable","type":"function"}]
```

---

## Notes

- **All steps require Safe multisig approval** (2-of-3 signers must sign each transaction).
- Steps should be executed in order, as later steps may depend on earlier configuration.
- For **Delta Neutral (DN) pools**, additional AAVE-specific setup may be required, such as calling `supplyAndBorrow()` to establish the initial hedge position.
- After completing all steps, run the keeper in check-only mode (`npm run check`) to verify the configuration is correct before enabling automated rebalancing.
