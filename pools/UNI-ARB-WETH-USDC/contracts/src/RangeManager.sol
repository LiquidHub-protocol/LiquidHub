// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./RangeOperations.sol";

interface ITreasury {
    function payKeeperBounty(address keeper) external;
    function payMetricsBounty(address keeper) external;
}

interface IMultiUserVault {
    function getCurrentPortfolioValue() external view returns (uint256);
    function recordFeesCollected(uint256 fees0, uint256 fees1, uint256 commission0, uint256 commission1) external;
    function getUserCount() external view returns (uint256);
    function getUserAtIndex(uint256 index) external view returns (address);
    function totalShares() external view returns (uint256);
    function commissionRate() external view returns (uint256);
    function treasuryAddress() external view returns (address);
    function startRebalance() external;
    function endRebalance() external;
}

/**
 * @title RangeManager
 * @notice Manages Uniswap V3 liquidity positions for the MultiUserVault
 * @dev OWNERSHIP MODEL: This contract intentionally uses Ownable pattern.
 *      Ownership is NOT a security risk here - it's a requirement:
 *      - Owner (MultiUserVault) relays governance settings; executors perform recurring operations
 *      - safeAddress is only the emergency rescue address
 *      - Required for: oracle configuration, emergency recovery, protocol upgrades
 *      - Renouncing ownership would break critical vault operations
 *      Security scanners may flag this as a risk, but for DeFi vault contracts
 *      managing user funds, administrative control is essential, not optional.
 */
