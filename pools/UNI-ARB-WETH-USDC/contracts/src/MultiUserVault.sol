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
        uint16 _rangeMultiplicatorBps,
        uint16 _rangeMinBps,
        uint16 _rangeMaxBps
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
    function mintInitialPosition() external returns (uint256 tokenId, uint128 liquidity);
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

interface IBotNav {
    function getOracleLpValueUsd() external view returns (uint256);
}

contract MultiUserVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OnlyOperationalExecutor();
    error OnlyEmergencySafe();
    error FirstDepositTooSmall();
    error ProtectedPoolToken();
    error InvalidRecipient();
    error NoPositionToBurn();
    error UserIndexOutOfBounds();

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
    mapping(address => uint256) private _pendingIndexPlusOne;
    uint256 private _pendingTotal0;
    uint256 private _pendingTotal1;

    /// @dev Nombre de dépôts EN ATTENTE (non encore traités) = longueur - tête.
    function _pendingCount() internal view returns (uint256) {
        uint256 len = pendingDeposits.length;
        return len > _pendingHead ? len - _pendingHead : 0;
    }

    function _removePending(uint256 index, PendingDeposit memory pd) private {
        hasPendingDeposit[pd.user] = false;
        delete _pendingIndexPlusOne[pd.user];
        _pendingTotal0 -= pd.amount0;
        _pendingTotal1 -= pd.amount1;

        uint256 head = _pendingHead;
        uint256 last = pendingDeposits.length - 1;
        if (index == head) {
            _pendingHead = head + 1;
        } else {
            if (index != last) {
                PendingDeposit memory moved = pendingDeposits[last];
                pendingDeposits[index] = moved;
                _pendingIndexPlusOne[moved.user] = index + 1;
            }
            pendingDeposits.pop();
        }

        if (_pendingHead >= pendingDeposits.length) {
            delete pendingDeposits;
            _pendingHead = 0;
        }
    }

    uint256 public totalShares;
    uint256 private constant DEAD_SHARES = 1_000_000; // Brûlées au premier dépôt (anti-inflation attack)

    // Systeme de tracking des fees
    mapping(address => uint256) public userFeeDebtToken0;
    mapping(address => uint256) public userFeeDebtToken1;

    FeeSnapshot[] public feeHistory;

    uint256 public lastCollectedFees0;
    uint256 public lastCollectedFees1;

    bool private _processingRebalance;
    uint64 private _rebalanceStartedAt;

    uint256 public minDepositUSD;
    uint256 public maxDepositUsd; // USD 8 decimals, 0 only before deployment batch sets the production cap
    address public emergencySafe;

    // Age max (secondes) du cache prix accepte par processDepositPermissionless (anti-prix-perime).
    // Reglable par la Safe sans redeploiement. Defaut 300s, aligne bot/keepers.
    uint256 public depositMaxCacheAge = 300;
    uint256 public depositRefundDelay = 7 days;

    // Systeme de tracking lazy des fees nettes par share
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
    event DepositRefunded(address indexed user, uint256 amount0, uint256 amount1);
    event DepositRefundDelayUpdated(uint256 oldDelay, uint256 newDelay);
    // event DepositsProcessed supprimé avec la fonction batch processPendingDeposits (audit V1)
    event FeesDistributed(uint256 fees0, uint256 fees1);
    event CommissionRateUpdated(uint256 oldRate, uint256 newRate);
    event RangeManagerSet(address indexed rangeManager);
    event EmergencyUserRecovered(
        address indexed user, uint256 amount0Recovered, uint256 amount1Recovered, uint256 sharesRemoved
    );
    event PositionBurned(uint256 indexed tokenId, address indexed executor);
    event AllPositionsBurned(uint256 positionCount, address indexed executor);
    event MinDepositUpdated(uint256 oldMinimum, uint256 newMinimum);
    event MaxDepositUpdated(uint256 oldMaximum, uint256 newMaximum);
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
        if (msg.sender != owner() && msg.sender != botModule && msg.sender != address(rangeManager)) {
            revert OnlyOperationalExecutor();
        }
        _;
    }

    modifier onlyEmergencySafe() {
        if (msg.sender != emergencySafe) revert OnlyEmergencySafe();
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

        require(_minDepositUSD > 0, "E23");
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
        uint16 _rangeMultiplicatorBps,
        uint16 _rangeMinBps,
        uint16 _rangeMaxBps
    ) external onlyOwner {
        IRangeManagerExtended(address(rangeManager)).setDynamicRangeConfig(
            _enabled,
            _maxSnapshotsPerDay,
            _volatMoyDay,
            _volatTrimDay,
            _rangeStepBps,
            _rangeMultiplicatorBps,
            _rangeMinBps,
            _rangeMaxBps
        );
    }

    /// @notice Phase 2 governance relay for RangeManager settings.
    /// @dev RangeManager is owned by this Vault. Once the Vault owner is a timelock and Safe ops are disabled
    ///      on RangeManager, governance can still execute RangeManager setters through this relay.
    function executeRangeManagerGovernance(bytes calldata data) external onlyOwner returns (bytes memory result) {
        require(data.length >= 4, "E20");
        bytes4 selector = bytes4(data[:4]);
        require(_isAllowedRangeManagerGovernanceSelector(selector), "E20");
        (bool ok, bytes memory ret) = address(rangeManager).call(data);
        require(ok, "E20");
        return ret;
    }

    function _isAllowedRangeManagerGovernanceSelector(bytes4 selector) private pure returns (bool) {
        return selector == bytes4(keccak256("configureRanges(uint16,uint16)"))
            || selector == bytes4(keccak256("setDynamicRangeConfig(bool,uint8,uint8,uint8,uint16,uint16,uint16,uint16)"))
            || selector == bytes4(keccak256("setDynamicRangeEnabled(bool)"))
            || selector == bytes4(keccak256("setRangeMultiplicator(uint16)"))
            || selector == bytes4(keccak256("configureSlippage(uint24)"))
            || selector == bytes4(keccak256("configureTolerance(uint16)"))
            || selector == bytes4(keccak256("configureProtections(bool,bool,bool,uint16)"))
            || selector == bytes4(keccak256("setOracleParams(uint16,uint32,uint32)"))
            || selector == bytes4(keccak256("configurePriceFeeds(address,address,address)"))
            || selector == bytes4(keccak256("setInitMultiSwapTvl(uint256)"))
            || selector == bytes4(keccak256("setTreasuryAddress(address)"))
            || selector == bytes4(keccak256("setSafeAddress(address)"))
            || selector == bytes4(keccak256("setAuthorizedExecutor(address,bool)"));
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

        rangeManager.refreshPriceCache();
        (uint128 p0, uint128 p1,,, uint64 ts, bool valid) = rangeManager.priceCache();
        require(valid && p0 > 0 && p1 > 0 && block.timestamp - uint256(ts) <= depositMaxCacheAge, "E38");

        // Vérifier les bornes dépôt sur la valeur oracle avant transfert.
        if (minDepositUSD > 0 || maxDepositUsd > 0) {
            uint256 depositValueUSD = _calculateDepositValue(amount0, amount1);
            if (minDepositUSD > 0) require(depositValueUSD >= minDepositUSD, "E23");
            if (maxDepositUsd > 0) require(depositValueUSD <= maxDepositUsd, "E26");
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
        _pendingIndexPlusOne[msg.sender] = pendingDeposits.length;
        _pendingTotal0 += amount0;
        _pendingTotal1 += amount1;

        emit PendingDepositAdded(msg.sender, amount0, amount1);
    }

    /// @notice Rembourse le dépôt en tête de file s'il reste inexécutable trop longtemps.
    /// @dev Permissionless et destination figée au déposant : libère la queue sans pouvoir détourner de fonds.
    function refundStaleHeadDeposit() external nonReentrant {
        require(_pendingCount() > 0, "E24");
        PendingDeposit memory pd = pendingDeposits[_pendingHead];
        require(block.timestamp >= pd.timestamp + depositRefundDelay, "E_NOT_REFUNDABLE");

        _removePending(_pendingHead, pd);

        if (pd.amount0 > 0) token0.safeTransfer(pd.user, pd.amount0);
        if (pd.amount1 > 0) token1.safeTransfer(pd.user, pd.amount1);

        emit DepositRefunded(pd.user, pd.amount0, pd.amount1);
    }

    // ===== PROCESS DEPOSITS ET WITHDRAW =====

    // SÉCURITÉ (audit V1) : la fonction batch processPendingDeposits() a été SUPPRIMÉE. Elle figeait
    // currentTotalValue avant la boucle tout en incrémentant totalShares à chaque itération, ce qui
    // sur-mintait des shares aux dépôts tardifs d'un même lot (dilution des holders existants). Elle
    // était `onlyBot` mais le selector restait whitelisté dans le module → atteignable par une clé bot
    // compromise. Le traitement des dépôts se fait désormais UNIQUEMENT un par un. Le flux public/bot/keepers
    // de production est processDepositPermissionless() (swap + mint/add atomiques). processSingleDeposit()
    // reste un chemin onlyBot historique non whitelisté module : ne pas l'utiliser comme flux keeper normal.
    // Tous recalculent la valeur du vault à CHAQUE dépôt (accounting juste).

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

    /// @notice Plan de swap du PROCHAIN dépôt (pool standard), isolé des donations, dust et fees historiques.
    ///         Ratio cible = celui du NFT EXISTANT (addLiquidityToPosition ajoute à CE range), pas le range cible
    ///         dynamique. À utiliser par les keepers/bot pour processDepositPermissionless.
    /// @return zeroForOne true si swap token0→token1 ; amountIn en unités natives (0 = pas de swap).
    function getDepositSwapParams() external view returns (bool zeroForOne, uint256 amountIn) {
        if (_pendingCount() == 0) return (false, 0);
        PendingDeposit memory pd = pendingDeposits[_pendingHead];
        // Calcul déporté en library (EIP-170 — le Vault std est serré). La library lit priceCache/config/ratio
        // NFT du RangeManager et ne dimensionne le swap que sur l'apport courant.
        return RangeOperations.depositSwapParams(address(rangeManager), pd.amount0, pd.amount1);
    }

    /// @notice Cristallise les fees LP avant de calculer un plan de dépôt.
    /// @dev Permissionless/no-bounty. Utile si des fees latentes déséquilibrent les soldes libres du RM :
    ///      bot/keepers peuvent appeler ceci, puis relire getDepositSwapParams() avant processDepositPermissionless().
    function syncFeesForDeposits() external nonReentrant {
        rangeManager.collectFeesForVault();
    }

    /**
     * @notice Traite UN SEUL dépôt (le premier de la queue)
     * @dev Chemin onlyBot historique, non whitelisté dans SecureBotModule. Le flux de production bot/keepers
     *      utilise processDepositPermissionless(), qui fait swaps + mint/add en une transaction atomique.
     *      Chaque utilisateur paie ses propres frais de swap proportionnels à son dépôt
     */
    function processSingleDeposit() external onlyBot nonReentrant {
        require(_pendingCount() > 0, "E24");
        bool hasPosition = rangeManager.getOwnerPositions().length > 0;
        if (hasPosition) {
            rangeManager.collectFeesForVault();
        }
        (PendingDeposit memory pd, uint256 depositValue, uint256 valueBefore, uint256 sharesBefore) =
            _processOneDeposit();
        if (hasPosition) rangeManager.addLiquidityToPosition();
        else rangeManager.mintInitialPosition();
        _finalizeProcessedDeposit(pd, depositValue, 0, valueBefore, sharesBefore);
    }

    /**
     * @notice Prepare UN depot de la file (premier element), sans minter les shares.
     * @dev H-01: les shares sont finalisees APRES swaps/addLiquidity afin que le slippage reel du
     *      depot soit impute au deposant, pas socialise aux holders existants.
     */
    function _processOneDeposit()
        private
        returns (PendingDeposit memory pd, uint256 depositValue, uint256 currentTotalValue, uint256 totalSharesBefore)
    {
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
            (,,,,, bool _valid) = rangeManager.priceCache();
            require(_valid, "E38"); // cache invalidé (déviation pool/oracle ou feed stale) -> on bloque le mint
        }

        // Récupérer le premier dépôt EN ATTENTE (tête de file = _pendingHead)
        pd = pendingDeposits[_pendingHead];

        currentTotalValue = _calculateTotalValue();
        depositValue = _calculateDepositValue(pd.amount0, pd.amount1);
        totalSharesBefore = totalShares;
        if (totalSharesBefore > DEAD_SHARES) {
            require(currentTotalValue > 0, "E25");
            require(depositValue > 0, "E_ZERO_VALUE"); // audit V1 (Medium) : pas de dépôt sans valeur
        } else {
            require(depositValue > 0, "E_ZERO_VALUE");
        }

        // Envoyer les fonds de CE DEPOT UNIQUEMENT au RangeManager
        if (pd.amount0 > 0) {
            token0.safeTransfer(address(rangeManager), pd.amount0);
        }
        if (pd.amount1 > 0) {
            token1.safeTransfer(address(rangeManager), pd.amount1);
        }

        // Retirer ce dépôt de la queue : avancer la tête (O(1), audit V1 — DoS gas A) au lieu du shift O(n).
        _removePending(_pendingHead, pd);

        return (pd, depositValue, currentTotalValue, totalSharesBefore);
    }

    function _finalizeProcessedDeposit(
        PendingDeposit memory pd,
        uint256 depositValue,
        uint256 swapLossUsd,
        uint256 currentTotalValue,
        uint256 totalSharesBefore
    ) private returns (uint256 sharesToMint) {
        uint256 creditedValue = depositValue > swapLossUsd ? depositValue - swapLossUsd : 0;
        require(creditedValue > 0, "E_ZERO_VALUE");

        if (totalSharesBefore <= DEAD_SHARES) {
            totalShares = 0;
            // Include any pre-mint protocol value in the initial share base. With no live user shares,
            // this preserves the initial share price and prevents dust from freezing the first mint.
            sharesToMint = (creditedValue + currentTotalValue) * 1e10;
            if (sharesToMint <= DEAD_SHARES) revert FirstDepositTooSmall();
            sharesToMint -= DEAD_SHARES;
            totalShares = DEAD_SHARES;
        } else {
            sharesToMint = (creditedValue * totalSharesBefore) / currentTotalValue;
            require(sharesToMint > 0, "E_ZERO_SHARES");
        }

        UserInfo storage user = userInfo[pd.user];
        _updateUserFees(pd.user);
        if (user.shares == 0) user.firstDepositTime = block.timestamp;

        user.shares += sharesToMint;
        user.depositedToken0 += pd.amount0;
        user.depositedToken1 += pd.amount1;
        user.depositedValueUSD += creditedValue;
        user.lastDepositTime = block.timestamp;
        user.lastDepositBlock = block.number;
        _registerUser(pd.user);

        userFeeDebtToken0[pd.user] = user.shares * accFeePerShare0;
        userFeeDebtToken1[pd.user] = user.shares * accFeePerShare1;
        totalShares += sharesToMint;

        emit Deposit(pd.user, pd.amount0, pd.amount1, sharesToMint);
    }

    /**
     * @notice Traite UN depot de la file de maniere PERMISSIONLESS et ATOMIQUE.
     * @dev Decentralise le dernier maillon : n'importe qui (keeper) peut convertir un depot en file
     *      en liquidite LP, sans le bot du fondateur. En UNE tx : refresh oracle -> calcul shares
     *      (oracle) -> transfert fonds au RM -> swaps bornes oracle (anti-MEV) -> addLiquidity ->
     *      deposit bounty. Verrou _processingRebalance pose pendant toute la fonction (un withdraw
     *      concurrent revert E32). Si aucune position n'existe encore, seul le botModule/owner peut
     *      traiter le depot initial et minter la premiere position dans cette meme transaction.
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
        require(!_processingRebalance, "E32");
        // 1. File non vide (anti-drain bounty : on ne paie que sur depot reel)
        require(_pendingCount() > 0, "E24");
        // 2. Etat LP : si aucun NFT n'existe, seule l'execution botModule/owner peut minter la position initiale.
        //    Les keepers anonymes gardent le traitement permissionless des depots de croissance apres creation du NFT.
        uint256[] memory positions = rangeManager.getOwnerPositions();
        bool hasPosition = positions.length > 0;
        if (!hasPosition) {
            require(msg.sender == botModule || msg.sender == owner(), "E71");
        }
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
        if (hasPosition) rangeManager.collectFeesForVault();
        PendingDeposit memory pdPlan = pendingDeposits[_pendingHead];
        rangeManager.validateDepositSwapPlan(
            pdPlan.amount0, pdPlan.amount1, swapAmountsIn, minAmountsOut, tokenIn, tokenOut
        );
        // 4. VERROU (un withdraw concurrent revert E32 ; pose pendant toute la modification de position)
        _processingRebalance = true;
        _rebalanceStartedAt = uint64(block.timestamp);

        // 5. Transfert des fonds au RangeManager. Shares finalisees APRES swaps/addLiquidity (H-01).
        (PendingDeposit memory pd, uint256 depositValue, uint256 valueBefore, uint256 sharesBefore) =
            _processOneDeposit();

        // 6. Swaps de reequilibrage bornes par l'oracle (anti-sandwich) + cap par chunk
        uint256 n = swapAmountsIn.length;
        uint256 totalSwapLossUsd;
        if (n > 0) {
            for (uint256 i = 0; i < n; i++) {
                uint256 amountOut = rangeManager.executeSwap(tokenIn, tokenOut, swapAmountsIn[i], minAmountsOut[i]);
                totalSwapLossUsd += _swapLossUsd(tokenIn == address(token0), swapAmountsIn[i], amountOut);
            }
        }

        // 7. Ajouter a la position existante, ou minter la position initiale en atomique bot-only.
        if (hasPosition) rangeManager.addLiquidityToPosition();
        else rangeManager.mintInitialPosition();

        _finalizeProcessedDeposit(pd, depositValue, totalSwapLossUsd, valueBefore, sharesBefore);

        // 8. DEVERROU
        _processingRebalance = false;
        _rebalanceStartedAt = 0;

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
        require(!_processingRebalance, "E32");
        _processingRebalance = true;
        _rebalanceStartedAt = uint64(block.timestamp);
    }

    function endRebalance() external {
        if (
            msg.sender != owner() && msg.sender != botModule && msg.sender != address(rangeManager)
                && msg.sender != emergencySafe
        ) revert OnlyOperationalExecutor();
        _processingRebalance = false;
        _rebalanceStartedAt = 0;
    }

    function isRebalancing() external view returns (bool) {
        return _processingRebalance;
    }

    function getRebalanceLockStatus() external view returns (bool locked, uint64 startedAt) {
        return (_processingRebalance, _rebalanceStartedAt);
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
        require(!_processingRebalance, "E32");
        UserInfo storage user = userInfo[msg.sender];
        require(user.shares >= shareAmount && shareAmount > 0 && totalShares > 0, "E33");
        // Anti-flash-loan: refuse tout withdraw dans le meme bloc que le processing du dernier
        // depot de l'utilisateur. Casse l'atomicite requise par l'exploit (V1+V3 audit).
        require(block.number > user.lastDepositBlock, "E_SAME_BLOCK");
        _requireWithdrawalAllowed(user.lastDepositTime);

        // SÉCURITÉ (audit V1 — High/Medium) : le burn de liquidité utilise désormais des amountMin
        // dérivés du slot0 live et bornés par maxSlippageBps. On garde en plus le check pool/oracle
        // live pour refuser un withdraw sur un slot0 manipulé ou divergent.
        // V3-H1 : REFRESH d'abord (slot0+oracle LIVE), updatePriceCache invalide le cache si déviation. Coh. DN.
        {
            rangeManager.refreshPriceCache();
            (,,,,, bool _valid) = rangeManager.priceCache();
            require(_valid, "E38"); // cache invalidé (déviation pool/oracle ou feed stale) -> on bloque le retrait
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
        address module = botModule;
        if (module == address(0)) return 0;
        try IBotNav(module).getOracleLpValueUsd() returns (uint256 valueUsd) {
            return valueUsd;
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

    function _swapLossUsd(bool tokenInIsToken0, uint256 amountIn, uint256 amountOut) private view returns (uint256) {
        (uint128 price0, uint128 price1,,,, bool valid) = rangeManager.priceCache();
        require(valid, "E38");
        RangeOperations.RangeConfig memory config = rangeManager.config();

        uint256 valueIn;
        uint256 valueOut;
        if (tokenInIsToken0) {
            valueIn = (amountIn * uint256(price0)) / (10 ** config.token0Decimals);
            valueOut = (amountOut * uint256(price1)) / (10 ** config.token1Decimals);
        } else {
            valueIn = (amountIn * uint256(price1)) / (10 ** config.token1Decimals);
            valueOut = (amountOut * uint256(price0)) / (10 ** config.token0Decimals);
        }
        return valueIn > valueOut ? valueIn - valueOut : 0;
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
        // Fees nettes comptabilisees: creditees + pending lazy. Les fees NFT non collectees
        // restent exclues jusqu'a leur cristallisation par collectFeesForVault().
        (fees0, fees1) = _currentUserFees(user);
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

        (totalFeesToken0, totalFeesToken1) = _currentUserFees(user);
    }

    function _currentUserFees(address user) private view returns (uint256 fees0, uint256 fees1) {
        UserInfo storage info = userInfo[user];
        uint256 shares = info.shares;
        if (shares == 0 || totalShares == 0) return (0, 0);

        fees0 = info.totalFeesEarnedToken0;
        fees1 = info.totalFeesEarnedToken1;
        uint256 accrued0 = shares * accFeePerShare0;
        uint256 accrued1 = shares * accFeePerShare1;
        if (accrued0 > userFeeDebtToken0[user]) fees0 += (accrued0 - userFeeDebtToken0[user]) / 1e36;
        if (accrued1 > userFeeDebtToken1[user]) fees1 += (accrued1 - userFeeDebtToken1[user]) / 1e36;
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
                    // Une unité est le plafond d'arrondi sûr : les transferts restent bornés aux montants
                    // proportionnels principal0/principal1, donc l'excédent éventuel demeure au RangeManager.
                    if (liquidityToRemove == 0) liquidityToRemove = 1;
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

        // Une fois le dernier utilisateur sorti, le NFT vide doit aussi quitter le PositionManager et le
        // tracking RangeManager. Le prochain dépôt repassera ainsi par un mint initial propre.
        if (isFullWithdraw && tokenId > 0) rangeManager.burnPosition(tokenId);

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

    function updateCommissionRate(uint256 newRate) external onlyOwner nonReentrant {
        require(newRate <= 3000, "E14"); // Max 30%
        uint256 oldRate = commissionRate;
        // Crystallize all fees already earned by the NFT while the old rate is still active.
        // The RangeManager is fail-closed: if collection fails, the rate remains unchanged.
        rangeManager.collectFeesForVault();
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
        require(_newMinimum > 0, "E23");
        uint256 oldMinimum = minDepositUSD;
        minDepositUSD = _newMinimum;
        emit MinDepositUpdated(oldMinimum, _newMinimum);
    }

    function setMaxDepositUsd(uint256 _newMaximum) external onlyOwner {
        require(_newMaximum > minDepositUSD, "E18");
        uint256 oldMaximum = maxDepositUsd;
        maxDepositUsd = _newMaximum;
        emit MaxDepositUpdated(oldMaximum, _newMaximum);
    }

    /// @notice Age max du cache prix (s) accepte par processDepositPermissionless. Gouvernance.
    function setDepositMaxCacheAge(uint256 _maxAge) external onlyOwner {
        require(_maxAge >= 60 && _maxAge <= 86400, "E18");
        depositMaxCacheAge = _maxAge;
    }

    function setDepositRefundDelay(uint256 refundDelay) external onlyOwner {
        require(refundDelay >= 3600 && refundDelay <= 30 days, "E18");
        uint256 oldDelay = depositRefundDelay;
        depositRefundDelay = refundDelay;
        emit DepositRefundDelayUpdated(oldDelay, refundDelay);
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

    /// @notice Recover airdrops or erroneous direct transfers held by this Vault.
    /// @dev For token0/token1, only the local balance strictly above queued deposit reserves is recoverable.
    ///      This function cannot access RangeManager balances, LP liquidity or pending user deposits.
    /// @param tokenAddr Token to rescue
    /// @param to Recipient address
    /// @param amount Amount to rescue
    function rescueToken(address tokenAddr, address to, uint256 amount) external onlyEmergencySafe nonReentrant {
        if (to == address(0)) revert InvalidRecipient();
        IERC20 rescueAsset = IERC20(tokenAddr);
        if (tokenAddr == address(token0) || tokenAddr == address(token1)) {
            uint256 reserved = tokenAddr == address(token0) ? _pendingTotal0 : _pendingTotal1;
            uint256 balance = rescueAsset.balanceOf(address(this));
            if (balance < reserved || amount > balance - reserved) revert ProtectedPoolToken();
        }
        rescueAsset.safeTransfer(to, amount);
        emit TokenRescued(tokenAddr, to, amount);
    }

    // ===== FONCTIONS DE RECUPERATION USER ET TOKENS PERDUS =====

    /**
     * @notice Recupere les fonds d'un utilisateur depuis RangeManager ou le Vault
     * @notice Precision : Les tokens de pool ne peuvent etre recuperes que par le depositaire
     * @param userAddress L'adresse de l'utilisateur a recuperer
     * @dev Les totaux pending et l'index utilisateur rendent ce chemin O(1), y compris avec une longue file.
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
            // Recuperer les balances totales (Vault HORS pending + RangeManager)
            uint256 rawVault0 = token0.balanceOf(address(this));
            uint256 rawVault1 = token1.balanceOf(address(this));
            vaultBalance0 = rawVault0 > _pendingTotal0 ? rawVault0 - _pendingTotal0 : 0;
            vaultBalance1 = rawVault1 > _pendingTotal1 ? rawVault1 - _pendingTotal1 : 0;

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

        // 3. Recuperer depuis RangeManager AVANT toute suppression d'accounting utilisateur.
        //    Fail-closed : si RangeManager revert, toute la transaction revert et userInfo reste intact.
        if (neededFromRange0 > 0 || neededFromRange1 > 0) {
            (uint256 received0, uint256 received1) = IRangeManager(address(rangeManager)).emergencyWithdrawForUser(
                neededFromRange0, neededFromRange1, address(this)
            );
            require(received0 == neededFromRange0 && received1 == neededFromRange1, "E47");
        }

        // 4. GeRER LE DePoT EN ATTENTE PAR INDEX (O(1))
        if (hasPendingDeposit[userAddress]) {
            uint256 indexPlusOne = _pendingIndexPlusOne[userAddress];
            require(indexPlusOne > _pendingHead && indexPlusOne <= pendingDeposits.length, "E48");
            uint256 index = indexPlusOne - 1;
            PendingDeposit memory pd = pendingDeposits[index];
            require(pd.user == userAddress, "E48");
            userAmount0 += pd.amount0;
            userAmount1 += pd.amount1;
            _removePending(index, pd);
            delete userFeeDebtToken0[userAddress];
            delete userFeeDebtToken1[userAddress];
        }

        // 5. METTRE a JOUR LES STATS APRES RECUPERATION EFFECTIVE DES FONDS
        if (userShares > 0) {
            totalShares = totalSharesBefore > userShares ? totalSharesBefore - userShares : 0;

            // Reset les infos de l'utilisateur
            delete userInfo[userAddress];
            delete userFeeDebtToken0[userAddress];
            delete userFeeDebtToken1[userAddress];
            // audit V1 (M3-B) : retirer aussi du registre actif (pruning O(1)) — coherence avec le retrait total.
            _unregisterUser(userAddress);
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

        if (positions.length == 0) revert NoPositionToBurn();

        // 2. Pour chaque position, retirer la liquidite puis burn le NFT.
        //    Fail-closed : si un burn echoue, toute la transaction revert et aucun succes global trompeur
        //    n'est emis. Avec maxPositions=1 en production, ce chemin reste simple et lisible.
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 tokenId = positions[i];

            IRangeManager(address(rangeManager)).burnPosition(tokenId);
            emit PositionBurned(tokenId, msg.sender);
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
        if (index >= users.length) revert UserIndexOutOfBounds();
        return users[index];
    }
}
