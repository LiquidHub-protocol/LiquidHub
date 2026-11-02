// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;
import "./ProtocolAccountingLib.sol";
import {VaultAccountingLib,VaultAccountingTypes} from "./VaultAccountingLib.sol";
import "./AutonomousErrors.sol";
import "./ProtocolSafetyLib.sol";
import "./AutonomousPoolLib.sol";
import "./interfaces/IGovernancePoolIntegration.sol";

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "./RangeOperations.sol";
import "./DnDepositLib.sol"; // EIP-170 : orchestration hedge au dépôt déportée (delegatecall)
import "./interfaces/IRangeStrategyEngine.sol";

// Interface etendue pour RangeManager

interface IRangeManagerExtended {
    function setSafeAddress(address _safe) external;
    function setAuthorizedExecutor(address _executor, bool _authorized) external;
    function strategyEngine() external view returns (address);
    function setStrategyEngine(address engine, address protocolBot) external;
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
    function adjustHedgeBps() external view returns (uint16);
}

interface IDnStrategyHedgeState {
    function getHedgeStrategyState()
        external
        view
        returns (
            bool positionExists,
            uint256 token0InLp,
            uint256 targetShort,
            uint256 debtToken0,
            int256 effectiveShort,
            uint256 driftBps,
            uint256 healthFactor
        );
}

interface IRangeManager {
    function getOwnerPositions() external view returns (uint256[] memory);
    function priceCache() external view returns (uint128, uint128, uint160, int24, uint64, bool);
    function getCurrentBalances() external view returns (uint256, uint256);
    function positionManager() external view returns (INonfungiblePositionManager);
    function removeLiquidityForWithdraw(uint256 tokenId, uint128 liquidityToRemove) external;
    function transferTokensForWithdraw(uint256 amount0, uint256 amount1, address recipient)
        external
        returns (uint256, uint256);
    function burnPosition(uint256 tokenId) external;
    function emergencyBurnPosition(uint256 tokenId) external;
    function emergencyWithdrawForUser(uint256 amount0Requested, uint256 amount1Requested, address recipient)
        external
        returns (uint256 amount0Sent, uint256 amount1Sent);
    function config() external view returns (RangeOperations.RangeConfig memory);
    // audit V1 (V3-H1) : le vault rafraîchit le cache (slot0+oracle LIVE) avant chaque mint/withdraw de shares.
    function refreshPriceCache() external;
    function addLiquidityToPosition() external;
    function mintInitialPosition() external returns (uint256 tokenId, uint128 liquidity);
    function collectFeesForVault() external returns (uint256 fees0, uint256 fees1);
    function initMultiSwapTvl() external view returns (uint256);
}

interface ITreasuryDeposit {
    function payDepositBounty(address keeper, address depositor, uint256 depositValueUsd) external;
}

interface IBotNav {
    function getOracleLpValueUsd() external view returns (uint256);
    function isWithdrawValueSufficient(uint256 amount0, uint256 amount1, uint256 minValueUsd)
        external
        view
        returns (bool);
}

