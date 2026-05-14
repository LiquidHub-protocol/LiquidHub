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
}

interface IRangeManager {
    function getOwnerPositions() external view returns (uint256[] memory);
    function getCurrentPortfolioValue() external view returns (uint256);
    function priceCache() external view returns (uint128, uint128, uint160, int24, uint64, bool);
    function reportFeesToVault() external;
    function getCurrentBalances() external view returns (uint256, uint256);
    function positionManager() external view returns (INonfungiblePositionManager);
    function pool() external view returns (IUniswapV3Pool);
    function removeLiquidityForWithdraw(uint256 tokenId, uint128 liquidityToRemove) external;
    function transferTokensForWithdraw(uint256 amount0, uint256 amount1, address recipient) external returns (uint256, uint256);
    function burnPosition(uint256 tokenId) external;
    function emergencyWithdrawForUser(
            uint256 amount0Requested,
            uint256 amount1Requested,
            address recipient
    ) external returns (uint256 amount0Sent, uint256 amount1Sent);
    function config() external view returns (RangeOperations.RangeConfig memory);
    function addLiquidityToPosition() external;
    function collectFeesForVault() external returns (uint256 fees0, uint256 fees1);
}

contract MultiUserVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ===== STRUCTURES =====
    
    struct UserInfo {
        uint256 shares;
        uint256 depositedToken0;
        uint256 depositedToken1;
        uint256 depositedValueUSD;  // Valeur USD au moment du dépôt (fixe)
        uint256 lastDepositTime;
        uint256 totalFeesEarnedToken0;
        uint256 totalFeesEarnedToken1;
        uint256 timeWeightedShares;
        uint256 lastTimeUpdate;
        uint256 firstDepositTime;   // Timestamp du premier dépôt d'une période de détention. Reset à 0 sur withdraw 100%.
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
    
    mapping(address => UserInfo) public userInfo;
    address[] private users; // Liste de tous les utilisateurs avec shares > 0
    mapping(address => bool) private isUser; // Pour éviter les doublons

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
    
    uint256 public totalShares;
    uint256 private constant DEAD_SHARES = 1000; // Brûlées au premier dépôt (anti-inflation attack)

    // Systeme de tracking des fees
    mapping(address => uint256) public userFeeDebtToken0;
    mapping(address => uint256) public userFeeDebtToken1;

    FeeSnapshot[] public feeHistory;
    
    uint256 public lastCollectedFees0;
    uint256 public lastCollectedFees1;
    
    bool private _processingRebalance;
    
    uint256 public minDepositUSD;
    
    // Système de tracking des fees time-weighted
    uint256 public totalTimeWeightedShares;
    uint256 public lastGlobalTimeUpdate;
    uint256 public cumulativeFeePerTimeWeightedShare0;
    uint256 public cumulativeFeePerTimeWeightedShare1;
    mapping(address => uint256) public userTimeWeightedShares;
    mapping(address => uint256) public userLastTimeUpdate;
          
    // ===== EVENTS =====
    
    event Deposit(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
    event PendingDepositAdded(address indexed user, uint256 amount0, uint256 amount1);
    event DepositsProcessed(uint256 count, uint256 totalAmount0, uint256 totalAmount1);
    event FeesDistributed(uint256 fees0, uint256 fees1);
    event CommissionRateUpdated(uint256 oldRate, uint256 newRate);
    event RebalancingStarted(uint256 timestamp);
    event RebalancingEnded(uint256 timestamp);
    event RangeManagerSet(address indexed rangeManager);
    event EmergencyUserRecovered(
        address indexed user,
        uint256 amount0Recovered,
        uint256 amount1Recovered,
        uint256 sharesRemoved
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
    
    // ===== MODIFIERS =====
    
        modifier onlyRangeManager() {
            require(msg.sender == address(rangeManager), "E01");
            _;
        }
        
        modifier onlyBot() {
                require(
                    msg.sender == owner() || msg.sender == botModule || msg.sender == address(rangeManager),
                    "Only bot"
                );
                _;
        }
    
    // ===== CONSTRUCTOR =====
    
    constructor(
        address _rangeManager,
        address _token0,
        address _token1,
        address _treasuryAddress,
        uint256 _commissionRate,
        uint256 _minDepositUSD
    ) {
        require(_rangeManager != address(0), "E11");
        require(_token0 != address(0) && _token1 != address(0), "E12");
        require(_treasuryAddress != address(0), "E13");

        rangeManager = IRangeManager(_rangeManager);
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);

        treasuryAddress = _treasuryAddress;        
        
        commissionRate = _commissionRate;
        require(commissionRate <= 3000, "E14"); // Max 30%
        
        authorizedRecipients[address(this)] = true;
        
        minDepositUSD = _minDepositUSD;
        
        // Initialiser le système time-weighted shares
        lastGlobalTimeUpdate = block.timestamp;
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
    
     /**
     * @notice Calcule la part proportionnelle des fees pour un utilisateur
     * @param tokensOwed0 Total des fees en token0
     * @param tokensOwed1 Total des fees en token1
     * @param userShares Nombre de shares de l'utilisateur
     * @return userFees0 Part de l'utilisateur en token0
     * @return userFees1 Part de l'utilisateur en token1
     */
    function calculateUserShareOfFees(
        uint128 tokensOwed0,
        uint128 tokensOwed1,
        uint256 userShares
    ) public view returns (uint256 userFees0, uint256 userFees1) {
        if (totalShares == 0) return (0, 0);
        
        userFees0 = (uint256(tokensOwed0) * userShares) / totalShares;
        userFees1 = (uint256(tokensOwed1) * userShares) / totalShares;
    }
        
    /**
     * @notice Estime les fees totales (crystallisees + non crystallisees) d'une position
     * @param tokenId L'ID de la position
     * @return fees0 Estimation des fees en token0
     * @return fees1 Estimation des fees en token1
     */
    function estimateTotalFees(uint256 tokenId) public view returns (uint256 fees0, uint256 fees1) {
        INonfungiblePositionManager positionManager = rangeManager.positionManager();

        (,,,,,int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 feeGrowthInside0LastX128,
         uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1) = positionManager.positions(tokenId);

        fees0 = uint256(tokensOwed0);
        fees1 = uint256(tokensOwed1);

        if (liquidity > 0) {
            (uint256 uncollected0, uint256 uncollected1) = _estimateUncollectedFees(
                liquidity, tickLower, tickUpper, feeGrowthInside0LastX128, feeGrowthInside1LastX128
            );
            fees0 += uncollected0;
            fees1 += uncollected1;
        }
    }
    
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
        pendingDeposits.push(PendingDeposit({
            user: msg.sender,
            amount0: amount0,
            amount1: amount1,
            timestamp: block.timestamp
        }));
        
        hasPendingDeposit[msg.sender] = true;
        
        emit PendingDepositAdded(msg.sender, amount0, amount1);
    }
    
    // ===== PROCESS DEPOSITS ET WITHDRAW =====
    
    function processPendingDeposits() external onlyBot {

        uint256 depositsCount = pendingDeposits.length;
        require(depositsCount > 0, "E24");
        
        uint256 totalAmount0;
        uint256 totalAmount1;
        uint256 currentTotalValue = _calculateTotalValue();
        
        // Mettre à jour les time-weighted shares globales AVANT modification de totalShares
        _updateGlobalTimeWeightedShares();

        // Traiter chaque depot
        for (uint256 i = 0; i < depositsCount; i++) {
            
            PendingDeposit memory pd = pendingDeposits[i];
            
            // Calculer les shares
            uint256 depositValue = _calculateDepositValue(pd.amount0, pd.amount1);
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
                sharesToMint = (depositValue * totalShares) / currentTotalValue;
            }

            // Mettre a jour les infos utilisateur
            UserInfo storage user = userInfo[pd.user];
            
            // Mettre à jour les time-weighted shares avant modification
            _updateTimeWeightedShares(pd.user);
            
            // Sauvegarder les time-weighted shares AVANT ajout des nouvelles shares
            uint256 timeWeightedSharesBeforeDeposit = user.timeWeightedShares;

            // Marquer le début d'une période de détention si l'utilisateur entre (ou rentre après withdraw total)
            if (user.shares == 0) {
                user.firstDepositTime = block.timestamp;
            }

            // Ajouter les nouvelles shares
            user.shares += sharesToMint;
            user.depositedToken0 += pd.amount0;
            user.depositedToken1 += pd.amount1;

            // Stocker la valeur USD au moment du dépôt (fixe, ne change plus)
            user.depositedValueUSD += depositValue;

            user.lastDepositTime = block.timestamp;

            // Ajouter l'utilisateur à la liste s'il n'y est pas déjà
            if (!isUser[pd.user]) {
                users.push(pd.user);
                isUser[pd.user] = true;
            }
                        
            // Initialiser la dette basée sur time-weighted shares AVANT le dépôt
            userFeeDebtToken0[pd.user] = timeWeightedSharesBeforeDeposit * cumulativeFeePerTimeWeightedShare0;
            userFeeDebtToken1[pd.user] = timeWeightedSharesBeforeDeposit * cumulativeFeePerTimeWeightedShare1;
            
            // Pour un nouveau dépôt, s'assurer que lastTimeUpdate est initialisé
            if (user.lastTimeUpdate == 0) {
                user.lastTimeUpdate = block.timestamp;
            }
            
            totalShares += sharesToMint;
            totalAmount0 += pd.amount0;
            totalAmount1 += pd.amount1;
            
            hasPendingDeposit[pd.user] = false;
            
            emit Deposit(pd.user, pd.amount0, pd.amount1, sharesToMint);
        }
        
        // Envoyer les fonds au RangeManager
        if (totalAmount0 > 0) {
            token0.safeTransfer(address(rangeManager), totalAmount0);
        }
        if (totalAmount1 > 0) {
            token1.safeTransfer(address(rangeManager), totalAmount1);
        }

        // Vider la queue
        delete pendingDeposits;
        
        emit DepositsProcessed(depositsCount, totalAmount0, totalAmount1);
    }

    // ===== TRAITEMENT INDIVIDUEL DES DEPOTS =====

    /**
     * @notice Retourne les informations du prochain dépôt en attente
     * @return user Adresse de l'utilisateur
     * @return amount0 Montant token0
     * @return amount1 Montant token1
     * @return timestamp Timestamp du dépôt
     * @return exists True si un dépôt existe
     */
    function getNextPendingDeposit() external view returns (
        address user,
        uint256 amount0,
        uint256 amount1,
        uint256 timestamp,
        bool exists
    ) {
        if (pendingDeposits.length == 0) {
            return (address(0), 0, 0, 0, false);
        }
        PendingDeposit memory pd = pendingDeposits[0];
        return (pd.user, pd.amount0, pd.amount1, pd.timestamp, true);
    }

    /**
     * @notice Traite UN SEUL dépôt (le premier de la queue)
     * @dev Le bot doit ensuite faire les multi-swaps et appeler addLiquidityToPosition
     *      Chaque utilisateur paie ses propres frais de swap proportionnels à son dépôt
     */
    function processSingleDeposit() external onlyBot {
        require(pendingDeposits.length > 0, "E24");

        // Récupérer le premier dépôt
        PendingDeposit memory pd = pendingDeposits[0];

        uint256 currentTotalValue = _calculateTotalValue();

        // Calculer les shares
        uint256 depositValue = _calculateDepositValue(pd.amount0, pd.amount1);
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
            sharesToMint = (depositValue * totalShares) / currentTotalValue;
        }

        // Mettre à jour les time-weighted shares globales AVANT modification de totalShares
        _updateGlobalTimeWeightedShares();

        // Mettre a jour les infos utilisateur
        UserInfo storage user = userInfo[pd.user];

        _updateTimeWeightedShares(pd.user);
        uint256 timeWeightedSharesBeforeDeposit = user.timeWeightedShares;

        if (user.shares == 0) {
            user.firstDepositTime = block.timestamp;
        }

        user.shares += sharesToMint;
        user.depositedToken0 += pd.amount0;
        user.depositedToken1 += pd.amount1;
        user.depositedValueUSD += depositValue;
        user.lastDepositTime = block.timestamp;

        if (!isUser[pd.user]) {
            users.push(pd.user);
            isUser[pd.user] = true;
        }

        userFeeDebtToken0[pd.user] = timeWeightedSharesBeforeDeposit * cumulativeFeePerTimeWeightedShare0;
        userFeeDebtToken1[pd.user] = timeWeightedSharesBeforeDeposit * cumulativeFeePerTimeWeightedShare1;

        if (user.lastTimeUpdate == 0) {
            user.lastTimeUpdate = block.timestamp;
        }

        totalShares += sharesToMint;
        hasPendingDeposit[pd.user] = false;

        // Envoyer les fonds de CE DEPOT UNIQUEMENT au RangeManager
        if (pd.amount0 > 0) {
            token0.safeTransfer(address(rangeManager), pd.amount0);
        }
        if (pd.amount1 > 0) {
            token1.safeTransfer(address(rangeManager), pd.amount1);
        }

        // Retirer ce dépôt de la queue (shift array)
        for (uint256 i = 0; i < pendingDeposits.length - 1; i++) {
            pendingDeposits[i] = pendingDeposits[i + 1];
        }
        pendingDeposits.pop();

        emit Deposit(pd.user, pd.amount0, pd.amount1, sharesToMint);
    }

    /**
     * @notice Retourne la valeur USD estimée du prochain dépôt
     * @dev Utilisé par le bot pour calculer le nombre de swaps nécessaires
     */
    function getNextDepositValueUSD() external view returns (uint256 valueUSD) {
        if (pendingDeposits.length == 0) {
            return 0;
        }
        PendingDeposit memory pd = pendingDeposits[0];
        return _calculateDepositValue(pd.amount0, pd.amount1);
    }

    function startRebalance() external onlyBot {
        _processingRebalance = true;
    }
    
    function endRebalance() external onlyBot {
        _processingRebalance = false;
    }
    
    function isRebalancing() external view returns (bool) {
        return _processingRebalance;
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

        // Calculer le pourcentage de shares retirées par rapport au total du vault
        uint256 vaultSharesPercent = totalShares > 0 ? (shareAmount * 10000) / totalShares : 0;

        // Mise à jour fees avant calculs
        _updateTimeWeightedShares(msg.sender);
        _updateUserFees(msg.sender);
        _handleUnclaimedFeesOnWithdraw(user, shareAmount);

        // Calculer montants pour le retrait (commission = 0, deja au Treasury)
        (uint256 commission0, uint256 commission1, uint256 principal0, uint256 principal1) =
            _calculateWithdrawAmounts(shareAmount);

        // ===== EFFECTS =====
        _finalizeWithdrawal(user, shareAmount, commission0, commission1, principal0, principal1);

        // ===== INTERACTIONS =====
        (uint256 toSend0, uint256 toSend1) = _executeWithdrawAndSend(
            principal0, principal1, 0, 0, 0, 0, vaultSharesPercent
        );

        emit Withdraw(msg.sender, toSend0, toSend1, shareAmount);
    }
    
    // ===== FEES MANAGEMENT =====

    /**
     * @notice Fonction interne pour distribuer les fees aux utilisateurs
     */
    function _distributeFees(uint256 fees0, uint256 fees1) private {
        if (totalShares == 0) return;
        if (fees0 == 0 && fees1 == 0) return;

        // Mettre à jour les time-weighted shares globales avant distribution
        _updateGlobalTimeWeightedShares();

        // Distribuer les fees nettes aux users (commission deja envoyee au Treasury)

        // Mettre à jour les fees cumulatives par time-weighted share
        // Precision 1e36 pour eviter perte d'arrondi sur tokens a faibles decimales (ex: USDC 6 dec)
        if (totalTimeWeightedShares > 0) {
            cumulativeFeePerTimeWeightedShare0 += (fees0 * 1e36) / totalTimeWeightedShares;
            cumulativeFeePerTimeWeightedShare1 += (fees1 * 1e36) / totalTimeWeightedShares;
        }

        // Créditer immédiatement les fees dans totalFeesEarnedToken0/1
        // pour que userInfo() retourne les bonnes valeurs
        _creditAllPendingFees();

        emit FeesDistributed(fees0, fees1);
    }
    
    function recordFeesCollected(
        uint256 fees0, uint256 fees1,
        uint256 commission0, uint256 commission1
    ) public onlyRangeManager {
        if (fees0 > 0 || fees1 > 0) {
            feeHistory.push(FeeSnapshot({
                token0Collected: fees0,
                token1Collected: fees1,
                timestamp: block.timestamp,
                blockNumber: block.number
            }));
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

    /**
     * @notice Credite les pending fees à tous les utilisateurs
     * @dev Appelle apres chaque rebalance pour que les fees soient visibles dans le dashboard
     */
    function _creditAllPendingFees() private {
        // Créditer tous les utilisateurs avec leurs fees accumulées
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            if (userInfo[user].shares > 0) {
                _updateUserFees(user);
            }
        }

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            if (userInfo[user].shares > 0) {
                userInfo[user].timeWeightedShares = 0;
                userInfo[user].lastTimeUpdate = block.timestamp;
                userFeeDebtToken0[user] = 0;
                userFeeDebtToken1[user] = 0;
            }
        }

        // Reset les variables globales pour la prochaine période
        totalTimeWeightedShares = 0;
        lastGlobalTimeUpdate = block.timestamp;
        cumulativeFeePerTimeWeightedShare0 = 0;
        cumulativeFeePerTimeWeightedShare1 = 0;
    }
    
    function _updateUserFees(address userAddress) private {
        _updateTimeWeightedShares(userAddress);

        UserInfo storage user = userInfo[userAddress];
        if (user.timeWeightedShares == 0) return;

        uint256 pending0 = (user.timeWeightedShares * cumulativeFeePerTimeWeightedShare0 - userFeeDebtToken0[userAddress]) / 1e36;
        uint256 pending1 = (user.timeWeightedShares * cumulativeFeePerTimeWeightedShare1 - userFeeDebtToken1[userAddress]) / 1e36;

        user.totalFeesEarnedToken0 += pending0;
        user.totalFeesEarnedToken1 += pending1;

        userFeeDebtToken0[userAddress] = user.timeWeightedShares * cumulativeFeePerTimeWeightedShare0;
        userFeeDebtToken1[userAddress] = user.timeWeightedShares * cumulativeFeePerTimeWeightedShare1;
    }
    
    /**
     * @notice Met à jour les time-weighted shares d'un utilisateur
     * @param userAddress L'adresse de l'utilisateur
     */
    function _updateTimeWeightedShares(address userAddress) private {
        UserInfo storage user = userInfo[userAddress];
        uint256 currentTime = block.timestamp;
        
        if (user.lastTimeUpdate > 0 && user.shares > 0) {
            uint256 timeDelta = currentTime - user.lastTimeUpdate;
            user.timeWeightedShares += user.shares * timeDelta;
        }
        user.lastTimeUpdate = currentTime;
    }
    
    /**
     * @notice Met à jour les time-weighted shares globales
     */
    function _updateGlobalTimeWeightedShares() private {
        uint256 currentTime = block.timestamp;
        
        if (lastGlobalTimeUpdate > 0 && totalShares > 0) {
            uint256 timeDelta = currentTime - lastGlobalTimeUpdate;
            totalTimeWeightedShares += totalShares * timeDelta;
        }
        lastGlobalTimeUpdate = currentTime;
    }
        
    // ===== WITHDRAW PROTOCOL FEES =====
    
    
    // ===== HELPERS =====
    
    function _calculateTotalValue() private view returns (uint256) {
        return getCurrentPortfolioValue();
    }
    
    function getCurrentPortfolioValue() public view returns (uint256) {
        try rangeManager.getCurrentBalances() returns (uint256 bal0, uint256 bal1) {
            try rangeManager.priceCache() returns (
                uint128 price0,
                uint128 price1,
                uint160,
                int24,
                uint64,
                bool valid
            ) {
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
       try rangeManager.priceCache() returns (
           uint128 price0,
           uint128 price1,
           uint160,
           int24,
           uint64,
           bool valid
       ) {
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
        return pendingDeposits.length;
    }
    
    function getUserInfo(address user) external view returns (
        uint256 shares,
        uint256 valueUSD,
        uint256 pendingFees0,
        uint256 pendingFees1
    ) {
        UserInfo memory info = userInfo[user];
        shares = info.shares;
        
        if (shares > 0 && totalShares > 0) {
            valueUSD = (_calculateTotalValue() * shares) / totalShares;
            
            // Calculer les time-weighted shares actuelles (simulation)
            uint256 currentTimeWeightedShares = info.timeWeightedShares;
            if (info.lastTimeUpdate > 0 && info.shares > 0) {
                uint256 timeDelta = block.timestamp - info.lastTimeUpdate;
                currentTimeWeightedShares += info.shares * timeDelta;
            }
            
            // Calculer les fees basées sur time-weighted shares
            if (currentTimeWeightedShares > 0) {
                pendingFees0 = (currentTimeWeightedShares * cumulativeFeePerTimeWeightedShare0 - userFeeDebtToken0[user]) / 1e36;
                pendingFees1 = (currentTimeWeightedShares * cumulativeFeePerTimeWeightedShare1 - userFeeDebtToken1[user]) / 1e36;
            }
        }
    }

    function estimateWithdrawAmounts(address user) external view returns (
        uint256 amount0,
        uint256 amount1,
        uint256 fees0,
        uint256 fees1
    ) {
        UserInfo memory info = userInfo[user];
        if (info.shares == 0 || totalShares == 0) return (0, 0, 0, 0);
        uint256 userSharePercent = (info.shares * 10000) / totalShares;
        (uint256 totalToken0, uint256 totalToken1) = rangeManager.getCurrentBalances();
        // Auto-compound: part proportionnelle du LP (inclut fees compoundees)
        amount0 = (totalToken0 * userSharePercent) / 10000;
        amount1 = (totalToken1 * userSharePercent) / 10000;
        // Fees bruts comptables pour affichage
        fees0 = info.totalFeesEarnedToken0;
        fees1 = info.totalFeesEarnedToken1;
    }

    /**
     * @notice Retourne les informations utilisateur avec fees comptables
     * @dev totalFeesEarnedToken0/1 (deja credites) + pendingFees time-weighted (pas encore credites)
     */
    function getUserInfoWithPendingFees(address user) external view returns (
        uint256 shares,
        uint256 depositedToken0,
        uint256 depositedToken1,
        uint256 depositedValueUSD,
        uint256 lastDepositTime,
        uint256 totalFeesToken0,
        uint256 totalFeesToken1,
        uint256 firstDepositTime
    ) {
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

            // Ajouter les fees pendantes non encore creditees (dans la position)
            uint256 currentTimeWeightedShares = info.timeWeightedShares;
            if (info.lastTimeUpdate > 0) {
                uint256 timeDelta = block.timestamp - info.lastTimeUpdate;
                currentTimeWeightedShares += info.shares * timeDelta;
            }

            if (currentTimeWeightedShares > 0 && cumulativeFeePerTimeWeightedShare0 > 0) {
                uint256 pending0 = (currentTimeWeightedShares * cumulativeFeePerTimeWeightedShare0 - userFeeDebtToken0[user]) / 1e36;
                uint256 pending1 = (currentTimeWeightedShares * cumulativeFeePerTimeWeightedShare1 - userFeeDebtToken1[user]) / 1e36;

                totalFeesToken0 += pending0;
                totalFeesToken1 += pending1;
            }
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
        uint256, // amount0Requested - non utilisé, on utilise les balances réelles
        uint256, // amount1Requested - non utilisé, on utilise les balances réelles
        address recipient,
        uint256 vaultSharesPercent
    ) private returns (uint256 amount0Sent, uint256 amount1Sent) {
        // Verifier que le recipient est autorise
        require(
            recipient == address(this) || 
            recipient == msg.sender || 
            authorizedRecipients[recipient], 
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
                if (vaultSharesPercent >= 9999) {
                    liquidityToRemove = totalLiquidity;
                } else {
                    // Retirer un pourcentage de liquidité proportionnel aux shares
                    liquidityToRemove = (totalLiquidity * vaultSharesPercent) / 10000;
                }
            }
        }
        
        // ===== ETAPE 2 : RETIRER LA LIQUIDITE SI NECESSAIRE =====
        if (liquidityToRemove > 0 && tokenId > 0) {
            rangeManager.removeLiquidityForWithdraw(tokenId, uint128(liquidityToRemove));
        }

        // ===== ETAPE 3 : TRANSFERER DEPUIS RANGEMANAGER VERS VAULT =====
        uint256 realBalance0 = IERC20(token0).balanceOf(address(rangeManager));
        uint256 realBalance1 = IERC20(token1).balanceOf(address(rangeManager));

        // Transférer les tokens vers le Vault
        (amount0Sent, amount1Sent) = rangeManager.transferTokensForWithdraw(
            realBalance0,
            realBalance1,
            address(this)
        );

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
    

    /**
     * @notice Estime les fees non collectées d'une position
     */
    function _estimateUncollectedFees(
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128
    ) private view returns (uint256, uint256) {
        try rangeManager.pool().slot0() returns (uint160, int24 currentTick, uint16, uint16, uint16, uint8, bool) {
            if (currentTick >= tickLower && currentTick < tickUpper) {
                return _calculateFeeGrowth(liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128);
            }
        } catch {}
        return (0, 0);
    }

    /**
     * @notice Calcule la croissance des fees
     */
    function _calculateFeeGrowth(
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128
    ) private view returns (uint256 uncollected0, uint256 uncollected1) {
        uint256 feeGrowthGlobal0 = rangeManager.pool().feeGrowthGlobal0X128();
        uint256 feeGrowthGlobal1 = rangeManager.pool().feeGrowthGlobal1X128();

        if (feeGrowthGlobal0 > feeGrowthInside0LastX128) {
            uncollected0 = (uint256(liquidity) * (feeGrowthGlobal0 - feeGrowthInside0LastX128)) >> 128;
        }

        if (feeGrowthGlobal1 > feeGrowthInside1LastX128) {
            uncollected1 = (uint256(liquidity) * (feeGrowthGlobal1 - feeGrowthInside1LastX128)) >> 128;
        }
    }

    /**
     * @notice Collecte les fees non reclamees avant un retrait
     * @dev Commission deduite dans le RangeManager → Treasury. Fees nettes restent sur le RM.
     */
    function _handleUnclaimedFeesOnWithdraw(UserInfo storage /* user */, uint256 /* shareAmount */) private {
        uint256[] memory positions = rangeManager.getOwnerPositions();
        if (positions.length == 0) return;
        rangeManager.collectFeesForVault();
        _updateUserFees(msg.sender);
    }

    /**
     * @notice Calcule les montants pour le retrait (auto-compound: commission deja au Treasury)
     */
    function _calculateWithdrawAmounts(
        uint256 shareAmount
    ) private view returns (uint256 commission0, uint256 commission1, uint256 principal0, uint256 principal1) {
        uint256 userSharePercent = totalShares > 0 ? (shareAmount * 10000) / totalShares : 0;
        (uint256 totalToken0, uint256 totalToken1) = rangeManager.getCurrentBalances();
        commission0 = 0;
        commission1 = 0;
        principal0 = (totalToken0 * userSharePercent) / 10000;
        principal1 = (totalToken1 * userSharePercent) / 10000;
    }

    /**
     * @notice Execute le retrait et envoie les fonds (auto-compound: pas de fees separees)
     */
    function _executeWithdrawAndSend(
        uint256 principal0,
        uint256 principal1,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256 vaultSharesPercent
    ) private returns (uint256 toSend0, uint256 toSend1) {
        _executeWithdrawFromRange(principal0, principal1, address(this), vaultSharesPercent);

        toSend0 = token0.balanceOf(address(this));
        toSend1 = token1.balanceOf(address(this));

        if (toSend0 > 0) token0.safeTransfer(msg.sender, toSend0);
        if (toSend1 > 0) token1.safeTransfer(msg.sender, toSend1);
    }

    /**
     * @notice Calcule le montant à envoyer après ajustements
     */
    function _calculateSendAmount(
        uint256 received,
        uint256 totalToWithdraw,
        uint256 principal,
        uint256 commission
    ) private view returns (uint256) {
        if (received < totalToWithdraw) {
            uint256 actualFees = received > principal ? received - principal : 0;
            uint256 adjustedCommission = (actualFees * commissionRate) / 10000;
            return received > adjustedCommission ? received - adjustedCommission : received;
        }
        return received - commission;
    }

    /**
     * @notice Finalise le retrait en mettant à jour l'état
     */
    function _finalizeWithdrawal(
        UserInfo storage user,
        uint256 shareAmount,
        uint256,
        uint256,
        uint256,
        uint256
    ) private {
        // Mettre à jour les time-weighted shares globales AVANT modification de totalShares
        _updateGlobalTimeWeightedShares();

        uint256 timeWeightedToReduce = _updateUserStateAfterWithdrawal(user, shareAmount);

        totalShares -= shareAmount;
        if (timeWeightedToReduce <= totalTimeWeightedShares) {
            totalTimeWeightedShares -= timeWeightedToReduce;
        }
    }

    /**
     * @notice Met à jour l'état utilisateur après un retrait
     */
    function _updateUserStateAfterWithdrawal(
        UserInfo storage user,
        uint256 shareAmount
    ) private returns (uint256 timeWeightedToReduce) {
        // Calculer la réduction de time-weighted shares AVANT modification
        if (user.shares == shareAmount) {
            // Retrait total
            timeWeightedToReduce = user.timeWeightedShares;
        } else {
            // Retrait partiel - proportionnel
            uint256 percentWithdrawn = (shareAmount * 1e18) / user.shares;
            timeWeightedToReduce = (user.timeWeightedShares * percentWithdrawn) / 1e18;
        }

        user.shares -= shareAmount;

        if (user.shares == 0) {
            // Si l'utilisateur retire tout, remettre TOUT à zéro
            user.depositedToken0 = 0;
            user.depositedToken1 = 0;
            user.depositedValueUSD = 0;
            user.totalFeesEarnedToken0 = 0;
            user.totalFeesEarnedToken1 = 0;
            user.timeWeightedShares = 0;
            user.lastTimeUpdate = 0;
            user.firstDepositTime = 0;
        } else {
            // Sinon, réduire proportionnellement
            uint256 percentWithdrawn = (shareAmount * 1e18) / (user.shares + shareAmount);

            user.timeWeightedShares = (user.timeWeightedShares * (1e18 - percentWithdrawn)) / 1e18;
            user.depositedToken0 = (user.depositedToken0 * (1e18 - percentWithdrawn)) / 1e18;
            user.depositedToken1 = (user.depositedToken1 * (1e18 - percentWithdrawn)) / 1e18;
            user.depositedValueUSD = (user.depositedValueUSD * (1e18 - percentWithdrawn)) / 1e18;
            user.totalFeesEarnedToken0 = (user.totalFeesEarnedToken0 * (1e18 - percentWithdrawn)) / 1e18;
            user.totalFeesEarnedToken1 = (user.totalFeesEarnedToken1 * (1e18 - percentWithdrawn)) / 1e18;

            // Mettre à jour la dette de fees basée sur les nouvelles time-weighted shares
            userFeeDebtToken0[msg.sender] = user.timeWeightedShares * cumulativeFeePerTimeWeightedShare0;
            userFeeDebtToken1[msg.sender] = user.timeWeightedShares * cumulativeFeePerTimeWeightedShare1;
        }

        return timeWeightedToReduce;
    }

    /**
     * @notice Fonction de collecte des fees
     */
    function _collectAllFeesInternal() private returns (uint256 fees0, uint256 fees1) {
        uint256[] memory positions = rangeManager.getOwnerPositions();
        if (positions.length == 0) return (0, 0);
        
        uint256 tokenId = positions[0];
        INonfungiblePositionManager positionManager = rangeManager.positionManager();
        
        // Recuperer la liquidite actuelle
        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(tokenId);
        
        // Si liquidite > 0, crystalliser les fees
        if (liquidity > 0) {
            try positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: 0,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 300
                })
            ) {} catch {}
        }
        
        // Collecter toutes les fees
        try positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(rangeManager),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        ) returns (uint256 amount0, uint256 amount1) {
            fees0 = amount0;
            fees1 = amount1;
        } catch {
            fees0 = 0;
            fees1 = 0;
        }
        
        return (fees0, fees1);
    }
    
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
        require(_newMinimum >= 0, "E18");
        uint256 oldMinimum = minDepositUSD;
        minDepositUSD = _newMinimum;
        emit MinDepositUpdated(oldMinimum, _newMinimum);
    }
    
    function setBotModule(address _module) external onlyOwner {
        require(_module != address(0), "E19");
        address oldModule = botModule;
        botModule = _module;
        emit BotModuleUpdated(oldModule, _module);
    }

    /// @notice Recover non-protected tokens (airdrops, erroneous transfers, donations)
    /// @dev Blocks token0/token1 (user funds, cannot be moved). Destination is flexible:
    ///      refund the sender, send to Treasury, or keep for protocol use depending on context.
    ///      Each rescue emits TokenRescued for full on-chain traceability.
    /// @param tokenAddr Token to rescue (must not be token0 or token1)
    /// @param to Recipient address
    /// @param amount Amount to rescue
    function rescueToken(address tokenAddr, address to, uint256 amount) external onlyOwner {
        require(tokenAddr != address(token0) && tokenAddr != address(token1), "Protected");
        require(to != address(0), "Invalid recipient");
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit TokenRescued(tokenAddr, to, amount);
    }

    // ===== FONCTIONS DE VUE =====
    
    function getCommissionStats() external view returns (
        uint256 pendingToken0,
        uint256 pendingToken1,
        uint256 totalCollectedToken0,
        uint256 totalCollectedToken1,
        uint256 currentRate
    ) {
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
     */
    function EmergencyRecoverUser(address userAddress) external onlyOwner nonReentrant {
        require(userAddress != address(0), "E43");
        
        UserInfo storage user = userInfo[userAddress];
        uint256 userShares = user.shares;
        uint256 totalSharesBefore = totalShares;
        
        // Verifier que l'utilisateur a des fonds ou des depots en attente
        require(userShares > 0 || hasPendingDeposit[userAddress], "E44");
        
        uint256 userAmount0 = 0;
        uint256 userAmount1 = 0;
        
        // 1. CALCULER LA PART DE L'UTILISATEUR
        if (totalSharesBefore > 0 && userShares > 0) {
            // Recuperer les balances totales (Vault + RangeManager)
            uint256 vaultBalance0 = token0.balanceOf(address(this));
            uint256 vaultBalance1 = token1.balanceOf(address(this));
            
            uint256 rangeBalance0 = token0.balanceOf(address(rangeManager));
            uint256 rangeBalance1 = token1.balanceOf(address(rangeManager));
            
            // Calculer la part proportionnelle
            uint256 totalBalance0 = vaultBalance0 + rangeBalance0;
            uint256 totalBalance1 = vaultBalance1 + rangeBalance1;
            
            userAmount0 = (totalBalance0 * userShares) / totalSharesBefore;
            userAmount1 = (totalBalance1 * userShares) / totalSharesBefore;
            
            // 2. ReCUPeRER LES FONDS DEPUIS RANGEMANAGER SI NeCESSAIRE
            uint256 neededFromRange0 = 0;
            uint256 neededFromRange1 = 0;
            
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
            
            // Recuperer depuis RangeManager si necessaire
            if (neededFromRange0 > 0 || neededFromRange1 > 0) {
                // Appeler la fonction emergencyWithdrawForUser dans RangeManager
                try IRangeManager(address(rangeManager)).emergencyWithdrawForUser(
                    neededFromRange0,
                    neededFromRange1,
                    address(this)
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
        }
        
        // 3. GeRER LES DePoTS EN ATTENTE
        if (hasPendingDeposit[userAddress]) {
            for (uint256 i = 0; i < pendingDeposits.length; i++) {
                if (pendingDeposits[i].user == userAddress) {
                    userAmount0 += pendingDeposits[i].amount0;
                    userAmount1 += pendingDeposits[i].amount1;
                    
                    if (i < pendingDeposits.length - 1) {
                        pendingDeposits[i] = pendingDeposits[pendingDeposits.length - 1];
                    }
                    pendingDeposits.pop();
                    break;
                }
            }
            hasPendingDeposit[userAddress] = false;
        }
        
        // 4. ENVOYER LES FONDS a L'UTILISATEUR
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
        
        // 5. METTRE a JOUR LES STATS
        if (userShares > 0) {
            totalShares = totalSharesBefore > userShares ? totalSharesBefore - userShares : 0;
            
            // Reset les infos de l'utilisateur
            delete userInfo[userAddress];
            delete userFeeDebtToken0[userAddress];
            delete userFeeDebtToken1[userAddress];
        }
        
        emit EmergencyUserRecovered(
            userAddress,
            toSend0,
            toSend1,
            userShares
        );
    }
         
    /**
     * @notice - Burn le NFT en cas de problème sur la position
     * @dev Les fonds restent dans RangeManager apres le burn en attente d'un nouveau MINT
     */
    function EmergencyBurnPositions() external onlyOwner nonReentrant {
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