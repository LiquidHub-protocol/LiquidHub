# Bibliothèques et déploiement des pools LiquidHub

Le découpage comprend **4 bibliothèques pour une pool standard et 6 pour une pool DN**, Treasury comprise. Les contrats de pools conservent leurs permissions, leurs fonctions publiques et leurs règles scellées. Les calculs et vérifications sont répartis sans ajouter de pouvoir administratif.

| Bibliothèque | Rôle |
| --- | --- |
| AutonomousRevenueLib | Commissions, réserves de bounties, conversions USDC, Stargate et transferts déterministes. Identique en standard, DN et SwapTreasury ; la Treasury ne dépend que de cette bibliothèque. |
| RangeOperations | Opérations LP, swaps et calculs de range. |
| ProtocolAccountingLib | Valorisation, lectures oracle/TWAP, suivi des positions et règlement des retraits ; normalisation de l’inventaire en DN. |
| ProtocolSafetyLib | Contrôles d’exécution canonique, installation, secours et paramètres bornés de la Safe ; contrôles HF en DN. |
| DnDepositLib — DN uniquement | Planification des dépôts et interaction atomique LP/Aave. |
| RangeStrategyDnLib — DN uniquement | Projections et décisions de stratégie DN. |

La compilation de production impose **au moins 2 048 octets de marge sous EIP-170 pour chaque contrat et chaque bibliothèque déployée**. Cette réserve sert aux futures versions des templates ; les pools scellées restent immuables. Le contrôle vérifie également que le catalogue respecte les dépendances réelles du bytecode. Le dashboard exécute les scripts de bibliothèques dans cet ordre et affiche chacune ; un script Forge individuel ne lance pas les autres scripts.

Les commandes ci-dessous constituent le parcours manuel. Les transactions de déploiement et le batch Safe doivent être signés et exécutés par l’opérateur ; cette mise à jour du code n’en exécute aucune.

## Tailles de production vérifiées

| Contrat ou bibliothèque | Standard : octets / marge | DN : octets / marge |
| --- | --- | --- |
| MultiUserVault | 21 559 / 3 017 | 22 504 / 2 072 |
| RangeManager | 21 678 / 2 898 | 22 520 / 2 056 |
| RangeStrategyEngine | 21 970 / 2 606 | 22 274 / 2 302 |
| SecureBotModule | 21 313 / 3 263 | 21 738 / 2 838 |
| PauseController | 3 200 / 21 376 | 3 200 / 21 376 |
| Treasury | 22 448 / 2 128 | 22 448 / 2 128 |
| AutonomousRevenueLib | 21 376 / 3 200 | 21 376 / 3 200 |
| RangeOperations | 20 826 / 3 750 | 21 482 / 3 094 |
| ProtocolAccountingLib | 15 021 / 9 555 | 19 506 / 5 070 |
| ProtocolSafetyLib | 16 625 / 7 951 | 21 942 / 2 634 |
| AaveHedgeManager | — | 22 354 / 2 222 |
| DnDepositLib | — | 21 906 / 2 670 |
| RangeStrategyDnLib | — | 20 103 / 4 473 |

Profil : Foundry 1.8.5, Solidity 0.8.36, via-IR, optimizer runs = 1, Paris, métadonnées de bytecode désactivées. Les bibliothèques de revenus sont identiques dans les deux pools et SwapTreasury.

## 🔴 1. Registre de la blockchain

Un registre peut être partagé par toutes les pools d’une même blockchain. S’il est conservé, vérifier son adresse et son réseau et passer au point 2. Pour un nouveau registre, vider uniquement `REGISTRY_ADDRESS` dans son `.env`, renseigner la clé du wallet de déploiement, puis :

```bash
cd /Users/ArnaudPerrot/RangeManager/app/pools/Registry/ARB
set -a
source .env
set +a
forge script script/DeployRegistry.s.sol:DeployRegistry --rpc-url "$RPC_URL" --chain "$CHAINID" --broadcast --verify --verifier "$FOUNDRY_VERIFIER"
```