contract MultiUserVault is Ownable, ReentrancyGuard, VaultAccountingTypes {
    function _calculateDepositValue(uint256 a, uint256 b) private view returns (uint256) {
        return ProtocolAccountingLib.depositValue(address(rangeManager), a, b);
    }

    function getCurrentPortfolioValue() public view returns (uint256) {
        return ProtocolSafetyLib.dnPortfolioValue(botModule, hedgeManager, address(rangeManager));
    }

    function _executeWithdrawFromRange(
        uint256 principal0,
        uint256 principal1,
        address recipient,
        uint256 shareAmount,
        bool isFullWithdraw
    ) private returns (uint256, uint256) {
        return ProtocolAccountingLib.withdrawFromRange(
            address(rangeManager),
            address(token0),
            address(token1),
            principal0,
            principal1,
            recipient,
            shareAmount,
            totalShares + shareAmount,
            isFullWithdraw
        );
    }

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
    error E46();
    error E70(); // DN pools: token0 deposits not allowed, use token1 only
    error E72(); // processDepositPermissionless: oracle cache stale / invalid / swap pair-cap-floor
    error E73(); // getCurrentPortfolioValue: source NAV indisponible (fail-closed)
    error E_SAME_BLOCK(); // withdraw in the same block as a deposit processing (anti flash-loan, V1+V3 audit)
    // REFONTE DN — dépôt permissionless hedgé
    // AUDIT (nettoyage code mort) : E_PRE_ADJUST_REQUIRED + E_INSUFFICIENT_COLLATERAL RETIRÉES du Vault
    // (jamais revert ici ; les équivalents PreAdjustRequired/InsufficientCollateral vivent dans DnDepositLib).
    error E_DEPOSIT_TOO_LARGE(); // dépôt en tête > plafond compatible MAX_SWAP_CHUNKS → anti-DoS file
    error E_NOT_REFUNDABLE(); // remboursement dépôt en tête demandé avant expiration
    error DepositNotQueueHead();
    error E_ZERO_SHARES(); // depot processe pour 0 share / 0 valeur (audit V1)
    error E_HEDGE_PAUSED(); // nouvelles entrees DN refusees tant que les ouvertures AAVE sont suspendues
    error WithdrawalValueTooLow();

    // ===== STRUCTURES =====

    // ===== VARIABLES D'ETAT =====

    IRangeManager public rangeManager;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    address public immutable pauseController;

    mapping(address => UserInfo) public userInfo;

    // Commission et treasury
    uint256 public commissionRate;
    address public treasuryAddress;

    // ===== DELTA NEUTRAL HEDGE =====
    // Le collatéral AAVE et la dette cible DN sont calculés on-chain via DnDepositLib/hedgeTargetBps.
    // Le vault envoie les dépôts au RangeManager puis ouvre le hedge atomiquement quand une position existe.

    //securbotmodule
    address public botModule;

    // Tracking comptable des commissions envoyees au Treasury (auto-compound)
    uint256 private _totalCommissionCollectedToken0;
    uint256 private _totalCommissionCollectedToken1;

    mapping(address => bool) public hasPendingDeposit;

    // ===== DELTA NEUTRAL HEDGE MANAGER =====
    address public hedgeManager;

    PendingQueue private _pendingQueue;

    function pendingDeposits(uint256 index) external view returns(address user,uint256 amount0,uint256 amount1,uint256 timestamp) {
        PendingDeposit storage pd=_pendingQueue.items[index];
        return(pd.user,pd.amount0,pd.amount1,pd.timestamp);
    }

    function _pendingCount() internal view returns (uint256) {
        uint256 len = _pendingQueue.items.length;
        return len > _pendingQueue.head ? len - _pendingQueue.head : 0;
    }

    function _removePending(uint256 index, PendingDeposit memory pd) private {
        VaultAccountingLib.removePending(_pendingQueue,hasPendingDeposit,index,pd);
    }

    uint256 public totalShares;
    uint256 private constant DEAD_SHARES = 1_000_000; // Brûlées au premier dépôt (anti-inflation attack)

    // Systeme de tracking des fees
    mapping(address => uint256) public userFeeDebtToken0;
    mapping(address => uint256) public userFeeDebtToken1;

    bool private _processingRebalance;
    uint64 private _rebalanceStartedAt;

    uint256 public minDepositUSD;
    address public emergencySafe;

    // Age max (secondes) du cache prix accepte par processDepositPermissionless (anti-prix-perime).
    // Reglable par la Safe sans redeploiement. Defaut 300s, aligne bot/keepers.
    uint256 public depositMaxCacheAge = 300;
    // False only for deployment bootstrap. A prior successful position permits a community keeper
    // to recreate the DN position after a full withdrawal through the same atomic hedge/deposit path.
    bool public initialPositionEstablished;

    // ===== REFONTE DN — dépôt permissionless hedgé (paramètres gouvernance) =====
    uint16 public dnPostCheckMaxDriftBps = 300; // plafond fixe ; DnDepositLib applique dynamiquement min(plafond, seuil critique range)
    uint256 public dnDustFloorUsd = 50e8; // plancher anti-poussière (USD 8 déc) : sous ce target, pas de post-check strict
    uint256 public dnMaxDepositUsd = 0; // plafond dépôt en tête (USD 8 déc) anti-DoS file ; setter interdit 0
    uint256 public dnDepositRefundDelay = 6 hours; // délai après lequel un dépôt en tête inexécutable peut être remboursé au déposant
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
    // The AAVE leg transfers directly to the user and emits its own settlement event. These two amounts are the
    // exact Vault leg only; together, both events provide the complete DN recovery trace without extra bytecode.
    event EmergencyUserRecovered(
        address indexed user, uint256 vaultAmount0Sent, uint256 vaultAmount1Sent, uint256 sharesRemoved
    );
    event PositionBurned(uint256 indexed tokenId, address indexed executor);
    event AllPositionsBurned(uint256 positionCount, address indexed executor);
    event MinDepositUpdated(uint256 oldMinimum, uint256 newMinimum);
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

    /// @notice Permanently closes installation before public deposits.

    uint256 private _governanceAccountingBusy;
    modifier accountingTransition() {
        _governanceAccountingBusy = 1;
        _;
        _governanceAccountingBusy = 0;
    }
    bool public installationSealed;
    event InstallationSealed(address indexed safe);

    function sealInstallation() external onlyOwner {
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
        _sealInstallation();
    }

    function _sealInstallation() private {
        ProtocolSafetyLib.validateVaultInstallation(botModule, address(rangeManager));
        installationSealed = true;
        emit InstallationSealed(emergencySafe);
    }

    /// @dev Read-only controller ABI includes technicalGovernance, depositorVoting,
    /// exposure journal and lifecycle. STATICCALL never forwards authority or value.
    fallback(bytes calldata input) external returns (bytes memory output) {
        bool ok;
        (ok, output) = pauseController.staticcall(input);
        if (!ok) assembly ("memory-safe") { revert(add(output, 32), mload(output)) }
    }

    function governanceRegistry() public view returns (address) {
        return IGovernancePoolController(pauseController).governanceRegistry();
    }

    function feeRecipient() external view returns (address) {
        address rebate = IGovernancePoolController(pauseController).feeRebate();
        return rebate == address(0) ? treasuryAddress : rebate;
    }

    /// @dev Quotes cannot certify a transient withdrawal/rebalance NAV.
    function checkpointAccountingBusy() external view returns (bool) {
        return _processingRebalance || _governanceAccountingBusy != 0;
    }

    function installEngineDepositorVoting(address voting, uint32[12] calldata bounds, bool stable)
        external onlyOwner {
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
        VaultAccountingLib.installPoolVoting(address(rangeManager), voting, bounds, stable);
    }

    function applyGovernanceLifecycle(uint8 action, bytes32 decisionId) external {
        require(msg.sender == governanceRegistry(), AutonomousCheck(0x486e7412));
        IGovernancePoolController(pauseController).applyLifecycleFromVault(action, decisionId);
    }

    function reportSafetyClosure() external {
        require(msg.sender == pauseController, AutonomousCheck(0x486e7412));
        IGovernancePoolRegistry(governanceRegistry()).notifySafetyClosure();
    }

    function _notifyGovernanceShares(address wallet, bool withdrawal) private {
        UserInfo storage user = userInfo[wallet];
        VaultAccountingLib.notifyGovernanceShares(pauseController, wallet, user.shares,
            user.depositedValueUSD, withdrawal, totalShares);
    }

    /// @notice Atomic terminal installation; no instance requires a subsequent Safe signature.
    function finalizeFactoryInstallation(address expectedSafe) external onlyOwner {
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
        VaultAccountingLib.validateFactorySafe(pauseController, expectedSafe, emergencySafe);
        _transferOwnership(expectedSafe);
        _sealInstallation();
    }

    function transferOwnership(address next) public override onlyOwner {
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
        super.transferOwnership(next);
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

    function renounceOwnership() public pure override {
        revert();
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
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
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
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
        if (executor == address(0)) revert E15();
        IRangeManagerExtended(address(rangeManager)).setAuthorizedExecutor(executor, authorized);
        emit ExecutorAuthorizedOnRangeManager(executor, authorized);
    }

    /// @dev Vault-owned RangeManager installation or published bounded safety adjustments only.
    function executeSafetyAdjustment(bytes calldata data) external onlyOwner returns (bytes memory result) {
        return ProtocolSafetyLib.executeBoundedCall(address(rangeManager), data);
    }

    /// @notice Installation-only relay to the immutable strategy engine owned by this Vault.

    // REFONTE DN (nettoyage EIP-170) : calculateUserShareOfFees + estimateTotalFees (+ helpers
    // _estimateUncollectedFees/_calculateFeeGrowth) RETIRÉS — code mort (ancien modèle de fees, remplacé
    // par accFeePerShare ; aucun appelant bot/keeper/frontend). Gain bytecode pour le dépôt DN hedgé.

    // ===== SETTER POUR RANGEMANAGER =====

    bool private rangeManagerSet;

    // Fonction pour configurer RangeManager
    function setRangeManager(address _rangeManager) external onlyOwner {
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
        if (rangeManagerSet) revert E16();
        if (_rangeManager == address(0)) revert E11();

        rangeManager = IRangeManager(_rangeManager);
        rangeManagerSet = true;

        emit RangeManagerSet(_rangeManager);
    }

    // ===== DEPOSIT FUNCTIONS =====

    error PoolTvlCapacityExceeded();
    function getAvailableDepositCapacityUsd8() public view returns(uint256) {
        return ProtocolAccountingLib.availableDepositCapacity(_pendingQueue);
    }

    function deposit(uint256 amount0, uint256 amount1) external nonReentrant {
        require(installationSealed, AutonomousCheck(0x60715aca));
        _requirePause(0x5ea9e82a); // requireInflowsActive()
        if (amount0 == 0 && amount1 == 0) revert E21();
        // DN pools: dépôts USDC uniquement (token0/WETH non accepté en dépôt direct)
        // AaveHedgeManager.paused bloque uniquement les NOUVELLES ouvertures AAVE. Refuser ici
        // evite d'empiler une entree FIFO inexecutable; settlement/withdraw/maintenance restent ouverts.
        RangeOperations.requireDepositOpen(hedgeManager, amount0);
        if (hasPendingDeposit[msg.sender]) revert E22();

        rangeManager.refreshPriceCache();
        (uint128 p0, uint128 p1,,, uint64 ts, bool valid) = rangeManager.priceCache();
        if (!valid || p0 == 0 || p1 == 0 || block.timestamp - uint256(ts) > depositMaxCacheAge) revert E72();

        uint256 depositValueUSD = _calculateDepositValue(amount0, amount1);
        VaultAccountingLib.validateAdditionalCapital(pauseController,depositValueUSD);
        if (depositValueUSD < minDepositUSD) revert E23();
        // Anti-DoS file (refonte DN) : plafond de dépôt compatible avec DN_MAX_SWAP_CHUNKS, pour qu'un dépôt
        // ne puisse pas exiger > 10 chunks de swap (sinon il bloquerait la tête de file en permissionless).
        if (dnMaxDepositUsd > 0 && depositValueUSD > dnMaxDepositUsd) revert E_DEPOSIT_TOO_LARGE();
        if(depositValueUSD>getAvailableDepositCapacityUsd8())revert PoolTvlCapacityExceeded();

        // Transferer les tokens au vault
        if (amount1 > 0) {
            DnDepositLib.pullExact(address(token1), amount1);
        }

        // Ajouter a la queue
        _pendingQueue.items.push(
            PendingDeposit({user: msg.sender, amount0: amount0, amount1: amount1, timestamp: block.timestamp})
        );

        hasPendingDeposit[msg.sender] = true;
        _pendingQueue.indexPlusOne[msg.sender] = _pendingQueue.items.length;
        _pendingQueue.total0 += amount0;
        _pendingQueue.total1 += amount1;

        emit PendingDepositAdded(msg.sender, amount0, amount1);
    }

    /// @notice Rembourse PERMISSIONLESS le dépôt en TÊTE de file s'il est resté trop longtemps non traité
    ///         (ex. devenu inexécutable après un mouvement de marché → post-check qui revert en boucle).
    /// @dev Anti-DoS file (refonte DN, E.2b) : sans ce chemin, un dépôt bloqué en tête figerait toute la file.
    ///      Les fonds sont renvoyés EXCLUSIVEMENT au déposant enregistré (jamais une adresse arbitraire).
    ///      Déclenchable par n'importe qui après `dnDepositRefundDelay`. Avance la tête comme un traitement.
    function refundStaleHeadDeposit() external nonReentrant {
        if (_pendingCount() == 0) revert E24();
        _refundStaleDeposit(_pendingQueue.head);
    }

    /// @notice Refund the matured request identified by its depositor once it reaches the queue head.
    /// @dev Keeping this overload head-only preserves FIFO order while any caller can still unblock the head.
    function refundStaleDeposit(address depositor) external nonReentrant {
        uint256 indexPlusOne = _pendingQueue.indexPlusOne[depositor];
        if (indexPlusOne == 0) revert E24();
        if (indexPlusOne != _pendingQueue.head + 1) revert DepositNotQueueHead();
        _refundStaleDeposit(indexPlusOne - 1);
    }

    function _refundStaleDeposit(uint256 index) private {
        PendingDeposit memory pd = _pendingQueue.items[index];
        if (block.timestamp < pd.timestamp + dnDepositRefundDelay
            && IGovernancePoolController(pauseController).lifecycle() == 0) revert E_NOT_REFUNDABLE();

        _removePending(index, pd);

        // Rembourser le déposant (fonds encore détenus par le vault tant que non traités). Destinataire FIGÉ = pd.user.
        _transferPair(pd.user, pd.amount0, pd.amount1);

        emit DepositRefunded(pd.user, pd.amount0, pd.amount1);
    }

    function _transferPair(address recipient, uint256 amount0, uint256 amount1) private {
        if (amount0 > 0) token0.safeTransfer(recipient, amount0);
        if (amount1 > 0) token1.safeTransfer(recipient, amount1);
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
        PendingDeposit memory pd = _pendingQueue.items[_pendingQueue.head];
        return (pd.user, pd.amount0, pd.amount1, pd.timestamp, true);
    }

    /// @notice AUDIT H-01 : plan de swap correct pour le PROCHAIN dépôt (état post-transfert + post-hedge),
    ///         à utiliser par les keepers/bot pour processDepositPermissionless — PAS getOptimalSwapParams
    ///         (qui reflète l'état rebalance/post-burn et donnerait un plan faux pour un dépôt).
    /// @return zeroForOne true si swap token0→token1 ; amountIn en unités natives du token d'entrée (0 = pas de swap).
    function getDepositSwapParams() external view returns (bool zeroForOne, uint256 amountIn) {
        if (_pendingCount() == 0) return (false, 0);
        PendingDeposit memory pd = _pendingQueue.items[_pendingQueue.head];
        // DnDepositLib lit lui-même priceCache/config via le RangeManager (évite de décoder les gros structs
        // côté Vault — EIP-170). On ne passe que le rangeManager + les montants du dépôt en tête.
        return DnDepositLib.getDepositSwapParams(address(rangeManager), pd.amount0, pd.amount1);
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
        // Récupérer le premier dépôt EN ATTENTE (tête = _pendingQueue.head)
        pd = _pendingQueue.items[_pendingQueue.head];

        currentTotalValue = getCurrentPortfolioValue();
        depositValue = _calculateDepositValue(pd.amount0, pd.amount1);
        VaultAccountingLib.validateAdditionalCapital(pauseController,depositValue);
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

        _removePending(_pendingQueue.head, pd);

        return (pd, depositValue, currentTotalValue, totalSharesBefore);
    }

    function _finalizeProcessedDeposit(
        PendingDeposit memory pd,
        uint256 creditedValue,
        uint256 currentTotalValue,
        uint256 totalSharesBefore
    ) private returns (uint256 sharesToMint) {
        (sharesToMint,totalShares)=VaultAccountingLib.finalizeDeposit(userInfo[pd.user],
            userFeeDebtToken0,userFeeDebtToken1,pd.user,accFeePerShare0,accFeePerShare1,
            VaultAccountingLib.DepositUpdate(creditedValue,currentTotalValue,totalSharesBefore,pd.amount0,pd.amount1,true));
        _notifyGovernanceShares(pd.user,false);
        address registry=governanceRegistry();
        if(registry!=address(0)) IGovernancePoolRegistry(registry).markPoolStarted(address(this));
        emit Deposit(pd.user,pd.amount0,pd.amount1,sharesToMint);
    }

    /**
     * @notice Traite UN depot de la file de maniere PERMISSIONLESS et ATOMIQUE.
     * @dev Decentralise le dernier maillon : n'importe qui (keeper) peut convertir un depot en file
     *      en liquidite LP, sans le bot du fondateur. En UNE tx : refresh oracle -> calcul shares
     *      (oracle) -> transfert fonds au RM -> swaps bornes oracle (anti-MEV) -> addLiquidity ->
     *      deposit bounty. Verrou _processingRebalance pose pendant toute la fonction (un withdraw
     *      concurrent revert E32). The initial and subsequent mints are public and use the complete atomic DN guards.
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
        // The initial and subsequent mints share the same public, fully hedged path.
        bool hasPosition = rangeManager.getOwnerPositions().length > 0;
        // 3. Refresh oracle atomique avant toute valorisation du depot permissionless.
        rangeManager.refreshPriceCache();
        if (hasPosition) {
            IRangeStrategyEngine.Decision memory decision =
                IRangeStrategyEngine(IRangeManagerExtended(address(rangeManager)).strategyEngine()).previewDecision();
            if (decision.dataFresh && decision.action == IRangeStrategyEngine.Action.RANGE_AND_HEDGE) revert E72();
        }
        // Le checkpoint strategique suit sa propre epoch permissionless. Le traitement d'un depot ne peut donc
        // jamais cumuler artificiellement les bounties de depot et de checkpoint.
        RangeOperations.RangeConfig memory cfg = rangeManager.config();
        (uint128 price0, uint128 price1,,, uint64 ts, bool valid) = rangeManager.priceCache();
        if (!valid || price0 == 0 || price1 == 0) revert E72();
        if (block.timestamp - uint256(ts) > depositMaxCacheAge) revert E72();
        // Crystallize incumbent fees first. If the tiny balance change invalidates the prepared plan,
        // validation below reverts atomically and the next bot/keeper cycle recomputes from fresh state.
        if (hasPosition) rangeManager.collectFeesForVault();
        uint16 depositPostCheckMaxDriftBps = dnPostCheckMaxDriftBps;
        if (hedgeManager != address(0)) {
            (bool positionExists,,,, int256 effectiveShort, uint256 driftBps,) = IDnStrategyHedgeState(
                    IRangeManagerExtended(address(rangeManager)).strategyEngine()
                )
                .getHedgeStrategyState();
            uint16 adjustThresholdBps = IAaveHedgeSettlement(hedgeManager).adjustHedgeBps();
            if (adjustThresholdBps <= dnPostCheckMaxDriftBps) revert E72();
            if (positionExists && (effectiveShort < 0 || driftBps >= adjustThresholdBps)) revert E72();
            if (driftBps > depositPostCheckMaxDriftBps) {
                uint256 inheritedLimit = driftBps + 1;
                if (inheritedLimit >= adjustThresholdBps) inheritedLimit = uint256(adjustThresholdBps) - 1;
                depositPostCheckMaxDriftBps = uint16(inheritedLimit);
            }
        }
        PendingDeposit memory pdPlan = _pendingQueue.items[_pendingQueue.head];
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
        ) {}
        catch {
            revert E73();
        }
        // 4. VERROU (un withdraw concurrent revert E32)
        _processingRebalance = true;
        _rebalanceStartedAt = uint64(block.timestamp);

        // 5. Transfert des fonds au RangeManager. Shares finalisees APRES hedge/swaps/addLiquidity (H-01).
        (PendingDeposit memory pd, uint256 depositValue, uint256 valueBefore, uint256 sharesBefore) =
            _processOneDeposit();

        // 5b. REFONTE DN : ouvrir le hedge ATOMIQUEMENT (avant les swaps, pour que le WETH emprunté soit
        // sur le RM au moment du calcul/exécution des swaps + addLiquidity). Hedge INCRÉMENTAL du dépôt :
        // le drift historique reste traité par adjustHedge/rebalance, jamais aux frais du nouveau déposant.
        if (hedgeManager != address(0)) {
            DnDepositLib.openDepositHedge(
                DnDepositLib.Addrs(hedgeManager, address(rangeManager), address(token0), address(token1)),
                price0,
                price1,
                pd.amount0,
                pd.amount1
            );
        }

        // 6. Swaps de reequilibrage bornes par l'oracle (anti-sandwich) + cap par chunk
        valueBefore += DnDepositLib.executeDepositSwaps(
            address(rangeManager),
            swapAmountsIn,
            minAmountsOut,
            tokenIn,
            tokenOut,
            price0,
            price1,
            cfg.token0Decimals,
            cfg.token1Decimals,
            commissionRate
        );

        // 7. Ajouter a la position existante, ou minter la position initiale après hedge + swaps.
        if (hasPosition) rangeManager.addLiquidityToPosition();
        else rangeManager.mintInitialPosition();
        initialPositionEstablished = true;

        // 7b. REFONTE DN : POST-CHECK strict. effectiveShort doit ≈ cible (tolérance dnPostCheckMaxDriftBps),
        // sinon REVERT toute la tx (le dépôt reste en file ; un rebalance/adjust approprié puis retente). + HF sain.
        if (hedgeManager != address(0)) {
            RangeOperations.RangeConfig memory cfgPc = rangeManager.config();
            DnDepositLib.postCheckDepositHedge(
                DnDepositLib.Addrs(hedgeManager, address(rangeManager), address(token0), address(token1)),
                price0,
                cfgPc.token0Decimals,
                depositPostCheckMaxDriftBps,
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
            try ITreasuryDeposit(treasuryAddress).payDepositBounty(msg.sender, pd.user, depositValue) {} catch {}
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
        PendingDeposit memory pd = _pendingQueue.items[_pendingQueue.head];
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
        if (msg.sender == emergencySafe) {
            // The DN Vault is close to EIP-170. Query only this public getter
            // without pulling in a full ABI call path; failure stays closed.
            address module = botModule;
            assembly ("memory-safe") {
                mstore(0x00, shl(224, 0x891d2780)) // progressiveRebalanceStatus()
                let ok := staticcall(gas(), module, 0x00, 0x04, 0x00, 0x20)
                if iszero(and(and(ok, eq(returndatasize(), 0x20)), iszero(mload(0x00)))) {
                    mstore(0x00, shl(224, 0x03df1f63)) // E32()
                    revert(0x00, 0x04)
                }
            }
        }
        _processingRebalance = false;
        _rebalanceStartedAt = 0;
    }

    function isRebalancing() external view returns (bool) {
        return _processingRebalance;
    }

    function getRebalanceLockStatus() external view returns (bool locked, uint64 startedAt) {
        return (_processingRebalance, _rebalanceStartedAt);
    }

    function withdraw(uint256 shareAmount) external nonReentrant accountingTransition {
        _withdrawInternal(shareAmount);
    }

    /**
     * @notice Retire un pourcentage des shares de l'utilisateur
     * @param pct Le pourcentage à retirer (1-100)
     */
    function withdrawPercentage(uint256 pct) external nonReentrant accountingTransition {
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

        // Refresh dans la transaction de retrait. Une divergence pool/oracle/TWAP n'autorise jamais
        // aveuglément le burn: le fallback ci-dessous exige des oracles frais puis vérifie la valeur USD
        // réellement récupérée après le settlement Aave. Un feed stale/illisible reste fail-closed.
        rangeManager.refreshPriceCache();

        uint256 totalSharesBefore = totalShares;
        bool isFullWithdraw = totalSharesBefore - shareAmount <= DEAD_SHARES;

        // Mise à jour fees avant calculs (regle sur l'ancien solde de shares, fige la dette).
        _updateUserFees(msg.sender);
        _handleUnclaimedFeesOnWithdraw();

        // Calculer montants pour le retrait (commission = 0, deja au Treasury)
        (uint256 principal0, uint256 principal1) = _calculateWithdrawAmounts(shareAmount, totalSharesBefore);
        uint256 minWithdrawValueUsd = _withdrawOracleGuard(shareAmount, totalSharesBefore);

        // ===== EFFECTS =====
        _finalizeWithdrawalState(user, shareAmount);

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
            IAaveHedgeSettlement(hedgeManager)
                .settleProportional(
                    wethBal,
                    RangeOperations.mulDivUp(shareAmount, 1e18, totalSharesBefore),
                    isFullWithdraw,
                    address(this)
                );
        }

        // Step 3: n'envoyer au user QUE le delta net (after − before), pas balanceOf entier.
        uint256 after0 = token0.balanceOf(address(this));
        uint256 after1 = token1.balanceOf(address(this));
        uint256 toSend0 = after0 > before0 ? after0 - before0 : 0;
        uint256 toSend1 = after1 > before1 ? after1 - before1 : 0;

        if (
            minWithdrawValueUsd != 0
                && !IBotNav(botModule).isWithdrawValueSufficient(toSend0, toSend1, minWithdrawValueUsd)
        ) revert WithdrawalValueTooLow();
        _transferPair(msg.sender, toSend0, toSend1);

        _notifyGovernanceShares(msg.sender, true);
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
            _totalCommissionCollectedToken0 += commission0;
            _totalCommissionCollectedToken1 += commission1;
        }
        // Distribuer les fees NETTES aux users (brutes - commission deja envoyee au Treasury)
        uint256 netFees0 = fees0 > commission0 ? fees0 - commission0 : 0;
        uint256 netFees1 = fees1 > commission1 ? fees1 - commission1 : 0;
        _distributeFees(netFees0, netFees1);
        VaultAccountingLib.recordGovernanceFees(pauseController, fees0, fees1, commission0, commission1);
    }

    // La distribution reste O(1) : le modele lazy regle chaque utilisateur lors de sa prochaine interaction.

    /// @dev audit V1 (M3-B-fix) — REGLE les fees du user (lazy). pending = shares*acc - debt, credite dans
    ///      totalFeesEarned, puis dette = shares*acc. Doit etre appele AVANT toute modification de user.shares
    ///      (deposit/withdraw) pour figer la dette sur l'ancien solde. shares constant entre 2 checkpoints =>
    ///      formule exacte (pas de surcomptage multi-distribution comme l'ancien modele TW).
    function _updateUserFees(address userAddress) private {
        VaultAccountingLib.updateFees(userInfo[userAddress],userFeeDebtToken0,userFeeDebtToken1,
            userAddress,accFeePerShare0,accFeePerShare1);
    }

    // ===== WITHDRAW PROTOCOL FEES =====

    // ===== HELPERS =====

    /**
     * @notice _calculateHedgeReserve supprimée — la répartition AAVE/LP est pilotée on-chain
     *         via hedgeTargetBps + DnDepositLib pendant les dépôts/rebalances DN.
     */

    /// @dev Valeur LP seule (tokens libres + position) en USD 8 dec. Une lecture impossible doit bloquer
    ///      tout calcul de shares : une NAV partielle sous-evaluerait le denominateur d'un nouveau depot.

    // ===== VIEW FONCTIONS =====

    function getPendingDepositsCount() external view returns (uint256) {
        return _pendingCount();
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
        return (_totalCommissionCollectedToken0, _totalCommissionCollectedToken1);
    }

    /**
     * @notice Fonction de retrait utilisateurs
     */

    // _estimateUncollectedFees + _calculateFeeGrowth RETIRÉS (helpers de estimateTotalFees, code mort).

    /**
     * @notice Gère les fees non réclamées lors d'un retrait
     * @dev Collecte les fees du NFT AVANT le withdraw pour que l'utilisateur les récupère
     *      Les fees sont envoyees au vault et distribuees via l'accumulateur net accFeePerShare
     *      L'utilisateur recevra sa part proportionnelle lors du withdraw
     */
    function _handleUnclaimedFeesOnWithdraw() private {
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
        returns (uint256 principal0, uint256 principal1)
    {
        (uint256 totalToken0, uint256 totalToken1) = rangeManager.getCurrentBalances();
        principal0 = (totalToken0 * shareAmount) / totalSharesBefore;
        principal1 = (totalToken1 * shareAmount) / totalSharesBefore;
    }

    /// @dev The fallback is limited to a freshly validated oracle pair. The complete DN NAV (LP,
    ///      idle hedge balances and Aave collateral minus debt) is used as the pre-withdraw reference.
    function _withdrawOracleGuard(uint256 shareAmount, uint256 totalSharesBefore)
        private
        view
        returns (uint256 minValueUsd)
    {
        bool valid;
        (,,,,, valid) = rangeManager.priceCache();
        if (valid) return 0;

        // getCurrentPortfolioValue() appelle le module oracle et les valorisations DN: un prix nul/stale
        // ou non rafraichi dans ce bloc revert fail-closed avant tout changement d'etat du retrait.
        uint256 nav = getCurrentPortfolioValue();
        if (nav == 0) revert E73();
        RangeOperations.RangeConfig memory cfg = rangeManager.config();
        uint256 userValue = Math.mulDiv(nav, shareAmount, totalSharesBefore);
        minValueUsd = Math.mulDiv(userValue, 10_000 - cfg.maxSlippageBps, 10_000);
        if (minValueUsd == 0) revert WithdrawalValueTooLow();
    }

    /**
     * @notice Met à jour l'état du vault lors d'un retrait (shares, fees, commissions)
     */
    function _finalizeWithdrawalState(UserInfo storage user, uint256 shareAmount) private {
        // audit V1 (M3-B-fix) : modele accFeePerShare -> plus de time-weighted global a maintenir.
        _updateUserStateAfterWithdrawal(user, shareAmount);
        totalShares -= shareAmount;
    }

    /**
     * @notice Met à jour l'état utilisateur après un retrait. Les fees ont deja ete reglees par
     *         _updateUserFees(msg.sender) en amont du withdraw (dette = ancien_solde * acc).
     */
    function _updateUserStateAfterWithdrawal(UserInfo storage user, uint256 shareAmount) private {
        VaultAccountingLib.reduceUser(user,userFeeDebtToken0,userFeeDebtToken1,
            msg.sender,shareAmount,accFeePerShare0,accFeePerShare1);
    }

    // ===== FONCTIONS DE CONFIGURATION =====

    function updateCommissionRate(uint256 newRate) external onlyOwner nonReentrant {
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
        if (newRate > 3000) revert E14();
        uint256 oldRate = commissionRate;
        // Cristallise feeGrowth avec l'ancien taux. Le callback recordFeesCollected() lit commissionRate
        // avant sa mise a jour; un echec de collecte laisse donc aussi le taux inchange (fail-closed).
        rangeManager.collectFeesForVault();
        commissionRate = newRate;
        emit CommissionRateUpdated(oldRate, newRate);
    }

    function updateTreasuryAddress(address newTreasury) external onlyOwner {
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
        if (newTreasury == address(0)) revert E17();
        address oldTreasury = treasuryAddress;
        treasuryAddress = newTreasury;
        emit TreasuryAddressUpdated(oldTreasury, newTreasury);
    }

    function setMinDepositUSD(uint256 _newMinimum) external onlyOwner {
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
        if (_newMinimum == 0 || _newMinimum > dnMaxDepositUsd) revert E23();
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
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
        if (postCheckMaxDriftBps < 50 || postCheckMaxDriftBps > 1000) revert E18();
        if (dustFloorUsd == 0 || dustFloorUsd > 50e8) revert E18();
        if (refundDelay < 3600 || refundDelay > 30 days) revert E18();
        if (maxDepositUsd < minDepositUSD) revert E18();
        uint256 maxByChunks = uint256(rangeManager.initMultiSwapTvl()) * 1e9;
        if (maxByChunks > 0 && maxDepositUsd > maxByChunks) revert E18();
        dnPostCheckMaxDriftBps = postCheckMaxDriftBps;
        dnDustFloorUsd = dustFloorUsd;
        dnMaxDepositUsd = maxDepositUsd;
        dnDepositRefundDelay = refundDelay;
        emit DnDepositParamsConfigured(postCheckMaxDriftBps, dustFloorUsd, maxDepositUsd, refundDelay);
    }

    /// @notice Atomically rotates the operational module and RangeManager identity, preserving the engine.

    function setBotModule(address _module) external onlyOwner {
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
        if (_module == address(0)) revert E19();
        address oldModule = botModule;
        botModule = _module;
        IRangeManagerExtended rm = IRangeManagerExtended(address(rangeManager));
        address engine = rm.strategyEngine();
        if (engine != address(0)) rm.setStrategyEngine(engine, _module);
        emit BotModuleUpdated(oldModule, _module);
    }

    function setHedgeManager(address _hedgeManager) external onlyOwner {
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
        // Configuration one-shot du deploiement courant. Aucune migration ni inspection d'un ancien
        // HedgeManager: chaque nouvelle pool est deployee proprement et son ancien deploiement est liquide
        // separement par l'operateur.
        if (_hedgeManager == address(0) || hedgeManager != address(0)) revert E18();
        hedgeManager = _hedgeManager;
        emit HedgeManagerSet(_hedgeManager);
    }

    /// @dev Emergency authority is separate from sealed installation; recovery fixes the beneficiary.
    function setEmergencySafe(address newSafe) external onlyOwner {
        require(!installationSealed, AutonomousCheck(0x9a247fa1));
        if (newSafe == address(0)) revert E17();
        emit EmergencySafeUpdated(emergencySafe, newSafe);
        emergencySafe = newSafe;
    }

    /// @notice Recover non-protected tokens (airdrops, erroneous transfers, donations)

    ///      Active LP/AAVE capital is held outside the Vault; pending user funds remain untouchable.
    /// @param tokenAddr Token to rescue
    /// @param to Recipient address
    /// @param amount Amount to rescue
    function rescueToken(address tokenAddr, address to, uint256 amount) external nonReentrant {
        if (!ProtocolSafetyLib.recoveryAllowed(pauseController, emergencySafe, address(0), 0)) revert E03();
        ProtocolSafetyLib.rescueVaultToken(treasuryAddress, tokenAddr, address(token0), address(token1), to, amount);
    }

    // ===== FONCTIONS DE RECUPERATION USER ET TOKENS PERDUS =====

    /**
     * @notice Recupere les fonds d'un utilisateur depuis RangeManager ou le Vault
     * @notice Precision : Les tokens de pool ne peuvent etre recuperes que par le depositaire
     * @param userAddress L'adresse de l'utilisateur a recuperer
     * @dev Le depot pending est retrouve par index 1-based puis retire par swap-and-pop. Le chemin reste O(1)
     *      quelle que soit la longueur de la file et ne demande aucun drainage prealable.
     */
    function EmergencyRecoverUser(address userAddress) external nonReentrant accountingTransition {
        totalShares=VaultAccountingLib.recoverDn(userInfo,userFeeDebtToken0,userFeeDebtToken1,hasPendingDeposit,
            _pendingQueue,VaultAccountingLib.Recovery(address(rangeManager),address(token0),address(token1),
                pauseController,emergencySafe,hedgeManager,totalShares),userAddress);
    }

    /**
     * @notice - Burn le NFT en cas de problème sur la position
     * @dev Les fonds restent dans RangeManager apres le burn en attente d'un nouveau MINT
     */
    function EmergencyBurnPositions() external nonReentrant {
        if (!ProtocolSafetyLib.recoveryAllowed(pauseController, emergencySafe, address(0), 2)) revert E03();

        uint256 count = ProtocolSafetyLib.burnPositions(address(rangeManager));
        emit AllPositionsBurned(count, msg.sender);
    }
}
