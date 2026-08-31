// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

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
import "./interfaces/IRangeStrategyEngine.sol";

interface ITreasury {
    function payKeeperBounty(address keeper) external;
}

interface IProtocolBotIdentity {
    function botAddress() external view returns (address);
}

interface IMultiUserVault {
    function getCurrentPortfolioValue() external view returns (uint256);
    function maxDepositUsd() external view returns (uint256);
    function startRebalance() external;
    function endRebalance() external;
    function isRebalancing() external view returns (bool);
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

    error E01();
    error E03();
    error E04();
    error E06();
    error E07();
    error E13();
    error E15();
    error E16();
    error E19();
    error E20();
    error E21();
    error E40();
    error E94();
    error E99();

    uint256 private constant MAX_UINT128 = type(uint128).max;
    uint256 private constant MIN_REBALANCE_INTERVAL = 300;
    uint256 private constant MAIN_BOT_KEEPER_DELAY = 60;

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

    // ===== SWAP & TREASURY =====
    ISwapRouter public immutable swapRouter;
    address public treasuryAddress;
    uint256 public initMultiSwapTvl;
    IRangeStrategyEngine public strategyEngine;
    address public protocolBotAddress;
    address private protocolBotOperator;

    // ===== VARIABLES D'ETAT (utilisant les structs de la library) =====

    RangeOperations.RangeConfig public config;
    RangeOperations.ProtectionConfig public protectionConfig;
    RangeOperations.PriceCache public priceCache;

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
    event LiquidityAdded(uint256 indexed tokenId, uint256 amount0, uint256 amount1, uint128 liquidity);
    event StrategyEngineSet(address indexed strategyEngine, address indexed protocolBot);

    // ===== NOUVEAUX MODIFIERS =====

    /**
     * @dev Droits operationnels uniquement: bot module / executors peuvent maintenir la position,
     * mais les reglages de gouvernance passent par onlyVaultOwner.
     */
    modifier onlyAuthorized() {
        if (!(msg.sender == owner() || authorizedExecutors[msg.sender])) revert E99();
        _;
    }

    /**
     * @dev Modifier strictement pour le owner (MultiUserVault)
     * Utilise pour les fonctions de gestion des autorisations
     */
    modifier onlyVaultOwner() {
        if (msg.sender != owner()) revert E01();
        _;
    }

    modifier operationalChecks() {
        // Failure counters are informational only: state changes made before a revert are rolled back by the EVM.
        // Liveness must rely on the bot/module watchdog, oracle/deviation checks and Safe intervention.
        if (protectionConfig.mevProtectionEnabled) {
            if (block.timestamp - config.lastRebalanceTime < MIN_REBALANCE_INTERVAL) revert E03();
        }
        if (!config.oraclesConfigured) revert E04();
        _;
    }

    modifier maxPositionsCheck() {
        if (positionCount >= config.maxPositions) revert E06();
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert E07();
        _;
    }

