// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "./RangeOperations.sol";

// Interface etendue pour RangeManager
interface IRangeManagerExtended {
    function setSafeAddress(address _safe) external;
    function setAuthorizedExecutor(address _executor, bool _authorized) external;
    function safeAddress() external view returns (address);
    function authorizedExecutors(address) external view returns (bool);
    function setDynamicRangeConfig(
        bool _enabled,
        uint8 _maxSnapshotsPerDay,
        uint8 _volatMoyDay,
        uint8 _volatTrimDay,
        uint16 _rangeStepBps,
        uint16 _rangeMultiplicatorBps
    ) external;
}

interface IRangeManager {
    function getOwnerPositions() external view returns (uint256[] memory);
    function priceCache() external view returns (uint128, uint128, uint160, int24, uint64, bool);
    function getCurrentBalances() external view returns (uint256, uint256);
    function positionManager() external view returns (INonfungiblePositionManager);
    function pool() external view returns (IUniswapV3Pool);
    function removeLiquidityForWithdraw(uint256 tokenId, uint128 liquidityToRemove) external;
    function transferTokensForWithdraw(uint256 amount0, uint256 amount1, address recipient)
        external
        returns (uint256, uint256);
    function burnPosition(uint256 tokenId) external;
    function emergencyWithdrawForUser(uint256 amount0Requested, uint256 amount1Requested, address recipient)
        external
        returns (uint256 amount0Sent, uint256 amount1Sent);
    function config() external view returns (RangeOperations.RangeConfig memory);
    // protectionConfig public getter (audit V1) : struct étendu V3 → (sandwichDet, mev, failure, sandwichBps,
    // maxOracleDeviationBps, maxAge0, maxAge1). Doit matcher l'ABI du struct public sinon decode faux. Sert au
    // check de déviation oracle/pool appliqué au mint des shares (chemins dépôt) — voir _processOneDeposit.
    function protectionConfig() external view returns (bool, bool, bool, uint16, uint16, uint32, uint32);
    // audit V1 (V3-H1) : le vault rafraîchit le cache (slot0+oracle LIVE) avant chaque mint/withdraw de shares.
    function refreshPriceCache() external;
    function addLiquidityToPosition() external;
    function collectFeesForVault() external returns (uint256 fees0, uint256 fees1);
    // --- depot permissionless ---
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256);
    function getOptimalSwapParams() external view returns (RangeOperations.OptimalSwapParams memory);
    function initMultiSwapTvl() external view returns (uint256);
    function validateDepositSwapPlan(
        uint256 depositAmount0,
        uint256 depositAmount1,
        uint256[] calldata swapAmountsIn,
        uint256[] calldata minAmountsOut,
        address tokenIn,
        address tokenOut
    ) external view;
}

interface ITreasuryDeposit {
    function payDepositBounty(address keeper, uint256 depositValueUsd) external;
}

