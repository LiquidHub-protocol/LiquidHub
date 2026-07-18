// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @dev Interface minimale du vault pour la comptabilite des fees (utilisee par burnPositionCore).
interface IRangeVaultComm {
    function commissionRate() external view returns (uint256);
    function recordFeesCollected(uint256 fees0, uint256 fees1, uint256 commission0, uint256 commission1) external;
}

/// @dev Lecture RangeManager pour depositSwapParams (AUDIT H-01/H-03, pool standard).
interface IRmDeposit {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getOwnerPositions() external view returns (uint256[] memory);
    function positionManager() external view returns (INonfungiblePositionManager);
    function pool() external view returns (IUniswapV3Pool);
    function priceCache() external view returns (uint128 p0, uint128 p1, uint160 sp, int24 tk, uint64 ts, bool v);
    function config()
        external
        view
        returns (uint24 fee, uint8 d0, uint8 d1, uint16 t, uint24 s, uint64 l, bool o, uint16 u, uint16 dn, uint32 m);
}

/**
 * @title RangeOperations
 * @notice Library externe pour les operations complexes du RangeManager
 */
library RangeOperations {
    using SafeERC20 for IERC20;

    error PartialFill();

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;

    // ===== STRUCTS (partages) =====

    struct RangeConfig {
        uint24 fee;
        uint8 token0Decimals;
        uint8 token1Decimals;
        uint16 toleranceBps;
        uint24 maxSlippageBps;
        uint64 lastRebalanceTime;
        bool oraclesConfigured;
        uint16 rangeUpPercent;
        uint16 rangeDownPercent;
        uint32 maxPositions;
    }

    struct PriceCache {
        uint128 price0;
        uint128 price1;
        uint160 poolSqrtPriceX96;
        int24 poolTick;
        uint64 timestamp;
        bool valid;
    }

    struct ProtectionConfig {
        // Legacy field names kept for ABI/storage compatibility:
        // sandwichDetectionEnabled = spot/TWAP guard enabled.
        bool sandwichDetectionEnabled;
        bool mevProtectionEnabled;
        bool failureProtectionEnabled;
        // sandwichThresholdBps = max spot/TWAP tick drift in bps-like ticks.
        uint16 sandwichThresholdBps;
        uint16 maxOracleDeviationBps;
        // audit V1 (V3) : heartbeats Chainlink PAR FEED (cohérence std/DN). 0 => défaut 90000s (25h) fallback.
        uint32 maxAge0;
        uint32 maxAge1;
    }

    struct SystemStats {
        uint128 totalRebalances;
        uint128 totalVolume;
        uint64 lastRebalanceBlock;
        // Deprecated: failed tx state is reverted by the EVM, so these counters are intentionally kept at zero.
        uint32 failedOperations;
        uint32 successfulOperations;
        // Deprecated: kept only for systemStats() ABI compatibility with bot/frontend readers.
        uint32 consecutiveFailures;
        bool initialized;
    }

    struct OptimalSwapParams {
        bool swapNeeded;
        bool zeroForOne;
        uint256 amountIn;
        uint256 currentBalance0;
        uint256 currentBalance1;
        uint256 targetRatio0Bps;
        int24 tickLower;
        int24 tickUpper;
    }

    // ===== DYNAMIC RANGE (calcul on-chain) =====

    /// @notice Snapshot horodate du ratio oracle token0/token1, normalise en 8 decimales.
    struct PriceSnapshot {
        uint128 price; // ratio token0/token1 en 8 decimales
        uint64 timestamp; // unix timestamp du snapshot
    }

    /// @notice Parametres de gouvernance du calcul dynamique des ranges (stockes on-chain)
    struct DynamicRangeConfig {
        bool dynamicRangeEnabled; // false => ranges fixes via configureRanges (ex: stablecoin)
        uint8 maxSnapshotsPerDay; // nombre de snapshots/jour (timing regulier = 86400/maxSnapshotsPerDay)
        uint8 volatMoyDay; // fenetre de calcul high/low en jours (<= 20)
        uint8 volatTrimDay; // nombre d'extremes hauts ET bas retires (trim des pics)
        uint16 rangeStepBps; // palier d'arrondi du range, ex 50 = 0,5%
        uint16 rangeMultiplicatorBps; // facteur d'amplitude, 10000 = x1,0 ; 12500 = x1,25 ; 8000 = x0,8
        uint16 rangeMinBps; // borne basse par cote du range dynamique (ex 100 = +/-1%)
        uint16 rangeMaxBps; // borne haute par cote du range dynamique (ex 1000 = +/-10%)
        uint64 lastSnapshotAt; // timestamp du dernier snapshot (timing regulier)
    }

    // ===== FONCTIONS PRINCIPALES =====

    /**
     * @notice Met a jour le cache prix avec validation des oracles
     */
    /// @dev V3 : on passe uniquement les 3 scalaires oracle (maxDeviationBps, maxAge0, maxAge1) au lieu de
    ///      tout le ProtectionConfig — évite au RangeManager d'ABI-encoder un struct à chaque refresh (bytecode).
    ///      Miroir exact de la pool DN (cohérence std/DN).
    function updatePriceCache(
        AggregatorV3Interface token0PriceFeed,
        AggregatorV3Interface token1PriceFeed,
        IUniswapV3Pool pool,
        RangeConfig memory cfg,
        bool twapGuardEnabled,
        uint16 maxTwapDeviationBps,
        uint16 maxDeviationBps,
        uint32 maxAge0In,
        uint32 maxAge1In
    ) external view returns (PriceCache memory newCache) {
        if (address(token0PriceFeed) == address(0) || address(token1PriceFeed) == address(0)) {
            return PriceCache(0, 0, 0, 0, 0, false);
        }

        // Pas de try/catch ici, le contrat principal s'en charge
        (uint80 roundId0, int256 price0,, uint256 updatedAt0, uint80 answeredInRound0) =
            token0PriceFeed.latestRoundData();
        (uint80 roundId1, int256 price1,, uint256 updatedAt1, uint80 answeredInRound1) =
            token1PriceFeed.latestRoundData();

        if (price0 <= 0 || price1 <= 0 || answeredInRound0 < roundId0 || answeredInRound1 < roundId1) {
            return PriceCache(0, 0, 0, 0, 0, false);
        }

        // audit V1 (V3) : âge max PAR FEED (heartbeats distincts). 0 => défaut 90000s (rétrocompat).
        uint256 maxAge0 = maxAge0In == 0 ? 90000 : uint256(maxAge0In);
        uint256 maxAge1 = maxAge1In == 0 ? 90000 : uint256(maxAge1In);
        if (block.timestamp - updatedAt0 > maxAge0 || block.timestamp - updatedAt1 > maxAge1) {
            return PriceCache(0, 0, 0, 0, 0, false);
        }

        (uint160 sqrtPriceX96, int24 tick,,,,,) = pool.slot0();

        newCache = PriceCache({
            price0: _safeUint128(uint256(price0)),
            price1: _safeUint128(uint256(price1)),
            poolSqrtPriceX96: sqrtPriceX96,
            poolTick: tick,
            timestamp: uint64(block.timestamp),
            valid: true
        });

        // audit V1 (V3 — High #1/#2) : check déviation pool/oracle INTÉGRÉ au refresh. slot0 et prix Chainlink
        // capturés au même instant => cache LIVE. Tous les appelants de _updatePriceCache héritent de la barrière.
        if (maxDeviationBps > 0 && _deviationExceeds(newCache, maxDeviationBps, cfg.token0Decimals, cfg.token1Decimals))
        {
            return PriceCache(0, 0, 0, 0, 0, false);
        }
        if (twapGuardEnabled && _twapDeviationExceeds(pool, tick, maxTwapDeviationBps)) {
            return PriceCache(0, 0, 0, 0, 0, false);
        }
    }

    function _twapDeviationExceeds(IUniswapV3Pool pool, int24 spotTick, uint16 maxTwapDeviationBps)
        private
        view
        returns (bool)
    {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 300;
        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
            int24 twapTick = int24(tickDelta / int56(uint56(300)));
            if (tickDelta < 0 && tickDelta % int56(uint56(300)) != 0) twapTick--;
            int24 diff = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
            return uint24(diff) > uint24(maxTwapDeviationBps);
        } catch {
            // Warm-up only: bypass if Uniswap has not written enough observations yet. Once at least two
            // observations exist, an observe(300s) failure is treated as unsafe and invalidates the cache.
            (,,, uint16 observationCardinality,,,) = pool.slot0();
            return observationCardinality > 1;
        }
    }

    /**
     * @notice Calcule les ticks cibles pour une nouvelle position
     * @dev Supporte les ranges asymetriques via rangeUpPercent et rangeDownPercent
     *      Le ratio optimal de tokens est calcule automatiquement par calculateOptimalRatio()
     */
    function calculateTargetTicks(PriceCache memory priceCache, RangeConfig memory config, IUniswapV3Pool pool)
        external
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        return _calculateTargetTicksInternal(priceCache, config, pool);
    }

    /**
     * @notice Version interne de calculateTargetTicks (pour appel depuis autres fonctions de la library)
     * @dev Supporte les ranges asymetriques: ticksUp et ticksDown peuvent etre differents
     *      Cela permet d'optimiser la generation de fees selon les conditions de marche
     */
    function _calculateTargetTicksInternal(PriceCache memory priceCache, RangeConfig memory config, IUniswapV3Pool pool)
        internal
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        int24 currentTick = priceCache.poolTick;
        int24 tickSpacing = pool.tickSpacing();

        // Calculer le nombre de ticks pour chaque cote (ASYMETRIQUE)
        // rangeUpPercent et rangeDownPercent sont en basis points (100 = 1%)
        // 1% de prix ≈ 100 ticks (formule exacte: log(1.01) / log(1.0001) ≈ 99.5)
        int24 ticksUp = int24(uint24(config.rangeUpPercent));
        int24 ticksDown = int24(uint24(config.rangeDownPercent));

        // Arrondir chaque cote au tickSpacing
        int24 spacingsUp = ticksUp / tickSpacing;
        if (spacingsUp < 1) spacingsUp = 1; // Minimum 1 tickSpacing
        int24 spacingsDown = ticksDown / tickSpacing;
        if (spacingsDown < 1) spacingsDown = 1; // Minimum 1 tickSpacing

        int24 alignedTicksUp = spacingsUp * tickSpacing;
        int24 alignedTicksDown = spacingsDown * tickSpacing;

        // Calculer les ticks theoriques ASYMETRIQUES autour du currentTick
        int24 theoreticalLower = currentTick - alignedTicksDown;
        int24 theoreticalUpper = currentTick + alignedTicksUp;

        // Aligner tickLower vers le bas (floor)
        tickLower = _floorToTickSpacing(theoreticalLower, tickSpacing);

        // Aligner tickUpper vers le haut (ceil)
        tickUpper = _ceilToTickSpacing(theoreticalUpper, tickSpacing);

        // Verifier que le currentTick est dans le range
        // Si non, ajuster le range pour le contenir
        if (currentTick <= tickLower) {
            // currentTick trop proche du bas, decaler le range vers le bas
            tickLower = _floorToTickSpacing(currentTick - 1, tickSpacing);
            tickUpper = tickLower + alignedTicksUp + alignedTicksDown;
        } else if (currentTick >= tickUpper) {
            // currentTick trop proche du haut, decaler le range vers le haut
            tickUpper = _ceilToTickSpacing(currentTick + 1, tickSpacing);
            tickLower = tickUpper - alignedTicksUp - alignedTicksDown;
        }

        // Verification finale : s'assurer que le currentTick est bien dans le range
        require(tickLower < currentTick && currentTick < tickUpper, "Current tick not in range");

        _validateTicks(tickLower, tickUpper, currentTick, tickSpacing);
    }

    /**
     * @notice Verifie si une position est hors du range
     * @param tokenId ID de la position a verifier
     * @param positionManager Le gestionnaire de positions NFT
     * @param priceCache Cache des prix actuels
     * @return bool True si la position est hors du range
     */
    function isPositionOutOfRange(
        uint256 tokenId,
        INonfungiblePositionManager positionManager,
        PriceCache memory priceCache
    ) external view returns (bool) {
        if (!priceCache.valid) return false;

        try positionManager.positions(tokenId) returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24 tickLower,
            int24 tickUpper,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        ) {
            int24 currentTick = priceCache.poolTick;
            return currentTick <= tickLower || currentTick >= tickUpper;
        } catch {
            return false;
        }
    }

    /**
     * @notice Ajoute de la liquidite a une position existante SANS faire de swap
     * @dev Les swaps doivent etre faits AVANT via Velora (multi-swap)
     * @param token0 Adresse du token0
     * @param token1 Adresse du token1
     * @param tokenId ID de la position
     * @param positionManager Le gestionnaire de positions
     * @param contractAddress Adresse du contrat (RangeManager)
     * @return liquidity Liquidite ajoutee
     * @return amount0Added Montant de token0 ajoute
     * @return amount1Added Montant de token1 ajoute
     * @dev SECURITY NOTE: This is a library function called via delegatecall from RangeManager.
     *      Access control is enforced by the calling contract (RangeManager) via onlyAuthorized modifier.
     *      Libraries cannot have their own access control modifiers since they execute in the
     *      caller's context. This function only operates on tokens already held by the contract
     *      and cannot transfer funds to arbitrary addresses - it adds liquidity to existing positions.
     */
    function addLiquidityWithoutSwap(
        address token0,
        address token1,
        uint256 tokenId,
        INonfungiblePositionManager positionManager,
        uint160 sqrtPriceX96,
        uint24 maxSlippageBps,
        address contractAddress
    ) external returns (uint128 liquidity, uint256 amount0Added, uint256 amount1Added) {
        // Approuver et ajouter la liquidité (PAS DE SWAP - fait avant via Velora)
        (uint256 newBalance0, uint256 newBalance1) =
            _approveAndGetBalances(token0, token1, positionManager, contractAddress);
        require(newBalance0 > 0 || newBalance1 > 0, "No funds to add");

        return _increaseLiquidity(tokenId, newBalance0, newBalance1, positionManager, sqrtPriceX96, maxSlippageBps);
    }

    /**
     * @notice Fournit les instructions pour le bot
     * @param positionCount Nombre de positions actives
     * @param maxPositions Limite max de positions
     * @param positions Array des positions existantes
     * @param positionManager Le gestionnaire de positions
     * @param priceCache Cache des prix actuels
     */
    /// @notice Cœur partagé du check de déviation : retourne true si l'écart pool/oracle dépasse le seuil.
    /// @dev Utilisé par updatePriceCache, qui invalide le cache pour tous les chemins sensibles.
    function _deviationExceeds(PriceCache memory pc, uint16 maxDeviationBps, uint8 token0Decimals, uint8 token1Decimals)
        internal
        pure
        returns (bool)
    {
        if (maxDeviationBps == 0 || !pc.valid || pc.poolSqrtPriceX96 == 0 || pc.price0 == 0 || pc.price1 == 0) {
            return false;
        }

        uint256 sp = uint256(pc.poolSqrtPriceX96);
        uint256 poolRaw = Math.mulDiv(sp, sp, 1 << 96);
        poolRaw = Math.mulDiv(poolRaw, 1e18, 1 << 96);
        uint256 poolPrice = Math.mulDiv(poolRaw, 10 ** token0Decimals, 10 ** token1Decimals);

        uint256 oraclePrice = Math.mulDiv(uint256(pc.price0), 1e18, uint256(pc.price1));
        if (oraclePrice == 0) return false;

        uint256 diff = poolPrice > oraclePrice ? poolPrice - oraclePrice : oraclePrice - poolPrice;
        uint256 deviationBps = (diff * 10000) / oraclePrice;
        return deviationBps > maxDeviationBps;
    }

    /// @notice Valide UN swap (executeSwap) contre l'oracle : plancher minOut basé sur le prix Chainlink.
    /// @dev V3 : check de déviation retiré d'ici (centralisé dans updatePriceCache + _refreshAndRequireValid
    ///      côté RangeManager). Cohérent avec le DN. Revert si minOut < plancher.
    function validateSwapAgainstOracle(
        bool tokenInIsToken0,
        uint256 amountIn,
        uint256 minAmountOut,
        PriceCache memory pc,
        RangeConfig memory cfg
    ) external pure {
        require(minAmountOut >= _oracleMinOut(tokenInIsToken0, amountIn, pc, cfg, cfg.maxSlippageBps), "minOut<floor");
    }

    /// @notice Détails d'une position (déporté du RangeManager pour le bytecode — audit V1). View pure-logique.
    function getPositionDetails(
        INonfungiblePositionManager positionManager,
        PriceCache memory priceCache,
        uint256 tokenId
    ) external view returns (bool inRange, int24 tickLower, int24 tickUpper, uint128 liquidity, int24 currentTick) {
        if (!priceCache.valid) {
            return (false, 0, 0, 0, 0);
        }
        (,,,,, tickLower, tickUpper, liquidity,,,,) = positionManager.positions(tokenId);
        currentTick = priceCache.poolTick;
        inRange = (currentTick > tickLower && currentTick < tickUpper);
    }

    function getBotInstructions(
        uint32 positionCount,
        uint32 maxPositions,
        uint256[] memory positions,
        INonfungiblePositionManager positionManager,
        PriceCache memory priceCache
    )
        external
        view
        returns (bool hasPosition, uint256 tokenId, bool needsRebalance, string memory action, string memory reason)
    {
        hasPosition = positions.length > 0;

        if (!hasPosition) {
            if (positionCount >= maxPositions) {
                return (false, 0, false, "MAX_POSITIONS_REACHED", "Limit positions");
            }
            return (false, 0, true, "MINT_INITIAL", "No position exists");
        }

        // Verifier chaque position
        for (uint256 i = 0; i < positions.length; i++) {
            if (_isPositionOutOfRange(positions[i], positionManager, priceCache)) {
                return (true, positions[i], true, "REBALANCE", "Position out of Range");
            }
        }

        tokenId = positions.length > 0 ? positions[0] : 0;
        action = "WAIT";
        reason = "All positions in Range";
    }

    /**
     * @notice Recupere les balances actuelles totales (libres + dans positions)
     */
    function getCurrentBalances(
        address token0,
        address token1,
        address contractAddress,
        uint256[] memory positions,
        INonfungiblePositionManager positionManager,
        IUniswapV3Pool pool
    ) external view returns (uint256 balance0, uint256 balance1) {
        balance0 = IERC20(token0).balanceOf(contractAddress);
        balance1 = IERC20(token1).balanceOf(contractAddress);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        for (uint256 i = 0; i < positions.length; i++) {
            (uint256 pos0, uint256 pos1) = _getPositionBalance(positions[i], positionManager, sqrtPriceX96);
            balance0 += pos0;
            balance1 += pos1;
        }
    }

    /**
     * @notice Cree une nouvelle position Uniswap V3
     * @dev SECURITY NOTE: This is a library function called via delegatecall from RangeManager.
     *      Access control is enforced by the calling contract (RangeManager) via onlyAuthorized modifier.
     *      Libraries cannot have their own access control modifiers since they execute in the
     *      caller's context. This function only uses tokens already held by the contract
     *      and mints a new position with recipient set to contractAddress (the calling contract).
     *
     *      FUND REDIRECTION RISK MITIGATION: The contractAddress parameter MUST be address(this)
     *      from the caller's perspective. In RangeManager._mintInternal(), this function is called
     *      with `address(this)` hardcoded - never from user input. The library requires this parameter
     *      because libraries execute via delegatecall and need the caller's address passed explicitly.
     *      The calling contract (RangeManager) is responsible for always passing address(this).
     */
    function mintNewPosition(
        address token0,
        address token1,
        RangeConfig memory config,
        int24 tickLower,
        int24 tickUpper,
        INonfungiblePositionManager positionManager,
        uint160 sqrtPriceX96,
        address contractAddress
    ) external returns (uint256 tokenId, uint128 liquidity) {
        uint256 balance0 = IERC20(token0).balanceOf(contractAddress);
        uint256 balance1 = IERC20(token1).balanceOf(contractAddress);
        require(balance0 > 0 || balance1 > 0, "No tokens");

        // Reset allowances a zero d'abord
        IERC20(token0).safeApprove(address(positionManager), 0);
        IERC20(token1).safeApprove(address(positionManager), 0);

        // Puis set les nouvelles allowances
        IERC20(token0).safeApprove(address(positionManager), balance0);
        IERC20(token1).safeApprove(address(positionManager), balance1);

        (uint256 amount0Min, uint256 amount1Min) =
            _liquidityMins(tickLower, tickUpper, sqrtPriceX96, balance0, balance1, config.maxSlippageBps);
        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: config.fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: balance0,
            amount1Desired: balance1,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            recipient: contractAddress,
            deadline: block.timestamp + 300
        });

        (tokenId, liquidity,,) = positionManager.mint(mintParams);

        IERC20(token0).safeApprove(address(positionManager), 0);
        IERC20(token1).safeApprove(address(positionManager), 0);
    }

    // audit V1 (M3-B-fix3, retour Codex) : collectAndRemoveLiquidity() SUPPRIMEE — helper externe mort (aucun
    // appelant en src/scripts/bot). Le rebalance utilise burnPositionCore/decreaseLiquidityPartialCore ; la
    // cristallisation des fees passe par collectFeesForVaultCore. On retire ce code mort pour la surface d'audit.

    /**
     * @notice Coeur du burn de position (deplace depuis RangeManager pour alleger son bytecode).
     * @dev Execute: collect fees -> decrease liquidity -> collect principal -> commission au
     *      treasury -> notification vault -> burn NFT. Le RangeManager conserve le tracking
     *      interne (isOwnedPosition / _removePosition) et l'event.
     * @return liquidity Liquidite qui etait dans la position (pour l'event).
     * @return fees0 Fees de trading collectees en token0.
     * @return fees1 Fees de trading collectees en token1.
     */
    function burnPositionCore(
        uint256 tokenId,
        address token0,
        address token1,
        address contractAddress,
        address treasuryAddress,
        address vault,
        INonfungiblePositionManager positionManager,
        IUniswapV3Pool pool,
        uint24 maxSlippageBps
    ) external returns (uint128 liquidity, uint256 fees0, uint256 fees1) {
        (,,,,,,, liquidity,,,,) = positionManager.positions(tokenId);

        // 1. Collecter les fees de trading AVANT retrait de liquidite
        (fees0, fees1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: contractAddress,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // 2-3. Retirer la liquidite + collecter le principal
        if (liquidity > 0) {
            (uint256 amount0Min, uint256 amount1Min) =
                _burnMinAmounts(tokenId, liquidity, positionManager, pool, maxSlippageBps);
            positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: block.timestamp + 300
                })
            );
            positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: contractAddress,
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        }

        // 4. Auto-compound: commission au Treasury, fees nettes restent sur le RM
        if (fees0 > 0 || fees1 > 0) {
            uint256 commRate = IRangeVaultComm(vault).commissionRate();
            uint256 commission0 = (fees0 * commRate) / 10000;
            uint256 commission1 = (fees1 * commRate) / 10000;
            if (commission0 > 0) IERC20(token0).safeTransfer(treasuryAddress, commission0);
            if (commission1 > 0) IERC20(token1).safeTransfer(treasuryAddress, commission1);
            IRangeVaultComm(vault).recordFeesCollected(fees0, fees1, commission0, commission1);
        }

        // 5. Burn le NFT
        positionManager.burn(tokenId);
    }

    /// @notice Crystallise + collecte les fees, applique la commission au treasury (deplace depuis RangeManager).
    /// @return fees0 Fees brutes collectees token0. @return fees1 Fees brutes collectees token1.
    function collectFeesForVaultCore(
        uint256 tokenId,
        address token0,
        address token1,
        address contractAddress,
        address treasuryAddress,
        address vault,
        INonfungiblePositionManager positionManager
    ) external returns (uint256 fees0, uint256 fees1) {
        // audit V1 (M3-B-fix3, retour Codex) — La cristallisation des fees vient de collect() : quand la
        // position a de la liquidite, NonfungiblePositionManager.collect() appelle pool.burn(...,0) en interne,
        // ce qui pousse le feeGrowth dans tokensOwed puis transfere. (Ne PAS utiliser decreaseLiquidity(0) : le
        // PM Uniswap le REJETTE quand liquidity==0 -> c'etait un no-op trompeur, supprime.)
        // FAIL-CLOSED : on NE wrappe PLUS collect() dans un try/catch. Les seuls appelants (deposit & withdraw)
        // n'invoquent cette fonction que lorsqu'une position existe ; un revert de collect() = echec reel de la
        // cristallisation -> il DOIT remonter (le mint/withdraw revert) plutot que de continuer sur (0,0).
        // Miroir exact de la pool DN.
        (fees0, fees1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: contractAddress,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // Auto-compound: commission au Treasury, fees nettes restent sur le RM
        if (fees0 > 0 || fees1 > 0) {
            uint256 commRate = IRangeVaultComm(vault).commissionRate();
            uint256 commission0 = (fees0 * commRate) / 10000;
            uint256 commission1 = (fees1 * commRate) / 10000;
            if (commission0 > 0) IERC20(token0).safeTransfer(treasuryAddress, commission0);
            if (commission1 > 0) IERC20(token1).safeTransfer(treasuryAddress, commission1);
            IRangeVaultComm(vault).recordFeesCollected(fees0, fees1, commission0, commission1);
        }
    }

    /// @notice Retrait d'urgence: transfere min(requested, balance) de chaque token vers recipient (deplace depuis RangeManager).
    function emergencyWithdrawCore(
        address token0,
        address token1,
        uint256 amount0Requested,
        uint256 amount1Requested,
        address recipient,
        address contractAddress
    ) external returns (uint256 amount0Sent, uint256 amount1Sent) {
        uint256 balance0 = IERC20(token0).balanceOf(contractAddress);
        uint256 balance1 = IERC20(token1).balanceOf(contractAddress);
        amount0Sent = amount0Requested > balance0 ? balance0 : amount0Requested;
        amount1Sent = amount1Requested > balance1 ? balance1 : amount1Requested;
        if (amount0Sent > 0) IERC20(token0).safeTransfer(recipient, amount0Sent);
        if (amount1Sent > 0) IERC20(token1).safeTransfer(recipient, amount1Sent);
    }

    /// @notice Swap exact-input single via SwapRouter + fee optionnelle au treasury (deplace depuis RangeManager).
    function executeSwapCore(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint24 fee,
        address contractAddress,
        ISwapRouter swapRouter,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut) {
        require(amountIn > 0, "E45");
        uint256 balanceBefore = IERC20(tokenIn).balanceOf(contractAddress);
        require(balanceBefore >= amountIn, "E46");

        amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: contractAddress,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );
        // A non-zero sqrt limit can make an exact-input Uniswap swap stop early. Never let
        // accounting or a rebalance continue as if the whole requested input was consumed.
        if (balanceBefore - IERC20(tokenIn).balanceOf(contractAddress) != amountIn) revert PartialFill();
    }

    /// @notice Retrait partiel de liquidite + collecte vers le contrat (deplace depuis RangeManager).
    function decreaseLiquidityPartialCore(
        uint256 tokenId,
        uint128 liquidityToRemove,
        INonfungiblePositionManager positionManager,
        IUniswapV3Pool pool,
        uint24 maxSlippageBps,
        address contractAddress
    ) external {
        require(liquidityToRemove > 0, "E45");
        (,,,,,,, uint128 currentLiquidity,,,,) = positionManager.positions(tokenId);
        require(liquidityToRemove <= currentLiquidity, "E46");

        (uint256 amount0Min, uint256 amount1Min) =
            _burnMinAmounts(tokenId, liquidityToRemove, positionManager, pool, maxSlippageBps);
        positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToRemove,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            })
        );
        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: contractAddress,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    /**
     * @notice Calcule le ratio optimal de tokens pour une position dans un range donne
     * @dev Utilise les formules exactes de Uniswap V3 pour calculer les montants de liquidite
     *      Cela garantit que le swap preparera exactement le bon ratio pour minimiser le dust
     * @return ratio0 Pourcentage de valeur en token0 (en basis points sur 10000)
     */
    // public → internal (EIP-170) : appelée uniquement en interne (calculateOptimalSwapParams, depositSwapParams).
    function calculateOptimalRatio(int24 tickLower, int24 tickUpper, int24 currentTick, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 ratio0)
    {
        // Si on est en dessous du range, tout en token0
        if (currentTick <= tickLower) {
            return 10000; // 100%
        }

        // Si on est au-dessus du range, tout en token1
        if (currentTick >= tickUpper) {
            return 0; // 0%
        }

        // Dans le range : calcul precis base sur les formules Uniswap V3
        uint160 sqrtPriceLower = getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceUpper = getSqrtRatioAtTick(tickUpper);

        // Protection overflows
        require(sqrtPriceX96 > sqrtPriceLower && sqrtPriceX96 < sqrtPriceUpper, "Price out of range");

        // Pour une liquidite L donnee, Uniswap V3 utilise:
        // amount0 = L * (1/sqrtPrice - 1/sqrtPriceUpper)
        // amount1 = L * (sqrtPrice - sqrtPriceLower)
        //
        // Le ratio de VALEUR (pas de quantite) est:
        // value0 = amount0 * price = amount0 * sqrtPrice^2
        // value1 est exprime dans la meme unite relative de pool; les valorisations USD utilisent price1 ailleurs.
        //
        // ratio0 = value0 / (value0 + value1)

        // Calcul de amount0 et amount1 pour une liquidite unitaire (L=2^96 pour eviter les divisions)
        // amount0 = L * (sqrtPriceUpper - sqrtPrice) / (sqrtPrice * sqrtPriceUpper)
        // amount1 = L * (sqrtPrice - sqrtPriceLower)

        // Pour eviter les overflows, on travaille avec des ratios
        // amount0_normalized = (sqrtPriceUpper - sqrtPrice) / sqrtPrice  (en Q96)
        // amount1_normalized = (sqrtPrice - sqrtPriceLower)  (en Q96)

        uint256 sqrtP = uint256(sqrtPriceX96);
        uint256 sqrtPL = uint256(sqrtPriceLower);
        uint256 sqrtPU = uint256(sqrtPriceUpper);

        // amount0 * sqrtPrice (proportionnel) = (sqrtPU - sqrtP) * 2^96 / sqrtPU
        // Ceci represente la "valeur" de token0 en termes de sqrt
        uint256 amount0Value = ((sqrtPU - sqrtP) << 96) / sqrtPU;

        // amount1 (proportionnel) = sqrtP - sqrtPL
        // Pour convertir en meme unite de valeur, on multiplie par sqrtP
        // car price = sqrtP^2 / 2^192, et on veut value1 = amount1 * 1
        uint256 amount1Value = sqrtP - sqrtPL;

        // Pour avoir le meme denominateur, on multiplie amount0Value par sqrtP
        // value0_total = amount0Value * sqrtP / 2^96
        // value1_total = amount1Value
        //
        // Mais pour eviter overflow, on calcule directement le ratio:
        // ratio0 = value0 / (value0 + value1)
        //        = (amount0Value * sqrtP) / (amount0Value * sqrtP + amount1Value * 2^96)

        uint256 value0Scaled = amount0Value * sqrtP;
        uint256 value1Scaled = amount1Value << 96;

        uint256 totalValue = value0Scaled + value1Scaled;

        if (totalValue == 0) {
            return 5000; // Fallback 50/50 si calcul impossible
        }

        // ratio0 en basis points (10000 = 100%)
        ratio0 = (value0Scaled * 10000) / totalValue;

        // Securite: borner entre 0 et 10000
        if (ratio0 > 10000) ratio0 = 10000;

        return ratio0;
    }

    /// @notice Plan de swap du PROCHAIN dépôt, isolé des soldes libres historiques du RangeManager.
    /// @dev Seul l'apport courant finance le swap. Les donations, dust et fees déjà détenus par le RangeManager
    ///      restent attribués aux shares existantes et ne peuvent ni bloquer la FIFO ni être dépensés par le keeper.
    function depositSwapParams(address rangeManager, uint256 depositAmount0, uint256 depositAmount1)
        external
        view
        returns (bool zeroForOne, uint256 amountIn)
    {
        IRmDeposit rm = IRmDeposit(rangeManager);
        (uint128 price0, uint128 price1, uint160 sp, int24 tk,, bool valid) = rm.priceCache();
        if (!valid) return (false, 0);
        (, uint8 dec0, uint8 dec1,,,,, uint16 rangeUpPercent, uint16 rangeDownPercent,) = rm.config();

        uint256 v0 = (depositAmount0 * uint256(price0)) / (10 ** dec0);
        uint256 v1 = (depositAmount1 * uint256(price1)) / (10 ** dec1);
        uint256 tot = v0 + v1;
        if (tot == 0) return (false, 0);

        uint256[] memory positions = rm.getOwnerPositions();
        uint256 ratioBps;
        if (positions.length > 0) {
            (,,,,, int24 tickLower, int24 tickUpper,,,,,) = rm.positionManager().positions(positions[0]);
            ratioBps = calculateOptimalRatio(tickLower, tickUpper, tk, sp);
        } else {
            IUniswapV3Pool lpPool = rm.pool();
            int24 spacing = lpPool.tickSpacing();
            int24 lower = _floorToTickSpacing(tk - int24(uint24(rangeDownPercent)), spacing);
            int24 upper = _ceilToTickSpacing(tk + int24(uint24(rangeUpPercent)), spacing);
            ratioBps = calculateOptimalRatio(lower, upper, tk, sp);
        }
        uint256 targetV0 = (tot * ratioBps) / 10000;

        if (v0 > targetV0) {
            amountIn = ((v0 - targetV0) * (10 ** dec0)) / uint256(price0);
            return (true, amountIn);
        } else if (targetV0 > v0) {
            amountIn = ((targetV0 - v0) * (10 ** dec1)) / uint256(price1);
            return (false, amountIn);
        }
        return (false, 0);
    }

    /// @notice Compact external TickMath wrapper used by the pool's SecureBotModule NAV view.
    function sqrtRatioAtTickExt(int24 tick) external pure returns (uint160) {
        return getSqrtRatioAtTick(tick);
    }

    // Remplace TickMath.getSqrtRatioAtTick
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= 887272, "T");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    // Ajouter les calculs de liquidite
    function getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        require(sqrtRatioAX96 > 0, "sqrtRatioA cannot be 0");

        return Math.mulDiv(uint256(liquidity) << 96, sqrtRatioBX96 - sqrtRatioAX96, sqrtRatioBX96) / sqrtRatioAX96;
    }

    function getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return Math.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, uint256(1) << 96);
    }

    // ===== FONCTIONS PRIVEES =====

    /**
     * @notice Helper interne pour vérifier si position hors range
     */
    function _isPositionOutOfRange(
        uint256 tokenId,
        INonfungiblePositionManager positionManager,
        PriceCache memory priceCache
    ) private view returns (bool) {
        if (!priceCache.valid) return false;

        try positionManager.positions(tokenId) returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24 tickLower,
            int24 tickUpper,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        ) {
            int24 currentTick = priceCache.poolTick;
            return currentTick <= tickLower || currentTick >= tickUpper;
        } catch {
            return false;
        }
    }

    /**
     * @notice Helper pour approuver et récupérer les nouvelles balances
     */
    function _approveAndGetBalances(
        address token0,
        address token1,
        INonfungiblePositionManager positionManager,
        address contractAddress
    ) private returns (uint256 newBalance0, uint256 newBalance1) {
        newBalance0 = IERC20(token0).balanceOf(contractAddress);
        newBalance1 = IERC20(token1).balanceOf(contractAddress);

        if (newBalance0 > 0) {
            IERC20(token0).safeApprove(address(positionManager), 0);
            IERC20(token0).safeApprove(address(positionManager), newBalance0);
        }
        if (newBalance1 > 0) {
            IERC20(token1).safeApprove(address(positionManager), 0);
            IERC20(token1).safeApprove(address(positionManager), newBalance1);
        }
    }

    /**
     * @notice Helper pour augmenter la liquidité d'une position
     */
    function _increaseLiquidity(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        INonfungiblePositionManager positionManager,
        uint160 sqrtPriceX96,
        uint24 maxSlippageBps
    ) private returns (uint128 liquidity, uint256 amount0Added, uint256 amount1Added) {
        address token0Addr;
        address token1Addr;
        int24 tickLower;
        int24 tickUpper;
        (,, token0Addr, token1Addr,, tickLower, tickUpper,,,,,) = positionManager.positions(tokenId);
        (uint256 amount0Min, uint256 amount1Min) =
            _liquidityMins(tickLower, tickUpper, sqrtPriceX96, amount0Desired, amount1Desired, maxSlippageBps);
        (liquidity, amount0Added, amount1Added) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp + 300
            })
        );
        // Clear any unused approval left after Uniswap consumed less than desired.
        // This keeps repeated LP operations safe without changing bot/keeper flows.
        IERC20(token0Addr).safeApprove(address(positionManager), 0);
        IERC20(token1Addr).safeApprove(address(positionManager), 0);
    }

    function _minWithSlippage(uint256 amount, uint24 slippageBps) private pure returns (uint256) {
        if (amount == 0) return 0;
        require(slippageBps < 10000, "bad slippage");
        uint256 slip = uint256(slippageBps);
        uint256 minAmount = Math.mulDiv(amount, 10000 - slip, 10000);
        return minAmount == 0 ? 1 : minAmount;
    }

    /// @dev Mirrors Uniswap periphery's liquidity quote, then applies slippage to the amounts the
    ///      position can actually consume. Unrelated one-sided balances remain free instead of
    ///      making amountMin impossible to satisfy.
    function _liquidityMins(
        int24 tickLower,
        int24 tickUpper,
        uint160 sqrtPriceX96,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint24 maxSlippageBps
    ) private pure returns (uint256 amount0Min, uint256 amount1Min) {
        uint160 sqrtA = getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = getSqrtRatioAtTick(tickUpper);
        uint256 q96 = uint256(1) << 96;
        uint256 liquidity;

        if (sqrtPriceX96 <= sqrtA) {
            liquidity = Math.mulDiv(amount0Desired, Math.mulDiv(sqrtA, sqrtB, q96), sqrtB - sqrtA);
        } else if (sqrtPriceX96 < sqrtB) {
            uint256 liquidity0 =
                Math.mulDiv(amount0Desired, Math.mulDiv(sqrtPriceX96, sqrtB, q96), sqrtB - sqrtPriceX96);
            uint256 liquidity1 = Math.mulDiv(amount1Desired, q96, sqrtPriceX96 - sqrtA);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = Math.mulDiv(amount1Desired, q96, sqrtB - sqrtA);
        }

        (uint256 expected0, uint256 expected1) =
            _calculateLiquidityAmountsAtSqrt(tickLower, tickUpper, _safeUint128(liquidity), sqrtPriceX96);
        amount0Min = _minWithSlippage(expected0, maxSlippageBps);
        amount1Min = _minWithSlippage(expected1, maxSlippageBps);
    }

    function _burnMinAmounts(
        uint256 tokenId,
        uint128 liquidity,
        INonfungiblePositionManager positionManager,
        IUniswapV3Pool pool,
        uint24 maxSlippageBps
    ) private view returns (uint256 amount0Min, uint256 amount1Min) {
        (,,,,, int24 tickLower, int24 tickUpper,,,,,) = positionManager.positions(tokenId);
        (uint256 amount0, uint256 amount1) = _calculateLiquidityAmounts(tickLower, tickUpper, liquidity, pool);
        amount0Min = _minWithSlippage(amount0, maxSlippageBps);
        amount1Min = _minWithSlippage(amount1, maxSlippageBps);
    }

    /**
     * @notice Helper pour récupérer les balances d'une position
     */
    function _getPositionBalance(uint256 tokenId, INonfungiblePositionManager positionManager, uint160 sqrtPriceX96)
        private
        view
        returns (uint256 balance0, uint256 balance1)
    {
        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,, uint128 tokensOwed0, uint128 tokensOwed1) =
            positionManager.positions(tokenId);

        if (liquidity > 0) {
            (balance0, balance1) = _calculateLiquidityAmountsAtSqrt(tickLower, tickUpper, liquidity, sqrtPriceX96);
        }

        balance0 += uint256(tokensOwed0);
        balance1 += uint256(tokensOwed1);
    }

    /**
     * @notice Calcule les montants de liquidité pour une position
     */
    function _calculateLiquidityAmounts(int24 tickLower, int24 tickUpper, uint128 liquidity, IUniswapV3Pool pool)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        return _calculateLiquidityAmountsAtSqrt(tickLower, tickUpper, liquidity, sqrtPriceX96);
    }

    function _calculateLiquidityAmountsAtSqrt(int24 tickLower, int24 tickUpper, uint128 liquidity, uint160 sqrtPriceX96)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtRatioAX96 = getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = getSqrtRatioAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            return (getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity), 0);
        } else if (sqrtPriceX96 >= sqrtRatioBX96) {
            return (0, getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity));
        } else {
            return (
                getAmount0ForLiquidity(sqrtPriceX96, sqrtRatioBX96, liquidity),
                getAmount1ForLiquidity(sqrtRatioAX96, sqrtPriceX96, liquidity)
            );
        }
    }

    function _validateTicks(int24 tickLower, int24 tickUpper, int24 currentTick, int24 tickSpacing) private pure {
        require(tickLower < tickUpper, "Invalid tick order");
        require(
            _isAlignedToTickSpacing(tickLower, tickSpacing) && _isAlignedToTickSpacing(tickUpper, tickSpacing),
            "Tick spacing misalignment"
        );
        require(tickLower >= MIN_TICK && tickUpper <= MAX_TICK, "Tick out of bounds");
        require(tickUpper - tickLower >= int24(int256(tickSpacing) * int256(10)), "Range too narrow");
        require(tickLower >= currentTick - 50000 && tickUpper <= currentTick + 50000, "Range too wide");
    }

    /**
     * @notice Arrondit un tick vers le bas (floor) au multiple de tickSpacing le plus proche
     * @dev Gere correctement les nombres negatifs (ex: -196327 avec spacing 10 -> -196330)
     */
    function _floorToTickSpacing(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 minUsableTick = (MIN_TICK / tickSpacing) * tickSpacing;
        if (tick <= minUsableTick) return minUsableTick;
        int24 remainder = tick % tickSpacing;
        if (remainder == 0) {
            return tick;
        }
        // Pour les nombres negatifs, le reste peut etre negatif
        // floor(-196327, 10) devrait donner -196330, pas -196320
        int24 rounded;
        if (tick < 0 && remainder != 0) {
            rounded = tick - remainder - tickSpacing;
        } else {
            rounded = tick - remainder;
        }
        return rounded < minUsableTick ? minUsableTick : rounded;
    }

    /**
     * @notice Arrondit un tick vers le haut (ceil) au multiple de tickSpacing le plus proche
     * @dev Gere correctement les nombres negatifs (ex: -196323 avec spacing 10 -> -196320)
     */
    function _ceilToTickSpacing(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 maxUsableTick = (MAX_TICK / tickSpacing) * tickSpacing;
        if (tick >= maxUsableTick) return maxUsableTick;
        int24 remainder = tick % tickSpacing;
        if (remainder == 0) {
            return tick;
        }
        // Pour les nombres negatifs, ceil(-196327, 10) devrait donner -196320
        int24 rounded;
        if (tick < 0) {
            rounded = tick - remainder;
        } else {
            rounded = tick - remainder + tickSpacing;
        }
        return rounded > maxUsableTick ? maxUsableTick : rounded;
    }

    /**
     * @notice Verifie si un tick est aligne sur le tickSpacing
     * @dev Gere correctement les nombres negatifs
     */
    function _isAlignedToTickSpacing(int24 tick, int24 tickSpacing) private pure returns (bool) {
        // Pour les nombres negatifs, % peut retourner un resultat negatif
        // Donc on verifie que le reste est 0 (positif ou negatif)
        return tick % tickSpacing == 0;
    }

    function _safeUint128(uint256 value) private pure returns (uint128) {
        require(value <= type(uint128).max, "Overflow uint128");
        return uint128(value);
    }

    /**
     * @notice Calcule les parametres optimaux pour un swap avant mint/rebalance
     * @param balance0 Balance actuelle de token0
     * @param balance1 Balance actuelle de token1
     * @param priceCache Cache des prix actuels
     * @param config Configuration du range
     * @param pool Pool Uniswap V3
     * @return params Parametres de swap optimaux
     */
    function calculateOptimalSwapParams(
        uint256 balance0,
        uint256 balance1,
        PriceCache memory priceCache,
        RangeConfig memory config,
        IUniswapV3Pool pool
    ) external view returns (OptimalSwapParams memory params) {
        params.currentBalance0 = balance0;
        params.currentBalance1 = balance1;

        if (balance0 == 0 && balance1 == 0) {
            params.targetRatio0Bps = 5000;
            return params;
        }

        // IMPORTANT: Utiliser EXACTEMENT la meme logique que calculateTargetTicks
        // pour que le ratio calcule corresponde au range qui sera effectivement utilise
        (params.tickLower, params.tickUpper) = _calculateTargetTicksInternal(priceCache, config, pool);

        // Calculer le ratio optimal
        params.targetRatio0Bps =
            calculateOptimalRatio(params.tickLower, params.tickUpper, priceCache.poolTick, priceCache.poolSqrtPriceX96);

        // Calculer le swap necessaire
        _calculateSwapAmount(params, priceCache, config);

        return params;
    }

    /**
     * @notice Helper interne pour calculer le montant de swap
     * @dev Utilise les prix Chainlink pour calculer la valeur USD (coherence avec le reste du systeme)
     *      Le ratio optimal est calcule via calculateOptimalRatio qui utilise sqrtPriceX96
     */
    function _calculateSwapAmount(
        OptimalSwapParams memory params,
        PriceCache memory priceCache,
        RangeConfig memory config
    ) private pure {
        // Calculer les valeurs en USD via les prix Chainlink (8 decimales)
        // value0_usd = balance0 * price0 / 10^token0Decimals (resultat en 8 decimales)
        // value1_usd = balance1 * price1 / 10^token1Decimals (resultat en 8 decimales)
        uint256 value0 = (params.currentBalance0 * priceCache.price0) / (10 ** config.token0Decimals);
        uint256 value1 = (params.currentBalance1 * priceCache.price1) / (10 ** config.token1Decimals);
        uint256 totalValue = value0 + value1;

        if (totalValue == 0) return;

        // Ratio actuel de token0 en bps
        uint256 currentRatio0Bps = (value0 * 10000) / totalValue;

        // Tolerance: on veut etre TRES precis pour minimiser le dust
        // Utiliser une tolerance tres faible (0.1% = 10 bps minimum)
        uint256 tolerance = config.toleranceBps / 10;
        if (tolerance < 10) tolerance = 10;

        if (currentRatio0Bps > params.targetRatio0Bps + tolerance) {
            // Trop de token0, swap token0 -> token1
            params.zeroForOne = true;

            // Calculer la valeur USD a swapper
            // excessValue = (currentRatio - targetRatio) * totalValue / 10000
            uint256 excessValueUSD = ((currentRatio0Bps - params.targetRatio0Bps) * totalValue) / 10000;

            // Convertir en montant de token0
            // amount0 = excessValueUSD * 10^token0Decimals / price0
            params.amountIn = (excessValueUSD * (10 ** config.token0Decimals)) / priceCache.price0;

            params.swapNeeded = params.amountIn > 0;
            if (params.amountIn > params.currentBalance0) {
                params.amountIn = params.currentBalance0;
            }
        } else if (currentRatio0Bps + tolerance < params.targetRatio0Bps) {
            // Pas assez de token0, swap token1 -> token0
            params.zeroForOne = false;

            // Calculer la valeur USD manquante
            uint256 deficitValueUSD = ((params.targetRatio0Bps - currentRatio0Bps) * totalValue) / 10000;

            // Convertir en montant de token1
            // amount1 = deficitValueUSD * 10^token1Decimals / price1
            params.amountIn = (deficitValueUSD * (10 ** config.token1Decimals)) / priceCache.price1;

            params.swapNeeded = params.amountIn > 0;
            if (params.amountIn > params.currentBalance1) {
                params.amountIn = params.currentBalance1;
            }
        }
    }

    // ===== DYNAMIC RANGE — CALCUL ON-CHAIN =====

    /**
     * @notice Indique si un nouveau snapshot de prix est du (timing regulier).
     * @dev Intervalle = 86400 / maxSnapshotsPerDay (ex: 2/jour => 12h, 4/jour => 6h).
     *      Au tout premier appel (lastSnapshotAt == 0) le snapshot est immediatement du.
     */
    function isSnapshotDue(DynamicRangeConfig memory drc, uint64 nowTs) external pure returns (bool) {
        if (drc.maxSnapshotsPerDay == 0) return false;
        if (drc.lastSnapshotAt == 0) return true;
        uint64 interval = uint64(86400) / uint64(drc.maxSnapshotsPerDay);
        return nowTs >= drc.lastSnapshotAt + interval;
    }

    /**
     * @notice Calcule le demi-range symetrique (en bps) a partir du ring buffer de prix.
     * @dev Formule: sur les snapshots des `volatMoyDay` derniers jours, on retire les
     *      `volatTrimDay` prix les plus hauts ET les plus bas (trim des pics aberrants),
     *      puis high = max restant, low = min restant. Amplitude haute = (high-cur)/cur,
     *      amplitude basse = (cur-low)/cur. Amplitude totale = haut+bas, multipliee par
     *      rangeMultiplicatorBps/10000, arrondie au palier rangeStepBps (vers le haut),
     *      puis divisee par 2 pour le demi-range symetrique.
     * @param snapshots Copie memoire du ring buffer (lue par le caller).
     * @param currentPrice Prix Chainlink courant (price0, 8 decimales).
     * @param drc Parametres de gouvernance.
     * @param nowTs Timestamp courant (pour filtrer la fenetre).
     * @return halfRangeBps Demi-range symetrique en bps (rangeUp == rangeDown).
     * @return enoughData False si pas assez de snapshots dans la fenetre (cold start).
     */
    /// @notice Écrit un snapshot dans le ring buffer circulaire (push tant que < cap, sinon overwrite à head).
    /// @dev Déporté du RangeManager (gain bytecode) : la library opère directement sur le storage array passé
    ///      par référence et renvoie le nouvel index de tête. cap==0 traité comme 1. Miroir exact de la pool DN.
    /// @return newHead Index circulaire d'écriture suivant.
    function writeRing(PriceSnapshot[] storage ring, uint16 head, uint16 cap, PriceSnapshot memory snap)
        external
        returns (uint16 newHead)
    {
        if (cap == 0) cap = 1;
        if (ring.length < cap) {
            ring.push(snap);
        } else {
            ring[head] = snap;
        }
        return uint16((uint256(head) + 1) % cap);
    }

    /// @notice Plancher de sortie d'un swap au prix oracle Chainlink, moins le slippage.
    /// @dev Anti-MEV pour les swaps permissionless (depots) : le minAmountOut fourni par un keeper
    ///      doit etre >= ce plancher. Conversion value-neutral via les prix oracle 8 decimales et les
    ///      decimales des tokens (generique pour toute paire). Pure -> vit dans la library (hors RM).
    /// @param tokenInIsToken0 True si on swappe token0->token1, false si token1->token0.
    /// @param amountIn Montant d'entree (decimales du tokenIn).
    /// @param pc Cache prix (price0/price1 en 8 decimales).
    /// @param cfg Config (decimales des tokens).
    /// @dev Helper interne reutilisable depuis les validateurs swap/rebalance.
    function _oracleMinOut(
        bool tokenInIsToken0,
        uint256 amountIn,
        PriceCache memory pc,
        RangeConfig memory cfg,
        uint24 slippageBps
    ) internal pure returns (uint256 minOut) {
        if (amountIn == 0 || !pc.valid || pc.price0 == 0 || pc.price1 == 0) return 0;
        uint256 priceIn = tokenInIsToken0 ? uint256(pc.price0) : uint256(pc.price1);
        uint256 priceOut = tokenInIsToken0 ? uint256(pc.price1) : uint256(pc.price0);
        uint256 decIn = tokenInIsToken0 ? cfg.token0Decimals : cfg.token1Decimals;
        uint256 decOut = tokenInIsToken0 ? cfg.token1Decimals : cfg.token0Decimals;
        uint256 theo = (amountIn * priceIn * (10 ** decOut)) / (priceOut * (10 ** decIn));
        uint256 slip = slippageBps >= 10000 ? 9999 : uint256(slippageBps);
        minOut = (theo * (10000 - slip)) / 10000;
    }

    /// @notice Valide qu'un tableau minAmountsOut respecte le plancher oracle (anti-sandwich).
    /// @dev Deportee depuis RangeManager.rebalance() pour rester sous EIP-170 et reutilisable
    ///      par processDepositPermissionless. Reverte avec "minOut<floor" si un chunk n'est pas
    ///      assez restrictif. Sans cette garde, un appelant permissionless pouvait passer 0 et
    ///      se faire sandwicher en MEV (V4 audit). N'execute pas les swaps : c'est au caller
    ///      d'appeler swapRouter (le delegatecall library briserait le contexte msg.sender/balance).
    /// @notice Valide les pre-conditions de chaque chunk de swap rebalance :
    ///         (1) chunk cap (en USD) <= initMultiSwapTvl si > 0,
    ///         (2) minAmountsOut[i] >= plancher oracle Chainlink (anti-sandwich V4 audit).
    function validateMinOutsAgainstOracle(
        bool tokenInIsToken0,
        uint256[] calldata swapAmountsIn,
        uint256[] calldata minAmountsOut,
        PriceCache memory pc,
        RangeConfig memory config,
        uint256 initMultiSwapTvl
    ) external pure returns (uint256 totalSwapUsd) {
        // V3 : check de déviation pool/oracle retiré d'ici (redondant) — centralisé dans updatePriceCache et
        // garanti par _refreshAndRequireValid() au début de rebalance(). Ne valide plus que minOut + cap. DN-coh.
        uint256 n = swapAmountsIn.length;
        uint256 cap = initMultiSwapTvl * 1e8;
        uint256 priceIn = tokenInIsToken0 ? uint256(pc.price0) : uint256(pc.price1);
        uint256 decIn = tokenInIsToken0 ? config.token0Decimals : config.token1Decimals;
        for (uint256 i; i < n; ++i) {
            uint256 amt = swapAmountsIn[i];
            if (amt == 0) continue;
            uint256 swapUsd = (amt * priceIn) / (10 ** decIn);
            if (initMultiSwapTvl > 0) {
                require(swapUsd <= cap, "chunk>cap");
            }
            totalSwapUsd += swapUsd;
            uint256 floor = _oracleMinOut(tokenInIsToken0, amt, pc, config, config.maxSlippageBps);
            require(minAmountsOut[i] >= floor, "minOut<floor");
        }
    }

    /// @dev Logique interne du calcul du demi-range (reutilisee par evaluateDynamicRange).
    function _computeDynamicRangeBps(
        PriceSnapshot[] memory snapshots,
        uint128 currentPrice,
        DynamicRangeConfig memory drc,
        uint64 nowTs
    ) internal pure returns (uint16 halfRangeBps, bool enoughData) {
        if (currentPrice == 0 || drc.volatMoyDay == 0) return (0, false);

        // 1. Filtrer les snapshots dans la fenetre [nowTs - volatMoyDay*1d, nowTs]
        uint64 windowStart = nowTs > uint64(drc.volatMoyDay) * 86400 ? nowTs - uint64(drc.volatMoyDay) * 86400 : 0;
        uint256 n = snapshots.length;
        uint128[] memory win = new uint128[](n);
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            if (snapshots[i].timestamp >= windowStart && snapshots[i].price > 0) {
                win[count] = snapshots[i].price;
                count++;
            }
        }

        // 2. Cold start: apres le trim haut+bas, deux valeurs doivent rester pour mesurer high-low.
        uint256 needed = uint256(drc.volatTrimDay) * 2 + 2;
        if (count < needed || count == 0) return (0, false);

        // 3. Trim: retirer les `volatTrimDay` plus hauts ET plus bas par selection par passes.
        //    On marque les valeurs retirees en les mettant a 0 (prix toujours > 0 sinon).
        uint256 trim = drc.volatTrimDay;
        for (uint256 p = 0; p < trim; p++) {
            // retirer le max courant
            uint256 maxIdx = type(uint256).max;
            uint128 maxVal = 0;
            for (uint256 i = 0; i < count; i++) {
                if (win[i] > maxVal) {
                    maxVal = win[i];
                    maxIdx = i;
                }
            }
            if (maxIdx != type(uint256).max) win[maxIdx] = 0;
            // retirer le min courant (parmi les valeurs encore > 0)
            uint256 minIdx = type(uint256).max;
            uint128 minVal = type(uint128).max;
            for (uint256 i = 0; i < count; i++) {
                if (win[i] > 0 && win[i] < minVal) {
                    minVal = win[i];
                    minIdx = i;
                }
            }
            if (minIdx != type(uint256).max) win[minIdx] = 0;
        }

        // 4. high/low sur les valeurs restantes (> 0)
        uint128 high = 0;
        uint128 low = type(uint128).max;
        for (uint256 i = 0; i < count; i++) {
            if (win[i] == 0) continue;
            if (win[i] > high) high = win[i];
            if (win[i] < low) low = win[i];
        }
        if (high == 0 || low == type(uint128).max) return (0, false);

        // 5. Amplitude PURE de la fenetre = (high - low) / prix courant, en bps.
        //    On mesure la dispersion reelle des prix observes (volatilite), independamment de la
        //    position instantanee du prix. L'ancien calcul (ampUp+ampDown clampes au prix courant)
        //    sous-estimait la volatilite quand le prix sortait de [low,high] (un cote etait clampe a 0),
        //    ce qui produisait un range biaise au moment meme ou le marche bougeait le plus.
        uint256 totalBps = (uint256(high - low) * 10000) / currentPrice;
        if (totalBps == 0) return (0, false);

        // 6. Appliquer le multiplicateur d'amplitude (rangeMultiplicatorBps/10000)
        uint256 mult = drc.rangeMultiplicatorBps == 0 ? 10000 : uint256(drc.rangeMultiplicatorBps);
        totalBps = (totalBps * mult) / 10000;

        // 7. Arrondir l'amplitude totale au palier rangeStepBps (vers le haut)
        uint256 step = drc.rangeStepBps == 0 ? 50 : uint256(drc.rangeStepBps);
        uint256 roundedTotal = ((totalBps + step - 1) / step) * step;

        // 8. Demi-range symetrique
        uint256 half = roundedTotal / 2;
        if (half == 0) return (0, false);
        if (half > type(uint16).max) half = type(uint16).max;
        return (uint16(half), true);
    }

    /**
     * @notice Calcule le nouveau demi-range ET decide s'il faut l'appliquer.
     * @dev Encapsule le calcul + la decision pour alleger le RangeManager (bytecode).
     *      Retourne shouldApply=false si: dynamique desactive, cold start, ou range trop petit (<10 bps).
     *      PAS d'hysteresis : appele lors du snapshot on-chain qui met a jour la config de range.
     *      Le mint/rebalance suivant lit cette config deja figee, ce qui garde le plan de swap coherent.
     * @return newHalfBps Demi-range a appliquer (borne 10..5000), valide seulement si shouldApply.
     * @return shouldApply True s'il faut reecrire config.rangeUp/DownPercent.
     */
    function evaluateDynamicRange(
        PriceSnapshot[] memory snapshots,
        uint128 currentPrice,
        DynamicRangeConfig memory drc,
        uint64 nowTs
    ) external pure returns (uint16 newHalfBps, bool shouldApply) {
        if (!drc.dynamicRangeEnabled || currentPrice == 0) return (0, false);

        (uint16 halfBps, bool ok) = _computeDynamicRangeBps(snapshots, currentPrice, drc, nowTs);
        if (!ok) return (0, false);

        uint16 minBps = drc.rangeMinBps == 0 ? 10 : drc.rangeMinBps;
        uint16 maxBps = drc.rangeMaxBps == 0 ? 5000 : drc.rangeMaxBps;
        if (minBps < 10 || minBps > maxBps || maxBps > 5000) return (0, false);

        // PAS d'hysteresis : le snapshot on-chain applique directement le nouveau range calcule.
        // Le rebalance/mint suivant utilise ensuite cette config de range deja figee, ce qui evite
        // une divergence entre le plan de swap lu par le bot/keeper et le range effectivement minte.
        // (Le palier rangeStepBps reste applique en amont dans _computeDynamicRangeBps.)
        if (halfBps < minBps) halfBps = minBps;
        if (halfBps > maxBps) halfBps = maxBps;
        return (halfBps, true);
    }
}
