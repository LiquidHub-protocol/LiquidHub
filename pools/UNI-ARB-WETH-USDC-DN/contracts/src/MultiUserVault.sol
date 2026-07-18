// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "./RangeOperations.sol";
import "./DnDepositLib.sol"; // EIP-170 : orchestration hedge au dépôt déportée (delegatecall)

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

interface IAaveHedgeSettlement {
    function settleProportional(uint256 wethReceived, uint256 proportionX18, bool isFullWithdraw, address recipient)
        external;
    function emergencySettleForVault(
        uint256 wethReceived,
        uint256 proportionX18,
        bool isFullWithdraw,
        address recipient
    ) external;
    /// @dev Retourne collat/dette/HF/borrowable depuis AAVE V3. Valeurs en USD a 8 decimales (AAVE base).
    function getHedgeData()
        external
        view
        returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 healthFactor, uint256 availableBorrowsBase);
    /// @dev Token0 libre detenu par le HedgeManager (en unites natives). Ce token0 est l'actif emprunte
    ///      sur AAVE, garde idle comme BUFFER DE REPAY zero-slippage (eviter un swap token1->token0 au
    ///      moment de rembourser). Le hedge delta-neutral lui-meme est la DETTE token0 sur AAVE (jambe
    ///      short), pas ce token0 idle. Mais cet actif est bien detenu par le protocole : il doit etre
    ///      compte dans le NAV, sinon (en ne comptant que collat-dette) le denominateur de mint de
    ///      shares sous-estime la valeur reelle.
    function getWethDebt() external view returns (uint256);
    // REFONTE DN : ouverture/réduction du hedge déclenchée par le Vault au dépôt permissionless hedgé
    // (montants EXACTS, destination figée RM). onlySafeOrVault côté HedgeManager.
    function supplyAndBorrow(uint256 collateralAmountUsdc, uint256 borrowAmountWeth) external;
    function sweepWethAmount(uint256 amount, address to) external;
    function withdrawCollateral(uint256 amountUsdc, address to) external;
    function hedgeTargetBps() external view returns (uint16);
    function reserveHfTargetBps() external view returns (uint16);
    function liqThresholdBps() external view returns (uint16);
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
    // protectionConfig getter (audit V1) : struct étendu V3 → (sandwichDet, mev, failure, sandwichBps,
    // maxOracleDeviationBps, maxAge0, maxAge1). Doit matcher l'ABI du struct public sinon decode faux.
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
    // REFONTE DN : le Vault transfère l'USDC collatéral RM -> HedgeManager (destination figée on-chain).
    function sendTokenForHedge(address token, uint256 amount, address to) external;
}

interface ITreasuryDeposit {
    function payDepositBounty(address keeper, uint256 depositValueUsd) external;
}

interface IBotNav {
    function getOracleLpValueUsd() external view returns (uint256);
}