contract RangeManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using RangeOperations for *;

    uint256 private constant MAX_UINT128 = type(uint128).max;
    uint256 private constant MIN_REBALANCE_INTERVAL = 300;

    // ===== SYSTEME D'AUTORISATION DOUBLE =====
    address public safeAddress;
    mapping(address => bool) public authorizedExecutors;

    event SafeAddressSet(address indexed safe);
    event ExecutorAuthorized(address indexed executor, bool authorized);

    // ===== VARIABLES IMMUTABLE =====

    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable factory;
    IUniswapV3Pool public immutable pool;
    address public immutable token0;
    address public immutable token1;

    // ===== MULTI-USER VAULT INTEGRATION =====
    address public immutable vault;
    mapping(address => bool) public authorizedRecipients;

    // ===== SWAP & TREASURY =====
    ISwapRouter public immutable swapRouter;
    address public treasuryAddress;
    uint16 public swapFeeBps;
    uint256 public initMultiSwapTvl;

    // ===== VARIABLES D'ETAT (utilisant les structs de la library) =====

    RangeOperations.RangeConfig public config;
    RangeOperations.ProtectionConfig public protectionConfig;
    RangeOperations.PriceCache public priceCache;
    RangeOperations.SystemStats public systemStats;

    // ===== DYNAMIC RANGE (calcul on-chain) =====
    RangeOperations.DynamicRangeConfig public dynRangeConfig;
    RangeOperations.PriceSnapshot[] private _priceRing;
    uint16 private _ringHead;
    uint16 private _ringCap;

    event PriceSnapshotRecorded(uint128 price, uint64 timestamp, address indexed keeper);
    event DynamicRangeConfigured(
        bool enabled,
        uint8 maxSnapshotsPerDay,
        uint8 volatMoyDay,
        uint8 volatTrimDay,
        uint16 rangeStepBps,
        uint16 rangeMultiplicatorBps,
        uint16 rangeMinBps,
        uint16 rangeMaxBps
    );
    event DynamicRangeApplied(uint16 halfRangeBps);

    // ===== ORACLES =====

    AggregatorV3Interface private token0PriceFeed;
    AggregatorV3Interface private token1PriceFeed;

    // ===== GESTION POSITIONS =====

    uint32 private positionCount;
    mapping(uint256 => uint32) private positionIndex;
    mapping(uint32 => uint256) private indexToPosition;
    mapping(uint256 => bool) private isOwnedPosition;

    // ===== EVENTS =====

    event PositionCreated(
        uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 totalValueUSD, string rangeMode
    );

    event TokenWithdrawn(address indexed token, uint256 amount, string reason);
    event PriceCacheUpdated(uint128 price0, uint128 price1, int24 poolTick);
    event ToleranceUpdated(uint16 oldToleranceBps, uint16 newToleranceBps);
    event TreasuryAddressUpdated(address indexed oldTreasury, address indexed newTreasury); // audit LOW-5
    event InitMultiSwapTvlUpdated(uint256 oldValue, uint256 newValue);
    event SwapFeeBpsUpdated(uint16 oldValue, uint16 newValue);
    event LiquidityAdded(uint256 indexed tokenId, uint256 amount0, uint256 amount1, uint128 liquidity);

    // ===== NOUVEAUX MODIFIERS =====

    /**
     * @dev Droits operationnels uniquement: bot module / executors peuvent maintenir la position,
     * mais les reglages de gouvernance passent par onlyVaultOwner.
     */
    modifier onlyAuthorized() {
        require(msg.sender == owner() || authorizedExecutors[msg.sender], "E99");
        _;
    }

    /**
     * @dev Modifier strictement pour le owner (MultiUserVault)
     * Utilise pour les fonctions de gestion des autorisations
     */
    modifier onlyVaultOwner() {
        require(msg.sender == owner(), "E01");
        _;
    }

    modifier operationalChecks() {
        // Failure counters are informational only: state changes made before a revert are rolled back by the EVM.
        // Liveness must rely on the bot/module watchdog, oracle/deviation checks and Safe intervention.
        if (protectionConfig.mevProtectionEnabled) {
            require(block.timestamp - config.lastRebalanceTime >= MIN_REBALANCE_INTERVAL, "E03");
        }
        require(config.oraclesConfigured, "E04");
        _;
    }

    modifier maxPositionsCheck() {
        require(positionCount < config.maxPositions, "E06");
        _;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "E07");
        _;
    }

    modifier onlyVaultOrAuthorized() {
        require(
            msg.sender == address(this) || msg.sender == vault || msg.sender == owner()
                || authorizedExecutors[msg.sender],
            "E94"
        );
        _;
    }

    // ===== CONSTRUCTOR =====

    constructor(
        address _vault,
        address _pauseController,
        address _positionManager,
        address _factory,
        address _token0,
        address _token1,
        uint24 _fee,
        uint8 _token0Decimals,
        uint8 _token1Decimals,
        address _swapRouter,
        address _treasuryAddress,
        uint16 _swapFeeBps,
        uint256 _initMultiSwapTvl,
        uint16 _rangeUpPercent,
        uint16 _rangeDownPercent
    ) {
        require(_vault != address(0), "E09");
        require(_pauseController != address(0), "E09");
        vault = _vault;

        require(
            _positionManager != address(0) && _factory != address(0) && _token0 != address(0) && _token1 != address(0)
                && _token0 != _token1 && _token0 < _token1,
            "E10"
        );

        // Validation des ranges (mêmes limites que configureRanges)
        require(_rangeUpPercent >= 10 && _rangeUpPercent <= 5000, "E17");
        require(_rangeDownPercent >= 10 && _rangeDownPercent <= 5000, "E18");
        require(_swapFeeBps == 0, "E99");
        require(_initMultiSwapTvl > 0 && _initMultiSwapTvl <= 1_000_000, "E97");

        positionManager = INonfungiblePositionManager(_positionManager);
        factory = IUniswapV3Factory(_factory);
        token0 = _token0;
        token1 = _token1;

        address poolAddress = IUniswapV3Factory(_factory).getPool(_token0, _token1, _fee);
        require(poolAddress != address(0), "E11");
        pool = IUniswapV3Pool(poolAddress);

        config = RangeOperations.RangeConfig({
            fee: _fee,
            token0Decimals: _token0Decimals,
            token1Decimals: _token1Decimals,
            toleranceBps: 50, //0,50% en basis points
            maxSlippageBps: 100, //1% en basis points
            lastRebalanceTime: 0,
            oraclesConfigured: false,
            rangeUpPercent: _rangeUpPercent,
            rangeDownPercent: _rangeDownPercent,
            maxPositions: 1
        });

        protectionConfig = RangeOperations.ProtectionConfig({
            sandwichDetectionEnabled: false,
            mevProtectionEnabled: true,
            failureProtectionEnabled: true,
            sandwichThresholdBps: 50,
            maxOracleDeviationBps: 100,
            maxAge0: 90000, // heartbeat par défaut (25h) — cohérent avec la pool DN
            maxAge1: 90000
        });

        systemStats.initialized = true;

        // Swap & Treasury config
        require(_swapRouter != address(0), "E51");
        require(_treasuryAddress != address(0), "E98");
        swapRouter = ISwapRouter(_swapRouter);
        treasuryAddress = _treasuryAddress;
        swapFeeBps = _swapFeeBps;
        initMultiSwapTvl = _initMultiSwapTvl;

        // Approve SwapRouter for both tokens
        IERC20(_token0).safeApprove(_swapRouter, type(uint256).max);
        IERC20(_token1).safeApprove(_swapRouter, type(uint256).max);

        _transferOwnership(_vault);
    }

    // ===== FONCTIONS DE GESTION DES AUTORISATIONS =====

    /**
     * @notice Configure l'adresse de la Safe
     * @dev Appelable par le vault owner pour permettre la migration Safe -> Timelock en phase 2.
     * @param _safe L'adresse de la Safe
     */
    function setSafeAddress(address _safe) external onlyVaultOwner {
        require(_safe != address(0), "E13");
        safeAddress = _safe;
        emit SafeAddressSet(_safe);
    }

    /**
     * @notice Autorise ou rEvoque un exEcuteur
     * @dev Appele par le vault owner. Phase 2: le Timelock passe par le Vault relay.
     * @param _executor L'adresse a autoriser/rEvoquer
     * @param _authorized True pour autoriser, false pour revoquer
     * @dev SECURITY NOTE: safeAddress n'a pas de droits de configuration ici. Il sert uniquement au rescueToken().
     *      Les autorisations operationnelles passent par le Vault owner (Safe en Phase 1, Timelock en Phase 2).
     */
    function setAuthorizedExecutor(address _executor, bool _authorized) external {
        require(_executor != address(0), "E15");
        require(msg.sender == owner(), "E16");
        authorizedExecutors[_executor] = _authorized;
        emit ExecutorAuthorized(_executor, _authorized);
    }

    // ===== FONCTIONS DE CONFIGURATION (gouvernance via Vault owner) =====

    function configureRanges(uint16 _rangeUpPercent, uint16 _rangeDownPercent) external onlyVaultOwner {
        require(_rangeUpPercent >= 10 && _rangeUpPercent <= 5000, "E17");
        require(_rangeDownPercent >= 10 && _rangeDownPercent <= 5000, "E18");

        config.rangeUpPercent = _rangeUpPercent;
        config.rangeDownPercent = _rangeDownPercent;
    }

    // ===== CONFIGURATION DYNAMIC RANGE (gouvernance) =====

    /// @notice Configure le calcul dynamique des ranges (parametres de gouvernance, lus par les keepers).
    function setDynamicRangeConfig(
        bool _enabled,
        uint8 _maxSnapshotsPerDay,
        uint8 _volatMoyDay,
        uint8 _volatTrimDay,
        uint16 _rangeStepBps,
        uint16 _rangeMultiplicatorBps,
        uint16 _rangeMinBps,
        uint16 _rangeMaxBps
    ) external onlyVaultOwner {
        require(
            _maxSnapshotsPerDay >= 1 && _maxSnapshotsPerDay <= 24 && _volatMoyDay >= 1 && _volatMoyDay <= 20
                && uint16(_volatTrimDay) * 2 + 1 <= uint16(_volatMoyDay) * uint16(_maxSnapshotsPerDay)
                && _rangeStepBps >= 10 && _rangeStepBps <= 1000 && _rangeMultiplicatorBps >= 5000
                && _rangeMultiplicatorBps <= 30000 && _rangeMinBps >= 10 && _rangeMinBps <= _rangeMaxBps
                && _rangeMaxBps <= 5000,
            "E40"
        );
        _ringCap = uint16(_volatMoyDay) * uint16(_maxSnapshotsPerDay);
        dynRangeConfig.dynamicRangeEnabled = _enabled;
        dynRangeConfig.maxSnapshotsPerDay = _maxSnapshotsPerDay;
        dynRangeConfig.volatMoyDay = _volatMoyDay;
        dynRangeConfig.volatTrimDay = _volatTrimDay;
        dynRangeConfig.rangeStepBps = _rangeStepBps;
        dynRangeConfig.rangeMultiplicatorBps = _rangeMultiplicatorBps;
        dynRangeConfig.rangeMinBps = _rangeMinBps;
        dynRangeConfig.rangeMaxBps = _rangeMaxBps;
        delete _priceRing;
        _ringHead = 0;
        dynRangeConfig.lastSnapshotAt = 0;
        emit DynamicRangeConfigured(
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

    function setDynamicRangeEnabled(bool _enabled) external onlyVaultOwner {
        dynRangeConfig.dynamicRangeEnabled = _enabled;
    }

    function setRangeMultiplicator(uint16 _rangeMultiplicatorBps) external onlyVaultOwner {
        require(_rangeMultiplicatorBps >= 5000 && _rangeMultiplicatorBps <= 30000, "E44");
        dynRangeConfig.rangeMultiplicatorBps = _rangeMultiplicatorBps;
    }

    function isSnapshotDue() external view returns (bool) {
        if (!dynRangeConfig.dynamicRangeEnabled) return false;
        return RangeOperations.isSnapshotDue(dynRangeConfig, uint64(block.timestamp));
    }

    /// @notice Enregistre un snapshot de prix (permissionless). Verse le metrics bounty au keeper.
    function recordPriceSnapshot() external nonReentrant {
        require(dynRangeConfig.dynamicRangeEnabled, "E45");
        require(RangeOperations.isSnapshotDue(dynRangeConfig, uint64(block.timestamp)), "E46");

        _updatePriceCache();
        require(priceCache.valid && priceCache.price0 > 0, "E38");

        _ringHead = RangeOperations.writeRing(
            _priceRing,
            _ringHead,
            _ringCap,
            RangeOperations.PriceSnapshot({price: priceCache.price0, timestamp: uint64(block.timestamp)})
        );
        dynRangeConfig.lastSnapshotAt = uint64(block.timestamp);
        _applyDynamicRangeIfDue();

        _payBounty(true);
        emit PriceSnapshotRecorded(priceCache.price0, uint64(block.timestamp), msg.sender);
    }

    /// @dev Recalcule et applique le range dynamique (calcul + decision delegues a la library).
    function _applyDynamicRangeIfDue() private {
        (uint16 halfBps, bool shouldApply) =
            RangeOperations.evaluateDynamicRange(_priceRing, priceCache.price0, dynRangeConfig, uint64(block.timestamp));
        if (!shouldApply) return;
        config.rangeUpPercent = halfBps;
        config.rangeDownPercent = halfBps;
        emit DynamicRangeApplied(halfBps);
    }

    function configureSlippage(uint24 _maxSlippageBps) external onlyVaultOwner {
        require(_maxSlippageBps >= 50 && _maxSlippageBps <= 500, "E19");
        config.maxSlippageBps = _maxSlippageBps;
    }

    function configureTolerance(uint16 _toleranceBps) external onlyVaultOwner {
        require(_toleranceBps <= 1000, "E20");

        uint16 oldTolerance = config.toleranceBps;
        config.toleranceBps = _toleranceBps;

        emit ToleranceUpdated(oldTolerance, _toleranceBps);
    }

    function configureProtections(
        bool _twapGuardEnabled,
        bool _mevProtection,
        bool _failureProtection,
        uint16 _maxTwapDeviationBps
    ) external onlyVaultOwner {
        // Historical field names kept for ABI/storage compatibility:
        // sandwichDetectionEnabled = spot/TWAP guard enabled, sandwichThresholdBps = max TWAP tick drift.
        require(_maxTwapDeviationBps <= 1000, "E21");
        require(!_twapGuardEnabled || _maxTwapDeviationBps > 0, "E21");

        protectionConfig.sandwichDetectionEnabled = _twapGuardEnabled;
        protectionConfig.mevProtectionEnabled = _mevProtection;
        protectionConfig.failureProtectionEnabled = _failureProtection;
        protectionConfig.sandwichThresholdBps = _maxTwapDeviationBps;
    }

    /// @notice (audit V1 — V3-M1) Paramètres oracle : seuil de déviation pool/oracle + heartbeats par feed.
    /// @dev Gouvernance via Vault owner (Safe phase 1, Timelock phase 2). Bornes dures : déviation <=10%,
    ///      heartbeats 1h-48h. _maxOracleDeviationBps=0
    ///      désactive le check (mode dégradé volontaire). Aiguille tous les _updatePriceCache() en aval. DN-coh.
    function setOracleParams(uint16 _maxOracleDeviationBps, uint32 _maxAge0, uint32 _maxAge1) external onlyVaultOwner {
        require(_maxOracleDeviationBps <= 1000, "E21"); // déviation <=10%
        require(_maxAge0 >= 3600 && _maxAge0 <= 172800 && _maxAge1 >= 3600 && _maxAge1 <= 172800, "E20"); // 1h-48h
        protectionConfig.maxOracleDeviationBps = _maxOracleDeviationBps;
        protectionConfig.maxAge0 = _maxAge0;
        protectionConfig.maxAge1 = _maxAge1;
    }

    /**
     * @notice Configure les oracles de prix Chainlink
     * @dev SECURITY: gouvernance via Vault owner. Le bot ne whitelist pas cette fonction.
     */
    // SÉCURITÉ (audit V1) : configurePriceFeeds REPOINTE les oracles Chainlink. C'est une opération de
    // GOUVERNANCE rare et sensible (un mauvais feed empoisonne tous les prix) -> retiree du SecureBotModule
    // (une clé bot compromise ne peut plus repointer). Le rafraîchissement
    // courant du cache (avant chaque tx) se fait via refreshPriceCache() ci-dessous, qui NE change aucune
    // adresse.
    function configurePriceFeeds(
        address _token0PriceFeed,
        address _token1PriceFeed,
        address _nativePriceFeedForBatchCheck
    ) external onlyVaultOwner {
        require(
            _token0PriceFeed != address(0) && _token1PriceFeed != address(0)
                && _nativePriceFeedForBatchCheck != address(0),
            "E23"
        );

        token0PriceFeed = AggregatorV3Interface(_token0PriceFeed);
        token1PriceFeed = AggregatorV3Interface(_token1PriceFeed);

        _updatePriceCache();
        require(priceCache.valid, "E38");

        config.oraclesConfigured = true;

        _recordSuccessfulOperation();
    }

    /// @notice Rafraîchit le cache de prix (lit les feeds Chainlink déjà configurés). NE modifie AUCUNE
    ///         adresse d'oracle — sûr en permissionless : l'appelant paie le gas et ne choisit aucun paramètre.
    /// @dev audit V1 — V3-H1 : le MultiUserVault l'appelle AVANT chaque mint/withdraw pour que le cache reflète
    ///      slot0+oracle LIVE. Ouvert aussi aux keepers/users pour éviter qu'un cache stale bloque l'action
    ///      suivante. Miroir exact de la pool DN (pas de _recordSuccessfulOperation ici).
    function refreshPriceCache() external {
        _updatePriceCache();
    }

    // ===== FONCTIONS PRINCIPALES (modifiees avec onlyAuthorized) =====

    function mintInitialPosition()
        external
        onlyAuthorized
        nonReentrant
        operationalChecks
        maxPositionsCheck
        returns (uint256 tokenId, uint128 liquidity)
    {
        require(config.oraclesConfigured, "E26");

        try this._mintInternal() returns (uint256 _tokenId, uint128 _liquidity) {
            _recordSuccessfulOperation();
            return (_tokenId, _liquidity);
        } catch (bytes memory reason) {
            if (reason.length > 0) {
                assembly {
                    revert(add(32, reason), mload(reason))
                }
            } else {
                revert("E27");
            }
        }
    }

    // rebalancePosition supprimee - le rebalance se fait maintenant via:
    // 1. burnPosition() - collecte fees + retire liquidite
    // 2. executeSwap() x N - swaps via Uniswap V3
    // 3. mintInitialPosition() - mint nouvelle position

    /**
     * @notice Internal mint function - callable only via try/catch from this contract
     * @dev SECURITY NOTE: This function uses `external` visibility with `msg.sender == address(this)`
     *      check intentionally. This is a standard Solidity pattern for try/catch error handling.
     *      In Solidity, try/catch only works with external calls, so to catch errors from internal
     *      logic, we must:
     *      1. Make the function external
     *      2. Call it via `this._mintInternal()` (external call to self)
     *      3. Protect with `require(msg.sender == address(this))` to prevent external exploitation
     *      This is NOT a security vulnerability - it's a design pattern. The only entry point is
     *      mintInitialPosition() which is protected by onlyAuthorized modifier.
     * @return tokenId The ID of the newly minted position
     * @return liquidity The amount of liquidity minted
     */
    function _mintInternal() external returns (uint256 tokenId, uint128 liquidity) {
        require(msg.sender == address(this), "E29"); // Self-call only - see NatSpec above

        // audit V1 (V3-H2) : refresh + barrière déviation/staleness AVANT de minter (cohérent DN). Cache invalidé
        // si le pool diverge de l'oracle => on refuse de poser de la liquidité sur un prix manipulé.
        _refreshAndRequireValid();

        // Verifier qu'on a des tokens a minter (swaps deja faits via executeSwap)
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        require(balance0 > 0 || balance1 > 0, "E30");

        // Calculer les ticks cibles
        (int24 tickLower, int24 tickUpper) = RangeOperations.calculateTargetTicks(priceCache, config, pool);

        // PAS DE SWAP ICI - les swaps sont faits via executeSwap (multi-swap) avant d'appeler cette fonction

        // Minter la nouvelle position avec les balances actuelles
        (tokenId, liquidity) = RangeOperations.mintNewPosition(
            token0, token1, config, tickLower, tickUpper, positionManager, address(this)
        );

        _addPosition(tokenId);

        uint256 totalValueUSD = _getCurrentPortfolioValue();
        config.lastRebalanceTime = uint64(block.timestamp);
        _updateSystemStats(totalValueUSD);

        emit PositionCreated(tokenId, tickLower, tickUpper, _safeUint128(totalValueUSD), "m");

        return (tokenId, liquidity);
    }

    /**
     * @notice Retire de la liquidite pour un withdraw utilisateur
     * @dev Pas de commission ici : les fees sont deja commissionnees par collectFeesForVault()
     *      appele dans _handleUnclaimedFeesOnWithdraw() du Vault avant ce call.
     */
    function removeLiquidityForWithdraw(uint256 tokenId, uint128 liquidityToRemove) external onlyVault nonReentrant {
        if (liquidityToRemove > 0) {
            _refreshAndRequireValid();
            RangeOperations.decreaseLiquidityPartialCore(
                tokenId, liquidityToRemove, positionManager, pool, config.maxSlippageBps, address(this)
            );
            emit TokenWithdrawn(token0, 0, "w");
        }
    }

    /**
     * @notice Transfere les tokens pour un withdraw utilisateur
     */
    function transferTokensForWithdraw(uint256 amount0Requested, uint256 amount1Requested, address recipient)
        external
        onlyVault
        returns (uint256 amount0Sent, uint256 amount1Sent)
    {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        amount0Sent = balance0 >= amount0Requested ? amount0Requested : balance0;
        amount1Sent = balance1 >= amount1Requested ? amount1Requested : balance1;
        if (amount0Sent > 0) {
            IERC20(token0).safeTransfer(recipient, amount0Sent);
            emit TokenWithdrawn(token0, amount0Sent, "u");
        }
        if (amount1Sent > 0) {
            IERC20(token1).safeTransfer(recipient, amount1Sent);
            emit TokenWithdrawn(token1, amount1Sent, "u");
        }
    }

    /**
     * @notice Collecte les fees accumulées dans la position NFT et les envoie au vault
     * @dev Appelée par le vault avant un withdraw pour que l'utilisateur récupère ses pending fees
     * @return fees0 Montant de token0 collecté
     * @return fees1 Montant de token1 collecté
     */
    function collectFeesForVault() external onlyVault returns (uint256 fees0, uint256 fees1) {
        uint256[] memory positions = getOwnerPositions();
        if (positions.length == 0) return (0, 0);

        (fees0, fees1) = RangeOperations.collectFeesForVaultCore(
            positions[0], token0, token1, address(this), treasuryAddress, vault, positionManager
        );
        if (fees0 > 0 || fees1 > 0) emit FeesCollectedForVault(fees0, fees1);
    }

    event FeesCollectedForVault(uint256 fees0, uint256 fees1);

    /**
     * @notice Ajoute de la liquidite a la position existante
     * @dev Les swaps doivent etre faits AVANT via executeSwap (multi-swap) par le bot
     *      Cette fonction ajoute simplement la liquidite avec les balances actuelles
     */
    function addLiquidityToPosition() external onlyVaultOrAuthorized nonReentrant {
        // audit V1 (V3-H2) : barrière déviation/staleness avant d'ajouter de la liquidité (composition LP
        // sensible au prix du pool). Cache invalidé si le pool diverge de l'oracle => on refuse. Cohérent DN.
        uint256 tokenId = _refreshAndFirstPosition();

        // Déléguer à la library SANS SWAP (les swaps sont faits avant via executeSwap)
        (uint128 liquidity, uint256 amount0Added, uint256 amount1Added) = RangeOperations.addLiquidityWithoutSwap(
            token0, token1, tokenId, positionManager, config.maxSlippageBps, address(this)
        );

        emit LiquidityAdded(tokenId, amount0Added, amount1Added, liquidity);
    }

    // ===== FONCTIONS DE CONSULTATION =====

    function getOwnerPositions() public view returns (uint256[] memory positions) {
        positions = new uint256[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = indexToPosition[uint32(i)];
        }
    }

    /// @dev Helper privé mutualisant l'appel (9 args) à RangeOperations.getBotInstructions, factorisé pour
    ///      éviter de dupliquer le marshalling dans getBotInstructions()/needsRebalance()/rebalance(). DN-coh.
    function _botInstructions()
        private
        view
        returns (bool hasPosition, uint256 tokenId, bool shouldRebalance, string memory action, string memory reason)
    {
        return RangeOperations.getBotInstructions(
            positionCount, config.maxPositions, getOwnerPositions(), positionManager, priceCache
        );
    }

    function getBotInstructions()
        external
        view
        returns (bool hasPosition, uint256 tokenId, bool shouldRebalance, string memory action, string memory reason)
    {
        return _botInstructions();
    }

    /**
     * @notice Fonction publique pour calculer les target ticks (appelable par le bot)
     * @dev Utilise le cache prix interne mis a jour
     * @return tickLower Le tick inferieur calcule
     * @return tickUpper Le tick superieur calcule
     */
    function calculateTargetTicks() external view returns (int24 tickLower, int24 tickUpper) {
        _requireOperational();
        // Utiliser la library avec le cache interne
        return RangeOperations.calculateTargetTicks(priceCache, config, pool);
    }

    /**
     * @notice Fonction publique pour verifier si une position est out of range
     * @param tokenId L'ID de la position a verifier
     * @return bool True si la position est hors du range
     */
    function isPositionOutOfRange(uint256 tokenId) external view returns (bool) {
        // Verifier que le cache est valide
        if (!priceCache.valid) {
            return false;
        }

        // Utiliser la library avec le cache interne
        return RangeOperations.isPositionOutOfRange(tokenId, positionManager, priceCache);
    }

    /**
     * @notice Fonction helper pour obtenir les details d'une position
     * @param tokenId L'ID de la position
     * @return inRange Si la position est dans le range
     * @return tickLower Le tick inferieur de la position
     * @return tickUpper Le tick superieur de la position
     * @return liquidity La liquidite de la position
     * @return currentTick Le tick actuel de la pool
     */
    function getPositionDetails(uint256 tokenId)
        external
        view
        returns (bool inRange, int24 tickLower, int24 tickUpper, uint128 liquidity, int24 currentTick)
    {
        // Déporté en library (audit V1 — cohérence avec le DN + gain bytecode).
        return RangeOperations.getPositionDetails(positionManager, priceCache, tokenId);
    }

    function getCurrentBalances() external view returns (uint256 balance0, uint256 balance1) {
        // Récupérer les balances dans RangeManager + positions NFT
        // Cela inclut : tokens libres + liquidité active + tokensOwed (pending fees)
        (balance0, balance1) = RangeOperations.getCurrentBalances(
            token0, token1, address(this), getOwnerPositions(), positionManager, pool
        );
    }

    function isSystemOperational() external view returns (bool) {
        return config.oraclesConfigured && priceCache.valid;
    }

    /**
     * @notice Calcule les parametres optimaux pour le swap avant mint/rebalance
     * @dev Delegue le calcul a la library RangeOperations
     */
    function getOptimalSwapParams() external view returns (RangeOperations.OptimalSwapParams memory) {
        _requireOperational();
        // AUDIT C-02 : balances TOTALES (libres + principal NFT) = composition POST-burn que rebalance()
        // rééquilibrera. Sinon une position hors-range (quasi mono-token, ~0 libre) → 0 swap calculé → mint
        // revert après burn. getCurrentBalances() reflète l'état post-burn → dimensionnement keeper correct.
        (uint256 bal0, uint256 bal1) = RangeOperations.getCurrentBalances(
            token0, token1, address(this), getOwnerPositions(), positionManager, pool
        );
        return RangeOperations.calculateOptimalSwapParams(bal0, bal1, priceCache, config, pool);
    }

    function validateDepositSwapPlan(
        uint256 depositAmount0,
        uint256 depositAmount1,
        uint256[] calldata swapAmountsIn,
        uint256[] calldata minAmountsOut,
        address tokenIn,
        address tokenOut
    ) external view onlyVault {
        require(swapAmountsIn.length == minAmountsOut.length, "len");
        (bool expectedZeroForOne, uint256 expectedAmountIn) =
            RangeOperations.depositSwapParams(address(this), depositAmount0, depositAmount1);
        uint256 n = swapAmountsIn.length;
        uint256 totalSwapIn;
        bool tokenInIsToken0 = tokenIn == token0;
        if (n > 0) {
            require((tokenIn == token0 && tokenOut == token1) || (tokenIn == token1 && tokenOut == token0), "E43");
            RangeOperations.validateMinOutsAgainstOracle(
                tokenInIsToken0, swapAmountsIn, minAmountsOut, priceCache, config, initMultiSwapTvl
            );
            for (uint256 i; i < n; ++i) {
                totalSwapIn += swapAmountsIn[i];
            }
        }
        _requireSubmittedSwapPlan(
            expectedAmountIn, expectedZeroForOne, tokenInIsToken0, totalSwapIn, config.toleranceBps
        );
    }

    // ===== FONCTIONS INTERNES =====

    /// @dev (audit V1 — V3-H2) Refresh + barrière déviation/staleness mutualisée. updatePriceCache invalide le
    ///      cache si le pool diverge de l'oracle ou si un feed est stale ; on revert alors avant toute action LP.
    function _refreshAndRequireValid() private {
        _updatePriceCache();
        require(priceCache.valid, "E38");
    }

    /// @dev (audit V1 — V3-H2) Prologue mutualisé add/decrease : refresh+barrière déviation puis 1ère position.
    function _refreshAndFirstPosition() private returns (uint256) {
        _refreshAndRequireValid();
        uint256[] memory positions = getOwnerPositions();
        require(positions.length > 0, "E35");
        return positions[0];
    }

    /// @dev Garde mutualisée : oracles configurés + cache valide (factorisée pour le bytecode).
    function _requireOperational() private view {
        require(config.oraclesConfigured, "E37");
        require(priceCache.valid, "E38");
    }

    /// @dev Verse un bounty au msg.sender (silent : ne bloque jamais l'action). isMetrics => payMetricsBounty,
    ///      sinon payKeeperBounty. Factorisé (recordPriceSnapshot + rebalance) pour le bytecode. DN-coh.
    function _payBounty(bool isMetrics) private {
        if (treasuryAddress == address(0)) return;
        if (isMetrics) {
            try ITreasury(treasuryAddress).payMetricsBounty(msg.sender) {} catch {}
        } else {
            try ITreasury(treasuryAddress).payKeeperBounty(msg.sender) {} catch {}
        }
    }

    function _updatePriceCache() private {
        if (address(token0PriceFeed) == address(0) || address(token1PriceFeed) == address(0)) {
            priceCache.valid = false;
            return;
        }
        // SIMPLIFIÉ (audit V1 — gain bytecode, cohérence DN) : le pré-check try/catch latestRoundData +
        // price<=0 était REDONDANT avec RangeOperations.updatePriceCache. Un seul try/catch suffit.
        try this._updatePriceCacheInternal() {
            emit PriceCacheUpdated(priceCache.price0, priceCache.price1, priceCache.poolTick);
        } catch {
            priceCache.valid = false;
        }
    }

    /**
     * @notice Internal price cache update function - callable only via try/catch from this contract
     * @dev SECURITY NOTE: This function uses `external` visibility with `msg.sender == address(this)`
     *      check intentionally. This is a standard Solidity pattern for try/catch error handling.
     *      In Solidity, try/catch only works with external calls, so to catch errors from internal
     *      logic, we must:
     *      1. Make the function external
     *      2. Call it via `this._updatePriceCacheInternal()` (external call to self)
     *      3. Protect with `require(msg.sender == address(this))` to prevent external exploitation
     *      This is NOT a security vulnerability - it's a design pattern. The only entry point is
     *      _updatePriceCache() which is called internally by other protected functions.
     */
    function _updatePriceCacheInternal() external {
        require(msg.sender == address(this), "E39"); // Self-call only - see NatSpec above
        // Utiliser la library pour calculer le nouveau cache
        RangeOperations.PriceCache memory newCache = RangeOperations.updatePriceCache(
            token0PriceFeed,
            token1PriceFeed,
            pool,
            config,
            protectionConfig.sandwichDetectionEnabled,
            protectionConfig.sandwichThresholdBps,
            protectionConfig.maxOracleDeviationBps,
            protectionConfig.maxAge0,
            protectionConfig.maxAge1
        );
        // Mettre a jour le storage
        priceCache = newCache;
    }

    function _addPosition(uint256 tokenId) private {
        if (!isOwnedPosition[tokenId]) {
            uint32 index = positionCount++;
            positionIndex[tokenId] = index;
            indexToPosition[index] = tokenId;
            isOwnedPosition[tokenId] = true;
        }
    }

    function _removePosition(uint256 tokenId) private {
        if (isOwnedPosition[tokenId]) {
            uint32 index = positionIndex[tokenId];
            uint32 lastIndex = --positionCount;

            if (index != lastIndex) {
                uint256 lastTokenId = indexToPosition[lastIndex];
                indexToPosition[index] = lastTokenId;
                positionIndex[lastTokenId] = index;
            }

            delete indexToPosition[lastIndex];
            delete positionIndex[tokenId];
            delete isOwnedPosition[tokenId];
        }
    }

    function _recordSuccessfulOperation() private {
        systemStats.successfulOperations++;
    }

    function _updateSystemStats(uint256 newValue) private {
        systemStats.totalRebalances++;
        systemStats.totalVolume += _safeUint128(newValue);
        systemStats.lastRebalanceBlock = uint64(block.number);
    }

    function _getCurrentPortfolioValue() private view returns (uint256) {
        return IMultiUserVault(vault).getCurrentPortfolioValue();
    }

    function _safeUint128(uint256 value) private pure returns (uint128) {
        require(value <= MAX_UINT128, "E40");
        return uint128(value);
    }

    /**
     * @notice Fonction d'urgence pour retirer des fonds pour un utilisateur
     * @dev Appelee uniquement par le Vault en cas d'urgence
     * @param amount0Requested Montant de token0 demande
     * @param amount1Requested Montant de token1 demande
     * @param recipient L'adresse qui recevra les tokens
     * @return amount0Sent Montant de token0 effectivement envoye
     * @return amount1Sent Montant de token1 effectivement envoye
     */
    function emergencyWithdrawForUser(uint256 amount0Requested, uint256 amount1Requested, address recipient)
        external
        onlyVault
        nonReentrant
        returns (uint256 amount0Sent, uint256 amount1Sent)
    {
        require(recipient != address(0), "E41");
        (amount0Sent, amount1Sent) = RangeOperations.emergencyWithdrawCore(
            token0, token1, amount0Requested, amount1Requested, recipient, address(this)
        );
        emit EmergencyWithdraw(recipient, amount0Sent, amount1Sent, msg.sender);
        return (amount0Sent, amount1Sent);
    }

    // Event pour emergencyWithdrawForUser
    event EmergencyWithdraw(address indexed recipient, uint256 amount0, uint256 amount1, address indexed initiator);

    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Recover ERC-20 tokens accidentally sent to this contract.
     * @dev Safe-only in Phase 1 and Phase 2. Pool tokens (token0/token1) are excluded
     *      to avoid interfering with rebalance flows; use the Vault path for those.
     */
    function rescueToken(address tokenAddr, address to, uint256 amount) external {
        require(msg.sender == safeAddress, "E16");
        require(to != address(0), "E40");
        require(tokenAddr != token0 && tokenAddr != token1, "E41");
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit TokenRescued(tokenAddr, to, amount);
    }

    /**
     * @notice Burn une position NFT apres avoir retire toute la liquidite
     * @dev Appelee par le Vault ou les adresses autorisees (pour multi-swap)
     *      Collecte les fees et les transfère au vault (comme rebalancePosition)
     * @param tokenId L'ID de la position a burn
     */
    function burnPosition(uint256 tokenId) external onlyVaultOrAuthorized nonReentrant {
        _refreshAndRequireValid();
        _burnTrackedPosition(tokenId);
    }

    function _burnTrackedPosition(uint256 tokenId) private {
        require(isOwnedPosition[tokenId], "E42");
        (uint128 liquidity, uint256 fees0, uint256 fees1) = RangeOperations.burnPositionCore(
            tokenId, token0, token1, address(this), treasuryAddress, vault, positionManager, pool, config.maxSlippageBps
        );

        _removePosition(tokenId);
        emit PositionBurned(tokenId, liquidity, fees0, fees1);
    }

    // Event pour burnPosition
    event PositionBurned(
        uint256 indexed tokenId, uint128 liquidityBurned, uint256 fees0Collected, uint256 fees1Collected
    );

    /**
     * @notice Execute a swap via Uniswap V3
     * @notice Execute a swap via Uniswap V3 SwapRouter
     * @param tokenIn Source token address
     * @param tokenOut Destination token address
     * @param amountIn Amount to swap
     * @param minAmountOut Minimum output (slippage protection)
     * @return amountOut Actual amount received
     */
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        onlyAuthorized
        nonReentrant
        returns (uint256 amountOut)
    {
        require((tokenIn == token0 && tokenOut == token1) || (tokenIn == token1 && tokenOut == token0), "E43");
        // SÉCURITÉ (audit V1 — High) : executeSwap est appelable par le bot via le module. Sans plancher,
        // une clé bot compromise pourrait burn la position puis swapper avec minAmountOut=0 et capter la
        // perte par sandwich. Check déviation + plancher oracle (déporté en lib pour le bytecode). Cache
        // rafraîchi avant pour un prix courant (la barrière déviation est intégrée au refresh — V3).
        _refreshAndRequireValid();
        bool tokenInIsToken0 = tokenIn == token0;
        RangeOperations.validateSwapAgainstOracle(tokenInIsToken0, amountIn, minAmountOut, priceCache, config);
        if (initMultiSwapTvl > 0) {
            uint256 amountUsd = (amountIn * uint256(tokenInIsToken0 ? priceCache.price0 : priceCache.price1))
                / (10 ** (tokenInIsToken0 ? config.token0Decimals : config.token1Decimals));
            require(amountUsd <= initMultiSwapTvl * 1e8, "E91");
        }

        amountOut = RangeOperations.executeSwapCore(
            tokenIn,
            tokenOut,
            amountIn,
            minAmountOut,
            config.fee,
            swapFeeBps,
            treasuryAddress,
            address(this),
            swapRouter
        );
        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut);
        return amountOut;
    }

    /// @notice Check if the current position needs rebalancing
    function needsRebalance() external view returns (bool) {
        (,, bool _needsRebalance,,) = _botInstructions();
        return _needsRebalance;
    }

    /// @notice Atomic rebalance: burn → N swaps → mint → pay keeper bounty. Permissionless.
    /// @dev Each swap chunk must be ≤ initMultiSwapTvl in USD. Pass empty arrays if no swap needed.
    ///      Intentionally keeps the position-maintenance path open when PauseController blocks user flows:
    ///      live oracle/deviation checks, needsRebalance, oracle minOuts, swap caps and the vault lock guard remain active.
    /// @param swapAmountsIn Amounts to swap per chunk (must match minAmountsOut length)
    /// @param minAmountsOut Minimum swap outputs per chunk (slippage protection)
    /// @param tokenIn Source token for all swaps
    /// @param tokenOut Destination token for all swaps
    function rebalance(
        uint256[] calldata swapAmountsIn,
        uint256[] calldata minAmountsOut,
        address tokenIn,
        address tokenOut
    ) external nonReentrant {
        require(swapAmountsIn.length == minAmountsOut.length, "len");
        if (protectionConfig.mevProtectionEnabled) {
            require(block.timestamp - config.lastRebalanceTime >= MIN_REBALANCE_INTERVAL, "E03");
        }

        // SÉCURITÉ (audit V1 — High 2 / V3-H2) : rafraîchir le cache AVANT de valider les minOuts. La barrière
        // de déviation pool/oracle est INTÉGRÉE au refresh (updatePriceCache invalide le cache si divergence) :
        // le require(priceCache.valid) ci-dessous la rend INCONDITIONNELLE, y compris dans le cas n==0 (rebalance
        // sans swap) qui auparavant n'était pas couvert. validateMinOutsAgainstOracle reste appelée pour les
        // swaps (plancher minOut), mais ne dépend plus de la présence de swaps pour la déviation. Cohérent DN.
        _refreshAndRequireValid();

        // Verify rebalance is needed
        (bool hasPosition, uint256 tokenId, bool _needsRebalance,,) = _botInstructions();
        require(hasPosition && _needsRebalance, "E90");
        RangeOperations.OptimalSwapParams memory expectedPlan = this.getOptimalSwapParams();

        uint256 n = swapAmountsIn.length;
        uint256 totalSwapIn;
        bool tokenInIsToken0 = tokenIn == token0;
        if (n > 0) {
            require((tokenIn == token0 && tokenOut == token1) || (tokenIn == token1 && tokenOut == token0), "E43");
            // Validation (chunk cap + plancher oracle anti-sandwich V4) deportee en library
            // pour rester sous EIP-170. Reverte sur chunk>cap ou minOut<floor. Sans ce plancher,
            // un appelant permissionless pouvait passer minAmountsOut[i] = 0 et se faire sandwicher.
            RangeOperations.validateMinOutsAgainstOracle(
                tokenIn == token0, swapAmountsIn, minAmountsOut, priceCache, config, initMultiSwapTvl
            );
            // (déviation pool/oracle déjà garantie par _refreshAndRequireValid() en tête de rebalance — V3-H2)
            uint256 maxTotalSwapUsd = _getCurrentPortfolioValue();
            uint256 totalSwapUsd;
            uint256 priceInUsd = tokenIn == token0 ? uint256(priceCache.price0) : uint256(priceCache.price1);
            uint256 decIn = tokenIn == token0 ? config.token0Decimals : config.token1Decimals;
            for (uint256 i; i < n; ++i) {
                totalSwapIn += swapAmountsIn[i];
                totalSwapUsd += (swapAmountsIn[i] * priceInUsd) / (10 ** decIn);
            }
            require(totalSwapUsd <= maxTotalSwapUsd, "E92");
        }
        _requireSubmittedSwapPlan(
            expectedPlan.swapNeeded ? expectedPlan.amountIn : 0,
            expectedPlan.zeroForOne,
            tokenInIsToken0,
            totalSwapIn,
            config.toleranceBps
        );

        // 1. Lock vault
        IMultiUserVault(vault).startRebalance();

        // 2. Burn existing position if any
        if (hasPosition && tokenId > 0) {
            _burnTrackedPosition(tokenId);
        }

        for (uint256 i; i < n; ++i) {
            uint256 amt = swapAmountsIn[i];
            if (amt == 0) continue;
            require(IERC20(tokenIn).balanceOf(address(this)) >= amt, "E46");
            swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: config.fee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amt,
                    amountOutMinimum: minAmountsOut[i],
                    sqrtPriceLimitX96: 0
                })
            );
        }

        // 4. Mint new position
        this._mintInternal();
        _recordSuccessfulOperation();

        // 5. Unlock vault
        IMultiUserVault(vault).endRebalance();

        // 6. Pay keeper bounty (silent - don't revert if bounty fails)
        _payBounty(false);
    }

    function _requireSubmittedSwapPlan(
        uint256 expectedAmountIn,
        bool expectedZeroForOne,
        bool tokenInIsToken0,
        uint256 submittedAmountIn,
        uint16 toleranceBps
    ) private pure {
        if (expectedAmountIn == 0) {
            require(submittedAmountIn == 0, "E93");
            return;
        }
        require(tokenInIsToken0 == expectedZeroForOne, "E94");
        uint256 tolerance = (expectedAmountIn * uint256(toleranceBps)) / 10000;
        if (tolerance == 0) tolerance = 1;
        require(submittedAmountIn + tolerance >= expectedAmountIn, "E93");
        require(submittedAmountIn <= expectedAmountIn + tolerance, "E93");
    }

    // ===== ADMIN SETTERS =====

    function setInitMultiSwapTvl(uint256 _initMultiSwapTvl) external onlyVaultOwner {
        require(_initMultiSwapTvl > 0 && _initMultiSwapTvl <= 1_000_000, "E97");
        emit InitMultiSwapTvlUpdated(initMultiSwapTvl, _initMultiSwapTvl);
        initMultiSwapTvl = _initMultiSwapTvl;
    }

    function setSwapFeeBps(uint16 _swapFeeBps) external onlyVaultOwner {
        require(_swapFeeBps == 0, "E99");
        emit SwapFeeBpsUpdated(swapFeeBps, _swapFeeBps);
        swapFeeBps = _swapFeeBps;
    }

    function setTreasuryAddress(address _treasuryAddress) external onlyVaultOwner {
        require(_treasuryAddress != address(0), "E98"); // audit LOW : garde address(0)
        emit TreasuryAddressUpdated(treasuryAddress, _treasuryAddress); // audit LOW-5 : observabilité
        treasuryAddress = _treasuryAddress;
    }

    // ===== EVENTS =====

    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
}