    modifier onlyVaultOrAuthorized() {
        if (
            !(
                msg.sender == address(this) || msg.sender == vault || msg.sender == owner()
                    || authorizedExecutors[msg.sender]
            )
        ) revert E94();
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
        uint256 _initMultiSwapTvl
    ) {
        require(_vault != address(0), "E09");
        require(_pauseController != address(0), "E09");
        vault = _vault;

        require(
            _positionManager != address(0) && _factory != address(0) && _token0 != address(0) && _token1 != address(0)
                && _token0 != _token1 && _token0 < _token1,
            "E10"
        );

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
            maxPositions: 1
        });

        protectionConfig = RangeOperations.ProtectionConfig({
            sandwichDetectionEnabled: false,
            mevProtectionEnabled: true,
            maxTwapDeviationTicks: 50,
            maxOracleDeviationBps: 100,
            maxAge0: 90000, // heartbeat par défaut (25h) — cohérent avec la pool DN
            maxAge1: 90000
        });

        // Swap & Treasury config
        require(_swapRouter != address(0), "E51");
        require(_treasuryAddress != address(0), "E98");
        swapRouter = ISwapRouter(_swapRouter);
        treasuryAddress = _treasuryAddress;
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
        if (_safe == address(0)) revert E13();
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
        if (_executor == address(0)) revert E15();
        if (msg.sender != owner()) revert E16();
        authorizedExecutors[_executor] = _authorized;
        emit ExecutorAuthorized(_executor, _authorized);
    }

    /// @notice Returns whether `caller` belongs to the protocol-operated execution path.
    /// @dev RangeStrategyEngine uses this view to enforce the community keeper priority window on-chain.
    function isProtocolBotCaller(address caller) public view returns (bool) {
        return caller != address(0)
            && (
                caller == protocolBotAddress || caller == protocolBotOperator || caller == safeAddress
                    || authorizedExecutors[caller]
            );
    }

    // ===== FONCTIONS DE CONFIGURATION (gouvernance via Vault owner) =====

    /// @notice One-time reciprocal link to this pool's immutable strategy engine.
    function setStrategyEngine(address engine, address protocolBot) external onlyVaultOwner {
        if (
            address(strategyEngine) != address(0) || engine.code.length == 0 || protocolBot.code.length == 0
                || protocolBotAddress != address(0)
        ) revert E40();
        address botOperator = IProtocolBotIdentity(protocolBot).botAddress();
        if (botOperator == address(0)) revert E40();
        IRangeStrategyEngine candidate = IRangeStrategyEngine(engine);
        IRangeStrategyEngine.StrategyProfile candidateProfile = candidate.profile();
        if (
            candidate.rangeManager() != address(this) || candidate.pool() != address(pool)
                || candidate.hedgeManager() != address(0)
                || candidateProfile == IRangeStrategyEngine.StrategyProfile.DELTA_NEUTRAL
        ) revert E40();
        strategyEngine = candidate;
        protocolBotAddress = protocolBot;
        protocolBotOperator = botOperator;
        emit StrategyEngineSet(engine, protocolBot);
    }

    function configureSlippage(uint24 _maxSlippageBps) external onlyVaultOwner {
        if (_maxSlippageBps < 50 || _maxSlippageBps > 500) revert E19();
        config.maxSlippageBps = _maxSlippageBps;
    }

    function configureTolerance(uint16 _toleranceBps) external onlyVaultOwner {
        if (_toleranceBps > 1000) revert E20();

        uint16 oldTolerance = config.toleranceBps;
        config.toleranceBps = _toleranceBps;

        emit ToleranceUpdated(oldTolerance, _toleranceBps);
    }

    function configureProtections(bool _twapGuardEnabled, bool _mevProtection, uint16 _maxTwapDeviationTicks)
        external
        onlyVaultOwner
    {
        if (_maxTwapDeviationTicks > 1000) revert E21();
        if (_twapGuardEnabled && _maxTwapDeviationTicks == 0) revert E21();

        protectionConfig.sandwichDetectionEnabled = _twapGuardEnabled;
        protectionConfig.mevProtectionEnabled = _mevProtection;
        protectionConfig.maxTwapDeviationTicks = _maxTwapDeviationTicks;
    }

    /// @notice (audit V1 — V3-M1) Paramètres oracle : seuil de déviation pool/oracle + heartbeats par feed.
    /// @dev Gouvernance via Vault owner (Safe phase 1, Timelock phase 2). Le garde pool/oracle ne peut pas être
    ///      désactivé : la NAV oracle du BotModule utilise le sqrt spot borné comme seed. Heartbeats 1h-48h.
    function setOracleParams(uint16 _maxOracleDeviationBps, uint32 _maxAge0, uint32 _maxAge1) external onlyVaultOwner {
        if (_maxOracleDeviationBps == 0 || _maxOracleDeviationBps > 1000) revert E21();
        if (_maxAge0 < 3600 || _maxAge0 > 172800 || _maxAge1 < 3600 || _maxAge1 > 172800) revert E20();
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
    }

    /// @notice Rafraîchit le cache de prix (lit les feeds Chainlink déjà configurés). NE modifie AUCUNE
    ///         adresse d'oracle — sûr en permissionless : l'appelant paie le gas et ne choisit aucun paramètre.
    /// @dev audit V1 — V3-H1 : le MultiUserVault l'appelle AVANT chaque mint/withdraw pour que le cache reflète
    ///      slot0+oracle LIVE. Ouvert aussi aux keepers/users pour éviter qu'un cache stale bloque l'action
    ///      suivante. Miroir exact de la pool DN.
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
        // The bot module calls processDepositPermissionless() on the Vault. The Vault enforces that
        // only its configured bot module (or governance) can process the first queued deposit, then
        // calls this function itself. Requiring the module here would make the atomic call chain
        // impossible because Solidity does not preserve the original caller across contracts.
        require(msg.sender == vault, "E99");
        _refreshAndRequireValid();
        IRangeStrategyEngine.Decision memory decision = _validatedStrategyDecision();
        require(
            decision.reason == IRangeStrategyEngine.ReasonCode.INITIAL_MINT_REQUIRED
                && decision.targetTickLower < priceCache.poolTick && decision.targetTickUpper > priceCache.poolTick,
            "E90"
        );

        try this._mintInternal(decision.targetTickLower, decision.targetTickUpper) returns (
            uint256 _tokenId, uint128 _liquidity
        ) {
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

    // Le chemin recurrent est adaptatif: rebalance() reste atomique sous le cap; le SecureBotModule
    // orchestre un etat progressif reprenable au-dessus, sans exposer les anciennes jambes manuelles.

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
    function _mintInternal(int24 tickLower, int24 tickUpper) external returns (uint256 tokenId, uint128 liquidity) {
        require(msg.sender == address(this), "E29"); // Self-call only - see NatSpec above

        // audit V1 (V3-H2) : refresh + barrière déviation/staleness AVANT de minter (cohérent DN). Cache invalidé
        // si le pool diverge de l'oracle => on refuse de poser de la liquidité sur un prix manipulé.
        _refreshAndRequireValid();
        require(tickLower < priceCache.poolTick && tickUpper > priceCache.poolTick, "E90");

        // Verifier qu'on a des tokens a minter (swaps deja faits via executeSwap)
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        require(balance0 > 0 || balance1 > 0, "E30");

        // PAS DE SWAP ICI - les swaps sont faits via executeSwap (multi-swap) avant d'appeler cette fonction

        // Minter la nouvelle position avec les balances actuelles
        (tokenId, liquidity) = RangeOperations.mintNewPosition(
            token0, token1, config, tickLower, tickUpper, positionManager, priceCache.poolSqrtPriceX96, address(this)
        );

        _addPosition(tokenId);

        uint256 totalValueUSD = _getCurrentPortfolioValue();
        config.lastRebalanceTime = uint64(block.timestamp);

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

        return _collectFeesForVault(positions[0]);
    }

    function _collectFeesForVault(uint256 tokenId) private returns (uint256 fees0, uint256 fees1) {
        (fees0, fees1) = RangeOperations.collectFeesForVaultCore(
            tokenId, token0, token1, address(this), treasuryAddress, vault, positionManager
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
        require(!RangeOperations.isPositionOutOfRange(tokenId, positionManager, priceCache), "E32");

        // Déléguer à la library SANS SWAP (les swaps sont faits avant via executeSwap)
        (uint128 liquidity, uint256 amount0Added, uint256 amount1Added) = RangeOperations.addLiquidityWithoutSwap(
            token0, token1, tokenId, positionManager, priceCache.poolSqrtPriceX96, config.maxSlippageBps, address(this)
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

    /**
     * @notice Fonction publique pour calculer les target ticks (appelable par le bot)
     * @dev Utilise le cache prix interne mis a jour
     * @return tickLower Le tick inferieur calcule
     * @return tickUpper Le tick superieur calcule
     */
    function calculateTargetTicks() external view returns (int24 tickLower, int24 tickUpper) {
        _requireOperational();
        IRangeStrategyEngine.Decision memory decision = _validatedStrategyDecision();
        tickLower = decision.targetTickLower;
        tickUpper = decision.targetTickUpper;
        require(tickLower < priceCache.poolTick && tickUpper > priceCache.poolTick, "E90");
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
        IRangeStrategyEngine.Decision memory decision = _validatedStrategyDecision();
        return _optimalSwapParams(decision.targetTickLower, decision.targetTickUpper);
    }

    function _optimalSwapParams(int24 tickLower, int24 tickUpper)
        private
        view
        returns (RangeOperations.OptimalSwapParams memory)
    {
        // AUDIT C-02 : balances TOTALES (libres + principal NFT) = composition POST-burn que rebalance()
        // rééquilibrera. Sinon une position hors-range (quasi mono-token, ~0 libre) → 0 swap calculé → mint
        // revert après burn. getCurrentBalances() reflète l'état post-burn → dimensionnement keeper correct.
        (uint256 bal0, uint256 bal1) = RangeOperations.getCurrentBalances(
            token0, token1, address(this), getOwnerPositions(), positionManager, pool
        );
        return RangeOperations.calculateOptimalSwapParams(bal0, bal1, priceCache, config, tickLower, tickUpper);
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
            uint256 totalSwapUsd = RangeOperations.validateMinOutsAgainstOracle(
                tokenInIsToken0, swapAmountsIn, minAmountsOut, priceCache, config, initMultiSwapTvl
            );
            uint256 depositUsd = ((depositAmount0 * uint256(priceCache.price0)) / (10 ** config.token0Decimals))
                + ((depositAmount1 * uint256(priceCache.price1)) / (10 ** config.token1Decimals));
            require(totalSwapUsd <= depositUsd, "swap>deposit");
            for (uint256 i; i < n; ++i) {
                totalSwapIn += swapAmountsIn[i];
            }
            require(totalSwapIn <= (tokenInIsToken0 ? depositAmount0 : depositAmount1), "swap>input");
        }
        _requireSubmittedSwapPlan(
            expectedAmountIn, expectedZeroForOne, tokenInIsToken0, totalSwapIn, config.toleranceBps
        );
    }

    // ===== FONCTIONS INTERNES =====

    function _validatedStrategyDecision() private view returns (IRangeStrategyEngine.Decision memory decision) {
        if (address(strategyEngine) == address(0)) revert E40();
        decision = strategyEngine.previewDecision();
        decision = strategyEngine.validateDecision(decision.decisionHash);
    }

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

    /// @dev Pays le bounty de rebalance sans jamais bloquer l'action principale.
    function _payBounty(address keeper) private {
        if (treasuryAddress == address(0)) return;
        try ITreasury(treasuryAddress).payKeeperBounty(keeper) {} catch {}
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
            protectionConfig.maxTwapDeviationTicks,
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

    /// @notice Removes all liquidity and burns one tracked NFT during Safe-led recovery.
    /// @dev Vault-only and intentionally independent from Chainlink/TWAP availability. No swap is performed;
    ///      the position principal and collected fees remain in this RangeManager for user recovery.
    function emergencyBurnPosition(uint256 tokenId) external onlyVault nonReentrant {
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
        return _executeValidatedSwap(tokenIn == token0, amountIn, minAmountOut);
    }

    /// @notice One state-machine step for a resumable high-TVL rebalance.
    /// @dev step 0 validates and burns; step 2 validates the final remainder, remints and unlocks.
    function progressiveRebalance(
        uint8 step,
        bytes32 expectedDecisionHash,
        int24 tickLower,
        int24 tickUpper,
        uint256 amountIn,
        uint256 minAmountOut,
        address keeper
    ) external onlyAuthorized nonReentrant returns (int24 lower, int24 upper) {
        _refreshAndRequireValid();
        if (step == 0) {
            IRangeStrategyEngine.Decision memory decision = _validatedRebalanceDecision(expectedDecisionHash, keeper);
            uint256 tokenId = indexToPosition[0];
            _collectFeesForVault(tokenId);
            strategyEngine.recordExecution(decision.decisionHash, decision.action, keeper);
            IMultiUserVault(vault).startRebalance();
            _burnTrackedPosition(tokenId);
            return (decision.targetTickLower, decision.targetTickUpper);
        }
        require(positionCount == 0 && IMultiUserVault(vault).isRebalancing(), "E90");
        RangeOperations.OptimalSwapParams memory plan = _optimalSwapParams(tickLower, tickUpper);
        require(step == 2, "E90");
        _requireSubmittedSwapPlan(
            plan.swapNeeded ? plan.amountIn : 0, plan.zeroForOne, plan.zeroForOne, amountIn, config.toleranceBps
        );
        if (amountIn > 0) _executeValidatedSwap(plan.zeroForOne, amountIn, minAmountOut);
        this._mintInternal(tickLower, tickUpper);
        IMultiUserVault(vault).endRebalance();
        _payBounty(keeper);
        return (tickLower, tickUpper);
    }

    /// @notice Atomic rebalance: burn, at most one bounded swap, mint and pay keeper bounty. Permissionless.
    /// @dev A larger canonical swap must use the resumable SecureBotModule path. Pass empty arrays if no swap is needed.
    ///      Intentionally keeps the position-maintenance path open when PauseController blocks user flows:
    ///      live oracle/deviation checks, the validated strategy decision, oracle minOuts, swap caps and the vault
    ///      lock guard remain active.
    /// @param swapAmountsIn Amounts to swap per chunk (must match minAmountsOut length)
    /// @param minAmountsOut Minimum swap outputs per chunk (slippage protection)
    /// @param tokenIn Source token for all swaps
    /// @param tokenOut Destination token for all swaps
    function rebalance(
        bytes32 expectedDecisionHash,
        uint256[] calldata swapAmountsIn,
        uint256[] calldata minAmountsOut,
        address tokenIn,
        address tokenOut
    ) external nonReentrant {
        require(swapAmountsIn.length == minAmountsOut.length, "len");
        // SÉCURITÉ (audit V1 — High 2 / V3-H2) : rafraîchir le cache AVANT de valider les minOuts. La barrière
        // de déviation pool/oracle est INTÉGRÉE au refresh (updatePriceCache invalide le cache si divergence) :
        // le require(priceCache.valid) ci-dessous la rend INCONDITIONNELLE, y compris dans le cas n==0 (rebalance
        // sans swap) qui auparavant n'était pas couvert. validateMinOutsAgainstOracle reste appelée pour les
        // swaps (plancher minOut), mais ne dépend plus de la présence de swaps pour la déviation. Cohérent DN.
        _refreshAndRequireValid();

        IRangeStrategyEngine.Decision memory decision = _validatedRebalanceDecision(expectedDecisionHash, msg.sender);
        uint256 tokenId = indexToPosition[0];

        // Crystallise les fees avant de figer le plan. Toute la sequence reste atomique : une validation,
        // un swap ou un mint qui revert annule aussi collect, commission et accounting Vault.
        _collectFeesForVault(tokenId);
        RangeOperations.OptimalSwapParams memory expectedPlan =
            _optimalSwapParams(decision.targetTickLower, decision.targetTickUpper);

        uint256 n = swapAmountsIn.length;
        require(n <= 1, "E91");
        uint256 totalSwapIn;
        bool tokenInIsToken0 = tokenIn == token0;
        if (n > 0) {
            require((tokenIn == token0 && tokenOut == token1) || (tokenIn == token1 && tokenOut == token0), "E43");
            // Validation (chunk cap + plancher oracle anti-sandwich V4) deportee en library
            // pour rester sous EIP-170. Reverte sur SwapChunkAboveCap ou MinOutBelowOracleFloor. Sans ce plancher,
            // un appelant permissionless pouvait passer minAmountsOut[i] = 0 et se faire sandwicher.
            uint256 totalSwapUsd = RangeOperations.validateMinOutsAgainstOracle(
                tokenIn == token0, swapAmountsIn, minAmountsOut, priceCache, config, initMultiSwapTvl
            );
            // (déviation pool/oracle déjà garantie par _refreshAndRequireValid() en tête de rebalance — V3-H2)
            uint256 maxTotalSwapUsd = _getCurrentPortfolioValue();
            for (uint256 i; i < n; ++i) {
                totalSwapIn += swapAmountsIn[i];
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
        strategyEngine.recordExecution(decision.decisionHash, decision.action, msg.sender);

        // 1. Lock vault
        IMultiUserVault(vault).startRebalance();

        // 2. Burn existing position if any
        if (tokenId > 0) {
            _burnTrackedPosition(tokenId);
        }

        uint160 sqrtPriceLimitX96 = n > 0 ? _swapSqrtPriceLimit(tokenInIsToken0) : 0;
        for (uint256 i; i < n; ++i) {
            uint256 amt = swapAmountsIn[i];
            if (amt == 0) continue;
            RangeOperations.executeSwapCore(
                tokenIn, tokenOut, amt, minAmountsOut[i], config.fee, address(this), swapRouter, sqrtPriceLimitX96
            );
        }

        // 4. Mint new position
        this._mintInternal(decision.targetTickLower, decision.targetTickUpper);

        // 5. Unlock vault
        IMultiUserVault(vault).endRebalance();

        // 6. Pay keeper bounty (silent - don't revert if bounty fails)
        _payBounty(msg.sender);
    }

    function _validatedRebalanceDecision(bytes32 expectedDecisionHash, address keeper)
        private
        view
        returns (IRangeStrategyEngine.Decision memory decision)
    {
        if (protectionConfig.mevProtectionEnabled) {
            require(block.timestamp - config.lastRebalanceTime >= MIN_REBALANCE_INTERVAL, "E03");
        }
        decision = strategyEngine.validateDecision(expectedDecisionHash);
        require(decision.action == IRangeStrategyEngine.Action.RANGE_REBALANCE && positionCount == 1, "E90");
        if (isProtocolBotCaller(keeper)) {
            IRangeStrategyEngine.Telemetry memory telemetry = strategyEngine.currentTelemetry();
            require(block.timestamp >= uint256(telemetry.checkpointTimestamp) + MAIN_BOT_KEEPER_DELAY, "E03");
        }
    }

    function _executeValidatedSwap(bool tokenInIsToken0, uint256 amountIn, uint256 minAmountOut)
        private
        returns (uint256 amountOut)
    {
        RangeOperations.validateSwapAgainstOracle(tokenInIsToken0, amountIn, minAmountOut, priceCache, config);
        uint256 amountUsd = (amountIn * uint256(tokenInIsToken0 ? priceCache.price0 : priceCache.price1))
            / (10 ** (tokenInIsToken0 ? config.token0Decimals : config.token1Decimals));
        require(amountUsd <= initMultiSwapTvl * 1e8, "E91");
        address tokenIn = tokenInIsToken0 ? token0 : token1;
        address tokenOut = tokenInIsToken0 ? token1 : token0;
        amountOut = RangeOperations.executeSwapCore(
            tokenIn,
            tokenOut,
            amountIn,
            minAmountOut,
            config.fee,
            address(this),
            swapRouter,
            _swapSqrtPriceLimit(tokenInIsToken0)
        );
        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev Bounds one swap to roughly config.maxSlippageBps of price movement from the validated live pool price.
    function _swapSqrtPriceLimit(bool zeroForOne) private view returns (uint160) {
        return RangeOperations.boundedSwapSqrtPriceLimit(priceCache.poolSqrtPriceX96, config.maxSlippageBps, zeroForOne);
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
        require(IMultiUserVault(vault).maxDepositUsd() <= _initMultiSwapTvl * 10 * 1e8, "E97");
        emit InitMultiSwapTvlUpdated(initMultiSwapTvl, _initMultiSwapTvl);
        initMultiSwapTvl = _initMultiSwapTvl;
    }

    function setTreasuryAddress(address _treasuryAddress) external onlyVaultOwner {
        require(_treasuryAddress != address(0), "E98"); // audit LOW : garde address(0)
        emit TreasuryAddressUpdated(treasuryAddress, _treasuryAddress); // audit LOW-5 : observabilité
        treasuryAddress = _treasuryAddress;
    }

    // ===== EVENTS =====

    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
}