contract MultiUserVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===== CUSTOM ERRORS =====
    // AUDIT (nettoyage code mort) : E02, E04, E41, E42, E50-E53, E67-E69 RETIRÉES (jamais revert).
    error E01();
    error E03();
    error E11();
    error E12();
    error E13();
    error E14();
    error E15();
    error E16();
    error E17();
    error E18();
    error E19();
    error E21();
    error E22();
    error E23();
    error E24();
    error E25();
    error E31();
    error E32();
    error E33();
    error E40();
    error E43();
    error E44();
    error E45();
    error E46();
    error E70(); // DN pools: token0 deposits not allowed, use token1 only
    error E72(); // processDepositPermissionless: oracle cache stale / invalid / swap pair-cap-floor
    error E73(); // getCurrentPortfolioValue: lecture hedge AAVE en echec alors qu'un hedgeManager existe (fail-closed)
    error E_SAME_BLOCK(); // withdraw in the same block as a deposit processing (anti flash-loan, V1+V3 audit)
    // REFONTE DN — dépôt permissionless hedgé
    // AUDIT (nettoyage code mort) : E_PRE_ADJUST_REQUIRED + E_INSUFFICIENT_COLLATERAL RETIRÉES du Vault
    // (jamais revert ici ; les équivalents PreAdjustRequired/InsufficientCollateral vivent dans DnDepositLib).
    error E_DEPOSIT_TOO_LARGE(); // dépôt en tête > plafond compatible MAX_SWAP_CHUNKS → anti-DoS file
    error E_NOT_REFUNDABLE(); // remboursement dépôt en tête demandé avant expiration
    error E_ZERO_SHARES(); // depot processe pour 0 share / 0 valeur (audit V1)
    error E_HEDGE_PAUSED(); // nouvelles entrees DN refusees tant que les ouvertures AAVE sont suspendues

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

    // ===== DELTA NEUTRAL HEDGE =====
    // Le collatéral AAVE et la dette cible DN sont calculés on-chain via DnDepositLib/hedgeTargetBps.
    // Le vault envoie les dépôts au RangeManager puis ouvre le hedge atomiquement quand une position existe.

    //securbotmodule
    address public botModule;

    // Tracking comptable des commissions envoyees au Treasury (auto-compound)
    uint256 public totalCommissionCollectedToken0;
    uint256 public totalCommissionCollectedToken1;

    mapping(address => bool) public hasPendingDeposit;

    // ===== DELTA NEUTRAL HEDGE MANAGER =====
    address public hedgeManager;

    PendingDeposit[] public pendingDeposits;
    // SÉCURITÉ (audit V1 — DoS gas A) : pointeur de tête de file (O(1) par dépôt, cf. std). File vide quand
    // _pendingHead >= length ; compactage (delete + reset) une fois vidée.
    uint256 private _pendingHead;
    mapping(address => uint256) private _pendingIndexPlusOne;
    uint256 private _pendingTotal0;
    uint256 private _pendingTotal1;

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
    address public emergencySafe;

    // Age max (secondes) du cache prix accepte par processDepositPermissionless (anti-prix-perime).
    // Reglable par la Safe sans redeploiement. Defaut 300s, aligne bot/keepers.
    uint256 public depositMaxCacheAge = 300;

    // ===== REFONTE DN — dépôt permissionless hedgé (paramètres gouvernance) =====
    uint16 public dnPostCheckMaxDriftBps = 300; // plafond fixe ; DnDepositLib applique dynamiquement min(plafond, seuil critique range)
    uint256 public dnDustFloorUsd = 50e8; // plancher anti-poussière (USD 8 déc) : sous ce target, pas de post-check strict
    uint256 public dnMaxDepositUsd = 0; // plafond dépôt en tête (USD 8 déc) anti-DoS file ; setter interdit 0
    uint256 public dnDepositRefundDelay = 7 days; // délai après lequel un dépôt en tête inexécutable peut être remboursé au déposant
    uint8 private constant DN_MAX_SWAP_CHUNKS = 10; // borne agrégée de swaps (cohérent bot/keepers)

    // audit V1 (M3-B-fix, retour Codex) : COMPTA DES FEES — accFeePerShare pro-rata des SHARES courantes.
    // Modele MasterChef standard, prouve correct et O(1). Remplace l'ancien "time-weighted + accumulateur
    // monotone" qui SURCOMPTAIT apres plusieurs distributions sans checkpoint (les TW-shares historiques
    // etaient re-remunerees aux nouveaux taux -> 3F au lieu de 2F). Les distributions sont DISCRETES (a chaque
    // rebalance) et les fees auto-compoundees : repartir au prorata des shares courantes a chaque distribution
    // est economiquement correct (equivalent time-weighted par periode) et sans le bug.
    // accFeePerShareX (echelle 1e36) : fees cumulees par share, MONOTONE. pending = shares*acc - debt, avec
    // debt fige a chaque interaction (deposit/withdraw/lecture mutative) -> shares CONSTANT entre 2 checkpoints
    // (contrairement aux TW-shares qui croissaient), ce qui rend la formule exacte.
    uint256 public accFeePerShare0;
    uint256 public accFeePerShare1;

    // ===== EVENTS =====

    event Deposit(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
    event PendingDepositAdded(address indexed user, uint256 amount0, uint256 amount1);
    event DepositRefunded(address indexed user, uint256 amount0, uint256 amount1); // refonte DN : remboursement dépôt en tête expiré
    event DnDepositParamsConfigured(
        uint16 postCheckMaxDriftBps, uint256 dustFloorUsd, uint256 maxDepositUsd, uint256 refundDelay
    );
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
    event BotModuleSet(address indexed module);
    event TreasuryAddressUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ExecutorAuthorizedOnRangeManager(address indexed executor, bool authorized);
    event BotModuleUpdated(address indexed oldModule, address indexed newModule);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event EmergencySafeUpdated(address indexed oldSafe, address indexed newSafe);
    // Events hedge reserve supprimés (répartition AAVE/LP pilotée par hedgeTargetBps + DnDepositLib)
    event HedgeManagerSet(address indexed hedgeManager);

    // ===== MODIFIERS =====

    modifier onlyRangeManager() {
        if (msg.sender != address(rangeManager)) revert E01();
        _;
    }

    modifier onlyBot() {
        if (msg.sender != owner() && msg.sender != botModule && msg.sender != address(rangeManager)) revert E03();
        _;
    }

    modifier onlyEmergencySafe() {
        if (msg.sender != emergencySafe) revert E03();
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
        if (_rangeManager == address(0)) revert E11();
        if (_token0 == address(0) || _token1 == address(0)) revert E12();
        if (_pauseController == address(0)) revert E12();
        if (_treasuryAddress == address(0)) revert E13();

        rangeManager = IRangeManager(_rangeManager);
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        pauseController = _pauseController;

        treasuryAddress = _treasuryAddress;

        commissionRate = _commissionRate;
        if (commissionRate > 3000) revert E14();

        if (_minDepositUSD == 0) revert E23();
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
        if (executor == address(0)) revert E15();
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
        if (data.length < 4) revert E21();
        bytes4 selector = bytes4(data[:4]);
        if (!_isAllowedRangeManagerGovernanceSelector(selector)) revert E21();
        (bool ok, bytes memory ret) = address(rangeManager).call(data);
        if (!ok) revert E21();
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
            || selector == bytes4(keccak256("sendTokenForHedge(address,uint256,address)"))
            || selector == bytes4(keccak256("setInitMultiSwapTvl(uint256)"))
            || selector == bytes4(keccak256("setTreasuryAddress(address)"))
            || selector == bytes4(keccak256("setSafeAddress(address)"))
            || selector == bytes4(keccak256("setAuthorizedExecutor(address,bool)"));
    }

    // REFONTE DN (nettoyage EIP-170) : calculateUserShareOfFees + estimateTotalFees (+ helpers
    // _estimateUncollectedFees/_calculateFeeGrowth) RETIRÉS — code mort (ancien modèle de fees, remplacé
    // par accFeePerShare ; aucun appelant bot/keeper/frontend). Gain bytecode pour le dépôt DN hedgé.

    // ===== SETTER POUR RANGEMANAGER =====

    bool private rangeManagerSet;

    // Fonction pour configurer RangeManager
    function setRangeManager(address _rangeManager) external onlyOwner {
        if (rangeManagerSet) revert E16();
        if (_rangeManager == address(0)) revert E11();

        rangeManager = IRangeManager(_rangeManager);
        rangeManagerSet = true;

        emit RangeManagerSet(_rangeManager);
    }

    // ===== DEPOSIT FUNCTIONS =====

    function deposit(uint256 amount0, uint256 amount1) external nonReentrant {
        _requirePause(0x5ea9e82a); // requireInflowsActive()
        if (amount0 == 0 && amount1 == 0) revert E21();
        // DN pools: dépôts USDC uniquement (token0/WETH non accepté en dépôt direct)
        // AaveHedgeManager.paused bloque uniquement les NOUVELLES ouvertures AAVE. Refuser ici
        // evite d'empiler une entree FIFO inexecutable; settlement/withdraw/maintenance restent ouverts.
        DnDepositLib.requireDepositOpen(hedgeManager, amount0);
        if (hasPendingDeposit[msg.sender]) revert E22();

        rangeManager.refreshPriceCache();
        (uint128 p0, uint128 p1,,, uint64 ts, bool valid) = rangeManager.priceCache();
        if (!valid || p0 == 0 || p1 == 0 || block.timestamp - uint256(ts) > depositMaxCacheAge) revert E72();

        // Vérifier le montant minimum seulement si > 0
        if (minDepositUSD > 0) {
            uint256 depositValueUSD = _calculateDepositValue(amount0, amount1);
            if (depositValueUSD < minDepositUSD) revert E23();
        }
        // Anti-DoS file (refonte DN) : plafond de dépôt compatible avec DN_MAX_SWAP_CHUNKS, pour qu'un dépôt
        // ne puisse pas exiger > 10 chunks de swap (sinon il bloquerait la tête de file en permissionless).
        if (dnMaxDepositUsd > 0) {
            uint256 depUsd = _calculateDepositValue(amount0, amount1);
            if (depUsd > dnMaxDepositUsd) revert E_DEPOSIT_TOO_LARGE();
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

    /// @notice Rembourse PERMISSIONLESS le dépôt en TÊTE de file s'il est resté trop longtemps non traité
    ///         (ex. devenu inexécutable après un mouvement de marché → post-check qui revert en boucle).
    /// @dev Anti-DoS file (refonte DN, E.2b) : sans ce chemin, un dépôt bloqué en tête figerait toute la file.
    ///      Les fonds sont renvoyés EXCLUSIVEMENT au déposant enregistré (jamais une adresse arbitraire).
    ///      Déclenchable par n'importe qui après `dnDepositRefundDelay`. Avance la tête comme un traitement.
    function refundStaleHeadDeposit() external nonReentrant {
        if (_pendingCount() == 0) revert E24();
        PendingDeposit memory pd = pendingDeposits[_pendingHead];
        if (block.timestamp < pd.timestamp + dnDepositRefundDelay) revert E_NOT_REFUNDABLE();

        _removePending(_pendingHead, pd);

        // Rembourser le déposant (fonds encore détenus par le vault tant que non traités). Destinataire FIGÉ = pd.user.
        if (pd.amount0 > 0) token0.safeTransfer(pd.user, pd.amount0);
        if (pd.amount1 > 0) token1.safeTransfer(pd.user, pd.amount1);

        emit DepositRefunded(pd.user, pd.amount0, pd.amount1);
    }

    // ===== PROCESS DEPOSITS ET WITHDRAW =====

    // SÉCURITÉ (audit V1) : la fonction batch processPendingDeposits() a été SUPPRIMÉE. Elle figeait
    // currentTotalValue (getCurrentPortfolioValue) avant la boucle tout en incrémentant totalShares à
    // chaque itération → sur-mint des shares aux dépôts tardifs d'un même lot (dilution des holders).
    // Elle était `onlyBot` mais le selector restait whitelisté dans le module → atteignable par une clé
    // bot compromise. En DN, le traitement des dépôts se fait UNIQUEMENT via processDepositPermissionless(),
    // qui traite un seul dépôt, ouvre le hedge AAVE dans la même transaction, puis post-check la couverture.

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

    /// @notice AUDIT H-01 : plan de swap correct pour le PROCHAIN dépôt (état post-transfert + post-hedge),
    ///         à utiliser par les keepers/bot pour processDepositPermissionless — PAS getOptimalSwapParams
    ///         (qui reflète l'état rebalance/post-burn et donnerait un plan faux pour un dépôt).
    /// @return zeroForOne true si swap token0→token1 ; amountIn en unités natives du token d'entrée (0 = pas de swap).
    function getDepositSwapParams() external view returns (bool zeroForOne, uint256 amountIn) {
        if (_pendingCount() == 0) return (false, 0);
        PendingDeposit memory pd = pendingDeposits[_pendingHead];
        // DnDepositLib lit lui-même priceCache/config via le RangeManager (évite de décoder les gros structs
        // côté Vault — EIP-170). On ne passe que le rangeManager + les montants du dépôt en tête.
        return DnDepositLib.getDepositSwapParams(address(rangeManager), pd.amount0, pd.amount1);
    }

    /// @notice Plan de swap DN pour rebalance permissionless compatible avec la dette AAVE fixe.
    /// @dev Vue utilisée par les keepers avant d'appeler RangeManager.rebalance().
    function getRebalanceSwapParams() external view returns (bool zeroForOne, uint256 amountIn) {
        return DnDepositLib.getRebalanceSwapParams(address(rangeManager));
    }

    /// @notice Cristallise les fees LP avant de calculer un plan de dépôt.
    /// @dev Permissionless/no-bounty. Utile si des fees latentes déséquilibrent les soldes libres du RM :
    ///      bot/keepers peuvent appeler ceci, puis relire getDepositSwapParams() avant processDepositPermissionless().
    function syncFeesForDeposits() external nonReentrant {
        rangeManager.collectFeesForVault();
    }

    /**
     * @notice Prepare UN depot de la file, sans minter les shares.
     * @dev H-01: les shares sont finalisees APRES hedge/swaps/addLiquidity afin que le slippage reel du
     *      depot soit impute au deposant, pas socialise aux holders existants.
     *      DN: appele uniquement par processDepositPermissionless(), apres refresh cache, validation plan et
     *      collectFeesForVault() si une position existe.
     */
    function _processOneDeposit()
        private
        returns (PendingDeposit memory pd, uint256 depositValue, uint256 currentTotalValue, uint256 totalSharesBefore)
    {
        _requirePause(0x5ea9e82a); // requireInflowsActive()
        // Récupérer le premier dépôt EN ATTENTE (tête = _pendingHead)
        pd = pendingDeposits[_pendingHead];

        currentTotalValue = getCurrentPortfolioValue();
        depositValue = _calculateDepositValue(pd.amount0, pd.amount1);
        totalSharesBefore = totalShares;
        if (totalSharesBefore > DEAD_SHARES) {
            if (currentTotalValue == 0) revert E25();
            if (depositValue == 0) revert E_ZERO_SHARES();
        } else if (depositValue == 0) {
            revert E_ZERO_SHARES();
        }

        // Envoyer tous les fonds de CE DEPOT au RangeManager ; le hedge DN est ouvert juste après on-chain.
        if (pd.amount0 > 0) {
            token0.safeTransfer(address(rangeManager), pd.amount0);
        }
        if (pd.amount1 > 0) {
            token1.safeTransfer(address(rangeManager), pd.amount1);
        }

        _removePending(_pendingHead, pd);

        return (pd, depositValue, currentTotalValue, totalSharesBefore);
    }

    function _finalizeProcessedDeposit(
        PendingDeposit memory pd,
        uint256 creditedValue,
        uint256 currentTotalValue,
        uint256 totalSharesBefore
    ) private returns (uint256 sharesToMint) {
        if (creditedValue == 0) revert E_ZERO_SHARES();

        if (totalSharesBefore <= DEAD_SHARES) {
            totalShares = 0;
            // A pre-mint donation is included in the initial share base, so dust cannot freeze the pool.
            sharesToMint = (creditedValue + currentTotalValue) * 1e10;
            if (sharesToMint <= DEAD_SHARES) revert E24();
            sharesToMint -= DEAD_SHARES;
            totalShares = DEAD_SHARES;
        } else {
            sharesToMint = (creditedValue * totalSharesBefore) / currentTotalValue;
            if (sharesToMint == 0) revert E_ZERO_SHARES();
        }

        UserInfo storage user = userInfo[pd.user];
        _updateUserFees(pd.user);
        if (user.shares == 0) {
            user.firstDepositTime = block.timestamp;
        }

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
     *      concurrent revert E32). En DN, le mint initial reste reserve au botModule/owner ; les keepers
     *      permissionless ne peuvent traiter que les depots de croissance apres creation du NFT.
     */
    function processDepositPermissionless(
        uint256[] calldata swapAmountsIn,
        uint256[] calldata minAmountsOut,
        address tokenIn,
        address tokenOut
    ) external nonReentrant {
        if (swapAmountsIn.length != minAmountsOut.length) revert E72();
        if (_processingRebalance) revert E32();
        // Anti-DoS file (refonte DN) : borne agrégée du nombre de swaps.
        if (swapAmountsIn.length > DN_MAX_SWAP_CHUNKS) revert E_DEPOSIT_TOO_LARGE();
        // 1. File non vide (anti-drain bounty)
        if (_pendingCount() == 0) revert E24();
        // 2. Etat LP : si aucun NFT n'existe, seule l'execution botModule/owner peut minter la position
        // initiale hedgee. Les keepers anonymes gardent le traitement permissionless des depots de croissance.
        bool hasPosition = rangeManager.getOwnerPositions().length > 0;
        if (!hasPosition && msg.sender != botModule && msg.sender != owner()) revert E03();
        // 3. Refresh oracle atomique. audit V1 (V3-R4 Point 3, retour Codex) : on REFRESH d'abord le cache
        // (slot0+oracle LIVE) de façon INCONDITIONNELLE — avant ne se faisait que via recordPriceSnapshot()
        // qui revert si le snapshot n'est pas dû (catché), laissant le check depositMaxCacheAge buter sur un
        // cache ancien et BLOQUER le chemin permissionless. refreshPriceCache() ne dépend pas du timing snapshot.
        rangeManager.refreshPriceCache();
        // AUDIT MED-2 : on NE rappelle PLUS recordPriceSnapshot() ici. Le bounty metrics de cette fonction est
        // versé à msg.sender = le VAULT (pas au keeper qui déclenche le dépôt) → fuite/incohérence de bounty.
        // La fraîcheur du cache est déjà garantie par refreshPriceCache() ci-dessus ; le ring-buffer des
        // snapshots est entretenu par la cadence keeper/bot dédiée (recordPriceSnapshot direct), pas ici.
        RangeOperations.RangeConfig memory cfg = rangeManager.config();
        (uint128 price0, uint128 price1,,, uint64 ts, bool valid) = rangeManager.priceCache();
        if (!valid || price0 == 0 || price1 == 0) revert E72();
        if (block.timestamp - uint256(ts) > depositMaxCacheAge) revert E72();
        PendingDeposit memory pdPlan = pendingDeposits[_pendingHead];
        uint256 plannedDepositValue = _calculateDepositValue(pdPlan.amount0, pdPlan.amount1);
        try DnDepositLib.validateDepositSwapPlan(
            address(rangeManager),
            pdPlan.amount0,
            pdPlan.amount1,
            swapAmountsIn,
            minAmountsOut,
            tokenIn,
            tokenOut,
            plannedDepositValue * 2
        ) {} catch Error(string memory) {
            revert E73();
        } catch Panic(uint256) {
            revert E73();
        } catch (bytes memory) {
            revert E73();
        }
        // Liveness: le bot/keeper calcule le plan avant la collecte des fees latentes. On valide d'abord
        // ce plan, puis on cristallise les fees AVANT le hedge/mint/add pour que les anciens holders gardent
        // bien leurs fees pre-depot.
        if (hasPosition) {
            rangeManager.collectFeesForVault();
        }

        // 4. VERROU (un withdraw concurrent revert E32)
        _processingRebalance = true;
        _rebalanceStartedAt = uint64(block.timestamp);

        // 5. Transfert des fonds au RangeManager. Shares finalisees APRES hedge/swaps/addLiquidity (H-01).
        (PendingDeposit memory pd, uint256 depositValue, uint256 valueBefore, uint256 sharesBefore) =
            _processOneDeposit();

        // 5b. REFONTE DN : ouvrir le hedge ATOMIQUEMENT (avant les swaps, pour que le WETH emprunté soit
        // sur le RM au moment du calcul/exécution des swaps + addLiquidity). Cible GLOBALE (corrige aussi le
        // drift existant). Si pas de hedgeManager (std) ou collateral=0 (déjà assez short) → no-op ici.
        if (hedgeManager != address(0)) {
            DnDepositLib.openDepositHedge(
                DnDepositLib.Addrs(hedgeManager, address(rangeManager), address(token0), address(token1)),
                price0,
                price1,
                cfg.token0Decimals,
                cfg.token1Decimals
            );
        }

        // 6. Swaps de reequilibrage bornes par l'oracle (anti-sandwich) + cap par chunk
        DnDepositLib.executeDepositSwaps(
            address(rangeManager),
            address(token0),
            swapAmountsIn,
            minAmountsOut,
            tokenIn,
            tokenOut,
            price0,
            price1,
            cfg.token0Decimals,
            cfg.token1Decimals
        );

        // 7. Ajouter a la position existante, ou minter la position initiale après hedge + swaps.
        if (hasPosition) rangeManager.addLiquidityToPosition();
        else rangeManager.mintInitialPosition();

        // 7b. REFONTE DN : POST-CHECK strict. effectiveShort doit ≈ cible (tolérance dnPostCheckMaxDriftBps),
        // sinon REVERT toute la tx (le dépôt reste en file ; un rebalance/adjust approprié puis retente). + HF sain.
        if (hedgeManager != address(0)) {
            RangeOperations.RangeConfig memory cfgPc = rangeManager.config();
            DnDepositLib.postCheckDepositHedge(
                DnDepositLib.Addrs(hedgeManager, address(rangeManager), address(token0), address(token1)),
                price0,
                cfgPc.token0Decimals,
                dnPostCheckMaxDriftBps,
                dnDustFloorUsd
            );
        }

        // Shares are based on the real NAV increase after hedge, swaps and LP mint/add. This attributes
        // every execution cost induced by this deposit to the depositor, including swaps of freshly
        // borrowed token0, without socializing that loss to existing holders.
        uint256 valueAfter = getCurrentPortfolioValue();
        uint256 creditedValue = valueAfter > valueBefore ? valueAfter - valueBefore : 0;
        _finalizeProcessedDeposit(pd, creditedValue, valueBefore, sharesBefore);

        // 8. DEVERROU
        _processingRebalance = false;
        _rebalanceStartedAt = 0;

        // 9. Deposit bounty (silent: ne jamais bloquer l'action) — payé APRÈS succès complet
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
        if (_processingRebalance) revert E32();
        _processingRebalance = true;
        _rebalanceStartedAt = uint64(block.timestamp);
    }

    function endRebalance() external {
        if (
            msg.sender != owner() && msg.sender != botModule && msg.sender != address(rangeManager)
                && msg.sender != emergencySafe
        ) revert E03();
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
        if (pct == 0 || pct > 100) revert E31();
        _withdrawInternal((userInfo[msg.sender].shares * pct) / 100);
    }

    /**
     * @notice Fonction interne de retrait atomique
     * @dev Burns LP, settles AAVE hedge (flash loan if needed), sends tokens to user — all in one tx.
     * @param shareAmount Le nombre de shares à retirer
     */
    function _withdrawInternal(uint256 shareAmount) internal {
        // ===== CHECKS =====
        if (_processingRebalance) revert E32();
        UserInfo storage user = userInfo[msg.sender];
        if (user.shares < shareAmount || shareAmount == 0 || totalShares == 0) revert E33();
        // Anti-flash-loan: refuse tout withdraw dans le meme bloc que le processing du dernier
        // depot de l'utilisateur. Casse l'atomicite requise par l'exploit (V1+V3 audit).
        if (block.number <= user.lastDepositBlock) revert E_SAME_BLOCK();
        _requireWithdrawalAllowed(user.lastDepositTime);

        // SÉCURITÉ (audit V1 — High/Medium) : le burn de liquidité utilise désormais des amountMin
        // dérivés du slot0 live et bornés par maxSlippageBps. On garde en plus le check pool/oracle
        // live pour refuser un withdraw sur un slot0 manipulé ou divergent.
        // V3-H1 : REFRESH d'abord (slot0+oracle LIVE), updatePriceCache invalide le cache si déviation.
        {
            rangeManager.refreshPriceCache();
            (,,,,, bool _valid) = rangeManager.priceCache();
            if (!_valid) revert E72(); // cache invalide (deviation pool/oracle ou feed stale) -> bloque le retrait
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
        _finalizeWithdrawalState(user, shareAmount, commission0, commission1, principal0, principal1);

        // ===== INTERACTIONS — ATOMIC =====

        // SÉCURITÉ (audit V1) : snapshot AVANT toute interaction. Le vault détient aussi les dépôts USDC
        // EN ATTENTE d'autres users (deposit() transfère sur le vault, forwardé au RM seulement au cycle
        // suivant). On ne doit envoyer au user QUE le delta net généré par CE withdraw (principal retiré
        // du RM + USDC net rendu par le settle hedge − WETH consommé par le hedge), jamais balanceOf entier.
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));

        // Step 1: Burn LP → tokens arrive on vault
        _executeWithdrawFromRange(principal0, principal1, address(this), shareAmount, isFullWithdraw);

        // Step 2: Settle AAVE hedge if DN pool. Le WETH à envoyer au hedge = WETH retiré du RM pour CE
        // withdraw (= delta token0 depuis before0), pas balanceOf entier (le DN bloque les dépôts token0
        // donc il n'y a normalement pas de WETH en attente, mais on reste strict par cohérence).
        if (hedgeManager != address(0)) {
            uint256 cur0 = token0.balanceOf(address(this));
            uint256 wethBal = cur0 > before0 ? cur0 - before0 : 0;
            if (wethBal > 0) {
                token0.safeTransfer(hedgeManager, wethBal);
            }
            IAaveHedgeSettlement(hedgeManager).settleProportional(
                wethBal, RangeOperations.mulDivUp(shareAmount, 1e18, totalSharesBefore), isFullWithdraw, address(this)
            );
        }

        // Step 3: n'envoyer au user QUE le delta net (after − before), pas balanceOf entier.
        uint256 after0 = token0.balanceOf(address(this));
        uint256 after1 = token1.balanceOf(address(this));
        uint256 toSend0 = after0 > before0 ? after0 - before0 : 0;
        uint256 toSend1 = after1 > before1 ? after1 - before1 : 0;

        if (toSend0 > 0) token0.safeTransfer(msg.sender, toSend0);
        if (toSend1 > 0) token1.safeTransfer(msg.sender, toSend1);

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

    // sendTokenForHedgeRepay RETIRÉ (refonte DN / EIP-170) : résidu de l'ancien withdraw NON-atomique.
    // Le withdraw DN est désormais atomique (_withdrawInternal transfère lui-même le WETH au HedgeManager
    // puis settleProportional). Fonction non whitelistée + aucun appelant → code mort.

    // ===== FEES MANAGEMENT =====

    /// @notice Distribue des fees nettes : incremente l'accumulateur par-share. O(1), aucune boucle.
    /// @dev audit V1 (M3-B-fix) — modele accFeePerShare (MasterChef). Taux += fees*1e36/totalShares. MONOTONE.
    ///      Chaque user regle SES fees a la demande (pending = shares*acc - debt). Comme `shares` est CONSTANT
    ///      entre deux checkpoints (deposit/withdraw figent la dette), la formule est exacte — contrairement a
    ///      l'ancien modele time-weighted ou la "share" (TW) croissait, ce qui surcomptait sur >1 distribution.
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
    ///      totalFeesEarned, puis dette = shares*acc. Doit etre appele AVANT toute modification de user.shares
    ///      (deposit/withdraw) pour figer la dette sur l'ancien solde. shares constant entre 2 checkpoints =>
    ///      formule exacte (pas de surcomptage multi-distribution comme l'ancien modele TW).
    function _updateUserFees(address userAddress) private {
        UserInfo storage user = userInfo[userAddress];
        uint256 s = user.shares;
        if (s == 0) {
            // Rien a regler ; on (re)pose la dette au niveau courant pour un futur depot propre.
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

    /**
     * @notice _calculateHedgeReserve supprimée — la répartition AAVE/LP est pilotée on-chain
     *         via hedgeTargetBps + DnDepositLib pendant les dépôts/rebalances DN.
     */
    function getCurrentPortfolioValue() public view returns (uint256) {
        uint256 lpValue = _lpPortfolioValue();
        if (lpValue == 0) return 0; // RM injoignable / cache invalide -> 0 (geres en amont par E25 au depot).

        // AAVE hedge net value (collat - dette), en USD 8 dec (meme unite que la valeur LP).
        // Audit V2: sans ce terme, currentTotalValue sous-estime la vraie valeur du protocole (collat AAVE
        // ignore) -> sharesToMint surevalue -> retrait > juste part via deposit+withdraw atomique.
        // audit V1 (M3-B-fix, retour Codex) — le bloc hedge est SORTI des try/catch internes : un revert ici
        // (FAIL-CLOSED) ne doit PAS etre avale par un catch englobant et rendre une valeur LP-seule fausse.
        if (hedgeManager != address(0)) {
            try IAaveHedgeSettlement(hedgeManager).getHedgeData() returns (
                uint256 totalCollateralBase, uint256 totalDebtBase, uint256, uint256
            ) {
                // Comptabilite signee : si AAVE devient net negatif, le deficit reduit la NAV.
                // Si le deficit couvre toute la LP, on retourne 0 pour bloquer les nouveaux mints.
                if (totalCollateralBase >= totalDebtBase) {
                    lpValue += (totalCollateralBase - totalDebtBase);
                } else {
                    uint256 deficit = totalDebtBase - totalCollateralBase;
                    if (deficit >= lpValue) return 0;
                    lpValue -= deficit;
                }
            } catch {
                // FAIL-CLOSED : hedgeManager present mais getHedgeData() en echec -> on ne peut pas evaluer
                // correctement. Retourner la valeur LP seule SOUS-ESTIMERAIT le denominateur du mint de shares
                // (hedge net positif ignore). On revert ; mint/withdraw retenteront quand AAVE repondra.
                revert E73();
            }

            try DnDepositLib.idleHedgeValueUsd(hedgeManager, address(rangeManager)) returns (uint256 idleUsd) {
                lpValue += idleUsd;
            } catch {
                revert E73();
            }
        }

        return lpValue;
    }

    /// @dev Valeur LP seule (tokens libres + position) en USD 8 dec. try/catch internes : si le RangeManager
    ///      est injoignable ou le cache invalide, retourne 0 (jamais de revert ici — c'est la garde hedge
    ///      au-dessus qui porte le fail-closed). Separe de getCurrentPortfolioValue pour que le revert E73
    ///      (fail-closed hedge) ne soit pas capture par ces catch.
    function _lpPortfolioValue() private view returns (uint256) {
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

    // ===== VIEW FONCTIONS =====

    function getPendingDepositsCount() external view returns (uint256) {
        return _pendingCount();
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
        bool isFullWithdraw
    ) private returns (uint256 amount0Sent, uint256 amount1Sent) {
        // Verifier que le recipient est autorise
        if (recipient != address(this) && recipient != msg.sender) revert E40();

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
                    liquidityToRemove = RangeOperations.mulDivUp(totalLiquidity, shareAmount, totalShares + shareAmount);
                }
            }
        }

        // ===== ETAPE 1b : CRISTALLISER LES FEES AVANT DE RETIRER LE PRINCIPAL (audit M-01) =====
        // removeLiquidityForWithdraw fait decreaseLiquidity + collect(max,max), qui BALAYE aussi les fees
        // accrues avec le principal SANS passer par recordFeesCollected → fees non commissionnées (Treasury)
        // ni créditées au ledger user. On collecte/comptabilise d'abord via collectFeesForVault() (qui
        // cristallise, prélève la commission et met à jour accFeePerShare) ; le collect() suivant ne ramène
        // alors plus que le principal.
        if (tokenId > 0) {
            rangeManager.collectFeesForVault();
        }

        // ===== ETAPE 2 : RETIRER LA LIQUIDITE SI NECESSAIRE =====
        if (liquidityToRemove > 0 && tokenId > 0) {
            rangeManager.removeLiquidityForWithdraw(tokenId, uint128(liquidityToRemove));
        }
        // Dernier utilisateur: le decrease/collect ci-dessus a vidé le NFT. Le burner puis le détracker
        // dans la même transaction permet au prochain cycle (totalShares == DEAD_SHARES) de remint un range.
        if (isFullWithdraw && tokenId > 0) rangeManager.burnPosition(tokenId);

        // ===== ETAPE 3 : TRANSFERER DEPUIS RANGEMANAGER VERS VAULT =====
        // SÉCURITÉ (audit V1) : on n'envoie QUE le principal proportionnel du user, borné par
        // la balance réellement disponible. Avant, on envoyait balanceOf(RM) ENTIER, ce qui
        // distribuait aussi les tokens libres non déployés (dépôt mono-token en attente, réserve
        // hedge) au premier qui withdraw. Le principal (= vaultSharesPercent% de getCurrentBalances,
        // qui inclut LP + tokens libres) est la juste part. Le settle hedge (step 2) ajoute la part
        // AAVE séparément. Full withdraw => on prend tout le restant.
        uint256 realBalance0 = IERC20(token0).balanceOf(address(rangeManager));
        uint256 realBalance1 = IERC20(token1).balanceOf(address(rangeManager));
        uint256 toWithdraw0;
        uint256 toWithdraw1;
        if (isFullWithdraw) {
            toWithdraw0 = realBalance0;
            toWithdraw1 = realBalance1;
        } else {
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

    // _estimateUncollectedFees + _calculateFeeGrowth RETIRÉS (helpers de estimateTotalFees, code mort).

    /**
     * @notice Gère les fees non réclamées lors d'un retrait
     * @dev Collecte les fees du NFT AVANT le withdraw pour que l'utilisateur les récupère
     *      Les fees sont envoyees au vault et distribuees via l'accumulateur net accFeePerShare
     *      L'utilisateur recevra sa part proportionnelle lors du withdraw
     */
    function _handleUnclaimedFeesOnWithdraw(UserInfo storage, /* user */ uint256 /* shareAmount */ ) private {
        uint256[] memory positions = rangeManager.getOwnerPositions();
        if (positions.length == 0) return;
        rangeManager.collectFeesForVault();
        _updateUserFees(msg.sender);
    }

    /**
     * @notice Calcule les montants pour le retrait
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
     * @notice Met à jour l'état du vault lors d'un retrait (shares, fees, commissions)
     */
    function _finalizeWithdrawalState(UserInfo storage user, uint256 shareAmount, uint256, uint256, uint256, uint256)
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

            // audit V1 (M3-B-fix) — RE-CHECKPOINT la dette sur le NOUVEAU solde de shares : debt = shares * acc.
            userFeeDebtToken0[msg.sender] = user.shares * accFeePerShare0;
            userFeeDebtToken1[msg.sender] = user.shares * accFeePerShare1;
        }
    }

    // ===== FONCTIONS DE CONFIGURATION =====

    function updateCommissionRate(uint256 newRate) external onlyOwner nonReentrant {
        if (newRate > 3000) revert E14();
        uint256 oldRate = commissionRate;
        // Cristallise feeGrowth avec l'ancien taux. Le callback recordFeesCollected() lit commissionRate
        // avant sa mise a jour; un echec de collecte laisse donc aussi le taux inchange (fail-closed).
        rangeManager.collectFeesForVault();
        commissionRate = newRate;
        emit CommissionRateUpdated(oldRate, newRate);
    }

    function updateTreasuryAddress(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert E17();
        address oldTreasury = treasuryAddress;
        treasuryAddress = newTreasury;
        emit TreasuryAddressUpdated(oldTreasury, newTreasury);
    }

    function setMinDepositUSD(uint256 _newMinimum) external onlyOwner {
        if (_newMinimum == 0) revert E23();
        uint256 oldMinimum = minDepositUSD;
        minDepositUSD = _newMinimum;
        emit MinDepositUpdated(oldMinimum, _newMinimum);
    }

    /// @notice Age max du cache prix (s) accepte par processDepositPermissionless. Gouvernance.
    function setDepositMaxCacheAge(uint256 _maxAge) external onlyOwner {
        if (_maxAge < 60 || _maxAge > 86400) revert E18();
        depositMaxCacheAge = _maxAge;
    }

    /// @notice Gouvernance : paramètres du dépôt DN permissionless hedgé (refonte DN).
    /// @dev postCheckMaxDriftBps borné 50..1000 (0.5%..10%) ; refundDelay borné 1h..30j ; maxDepositUsd obligatoire.
    function setDnDepositParams(
        uint16 postCheckMaxDriftBps,
        uint256 dustFloorUsd,
        uint256 maxDepositUsd,
        uint256 refundDelay
    ) external onlyOwner {
        if (postCheckMaxDriftBps < 50 || postCheckMaxDriftBps > 1000) revert E18();
        if (dustFloorUsd == 0) revert E18();
        if (refundDelay < 3600 || refundDelay > 30 days) revert E18();
        if (maxDepositUsd == 0) revert E18();
        uint256 maxByChunks = uint256(rangeManager.initMultiSwapTvl()) * 10 * 1e8;
        if (maxByChunks > 0 && maxDepositUsd > maxByChunks) revert E18();
        dnPostCheckMaxDriftBps = postCheckMaxDriftBps;
        dnDustFloorUsd = dustFloorUsd;
        dnMaxDepositUsd = maxDepositUsd;
        dnDepositRefundDelay = refundDelay;
        emit DnDepositParamsConfigured(postCheckMaxDriftBps, dustFloorUsd, maxDepositUsd, refundDelay);
    }

    function setBotModule(address _module) external onlyOwner {
        if (_module == address(0)) revert E19();
        address oldModule = botModule;
        botModule = _module;
        emit BotModuleUpdated(oldModule, _module);
    }

    function setHedgeManager(address _hedgeManager) external onlyOwner {
        // Configuration one-shot du deploiement courant. Aucune migration ni inspection d'un ancien
        // HedgeManager: chaque nouvelle pool est deployee proprement et son ancien deploiement est liquide
        // separement par l'operateur.
        if (_hedgeManager == address(0) || hedgeManager != address(0)) revert E18();
        hedgeManager = _hedgeManager;
        emit HedgeManagerSet(_hedgeManager);
    }

    /// @notice Configure la Safe qui conserve les actions de secours en Phase 2.
    /// @dev Séparé de owner/gouvernance : un transfert futur vers timelock ne doit pas bloquer le dépannage.
    function setEmergencySafe(address newSafe) external onlyOwner {
        if (newSafe == address(0)) revert E17();
        emit EmergencySafeUpdated(emergencySafe, newSafe);
        emergencySafe = newSafe;
    }

    /// @notice Recover non-protected tokens (airdrops, erroneous transfers, donations)
    /// @dev Pool tokens are recoverable only above the exact reserves backing queued deposits.
    ///      Active LP/AAVE capital is held outside the Vault; pending user funds remain untouchable.
    /// @param tokenAddr Token to rescue
    /// @param to Recipient address
    /// @param amount Amount to rescue
    function rescueToken(address tokenAddr, address to, uint256 amount) external onlyEmergencySafe nonReentrant {
        if (to == address(0)) revert E17();
        DnDepositLib.rescueVaultToken(
            tokenAddr, address(token0), address(token1), to, amount, _pendingTotal0, _pendingTotal1
        );
        emit TokenRescued(tokenAddr, to, amount);
    }

    // ===== FONCTIONS DE RECUPERATION USER ET TOKENS PERDUS =====

    /**
     * @notice Recupere les fonds d'un utilisateur depuis RangeManager ou le Vault
     * @notice Precision : Les tokens de pool ne peuvent etre recuperes que par le depositaire
     * @param userAddress L'adresse de l'utilisateur a recuperer
     * @dev audit V1 (M3-B-fix5, retour Codex — Low gas) : ce chemin Safe-only ITERE sur la file des depots EN
     *      ATTENTE (pendingDeposits, de _pendingHead a la fin). Cout O(taille file). En pratique la file est
     *      drainee a chaque cycle bot (~10 min) donc elle reste petite ; mais si elle devait devenir tres
     *      grande, DRAINER la file (processDepositPermissionless) AVANT d'appeler cette
     *      fonction d'urgence. Non bloquant (pas le chemin normal), pas optimise on-chain pour ne pas alourdir
     *      le bytecode du vault (contrainte EIP-170).
     */
    function EmergencyRecoverUser(address userAddress) external onlyEmergencySafe nonReentrant {
        if (userAddress == address(0)) revert E43();

        UserInfo storage user = userInfo[userAddress];
        uint256 userShares = user.shares;
        uint256 totalSharesBefore = totalShares;

        if (userShares == 0 && !hasPendingDeposit[userAddress]) revert E44();

        uint256 userAmount0;
        uint256 userAmount1;
        uint256 n0;
        uint256 n1;

        // 1. Shares actives (cas normal)
        //    EmergencyBurnPositions doit etre appele avant pour ramener les tokens sur vault/RM
        if (userShares > 0) {
            if (rangeManager.getOwnerPositions().length != 0) revert E46();
            // SÉCURITÉ (audit V1) : exclure les dépôts EN ATTENTE de TOUS les users du balanceOf(vault)
            // avant le calcul proportionnel (deposit() transfère sur le vault avant traitement). Sinon un
            // user récupérerait une part d'un total gonflé par les pending d'autrui. Ses propres pending
            // sont ajoutés séparément à l'étape 2.
            uint256 raw0 = token0.balanceOf(address(this));
            uint256 raw1 = token1.balanceOf(address(this));
            uint256 vBal0 = raw0 > _pendingTotal0 ? raw0 - _pendingTotal0 : 0;
            uint256 vBal1 = raw1 > _pendingTotal1 ? raw1 - _pendingTotal1 : 0;
            uint256 rBal0 = token0.balanceOf(address(rangeManager));
            uint256 rBal1 = token1.balanceOf(address(rangeManager));
            uint256 share0 = ((vBal0 + rBal0) * userShares) / totalSharesBefore;
            uint256 share1 = ((vBal1 + rBal1) * userShares) / totalSharesBefore;

            // Recuperer depuis RangeManager si vault n'a pas assez
            if (share0 > vBal0 || share1 > vBal1) {
                n0 = share0 > vBal0 ? share0 - vBal0 : 0;
                n1 = share1 > vBal1 ? share1 - vBal1 : 0;
                if (n0 > rBal0) n0 = rBal0;
                if (n1 > rBal1) n1 = rBal1;
            }
            userAmount0 += share0;
            userAmount1 += share1;
        }

        // 2. Depot en attente: index direct + swap-and-pop, donc O(1).
        if (hasPendingDeposit[userAddress]) {
            uint256 idx1 = _pendingIndexPlusOne[userAddress];
            uint256 len = pendingDeposits.length;
            if (idx1 == 0 || idx1 <= _pendingHead || idx1 > len) revert E44();
            uint256 i = idx1 - 1;
            PendingDeposit memory pd = pendingDeposits[i];
            if (pd.user != userAddress) revert E44();
            userAmount0 += pd.amount0;
            userAmount1 += pd.amount1;
            _removePending(i, pd);
            delete userFeeDebtToken0[userAddress];
            delete userFeeDebtToken1[userAddress];
        }

        // 3. Settle hedge proportionnel pour pools DN
        uint256 proportionX18 =
            totalSharesBefore > 0 ? RangeOperations.mulDivUp(userShares, 1e18, totalSharesBefore) : 0;
        bool isFullWithdraw = totalSharesBefore > userShares ? totalSharesBefore - userShares <= DEAD_SHARES : true;

        // 4. Mettre a jour les stats avant les appels externes.
        if (userShares > 0) {
            totalShares = totalSharesBefore > userShares ? totalSharesBefore - userShares : 0;
            delete userInfo[userAddress];
            delete userFeeDebtToken0[userAddress];
            delete userFeeDebtToken1[userAddress];
            // audit V1 (M3-B-fix2, retour Codex — Low) : retirer aussi du registre actif (pruning O(1)), sinon
            // getUserCount/getUserAtIndex restent pollues (incoherence dashboards/indexeurs). Miroir du std.
            _unregisterUser(userAddress);
        }

        uint256 bal0BeforeWithdraw = token0.balanceOf(address(this));
        if (n0 > 0 || n1 > 0) {
            (uint256 received0, uint256 received1) =
                IRangeManager(address(rangeManager)).emergencyWithdrawForUser(n0, n1, address(this));
            if (received0 != n0 || received1 != n1) revert E46();
        }

        // Emergency DN : le settlement AAVE envoie directement la part hedge au user. Cela evite de sous-compter
        // le token0 eventuellement renvoye par le HedgeManager et garde le Vault plafonne au reliquat LP/pending.
        if (hedgeManager != address(0) && userShares > 0) {
            uint256 bal0AfterWithdraw = token0.balanceOf(address(this));
            uint256 wethForRepay = bal0AfterWithdraw > bal0BeforeWithdraw ? bal0AfterWithdraw - bal0BeforeWithdraw : 0;
            if (wethForRepay > 0) {
                token0.safeTransfer(hedgeManager, wethForRepay);
            }
            IAaveHedgeSettlement(hedgeManager).emergencySettleForVault(
                wethForRepay, proportionX18, isFullWithdraw, userAddress
            );
        }

        // 5. Envoyer les fonds.
        // SÉCURITÉ (audit V1) : ne JAMAIS envoyer balanceOf(vault) entier — il inclut les dépôts EN
        // ATTENTE des AUTRES users. À ce stade, le pending de CE user a déjà été retiré de la queue
        // (étape 2) ; il reste donc sur le vault les pending des autres, à exclure. On borne le solde
        // disponible à (balanceOf − pending des autres) puis on plafonne par le dû du user.
        uint256 rawBal0 = token0.balanceOf(address(this));
        uint256 rawBal1 = token1.balanceOf(address(this));
        uint256 bal0 = rawBal0 > _pendingTotal0 ? rawBal0 - _pendingTotal0 : 0;
        uint256 bal1 = rawBal1 > _pendingTotal1 ? rawBal1 - _pendingTotal1 : 0;
        // AUDIT MED-1 : un SEUL chemin de plafonnement pour DN et std — toSend = min(dû user, solde dispo).
        // En DN, emergencySettleForVault envoie directement au user la part hedge récupérée; ce bloc ne paie
        // que la quote-part vault/RangeManager restante. Plus d'envoi de tout le solde disponible.
        uint256 toSend0 = userAmount0 > bal0 ? bal0 : userAmount0;
        uint256 toSend1 = userAmount1 > bal1 ? bal1 : userAmount1;
        if (toSend0 > 0) token0.safeTransfer(userAddress, toSend0);
        if (toSend1 > 0) token1.safeTransfer(userAddress, toSend1);

        emit EmergencyUserRecovered(userAddress, toSend0, toSend1, userShares);
    }

    /**
     * @notice - Burn le NFT en cas de problème sur la position
     * @dev Les fonds restent dans RangeManager apres le burn en attente d'un nouveau MINT
     */
    function EmergencyBurnPositions() external onlyEmergencySafe nonReentrant {
        // 1. Recuperer toutes les positions NFT
        uint256[] memory positions = rangeManager.getOwnerPositions();

        if (positions.length == 0) revert E46();

        // 2. Pour chaque position, retirer la liquidite puis burn le NFT
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 tokenId = positions[i];

            // Appeler burnPosition directement (pas de try/catch pour voir les erreurs)
            IRangeManager(address(rangeManager)).burnPosition(tokenId);
            emit PositionBurned(tokenId, msg.sender);
        }

        // 3. Les fonds restent dans RangeManager
        // 4. Les userInfo restent intacts

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
        if (index >= users.length) revert E45();
        return users[index];
    }
}