contract MultiUserVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===== STRUCTURES =====

    struct UserInfo {
        uint256 shares;
        uint256 depositedToken0;
        uint256 depositedToken1;
        uint256 depositedValueUSD; // Valeur USD au moment du dépôt (fixe)
        uint256 lastDepositTime;
        uint256 totalFeesEarnedToken0;
        uint256 totalFeesEarnedToken1;
        // AUDIT (nettoyage code mort) : timeWeightedShares + lastTimeUpdate RETIRÉS (jamais écrits, modèle
        // accFeePerShare). ABIs off-chain userInfo() mises à jour en conséquence (décodage positionnel).
        uint256 firstDepositTime; // Timestamp du premier dépôt d'une période de détention. Reset à 0 sur withdraw 100%.
        uint256 lastDepositBlock; // Block du dernier dépôt processé. Bloque deposit+withdraw atomique (anti-flash-loan).
    }

    struct PendingDeposit {
        address user;
        uint256 amount0;
        uint256 amount1;
        uint256 timestamp;
    }

    struct FeeSnapshot {
        uint256 token0Collected;
        uint256 token1Collected;
        uint256 timestamp;
        uint256 blockNumber;
    }

    // ===== VARIABLES D'ETAT =====

    IRangeManager public rangeManager;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    address private immutable pauseController;

    mapping(address => UserInfo) public userInfo;
    address[] private users; // Liste des utilisateurs actuellement actifs (shares > 0)
    // audit V1 (M3-B) : index 1-based de chaque user dans `users` (0 = absent). Permet le swap-and-pop O(1)
    // au retrait total (pruning) — `users` ne grandit plus indefiniment, eliminant le DoS gas historique.
    // Remplace l'ancien mapping isUser (bool) : un index != 0 vaut "present".
    mapping(address => uint256) private userIndexPlusOne;

    // Commission et treasury
    uint256 public commissionRate;
    address public treasuryAddress;

    //securbotmodule
    address public botModule;

    // Tracking comptable des commissions envoyees au Treasury (auto-compound)
    uint256 public totalCommissionCollectedToken0;
    uint256 public totalCommissionCollectedToken1;

    mapping(address => bool) public authorizedRecipients;
    mapping(address => bool) public hasPendingDeposit;

    PendingDeposit[] public pendingDeposits;
    // SÉCURITÉ (audit V1 — DoS gas A) : pointeur de tête de file. Traiter un dépôt avance _pendingHead
    // (O(1)) au lieu de décaler tout le tableau (O(n) → O(n²) pour vider la file). La file est "vide"
    // quand _pendingHead >= pendingDeposits.length ; on compacte (delete + reset) une fois vidée.
    uint256 private _pendingHead;

    /// @dev Nombre de dépôts EN ATTENTE (non encore traités) = longueur - tête.
    function _pendingCount() internal view returns (uint256) {
        uint256 len = pendingDeposits.length;
        return len > _pendingHead ? len - _pendingHead : 0;
    }

    uint256 public totalShares;
    uint256 private constant DEAD_SHARES = 1000; // Brûlées au premier dépôt (anti-inflation attack)

    // Systeme de tracking des fees
    mapping(address => uint256) public userFeeDebtToken0;
    mapping(address => uint256) public userFeeDebtToken1;

    FeeSnapshot[] public feeHistory;

    uint256 public lastCollectedFees0;
    uint256 public lastCollectedFees1;

    bool private _processingRebalance;
    uint64 private _rebalanceStartedAt;

    uint256 public minDepositUSD;
    address public emergencySafe;

    // Age max (secondes) du cache prix accepte par processDepositPermissionless (anti-prix-perime).
    // Reglable par la Safe sans redeploiement. Defaut 3600 (1h) ; pool stablecoin peut elargir.
    uint256 public depositMaxCacheAge = 3600;

    // Système de tracking des fees time-weighted
    // audit V1 (M3-B-fix, retour Codex) : COMPTA DES FEES — accFeePerShare pro-rata des SHARES courantes.
    // Modele MasterChef standard, prouve correct et O(1). Remplace l'ancien "time-weighted + accumulateur
    // monotone" qui SURCOMPTAIT apres plusieurs distributions sans checkpoint (3F au lieu de 2F). Les
    // distributions sont DISCRETES (a chaque rebalance) et les fees auto-compoundees : repartir au prorata des
    // shares courantes a chaque distribution est economiquement correct et sans le bug. Miroir exact de la DN.
    // pending = shares*acc - debt, avec debt fige a chaque interaction -> shares CONSTANT entre 2 checkpoints.
    uint256 public accFeePerShare0;
    uint256 public accFeePerShare1;

    // ===== EVENTS =====

    event Deposit(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
    event PendingDepositAdded(address indexed user, uint256 amount0, uint256 amount1);
    // event DepositsProcessed supprimé avec la fonction batch processPendingDeposits (audit V1)
    event FeesDistributed(uint256 fees0, uint256 fees1);
    event CommissionRateUpdated(uint256 oldRate, uint256 newRate);
    event RebalancingStarted(uint256 timestamp);
    event RebalancingEnded(uint256 timestamp);
    event RangeManagerSet(address indexed rangeManager);
    event EmergencyUserRecovered(
        address indexed user, uint256 amount0Recovered, uint256 amount1Recovered, uint256 sharesRemoved
    );
    event PositionBurned(uint256 indexed tokenId, address indexed executor);
    event BurnFailed(uint256 indexed tokenId, string reason);
    event AllPositionsBurned(uint256 positionCount, address indexed executor);
    event MinDepositUpdated(uint256 oldMinimum, uint256 newMinimum);
    event BotModuleSet(address indexed module);
    event TreasuryAddressUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ExecutorAuthorizedOnRangeManager(address indexed executor, bool authorized);
    event BotModuleUpdated(address indexed oldModule, address indexed newModule);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event EmergencySafeUpdated(address indexed oldSafe, address indexed newSafe);

    // ===== MODIFIERS =====

    modifier onlyRangeManager() {
        require(msg.sender == address(rangeManager), "E01");
        _;
    }

    modifier onlyBot() {
        require(msg.sender == owner() || msg.sender == botModule || msg.sender == address(rangeManager), "Only bot");
        _;
    }

    modifier onlyEmergencySafe() {
        require(msg.sender == emergencySafe, "Only emergency safe");
        _;
    }

    // ===== CONSTRUCTOR =====

    constructor(
        address _rangeManager,
        address _token0,
        address _token1,
        address _pauseController,
        address _treasuryAddress,
        uint256 _commissionRate,
        uint256 _minDepositUSD
    ) {
        require(_rangeManager != address(0), "E11");
        require(_token0 != address(0) && _token1 != address(0), "E12");
        require(_pauseController != address(0), "E12");
        require(_treasuryAddress != address(0), "E13");

        rangeManager = IRangeManager(_rangeManager);
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        pauseController = _pauseController;

        treasuryAddress = _treasuryAddress;

        commissionRate = _commissionRate;
        require(commissionRate <= 3000, "E14"); // Max 30%

        authorizedRecipients[address(this)] = true;

        minDepositUSD = _minDepositUSD;
        emergencySafe = msg.sender;

        // audit V1 (M3-B-fix) : plus d'init time-weighted (modele accFeePerShare, accumulateurs a 0 par defaut).
    }

    // ===== FONCTIONS DE CONFIGURATION RANGEMANAGER =====
    // Ces fonctions permettent a la Safe (owner de MultiUserVault)
    // de configurer RangeManager dont MultiUserVault est l'owner

    /**
     * @notice Configure l'adresse de la Safe dans RangeManager
     * @dev Permet a la Safe d'etre autorisee directement sur RangeManager
     * Cette fonction ne peut etre appelee qu'une fois
     */
    function setupRangeManagerSafeAuthorization() external onlyOwner {
        // Appel a la nouvelle fonction setSafeAddress de RangeManager
        // Comme MultiUserVault est l'owner de RangeManager, cet appel va reussir
        IRangeManagerExtended(address(rangeManager)).setSafeAddress(owner());
    }

    /**
     * @notice Autorise un executeur sur RangeManager
     * @param executor L'adresse a autoriser
     * @param authorized True pour autoriser, false pour revoquer
     */
    function authorizeExecutorOnRangeManager(address executor, bool authorized) external onlyOwner {
        require(executor != address(0), "E15");
        IRangeManagerExtended(address(rangeManager)).setAuthorizedExecutor(executor, authorized);
        emit ExecutorAuthorizedOnRangeManager(executor, authorized);
    }

    /// @notice Relaie setDynamicRangeConfig au RangeManager (dont ce Vault est l'owner).
    /// @dev Permet de configurer le range dynamique au deploiement : le RangeManager appartient
    ///      au Vault des sa construction, donc le deployeur ne peut pas l'appeler directement
    ///      (onlyAuthorized => E99). Le deployeur (owner du Vault a ce stade) passe par ici.
    function setDynamicRangeConfigOnRangeManager(
        bool _enabled,
        uint8 _maxSnapshotsPerDay,
        uint8 _volatMoyDay,
        uint8 _volatTrimDay,
        uint16 _rangeStepBps,
        uint16 _rangeMultiplicatorBps
    ) external onlyOwner {
        IRangeManagerExtended(address(rangeManager)).setDynamicRangeConfig(
            _enabled, _maxSnapshotsPerDay, _volatMoyDay, _volatTrimDay, _rangeStepBps, _rangeMultiplicatorBps
        );
    }

    /// @notice Phase 2 governance relay for RangeManager settings.
    /// @dev RangeManager is owned by this Vault. Once the Vault owner is a timelock and Safe ops are disabled
    ///      on RangeManager, governance can still execute RangeManager setters through this relay.
    function executeRangeManagerGovernance(bytes calldata data) external onlyOwner returns (bytes memory result) {
        require(data.length >= 4, "E20");
        (bool ok, bytes memory ret) = address(rangeManager).call(data);
        require(ok, "E20");
        return ret;
    }

    // AUDIT (nettoyage code mort, parité avec la pool DN) : calculateUserShareOfFees + estimateTotalFees
    // (+ helpers privés _estimateUncollectedFees / _calculateFeeGrowth) RETIRÉS — aucun appelant on-chain
    // ni off-chain. La compta réelle passe par accFeePerShare / getUserInfoWithPendingFees.

    // ===== SETTER POUR RANGEMANAGER =====

    bool private rangeManagerSet;

    // Fonction pour configurer RangeManager
    function setRangeManager(address _rangeManager) external onlyOwner {
        require(!rangeManagerSet, "E16");
        require(_rangeManager != address(0), "E11");

        rangeManager = IRangeManager(_rangeManager);
        rangeManagerSet = true;

        emit RangeManagerSet(_rangeManager);
    }

    // ===== DEPOSIT FUNCTIONS =====

    function deposit(uint256 amount0, uint256 amount1) external nonReentrant {
        _requirePause(0x5ea9e82a); // requireInflowsActive()
        require(amount0 > 0 || amount1 > 0, "E21");
        require(!hasPendingDeposit[msg.sender], "E22");

        // Vérifier le montant minimum seulement si > 0
        if (minDepositUSD > 0) {
            uint256 depositValueUSD = _calculateDepositValue(amount0, amount1);
            require(depositValueUSD >= minDepositUSD, "E23");
        }

        // Transferer les tokens au vault
        if (amount0 > 0) {
            token0.safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            token1.safeTransferFrom(msg.sender, address(this), amount1);
        }

        // Ajouter a la queue
        pendingDeposits.push(
            PendingDeposit({user: msg.sender, amount0: amount0, amount1: amount1, timestamp: block.timestamp})
        );

        hasPendingDeposit[msg.sender] = true;

        emit PendingDepositAdded(msg.sender, amount0, amount1);
    }

    // ===== PROCESS DEPOSITS ET WITHDRAW =====

    // SÉCURITÉ (audit V1) : la fonction batch processPendingDeposits() a été SUPPRIMÉE. Elle figeait
    // currentTotalValue avant la boucle tout en incrémentant totalShares à chaque itération, ce qui
    // sur-mintait des shares aux dépôts tardifs d'un même lot (dilution des holders existants). Elle
    // était `onlyBot` mais le selector restait whitelisté dans le module → atteignable par une clé bot
    // compromise. Le traitement des dépôts se fait désormais UNIQUEMENT un par un via processSingleDeposit()
    // / processDepositPermissionless(), qui recalculent la valeur du vault à CHAQUE dépôt (accounting juste).

    // ===== TRAITEMENT INDIVIDUEL DES DEPOTS =====

    /**
     * @notice Retourne les informations du prochain dépôt en attente
     * @return user Adresse de l'utilisateur
     * @return amount0 Montant token0
     * @return amount1 Montant token1
     * @return timestamp Timestamp du dépôt
     * @return exists True si un dépôt existe
     */
    function getNextPendingDeposit()
        external
        view
        returns (address user, uint256 amount0, uint256 amount1, uint256 timestamp, bool exists)
    {
        if (_pendingCount() == 0) {
            return (address(0), 0, 0, 0, false);
        }
        PendingDeposit memory pd = pendingDeposits[_pendingHead];
        return (pd.user, pd.amount0, pd.amount1, pd.timestamp, true);
    }

    /// @notice AUDIT H-01/H-03 : plan de swap correct pour le PROCHAIN dépôt (pool standard). État FUTUR =
    ///         soldes libres du RM + le dépôt en tête (PAS getOptimalSwapParams, qui reflète l'état rebalance/
    ///         post-burn incluant le NFT). Ratio cible = celui du NFT EXISTANT (addLiquidityToPosition ajoute à
    ///         CE range), pas le range cible dynamique. À utiliser par les keepers/bot pour processDepositPermissionless.
    /// @return zeroForOne true si swap token0→token1 ; amountIn en unités natives (0 = pas de swap).
    function getDepositSwapParams() external view returns (bool zeroForOne, uint256 amountIn) {
        if (_pendingCount() == 0) return (false, 0);
        PendingDeposit memory pd = pendingDeposits[_pendingHead];
        // Calcul déporté en library (EIP-170 — le Vault std est serré). La library lit priceCache/config/ratio
        // NFT du RangeManager et ajoute le dépôt aux soldes libres pour refléter l'état futur de la tx.
        return RangeOperations.depositSwapParams(address(rangeManager), pd.amount0, pd.amount1);
    }

    /**
     * @notice Traite UN SEUL dépôt (le premier de la queue)
     * @dev Le bot doit ensuite faire les multi-swaps et appeler addLiquidityToPosition
     *      Chaque utilisateur paie ses propres frais de swap proportionnels à son dépôt
     */
    function processSingleDeposit() external onlyBot {
        require(_pendingCount() > 0, "E24");
        _processOneDeposit();
    }

    /**
     * @notice Logique partagee de traitement d'UN depot de la file (premier element).
     * @dev Extraite de processSingleDeposit pour etre reutilisee par processDepositPermissionless,
     *      garantissant un calcul de shares IDENTIQUE (oracle Chainlink). Calcule les shares,
     *      met a jour l'accounting utilisateur, transfere les fonds du depot au RangeManager,
     *      retire le depot de la file, emet Deposit. Le caller gere verrou/swaps/addLiquidity/bounty.
     * @return amount0 Montant token0 du depot traite. @return amount1 Montant token1.
     */
    function _processOneDeposit() private returns (uint256 amount0, uint256 amount1, uint256 depositValue) {
        _requirePause(0x5ea9e82a); // requireInflowsActive()
        // SÉCURITÉ (audit V1 — High) : le calcul des shares utilise getCurrentBalances() (composition LP au
        // prix slot0 Uniswap, MANIPULABLE) au dénominateur, alors que depositValue vient de l'oracle Chainlink.
        // Sans garde-fou, un attaquant peut manipuler slot0, déposer et obtenir un ratio de shares biaisé.
        // On refuse donc le mint si le prix POOL diverge de l'ORACLE au-delà du seuil gouvernance. Couvre
        // LES DEUX chemins (processSingleDeposit ET processDepositPermissionless) car tous deux passent ici.
        // V3-H1 : on REFRESH d'abord (slot0+oracle LIVE) pour éliminer le risque de cache obsolète vs le slot0
        // lu par getCurrentBalances ; updatePriceCache invalide le cache si déviation > seuil. Cohérent DN.
        {
            rangeManager.refreshPriceCache();
            (uint128 _p0, uint128 _p1, uint160 _sqrtP,,, bool _valid) = rangeManager.priceCache();
            require(_valid, "E38"); // cache invalidé (déviation pool/oracle ou feed stale) -> on bloque le mint
            (,,,, uint16 _maxDevBps,,) = rangeManager.protectionConfig();
            RangeOperations.RangeConfig memory _cfg = rangeManager.config();
            RangeOperations.PriceCache memory _pc = RangeOperations.PriceCache({
                price0: _p0,
                price1: _p1,
                poolSqrtPriceX96: _sqrtP,
                poolTick: 0,
                timestamp: 0,
                valid: _valid
            });
            RangeOperations.checkOracleDeviation(_pc, _maxDevBps, _cfg.token0Decimals, _cfg.token1Decimals);
        }

        // Récupérer le premier dépôt EN ATTENTE (tête de file = _pendingHead)
        PendingDeposit memory pd = pendingDeposits[_pendingHead];

        // audit V1 (M3-B-fix2, retour Codex — Medium) : CRISTALLISER les fees Uniswap AVANT de calculer les
        // shares. getCurrentBalances() ne valorise que tokens libres + liquidite + tokensOwed DEJA cristallises,
        // PAS le feeGrowth latent. Sans cette collecte, un deposant entrerait avec un denominateur SOUS-EVALUE
        // puis capterait une part des fees pre-depot d'autrui lors de la prochaine collecte. collectFeesForVault()
        // pousse le feeGrowth -> met a jour accFeePerShare pour les porteurs EXISTANTS + libere les tokens (donc
        // _calculateTotalValue ci-dessous est exact). Le nouvel user est checkpointe APRES (debt=shares*acc).
        // FAIL-CLOSED : si la collecte revert (position existante), on bloque le mint (retry au cycle suivant).
        if (rangeManager.getOwnerPositions().length > 0) {
            rangeManager.collectFeesForVault();
        }

        uint256 currentTotalValue = _calculateTotalValue();

        // Calculer les shares
        depositValue = _calculateDepositValue(pd.amount0, pd.amount1);
        uint256 sharesToMint;

        if (totalShares <= DEAD_SHARES) {
            // Premier dépôt (ou re-dépôt après withdraw total, ne reste que les dead shares)
            totalShares = 0; // Reset pour recalculer proprement
            sharesToMint = depositValue * 1e10;
            require(sharesToMint > DEAD_SHARES, "First deposit too small");
            sharesToMint -= DEAD_SHARES;
            totalShares += DEAD_SHARES; // Dead shares permanentes (pas attribuées)
        } else {
            require(currentTotalValue > 0, "E25");
            require(depositValue > 0, "E_ZERO_VALUE"); // audit V1 (Medium) : pas de dépôt sans valeur
            sharesToMint = (depositValue * totalShares) / currentTotalValue;
            require(sharesToMint > 0, "E_ZERO_SHARES"); // audit V1 (Medium) : pas de mint à 0 share
        }

        // Mettre a jour les infos utilisateur
        UserInfo storage user = userInfo[pd.user];

        // audit V1 (M3-B-fix) — COMPTA accFeePerShare : REGLER les fees AVANT d'ajouter les nouvelles shares
        // (fige la dette sur l'ancien solde). No-op si shares==0 (1er depot / re-depot apres retrait total).
        _updateUserFees(pd.user);

        if (user.shares == 0) {
            user.firstDepositTime = block.timestamp;
        }

        user.shares += sharesToMint;
        user.depositedToken0 += pd.amount0;
        user.depositedToken1 += pd.amount1;
        user.depositedValueUSD += depositValue;
        user.lastDepositTime = block.timestamp;
        // Anti-flash-loan: bloque withdraw dans le meme bloc que le processing du depot.
        // Sans ce garde-fou, un attaquant peut deposit+process+withdraw dans une seule tx
        // et exploiter l'ecart entre prix oracle (sert au calcul des shares) et balances LP
        // (servent au calcul du withdraw). Voir audit V1+V3.
        user.lastDepositBlock = block.number;

        _registerUser(pd.user);

        // audit V1 (M3-B-fix) — RE-CHECKPOINT la dette sur le NOUVEAU solde : les shares fraichement mintees
        // ne reclament pas les fees passees. debt = shares * acc.
        userFeeDebtToken0[pd.user] = user.shares * accFeePerShare0;
        userFeeDebtToken1[pd.user] = user.shares * accFeePerShare1;

        totalShares += sharesToMint;
        hasPendingDeposit[pd.user] = false;

        // Envoyer les fonds de CE DEPOT UNIQUEMENT au RangeManager
        if (pd.amount0 > 0) {
            token0.safeTransfer(address(rangeManager), pd.amount0);
        }
        if (pd.amount1 > 0) {
            token1.safeTransfer(address(rangeManager), pd.amount1);
        }

        // Retirer ce dépôt de la queue : avancer la tête (O(1), audit V1 — DoS gas A) au lieu du shift O(n).
        _pendingHead++;
        // Compactage : si la file est entièrement traitée, libérer le storage et réinitialiser la tête.
        if (_pendingHead >= pendingDeposits.length) {
            delete pendingDeposits;
            _pendingHead = 0;
        }

        emit Deposit(pd.user, pd.amount0, pd.amount1, sharesToMint);
        return (pd.amount0, pd.amount1, depositValue);
    }

    /**
     * @notice Traite UN depot de la file de maniere PERMISSIONLESS et ATOMIQUE.
     * @dev Decentralise le dernier maillon : n'importe qui (keeper) peut convertir un depot en file
     *      en liquidite LP, sans le bot du fondateur. En UNE tx : refresh oracle -> calcul shares
     *      (oracle) -> transfert fonds au RM -> swaps bornes oracle (anti-MEV) -> addLiquidity ->
     *      deposit bounty. Verrou _processingRebalance pose pendant toute la fonction (un withdraw
     *      concurrent revert E32). Le mint initial reste reserve au bot (revert si aucune position).
     *      Le hedge DN n'est PAS touche ici : il est corrige separement par adjustHedge() permissionless.
     * @param swapAmountsIn Montants d'entree des swaps de reequilibrage (chunks), fournis par le keeper.
     * @param minAmountsOut Sorties minimales par chunk. Bornees on-chain : require(>= oracleMinOut).
     * @param tokenIn Token vendu (token0 ou token1). @param tokenOut Token achete.
     */
    function processDepositPermissionless(
        uint256[] calldata swapAmountsIn,
        uint256[] calldata minAmountsOut,
        address tokenIn,
        address tokenOut
    ) external nonReentrant {
        require(swapAmountsIn.length == minAmountsOut.length, "len");
        // 1. File non vide (anti-drain bounty : on ne paie que sur depot reel)
        require(_pendingCount() > 0, "E24");
        // 2. NFT existant (le mint initial reste au bot)
        uint256[] memory positions = rangeManager.getOwnerPositions();
        require(positions.length > 0, "E71");
        // 3. Refresh oracle atomique. audit V1 (V3-R4 Point 3, retour Codex) : on REFRESH d'abord le cache
        // (slot0+oracle LIVE) de façon INCONDITIONNELLE — avant ne se faisait que via recordPriceSnapshot()
        // qui revert si le snapshot n'est pas dû (catché), laissant le check depositMaxCacheAge buter sur un
        // cache ancien et BLOQUER le chemin permissionless. refreshPriceCache() ne dépend pas du timing snapshot.
        rangeManager.refreshPriceCache();
        // AUDIT MED-2 : on NE rappelle PLUS recordPriceSnapshot() ici. Son bounty metrics irait à msg.sender =
        // le VAULT (pas au keeper déclencheur) → fuite/incohérence. La fraîcheur est déjà assurée par
        // refreshPriceCache() ; le ring-buffer est entretenu par la cadence keeper/bot dédiée.
        (uint128 price0, uint128 price1,,, uint64 ts, bool valid) = rangeManager.priceCache();
        require(valid && price0 > 0 && price1 > 0, "E38");
        require(block.timestamp - uint256(ts) <= depositMaxCacheAge, "stale");
        PendingDeposit memory pdPlan = pendingDeposits[_pendingHead];
        rangeManager.validateDepositSwapPlan(
            pdPlan.amount0, pdPlan.amount1, swapAmountsIn, minAmountsOut, tokenIn, tokenOut
        );

        // 4. VERROU (un withdraw concurrent revert E32 ; pose pendant toute la modification de position)
        _processingRebalance = true;

        // 5. Shares + transfert des fonds au RangeManager (logique identique a processSingleDeposit)
        (,, uint256 depositValue) = _processOneDeposit();

        // 6. Swaps de reequilibrage bornes par l'oracle (anti-sandwich) + cap par chunk
        uint256 n = swapAmountsIn.length;
        if (n > 0) {
            for (uint256 i = 0; i < n; i++) {
                rangeManager.executeSwap(tokenIn, tokenOut, swapAmountsIn[i], minAmountsOut[i]);
            }
        }

        // 7. Ajouter la liquidite a la position existante
        rangeManager.addLiquidityToPosition();

        // 8. DEVERROU
        _processingRebalance = false;

        // 9. Deposit bounty (silent: ne jamais bloquer l'action si treasury vide / desactive)
        if (treasuryAddress != address(0)) {
            try ITreasuryDeposit(treasuryAddress).payDepositBounty(msg.sender, depositValue) {} catch {}
        }
    }

    /**
     * @notice Retourne la valeur USD estimée du prochain dépôt
     * @dev Utilisé par le bot pour calculer le nombre de swaps nécessaires
     */
    function getNextDepositValueUSD() external view returns (uint256 valueUSD) {
        if (_pendingCount() == 0) {
            return 0;
        }
        PendingDeposit memory pd = pendingDeposits[_pendingHead];
        return _calculateDepositValue(pd.amount0, pd.amount1);
    }

    function startRebalance() external onlyBot {
        require(!_processingRebalance || block.timestamp > uint256(_rebalanceStartedAt) + 30 minutes, "E32");
        _processingRebalance = true;
        _rebalanceStartedAt = uint64(block.timestamp);
    }

    function endRebalance() external onlyBot {
        _processingRebalance = false;
    }

    function isRebalancing() external view returns (bool) {
        return _processingRebalance && block.timestamp <= uint256(_rebalanceStartedAt) + 30 minutes;
    }

    function withdraw(uint256 shareAmount) external nonReentrant {
        _withdrawInternal(shareAmount);
    }

    /**
     * @notice Retire un pourcentage des shares de l'utilisateur
     * @param pct Le pourcentage à retirer (1-100)
     */
    function withdrawPercentage(uint256 pct) external nonReentrant {
        require(pct > 0 && pct <= 100, "E31");
        _withdrawInternal((userInfo[msg.sender].shares * pct) / 100);
    }

    /**
     * @notice Fonction interne de retrait partagée
     * @param shareAmount Le nombre de shares à retirer
     */
    function _withdrawInternal(uint256 shareAmount) internal {
        // ===== CHECKS =====
        require(!_processingRebalance || block.timestamp > uint256(_rebalanceStartedAt) + 30 minutes, "E32");
        UserInfo storage user = userInfo[msg.sender];
        require(user.shares >= shareAmount && shareAmount > 0 && totalShares > 0, "E33");
        // Anti-flash-loan: refuse tout withdraw dans le meme bloc que le processing du dernier
        // depot de l'utilisateur. Casse l'atomicite requise par l'exploit (V1+V3 audit).
        require(block.number > user.lastDepositBlock, "E_SAME_BLOCK");
        _requireWithdrawalAllowed(user.lastDepositTime);

        // SÉCURITÉ (audit V1 — High/Medium) : le burn de liquidité au withdraw passe amount0Min/1Min=0.
        // Un withdraw visible en mempool pourrait être exécuté sur un slot0 manipulé (sandwich). On refuse
        // donc le retrait si le prix POOL diverge de l'ORACLE au-delà du seuil gouvernance.
        // V3-H1 : REFRESH d'abord (slot0+oracle LIVE), updatePriceCache invalide le cache si déviation. Coh. DN.
        {
            rangeManager.refreshPriceCache();
            (uint128 _p0, uint128 _p1, uint160 _sqrtP,,, bool _valid) = rangeManager.priceCache();
            require(_valid, "E38"); // cache invalidé (déviation pool/oracle ou feed stale) -> on bloque le retrait
            (,,,, uint16 _maxDevBps,,) = rangeManager.protectionConfig();
            RangeOperations.RangeConfig memory _cfg = rangeManager.config();
            RangeOperations.PriceCache memory _pc = RangeOperations.PriceCache({
                price0: _p0,
                price1: _p1,
                poolSqrtPriceX96: _sqrtP,
                poolTick: 0,
                timestamp: 0,
                valid: _valid
            });
            RangeOperations.checkOracleDeviation(_pc, _maxDevBps, _cfg.token0Decimals, _cfg.token1Decimals);
        }

        uint256 totalSharesBefore = totalShares;
        bool isFullWithdraw = totalSharesBefore - shareAmount <= DEAD_SHARES;

        // Mise à jour fees avant calculs (regle sur l'ancien solde de shares, fige la dette).
        _updateUserFees(msg.sender);
        _handleUnclaimedFeesOnWithdraw(user, shareAmount);

        // Calculer montants pour le retrait (commission = 0, deja au Treasury)
        (uint256 commission0, uint256 commission1, uint256 principal0, uint256 principal1) =
            _calculateWithdrawAmounts(shareAmount, totalSharesBefore);

        // ===== EFFECTS =====
        _finalizeWithdrawal(user, shareAmount, commission0, commission1, principal0, principal1);

        // ===== INTERACTIONS =====
        (uint256 toSend0, uint256 toSend1) =
            _executeWithdrawAndSend(principal0, principal1, shareAmount, totalSharesBefore, isFullWithdraw);

        emit Withdraw(msg.sender, toSend0, toSend1, shareAmount);
    }

    function _requirePause(uint256 selector) private view {
        address controller = pauseController;
        // Yul shl order is shl(shift, value): left-align the 4-byte selector in calldata.
        assembly ("memory-safe") {
            mstore(0x00, shl(224, selector))
            if iszero(staticcall(gas(), controller, 0x00, 0x04, 0x00, 0x00)) {
                returndatacopy(0x00, 0x00, returndatasize())
                revert(0x00, returndatasize())
            }
        }
    }

    function _requireWithdrawalAllowed(uint256 lastDepositTime) private view {
        address controller = pauseController;
        // Yul shl order is shl(shift, value): left-align requireWithdrawalsActiveAfter(uint256).
        assembly ("memory-safe") {
            mstore(0x00, shl(224, 0xedde0818)) // requireWithdrawalsActiveAfter(uint256)
            mstore(0x04, lastDepositTime)
            if iszero(staticcall(gas(), controller, 0x00, 0x24, 0x00, 0x00)) {
                returndatacopy(0x00, 0x00, returndatasize())
                revert(0x00, returndatasize())
            }
        }
    }

    // ===== FEES MANAGEMENT =====

    /// @notice Distribue des fees nettes : incremente l'accumulateur par-share. O(1), aucune boucle.
    /// @dev audit V1 (M3-B-fix) — modele accFeePerShare (MasterChef). Taux += fees*1e36/totalShares. MONOTONE.
    ///      Chaque user regle SES fees a la demande (pending = shares*acc - debt). `shares` constant entre 2
    ///      checkpoints -> formule exacte (corrige le surcomptage multi-distribution de l'ancien modele TW).
    ///      Miroir exact de la pool DN.
    function _distributeFees(uint256 fees0, uint256 fees1) private {
        if (totalShares == 0) return;
        if (fees0 == 0 && fees1 == 0) return;

        // Precision 1e36 anti-perte d'arrondi sur tokens a faibles decimales (ex: USDC 6 dec).
        accFeePerShare0 += (fees0 * 1e36) / totalShares;
        accFeePerShare1 += (fees1 * 1e36) / totalShares;

        emit FeesDistributed(fees0, fees1);
    }

    function recordFeesCollected(uint256 fees0, uint256 fees1, uint256 commission0, uint256 commission1)
        external
        onlyRangeManager
    {
        if (fees0 > 0 || fees1 > 0) {
            feeHistory.push(
                FeeSnapshot({
                    token0Collected: fees0,
                    token1Collected: fees1,
                    timestamp: block.timestamp,
                    blockNumber: block.number
                })
            );
            lastCollectedFees0 = fees0;
            lastCollectedFees1 = fees1;
            totalCommissionCollectedToken0 += commission0;
            totalCommissionCollectedToken1 += commission1;
        }
        // Distribuer les fees NETTES aux users (brutes - commission deja envoyee au Treasury)
        uint256 netFees0 = fees0 > commission0 ? fees0 - commission0 : 0;
        uint256 netFees1 = fees1 > commission1 ? fees1 - commission1 : 0;
        _distributeFees(netFees0, netFees1);
    }

    // audit V1 (M3-B) : _creditAllPendingFees() SUPPRIMEE. Sa double boucle O(n) sur users[] etait la source
    // du DoS gas et n'existait que pour remettre a zero les accumulateurs apres distribution. Le modele lazy
    // (accumulateurs monotones + reglement a la demande dans _updateUserFees) la rend inutile.

    /// @dev audit V1 (M3-B-fix) — REGLE les fees du user (lazy). pending = shares*acc - debt, credite dans
    ///      totalFeesEarned, puis dette = shares*acc. Appele AVANT toute modification de user.shares.
    function _updateUserFees(address userAddress) private {
        UserInfo storage user = userInfo[userAddress];
        uint256 s = user.shares;
        if (s == 0) {
            userFeeDebtToken0[userAddress] = 0;
            userFeeDebtToken1[userAddress] = 0;
            return;
        }

        uint256 accrued0 = s * accFeePerShare0;
        uint256 accrued1 = s * accFeePerShare1;
        user.totalFeesEarnedToken0 += (accrued0 - userFeeDebtToken0[userAddress]) / 1e36;
        user.totalFeesEarnedToken1 += (accrued1 - userFeeDebtToken1[userAddress]) / 1e36;
        userFeeDebtToken0[userAddress] = accrued0;
        userFeeDebtToken1[userAddress] = accrued1;
    }

    // ===== REGISTRE DES USERS ACTIFS (audit V1 — M3-B, pruning anti-DoS) =====

    /// @dev Ajoute le user au registre s'il n'y est pas deja (index 1-based). O(1).
    function _registerUser(address u) private {
        if (userIndexPlusOne[u] == 0) {
            users.push(u);
            userIndexPlusOne[u] = users.length; // = index + 1
        }
    }

    /// @dev Retire le user du registre en swap-and-pop O(1). Appele au retrait TOTAL (shares==0) — apres que
    ///      _updateUserStateAfterWithdrawal a remis a zero ses fees/TW (donc plus rien a regler). `users` ne
    ///      grandit plus de facon monotone : la boucle de distribution disparue + ce pruning suppriment le DoS.
    function _unregisterUser(address u) private {
        uint256 idx1 = userIndexPlusOne[u];
        if (idx1 == 0) return; // pas dans le registre
        uint256 i = idx1 - 1;
        uint256 lastI = users.length - 1;
        if (i != lastI) {
            address last = users[lastI];
            users[i] = last;
            userIndexPlusOne[last] = i + 1;
        }
        users.pop();
        userIndexPlusOne[u] = 0;
    }

    // ===== WITHDRAW PROTOCOL FEES =====

    // ===== HELPERS =====

    function _calculateTotalValue() private view returns (uint256) {
        return getCurrentPortfolioValue();
    }

    function getCurrentPortfolioValue() public view returns (uint256) {
        try rangeManager.getCurrentBalances() returns (uint256 bal0, uint256 bal1) {
            try rangeManager.priceCache() returns (uint128 price0, uint128 price1, uint160, int24, uint64, bool valid) {
                if (!valid) return 0;

                // Decimales depuis RangeManager pour generaliser a toutes les paires
                // (anciennement 1e18 / 1e6 hardcodes pour WETH/USDC).
                RangeOperations.RangeConfig memory config = rangeManager.config();

                uint256 value0 = (bal0 * uint256(price0)) / (10 ** config.token0Decimals);
                uint256 value1 = (bal1 * uint256(price1)) / (10 ** config.token1Decimals);

                return value0 + value1;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    function _calculateDepositValue(uint256 amount0, uint256 amount1) private view returns (uint256) {
        try rangeManager.priceCache() returns (uint128 price0, uint128 price1, uint160, int24, uint64, bool valid) {
            if (!valid) return 0;

            // Récupérer les décimales depuis RangeManager
            RangeOperations.RangeConfig memory config = rangeManager.config();

            uint256 value0 = (amount0 * uint256(price0)) / (10 ** config.token0Decimals);
            uint256 value1 = (amount1 * uint256(price1)) / (10 ** config.token1Decimals);

            return value0 + value1;
        } catch {
            return 0;
        }
    }

    // ===== VIEW FONCTIONS =====

    function isAuthorizedRecipient(address recipient) external view returns (bool) {
        return authorizedRecipients[recipient];
    }

    function getPendingDepositsCount() external view returns (uint256) {
        return _pendingCount();
    }

    function getUserInfo(address user)
        external
        view
        returns (uint256 shares, uint256 valueUSD, uint256 pendingFees0, uint256 pendingFees1)
    {
        UserInfo memory info = userInfo[user];
        shares = info.shares;

        if (shares > 0 && totalShares > 0) {
            valueUSD = (_calculateTotalValue() * shares) / totalShares;

            // audit V1 (M3-B-fix) — fees pending = shares * accFeePerShare - debt (modele accFeePerShare).
            uint256 accrued0 = shares * accFeePerShare0;
            uint256 accrued1 = shares * accFeePerShare1;
            if (accrued0 > userFeeDebtToken0[user]) pendingFees0 = (accrued0 - userFeeDebtToken0[user]) / 1e36;
            if (accrued1 > userFeeDebtToken1[user]) pendingFees1 = (accrued1 - userFeeDebtToken1[user]) / 1e36;
        }
    }

    function estimateWithdrawAmounts(address user)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1)
    {
        UserInfo memory info = userInfo[user];
        if (info.shares == 0 || totalShares == 0) return (0, 0, 0, 0);
        (uint256 totalToken0, uint256 totalToken1) = rangeManager.getCurrentBalances();
        // Auto-compound: part proportionnelle du LP (inclut fees compoundees)
        amount0 = (totalToken0 * info.shares) / totalShares;
        amount1 = (totalToken1 * info.shares) / totalShares;
        // Fees bruts comptables pour affichage
        fees0 = info.totalFeesEarnedToken0;
        fees1 = info.totalFeesEarnedToken1;
    }

    /**
     * @notice Retourne les informations utilisateur avec fees comptables
     * @dev totalFeesEarnedToken0/1 (deja credites) + pendingFees (modele accFeePerShare : shares*acc - debt, pas encore credites)
     */
    function getUserInfoWithPendingFees(address user)
        external
        view
        returns (
            uint256 shares,
            uint256 depositedToken0,
            uint256 depositedToken1,
            uint256 depositedValueUSD,
            uint256 lastDepositTime,
            uint256 totalFeesToken0,
            uint256 totalFeesToken1,
            uint256 firstDepositTime
        )
    {
        UserInfo memory info = userInfo[user];
        shares = info.shares;
        depositedToken0 = info.depositedToken0;
        depositedToken1 = info.depositedToken1;
        depositedValueUSD = info.depositedValueUSD;
        lastDepositTime = info.lastDepositTime;
        firstDepositTime = info.firstDepositTime;

        if (info.shares > 0 && totalShares > 0) {
            // Fees deja creditees (comptable)
            totalFeesToken0 = info.totalFeesEarnedToken0;
            totalFeesToken1 = info.totalFeesEarnedToken1;

            // audit V1 (M3-B-fix) — pending = shares * accFeePerShare - debt (modele accFeePerShare), par token.
            uint256 accrued0 = info.shares * accFeePerShare0;
            uint256 accrued1 = info.shares * accFeePerShare1;
            if (accrued0 > userFeeDebtToken0[user]) totalFeesToken0 += (accrued0 - userFeeDebtToken0[user]) / 1e36;
            if (accrued1 > userFeeDebtToken1[user]) totalFeesToken1 += (accrued1 - userFeeDebtToken1[user]) / 1e36;
        } else {
            totalFeesToken0 = 0;
            totalFeesToken1 = 0;
        }
    }

    // ===== FONCTIONS DE RETRAITS ET DE COLLECTE =====

    /**
     * @notice Retourne le total des commissions envoyees au Treasury (comptable)
     */
    function getTotalCommissions() external view returns (uint256 total0, uint256 total1) {
        return (totalCommissionCollectedToken0, totalCommissionCollectedToken1);
    }

    /**
     * @notice Fonction de retrait utilisateurs
     */
    function _executeWithdrawFromRange(
        uint256 principal0, // part proportionnelle du user (calculee par _calculateWithdrawAmounts)
        uint256 principal1, // idem token1 — SÉCURITÉ: on borne l'envoi a ce principal (audit V1)
        address recipient,
        uint256 shareAmount,
        uint256 totalSharesBefore,
        bool isFullWithdraw
    ) private returns (uint256 amount0Sent, uint256 amount1Sent) {
        // Verifier que le recipient est autorise
        require(
            recipient == address(this) || recipient == msg.sender || authorizedRecipients[recipient],
            "Recipient not authorized"
        );

        uint256[] memory positions = rangeManager.getOwnerPositions();

        // ===== ETAPE 1 : CALCULER LA LIQUIDITE A RETIRER =====
        uint256 liquidityToRemove = 0;
        uint256 totalLiquidity = 0;
        uint256 tokenId = 0;

        if (positions.length > 0) {
            tokenId = positions[0];
            INonfungiblePositionManager positionManager = rangeManager.positionManager();
            (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(tokenId);
            totalLiquidity = uint256(liquidity);

            if (totalLiquidity > 0) {
                if (isFullWithdraw) {
                    liquidityToRemove = totalLiquidity;
                } else {
                    // Retirer un pourcentage de liquidité proportionnel aux shares
                    liquidityToRemove = (totalLiquidity * shareAmount) / totalSharesBefore;
                }
            }
        }

        // ===== ETAPE 1b : CRISTALLISER LES FEES AVANT DE RETIRER LE PRINCIPAL (audit M-01) =====
        // removeLiquidityForWithdraw fait decreaseLiquidity + collect(max,max), qui balaye aussi les fees
        // accrues avec le principal SANS recordFeesCollected. On collecte/comptabilise d'abord (commission
        // Treasury + accFeePerShare) ; le collect() suivant ne ramène plus que le principal.
        if (tokenId > 0) {
            rangeManager.collectFeesForVault();
        }

        // ===== ETAPE 2 : RETIRER LA LIQUIDITE SI NECESSAIRE =====
        if (liquidityToRemove > 0 && tokenId > 0) {
            rangeManager.removeLiquidityForWithdraw(tokenId, uint128(liquidityToRemove));
        }

        // ===== ETAPE 3 : TRANSFERER DEPUIS RANGEMANAGER VERS VAULT =====
        // SÉCURITÉ (audit V1) : on n'envoie QUE le principal proportionnel du user, borné par
        // la balance réellement disponible. Avant, on envoyait balanceOf(RM) ENTIER, ce qui
        // distribuait aussi les tokens libres non déployés (ex: un dépôt mono-token en attente)
        // au premier qui withdraw → un attaquant déposait des fonds restant libres puis récupérait
        // sa part + celle des autres. Le principal (= vaultSharesPercent% de getCurrentBalances,
        // qui inclut LP + tokens libres) est la juste part : full withdraw => principal=balance.
        uint256 realBalance0 = IERC20(token0).balanceOf(address(rangeManager));
        uint256 realBalance1 = IERC20(token1).balanceOf(address(rangeManager));
        uint256 toWithdraw0;
        uint256 toWithdraw1;
        if (isFullWithdraw) {
            // Full withdraw (dernier user / 100%) : il a droit a TOUT le restant (dust inclus).
            toWithdraw0 = realBalance0;
            toWithdraw1 = realBalance1;
        } else {
            // Withdraw partiel : strictement la juste part, bornee par le disponible.
            toWithdraw0 = principal0 < realBalance0 ? principal0 : realBalance0;
            toWithdraw1 = principal1 < realBalance1 ? principal1 : realBalance1;
        }

        // Transférer la juste part vers le Vault
        (amount0Sent, amount1Sent) = rangeManager.transferTokensForWithdraw(toWithdraw0, toWithdraw1, address(this));

        // ===== ETAPE 4 : SI LE RECIPIENT N'EST PAS LE VAULT, TRANSFERER DEPUIS LE VAULT =====
        if (recipient != address(this)) {
            if (amount0Sent > 0) {
                token0.safeTransfer(recipient, amount0Sent);
            }
            if (amount1Sent > 0) {
                token1.safeTransfer(recipient, amount1Sent);
            }
        }

        return (amount0Sent, amount1Sent);
    }

    // AUDIT (nettoyage code mort) : _estimateUncollectedFees + _calculateFeeGrowth RETIRÉS — n'étaient
    // appelés que par estimateTotalFees (elle-même retirée). Parité avec la pool DN.

    /**
     * @notice Collecte les fees non reclamees avant un retrait
     * @dev Commission deduite dans le RangeManager → Treasury. Fees nettes restent sur le RM.
     */
    function _handleUnclaimedFeesOnWithdraw(UserInfo storage, /* user */ uint256 /* shareAmount */ ) private {
        uint256[] memory positions = rangeManager.getOwnerPositions();
        if (positions.length == 0) return;
        rangeManager.collectFeesForVault();
        _updateUserFees(msg.sender);
    }

    /**
     * @notice Calcule les montants pour le retrait (auto-compound: commission deja au Treasury)
     */
    function _calculateWithdrawAmounts(uint256 shareAmount, uint256 totalSharesBefore)
        private
        view
        returns (uint256 commission0, uint256 commission1, uint256 principal0, uint256 principal1)
    {
        (uint256 totalToken0, uint256 totalToken1) = rangeManager.getCurrentBalances();
        commission0 = 0;
        commission1 = 0;
        principal0 = (totalToken0 * shareAmount) / totalSharesBefore;
        principal1 = (totalToken1 * shareAmount) / totalSharesBefore;
    }

    /**
     * @notice Execute le retrait et envoie les fonds (auto-compound: pas de fees separees)
     */
    function _executeWithdrawAndSend(
        uint256 principal0,
        uint256 principal1,
        uint256 shareAmount,
        uint256 totalSharesBefore,
        bool isFullWithdraw
    ) private returns (uint256 toSend0, uint256 toSend1) {
        // SÉCURITÉ (audit V1) : ne JAMAIS envoyer balanceOf(vault) entier — le vault détient aussi
        // les dépôts EN ATTENTE d'autres users (deposit() transfère sur le vault, le bot ne les forwarde
        // au RangeManager qu'au cycle suivant). Envoyer balanceOf entier permettrait à un shareholder
        // de voler le dépôt en attente d'une victime. On snapshot AVANT le retrait depuis le RM et on
        // n'envoie QUE le delta (= exactement les fonds retirés du RM pour CE withdraw).
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));

        _executeWithdrawFromRange(principal0, principal1, address(this), shareAmount, totalSharesBefore, isFullWithdraw);

        uint256 after0 = token0.balanceOf(address(this));
        uint256 after1 = token1.balanceOf(address(this));
        toSend0 = after0 > before0 ? after0 - before0 : 0;
        toSend1 = after1 > before1 ? after1 - before1 : 0;

        if (toSend0 > 0) token0.safeTransfer(msg.sender, toSend0);
        if (toSend1 > 0) token1.safeTransfer(msg.sender, toSend1);
    }

    // audit V1 (M3-B-fix4, retour Codex/Slither) : _calculateSendAmount() SUPPRIMEE — fonction morte (aucun
    // appelant). Nettoyage surface d'audit.

    /**
     * @notice Finalise le retrait en mettant à jour l'état
     */
    function _finalizeWithdrawal(UserInfo storage user, uint256 shareAmount, uint256, uint256, uint256, uint256)
        private
    {
        // audit V1 (M3-B-fix) : modele accFeePerShare -> plus de time-weighted global a maintenir.
        _updateUserStateAfterWithdrawal(user, shareAmount);
        totalShares -= shareAmount;
    }

    /**
     * @notice Met à jour l'état utilisateur après un retrait. Les fees ont deja ete reglees par
     *         _updateUserFees(msg.sender) en amont du withdraw (dette = ancien_solde * acc).
     */
    function _updateUserStateAfterWithdrawal(UserInfo storage user, uint256 shareAmount) private {
        user.shares -= shareAmount;

        if (user.shares == 0) {
            // Retrait total : tout a zero.
            user.depositedToken0 = 0;
            user.depositedToken1 = 0;
            user.depositedValueUSD = 0;
            user.totalFeesEarnedToken0 = 0;
            user.totalFeesEarnedToken1 = 0;
            user.firstDepositTime = 0;
            // audit V1 (M3-B) — dette a zero (shares==0) pour un re-depot propre + pruning O(1) du registre.
            userFeeDebtToken0[msg.sender] = 0;
            userFeeDebtToken1[msg.sender] = 0;
            _unregisterUser(msg.sender);
        } else {
            // Retrait partiel : reduire proportionnellement les compteurs comptables.
            uint256 percentWithdrawn = (shareAmount * 1e18) / (user.shares + shareAmount);
            user.depositedToken0 = (user.depositedToken0 * (1e18 - percentWithdrawn)) / 1e18;
            user.depositedToken1 = (user.depositedToken1 * (1e18 - percentWithdrawn)) / 1e18;
            user.depositedValueUSD = (user.depositedValueUSD * (1e18 - percentWithdrawn)) / 1e18;
            user.totalFeesEarnedToken0 = (user.totalFeesEarnedToken0 * (1e18 - percentWithdrawn)) / 1e18;
            user.totalFeesEarnedToken1 = (user.totalFeesEarnedToken1 * (1e18 - percentWithdrawn)) / 1e18;

            // audit V1 (M3-B-fix) — RE-CHECKPOINT la dette sur le NOUVEAU solde : debt = shares * acc.
            userFeeDebtToken0[msg.sender] = user.shares * accFeePerShare0;
            userFeeDebtToken1[msg.sender] = user.shares * accFeePerShare1;
        }
    }

    // audit V1 (M3-B-fix4, retour Codex/Slither) : _collectAllFeesInternal() SUPPRIMEE — fonction morte (aucun
    // appelant) qui contenait ENCORE l'ancien pattern dangereux decreaseLiquidity(0) + try/catch collect (no-op
    // trompeur + collecte non fail-closed). La cristallisation reelle passe par rangeManager.collectFeesForVault()
    // (deposit & withdraw), deja fail-closed. On retire ce code mort pour eviter toute reintroduction future.

    // ===== FONCTIONS DE CONFIGURATION =====

    function updateCommissionRate(uint256 newRate) external onlyOwner {
        require(newRate <= 3000, "E14"); // Max 30%
        uint256 oldRate = commissionRate;
        commissionRate = newRate;
        emit CommissionRateUpdated(oldRate, newRate);
    }

    function updateTreasuryAddress(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "E17");
        address oldTreasury = treasuryAddress;
        treasuryAddress = newTreasury;
        emit TreasuryAddressUpdated(oldTreasury, newTreasury);
    }

    function setMinDepositUSD(uint256 _newMinimum) external onlyOwner {
        // audit V1 (M3-B-fix4, Slither) : require(_newMinimum >= 0) RETIRE — tautologie sur un uint256
        // (toujours >= 0). Aligne sur la pool DN (coherence std/DN).
        uint256 oldMinimum = minDepositUSD;
        minDepositUSD = _newMinimum;
        emit MinDepositUpdated(oldMinimum, _newMinimum);
    }

    /// @notice Age max du cache prix (s) accepte par processDepositPermissionless. Gouvernance.
    function setDepositMaxCacheAge(uint256 _maxAge) external onlyOwner {
        require(_maxAge >= 60 && _maxAge <= 86400, "E18");
        depositMaxCacheAge = _maxAge;
    }

    function setBotModule(address _module) external onlyOwner {
        require(_module != address(0), "E19");
        address oldModule = botModule;
        botModule = _module;
        emit BotModuleUpdated(oldModule, _module);
    }

    /// @notice Configure la Safe qui conserve les actions de secours en Phase 2.
    /// @dev Séparé de owner/gouvernance : un transfert futur vers timelock ne doit pas bloquer le dépannage.
    function setEmergencySafe(address newSafe) external onlyOwner {
        require(newSafe != address(0), "E19");
        emit EmergencySafeUpdated(emergencySafe, newSafe);
        emergencySafe = newSafe;
    }

    /// @notice Recover non-protected tokens (airdrops, erroneous transfers, donations)
    /// @dev Blocks token0/token1 (user funds, cannot be moved). Destination is flexible:
    ///      refund the sender, send to Treasury, or keep for protocol use depending on context.
    ///      Each rescue emits TokenRescued for full on-chain traceability.
    /// @param tokenAddr Token to rescue (must not be token0 or token1)
    /// @param to Recipient address
    /// @param amount Amount to rescue
    function rescueToken(address tokenAddr, address to, uint256 amount) external onlyEmergencySafe {
        require(tokenAddr != address(token0) && tokenAddr != address(token1), "Protected");
        require(to != address(0), "Invalid recipient");
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit TokenRescued(tokenAddr, to, amount);
    }

    // ===== FONCTIONS DE VUE =====

    function getCommissionStats()
        external
        view
        returns (
            uint256 pendingToken0,
            uint256 pendingToken1,
            uint256 totalCollectedToken0,
            uint256 totalCollectedToken1,
            uint256 currentRate
        )
    {
        return (
            0, // plus de pending — commissions envoyees directement au Treasury
            0,
            totalCommissionCollectedToken0,
            totalCommissionCollectedToken1,
            commissionRate
        );
    }

    // ===== FONCTIONS DE RECUPERATION USER ET TOKENS PERDUS =====

    /**
     * @notice Recupere les fonds d'un utilisateur depuis RangeManager ou le Vault
     * @notice Precision : Les tokens de pool ne peuvent etre recuperes que par le depositaire
     * @param userAddress L'adresse de l'utilisateur a recuperer
     * @dev audit V1 (M3-B-fix5, retour Codex — Low gas) : ce chemin Safe-only ITERE sur la file des depots EN
     *      ATTENTE (pendingDeposits, de _pendingHead a la fin). Cout O(taille file). En pratique la file est
     *      drainee a chaque cycle bot (~10 min) donc elle reste petite ; mais si elle devait devenir tres
     *      grande, DRAINER la file (processSingleDeposit/processDepositPermissionless) AVANT d'appeler cette
     *      fonction d'urgence. Non bloquant (pas le chemin normal), pas optimise on-chain pour ne pas alourdir
     *      le bytecode du vault (contrainte EIP-170).
     */
    function EmergencyRecoverUser(address userAddress) external onlyEmergencySafe nonReentrant {
        require(userAddress != address(0), "E43");

        UserInfo storage user = userInfo[userAddress];
        uint256 userShares = user.shares;
        uint256 totalSharesBefore = totalShares;

        // Verifier que l'utilisateur a des fonds ou des depots en attente
        require(userShares > 0 || hasPendingDeposit[userAddress], "E44");
        uint256 userAmount0 = 0;
        uint256 userAmount1 = 0;
        uint256 vaultBalance0 = 0;
        uint256 vaultBalance1 = 0;
        uint256 neededFromRange0 = 0;
        uint256 neededFromRange1 = 0;

        // 1. CALCULER LA PART DE L'UTILISATEUR
        if (userShares > 0) {
            require(rangeManager.getOwnerPositions().length == 0, "E46");
            // SÉCURITÉ (audit V1) : balanceOf(vault) inclut les dépôts EN ATTENTE de TOUS les users
            // (deposit() transfère sur le vault avant traitement). Il faut les EXCLURE du calcul
            // proportionnel, sinon un user récupérerait une part d'un total gonflé par les pending
            // d'autrui (même classe de bug que le sweep balanceOf au withdraw). Les pending du user
            // lui-même sont ajoutés séparément à l'étape 3.
            uint256 pendingTotal0 = 0;
            uint256 pendingTotal1 = 0;
            // Itérer sur les dépôts EN ATTENTE uniquement (de _pendingHead à la fin) — audit V1 DoS gas A.
            uint256 pendingLen = pendingDeposits.length;
            for (uint256 i = _pendingHead; i < pendingLen; i++) {
                pendingTotal0 += pendingDeposits[i].amount0;
                pendingTotal1 += pendingDeposits[i].amount1;
            }

            // Recuperer les balances totales (Vault HORS pending + RangeManager)
            uint256 rawVault0 = token0.balanceOf(address(this));
            uint256 rawVault1 = token1.balanceOf(address(this));
            vaultBalance0 = rawVault0 > pendingTotal0 ? rawVault0 - pendingTotal0 : 0;
            vaultBalance1 = rawVault1 > pendingTotal1 ? rawVault1 - pendingTotal1 : 0;

            uint256 rangeBalance0 = token0.balanceOf(address(rangeManager));
            uint256 rangeBalance1 = token1.balanceOf(address(rangeManager));

            // Calculer la part proportionnelle
            uint256 totalBalance0 = vaultBalance0 + rangeBalance0;
            uint256 totalBalance1 = vaultBalance1 + rangeBalance1;

            userAmount0 = (totalBalance0 * userShares) / totalSharesBefore;
            userAmount1 = (totalBalance1 * userShares) / totalSharesBefore;

            // 2. ReCUPeRER LES FONDS DEPUIS RANGEMANAGER SI NeCESSAIRE
            // Calculer combien on doit recuperer depuis RangeManager
            if (userAmount0 > vaultBalance0) {
                neededFromRange0 = userAmount0 - vaultBalance0;
                // S'assurer de ne pas demander plus que ce qui est disponible
                if (neededFromRange0 > rangeBalance0) {
                    neededFromRange0 = rangeBalance0;
                }
            }

            if (userAmount1 > vaultBalance1) {
                neededFromRange1 = userAmount1 - vaultBalance1;
                // S'assurer de ne pas demander plus que ce qui est disponible
                if (neededFromRange1 > rangeBalance1) {
                    neededFromRange1 = rangeBalance1;
                }
            }
        }

        // 3. GeRER LES DePoTS EN ATTENTE (de _pendingHead à la fin — audit V1 DoS gas A)
        if (hasPendingDeposit[userAddress]) {
            uint256 len = pendingDeposits.length;
            for (uint256 i = _pendingHead; i < len; i++) {
                if (pendingDeposits[i].user == userAddress) {
                    userAmount0 += pendingDeposits[i].amount0;
                    userAmount1 += pendingDeposits[i].amount1;

                    // Swap-and-pop avec le DERNIER élément (toujours dans la zone active [head, len)).
                    if (i < len - 1) {
                        pendingDeposits[i] = pendingDeposits[len - 1];
                    }
                    pendingDeposits.pop();
                    break;
                }
            }
            hasPendingDeposit[userAddress] = false;
            delete userFeeDebtToken0[userAddress];
            delete userFeeDebtToken1[userAddress];
        }

        // 4. METTRE a JOUR LES STATS AVANT LES APPELS EXTERNES
        if (userShares > 0) {
            totalShares = totalSharesBefore > userShares ? totalSharesBefore - userShares : 0;

            // Reset les infos de l'utilisateur
            delete userInfo[userAddress];
            delete userFeeDebtToken0[userAddress];
            delete userFeeDebtToken1[userAddress];
            // audit V1 (M3-B) : retirer aussi du registre actif (pruning O(1)) — coherence avec le retrait total.
            _unregisterUser(userAddress);
        }

        // 5. Recuperer depuis RangeManager si necessaire
        if (neededFromRange0 > 0 || neededFromRange1 > 0) {
            // Appeler la fonction emergencyWithdrawForUser dans RangeManager
            try IRangeManager(address(rangeManager)).emergencyWithdrawForUser(
                neededFromRange0, neededFromRange1, address(this)
            ) returns (uint256 received0, uint256 received1) {
                // Ajuster les montants si on n'a pas tout reçu
                if (received0 < neededFromRange0) {
                    userAmount0 = vaultBalance0 + received0;
                }
                if (received1 < neededFromRange1) {
                    userAmount1 = vaultBalance1 + received1;
                }
            } catch {
                // Si l'appel echoue, utiliser seulement ce qui est dans le vault
                userAmount0 = userAmount0 > vaultBalance0 ? vaultBalance0 : userAmount0;
                userAmount1 = userAmount1 > vaultBalance1 ? vaultBalance1 : userAmount1;
            }
        }

        // 6. ENVOYER LES FONDS a L'UTILISATEUR
        uint256 finalBalance0 = token0.balanceOf(address(this));
        uint256 finalBalance1 = token1.balanceOf(address(this));

        uint256 toSend0 = userAmount0 > finalBalance0 ? finalBalance0 : userAmount0;
        uint256 toSend1 = userAmount1 > finalBalance1 ? finalBalance1 : userAmount1;

        if (toSend0 > 0) {
            token0.safeTransfer(userAddress, toSend0);
        }
        if (toSend1 > 0) {
            token1.safeTransfer(userAddress, toSend1);
        }

        emit EmergencyUserRecovered(userAddress, toSend0, toSend1, userShares);
    }

    /**
     * @notice - Burn le NFT en cas de problème sur la position
     * @dev Les fonds restent dans RangeManager apres le burn en attente d'un nouveau MINT
     */
    function EmergencyBurnPositions() external onlyEmergencySafe nonReentrant {
        // 1. Recuperer toutes les positions NFT
        uint256[] memory positions = rangeManager.getOwnerPositions();

        if (positions.length == 0) {
            revert("No positions to burn");
        }

        // 2. Pour chaque position, retirer la liquidite puis burn le NFT
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 tokenId = positions[i];

            // Appeler la fonction burnPosition dans RangeManager
            // Cette fonction doit retirer la liquidite et burn le NFT
            try IRangeManager(address(rangeManager)).burnPosition(tokenId) {
                emit PositionBurned(tokenId, msg.sender);
            } catch Error(string memory reason) {
                emit BurnFailed(tokenId, reason);
            } catch {
                emit BurnFailed(tokenId, "Unknown error");
            }
        }

        // 3. Les fonds restent dans RangeManager
        // Pas de transfert vers le vault ou la safe

        // 4. Conserver l'association avec les utilisateurs
        // Les userInfo restent intacts pour tracer qui a depose quoi

        emit AllPositionsBurned(positions.length, msg.sender);
    }

    /**
     * @notice Retourne le nombre total d'utilisateurs avec des shares
     */
    function getUserCount() external view returns (uint256) {
        return users.length;
    }

    /**
     * @notice Retourne l'adresse d'un utilisateur par son index
     */
    function getUserAtIndex(uint256 index) external view returns (address) {
        require(index < users.length, "Index out of bounds");
        return users[index];
    }
}