Reporter l’adresse dans `REGISTRY_ADDRESS` du registre et des pools du même réseau. Supprimer ensuite la clé privée du `.env` du registre et exécuter `unset PRIVATE_KEY` dans le terminal. La transmission des adaptateurs aux wallets (MetaMask, Rabby, Zerion…) reste une démarche séparée du déploiement.

## 🔴 2. Configuration de la pool, compilation et wrappers oracle

Depuis **le dossier de la pool choisie**, standard ou DN :

```bash
cd /Users/ArnaudPerrot/RangeManager/app/pools/UNI-ARB-WETH-USDC
# Pour le DN, utiliser à la place :
# cd /Users/ArnaudPerrot/RangeManager/app/pools/UNI-ARB-WETH-USDC-DN
set -a
source .env
set +a
forge build --sizes --skip test --skip script
node ../check-library-layout.js .
```

Utiliser le profil Foundry épinglé dans le dépôt. Avant les signatures, rejouer les tests complets depuis la racine du dépôt :

```bash
cd /Users/ArnaudPerrot/RangeManager
LIQUIDHUB_TEST_RPC_TIER=premium node app/scripts/run-contract-tests.js app/pools/UNI-ARB-WETH-USDC full
# Ou, pour la pool DN :
LIQUIDHUB_TEST_RPC_TIER=premium node app/scripts/run-contract-tests.js app/pools/UNI-ARB-WETH-USDC-DN full
```

Revenir ensuite dans le dossier de la pool choisie et recharger sa configuration :

```bash
cd /Users/ArnaudPerrot/RangeManager/app/pools/UNI-ARB-WETH-USDC
# Pour le DN : cd /Users/ArnaudPerrot/RangeManager/app/pools/UNI-ARB-WETH-USDC-DN
set -a
source .env
set +a
```

Les forks et le proxy RPC de test ne transmettent aucune transaction réelle. Renseigner la Safe existante, le réseau et les politiques du template. Aucun contrôle du nombre de signataires ou du seuil de la Safe ne bloque cette installation ; les contrôles d’adresse, de réseau et de code restent actifs.

Renseigner les vrais feeds Chainlink dans `TOKEN0_ORACLE_RAW`, `TOKEN1_ORACLE_RAW`, `NATIVE_ORACLE_RAW` et `TREASURY_USDC_ORACLE_RAW`. Si des wrappers compatibles sont déjà déployés, conserver leurs adresses et effectuer le preflight ci-dessous. Sinon :

```bash
forge script script/00_DeploySequencerWrappers.s.sol:DeploySequencerWrappers --rpc-url "$RPC_URL" --chain "$CHAINID" --broadcast --verify --verifier "$FOUNDRY_VERIFIER"
```

Reporter les quatre sorties dans `TOKEN0_ORACLE_ADDRESS`, `TOKEN1_ORACLE_ADDRESS`, `NATIVE_ORACLE_ADDRESS` et `TREASURY_USDC_ORACLE_ADDRESS`, puis recharger le fichier et vérifier :

```bash
set -a
source .env
set +a
forge script script/01b_PreflightWrappers.s.sol:PreflightWrappers --rpc-url "$RPC_URL" --chain "$CHAINID"
```

## 🔴 3. Bibliothèques dans l’ordre des dépendances

Créer les bibliothèques de la nouvelle pool depuis son propre template. Les adresses standard et DN ne sont pas interchangeables, hormis le code commun d’AutonomousRevenueLib. Une reprise doit utiliser les bibliothèques et les liens exacts du même déploiement vérifié.

Préparer les options de déploiement, puis déployer la bibliothèque de revenus indépendante :

```bash
DEPLOY_FLAGS=(--rpc-url "$RPC_URL" --chain "$CHAINID" --broadcast --verify --verifier "$FOUNDRY_VERIFIER")
forge script script/00b_DeployAutonomousRevenueLib.s.sol:DeployAutonomousRevenueLib "${DEPLOY_FLAGS[@]}"
```

Reporter la sortie `AUTONOMOUS_REVENUE_LIB` dans le `.env`, recharger, puis :

```bash
set -a
source .env
set +a
LINK_FLAGS=(--libraries "src/AutonomousRevenueLib.sol:AutonomousRevenueLib:$AUTONOMOUS_REVENUE_LIB")
forge script script/01_DeployLibrary.s.sol:DeployLibrary "${DEPLOY_FLAGS[@]}" "${LINK_FLAGS[@]}"
```

Reporter `RANGE_OPERATIONS_LIB`, recharger, puis :

```bash
set -a
source .env
set +a
LINK_FLAGS+=(--libraries "src/RangeOperations.sol:RangeOperations:$RANGE_OPERATIONS_LIB")
forge script script/01d_DeployProtocolAccountingLib.s.sol:DeployProtocolAccountingLib "${DEPLOY_FLAGS[@]}" "${LINK_FLAGS[@]}"
```

Reporter `PROTOCOL_ACCOUNTING_LIB`, recharger, puis ajouter le lien :

```bash
set -a
source .env
set +a
LINK_FLAGS+=(--libraries "src/ProtocolAccountingLib.sol:ProtocolAccountingLib:$PROTOCOL_ACCOUNTING_LIB")
```

**DN uniquement :** déployer les deux bibliothèques DN avant la bibliothèque de sécurité :

```bash
forge script script/01b_DeployDnDepositLib.s.sol:DeployDnDepositLib "${DEPLOY_FLAGS[@]}" "${LINK_FLAGS[@]}"
```

Reporter `DN_DEPOSIT_LIB`, recharger, puis :

```bash
set -a
source .env
set +a
LINK_FLAGS+=(--libraries "src/DnDepositLib.sol:DnDepositLib:$DN_DEPOSIT_LIB")
forge script script/01c_DeployRangeStrategyDnLib.s.sol:DeployRangeStrategyDnLib "${DEPLOY_FLAGS[@]}" "${LINK_FLAGS[@]}"
```

Reporter `RANGE_STRATEGY_DN_LIB`, recharger, puis :

```bash
set -a
source .env
set +a
LINK_FLAGS+=(--libraries "src/RangeStrategyDnLib.sol:RangeStrategyDnLib:$RANGE_STRATEGY_DN_LIB")
```

**Standard et DN :** terminer par ProtocolSafetyLib :

```bash
forge script script/00a_DeployProtocolSafetyLib.s.sol:DeployProtocolSafetyLib "${DEPLOY_FLAGS[@]}" "${LINK_FLAGS[@]}"
```

Reporter `PROTOCOL_SAFETY_LIB`, recharger et compléter les liens conservés pour le point 5 :

```bash
set -a
source .env
set +a
LINK_FLAGS+=(--libraries "src/ProtocolSafetyLib.sol:ProtocolSafetyLib:$PROTOCOL_SAFETY_LIB")
```

## 🔴 4. Treasury, nouvelle ou partagée

Une Treasury de commissions de pools peut servir plusieurs pools standard et DN sur la même blockchain et accueillir les actifs de nouvelles pools via leurs politiques d’installation scellées. SwapTreasury est distincte, à raison d’un projet de swap par blockchain. Les politiques et destinations d’une Treasury existante restent celles de son installation.

Si une Treasury est conservée, renseigner son adresse dans `TREASURY_ADDRESS` et conserver son adresse de bibliothèque réelle dans `TREASURY_AUTONOMOUS_REVENUE_LIB`. Le wizard et le générateur de batch authentifient ses liens depuis le bytecode ; ne pas lui attribuer par défaut l’adresse de bibliothèque d’une nouvelle pool.

Pour une nouvelle Treasury, vider `TREASURY_ADDRESS` dans le `.env`, recharger, puis :

```bash
set -a
source .env
set +a
forge script script/Deploy_Treasury.s.sol:DeployTreasury "${DEPLOY_FLAGS[@]}" --libraries "src/AutonomousRevenueLib.sol:AutonomousRevenueLib:$AUTONOMOUS_REVENUE_LIB"
```

Reporter `TREASURY_ADDRESS` et `TREASURY_AUTONOMOUS_REVENUE_LIB` dans la configuration de chaque pool qui utilise cette Treasury. Pour cette nouvelle instance, `TREASURY_AUTONOMOUS_REVENUE_LIB` correspond à la bibliothèque passée à la commande ci-dessus. La propriété reste à accepter par la Safe au point 6.

## 🔴 5. Contrats de la pool

Régler `MIN_DEPOSIT_USD` avant la commande : `500000000` pour 5 USD en test, ou `10000000000` pour 100 USD en production. Recharger le fichier :

```bash
set -a
source .env
set +a
```

**Standard :** Vault, PauseController, RangeManager, RangeStrategyEngine et SecureBotModule :

```bash
forge script script/02_DeployContracts.s.sol:DeployContracts "${DEPLOY_FLAGS[@]}" "${LINK_FLAGS[@]}"
```

**DN :** les mêmes contrats, plus AaveHedgeManager :

```bash
forge script script/03_DeployAaveHedge.s.sol:DeployAaveHedge "${DEPLOY_FLAGS[@]}" "${LINK_FLAGS[@]}"
```

Ces commandes sont alternatives selon le template. Elles exigent les bibliothèques et la Treasury précédentes ; elles ne les déploient pas. Reporter `VAULT_ADDRESS`, `RANGEMANAGER_ADDRESS`, `SAFE_MODULE_ADDRESS`, `PAUSE_CONTROLLER_ADDRESS`, `RANGE_STRATEGY_ENGINE_ADDRESS` et, en DN, `AAVE_HEDGE_MANAGER_ADDRESS`. Conserver aussi le hash de transaction de déploiement du Vault. Vérifier les contrats et leur code dans l’explorateur du réseau.

Supprimer `PRIVATE_KEY` du `.env` de la pool puis vider et vérifier l’environnement sans afficher la clé :

```bash
unset PRIVATE_KEY
if [ -z "${PRIVATE_KEY-}" ]; then printf 'PRIVATE_KEY absent du terminal\n'; else printf 'PRIVATE_KEY encore présente\n'; fi
```

## 🔴 6. Batch Safe d’installation et vérification après exécution

`ACCEPT_TREASURY_OWNERSHIP=true` si la Safe est encore `pendingOwner` de la Treasury, même si celle-ci a été déployée lors d’une étape précédente. Utiliser `false` lorsque la Safe en est déjà `owner`.

Depuis le dossier de la pool :

```bash
node script/GenerateSafeBatch.js
```

Ce script vérifie les adresses, bibliothèques, routes, oracles et politiques avant de générer le JSON ; il ne déploie rien et ne signe pas. Il prépare les bindings, permissions publiques, bounties, destinations de conversion/bridge et verrous définitifs d’installation.

Dans la Safe : **Transaction Builder → Upload batch → importer `script/safe-batch-<identifiant-de-pool-en-minuscules>.json` → Create Batch → signatures du multisig → Send Batch**.

Après confirmation sur la blockchain :

```bash
node script/GenerateSafeBatch.js --verify-post-batch
```

Cette vérification est obligatoire avant le premier mint et l’ouverture aux utilisateurs. Conserver le JSON exécuté et son hash de transaction comme preuve d’installation. Le financement initial des bounties et du gas des opérateurs, le premier mint par la société, puis les mises à jour des adresses des bots/keepers restent nécessaires avant leur mise en service.
