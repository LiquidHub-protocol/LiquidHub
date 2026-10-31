// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ProtocolSafetyLib} from "./ProtocolSafetyLib.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {RangeOperations} from "./RangeOperations.sol";
import "./AutonomousErrors.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Fixed accounting and valuation; delegatecall retains payer, recipient and pool context.
interface IAccountingRange {
    function pool() external view returns (IUniswapV3Pool);
    function addLiquidityToPosition() external;
    function protocolBotAddress() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function priceCache() external view returns (uint128, uint128, uint160, int24, uint64, bool);
    function config() external view returns (RangeOperations.RangeConfig memory);
    function swapRouter() external view returns (ISwapRouter);
    function getOwnerPositions() external view returns (uint256[] memory);
    function getCurrentBalances() external view returns (uint256 balance0, uint256 balance1);
    function getOptimalSwapParams() external view returns (RangeOperations.OptimalSwapParams memory);
    function initMultiSwapTvl() external view returns (uint256);
    function positionManager() external view returns (INonfungiblePositionManager);
    function refreshPriceCache() external;
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);
}

interface IAccountingWithdrawRange {
    function getOwnerPositions() external view returns (uint256[] memory);
    function positionManager() external view returns (INonfungiblePositionManager);
    function collectFeesForVault() external returns (uint256, uint256);
    function removeLiquidityForWithdraw(uint256, uint128) external;
    function emergencyBurnPosition(uint256) external;
    function transferTokensForWithdraw(uint256, uint256, address) external returns (uint256, uint256);
}

interface IAccountingBotNav {
    function getOracleLpValueUsd() external view returns (uint256);
}

interface IAccountingHedgeNav {
    function getHedgeData() external view returns (uint256, uint256, uint256, uint256);
    function getWethBalance() external view returns (uint256);
    function getUsdcBalance() external view returns (uint256);
}

interface ISettlementDnNegativeHedgeContext {
    function pool() external view returns (address);
    function weth() external view returns (address);
    function usdc() external view returns (address);
    function variableDebtWeth() external view returns (address);
    function rangeManager() external view returns (address);
    function swapRouter() external view returns (address);
    function swapPoolFee() external view returns (uint24);
    function volatileDecimals() external view returns (uint8);
    function stableDecimals() external view returns (uint8);
    function donationDustToken0() external view returns (uint256);
    function swapSlippageBps() external view returns (uint16);
}

interface ISettlementDnRangeManagerState {
    function token1() external view returns (address);
    function initMultiSwapTvl() external view returns (uint256);
    function sendTokenForHedge(address token, uint256 amount, address to) external;
    function refreshPriceCache() external;
    function priceCache()
        external
        view
        returns (uint128 price0, uint128 price1, uint160 sqrtP, int24 tick, uint64 timestamp, bool valid);
    function config()
        external
        view
        returns (
            uint24 fee,
            uint8 token0Decimals,
            uint8 token1Decimals,
            uint16 toleranceBps,
            uint24 maxSlippageBps,
            uint64 lastRebalanceTime,
            bool oraclesConfigured,
            uint32 maxPositions
        );
}

interface ISettlementDnAaveStrategyState {
    function getHedgeData()
        external
        view
        returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 healthFactor, uint256 availableBorrowsBase);
    function getWethDebt() external view returns (uint256);
    function inventoryNormalizationPending() external view returns (bool);
    function getStrategyReserveData()
        external
        view
        returns (uint256 idleStable, uint16 operationalTargetBps, uint16 liveLtvBps);
    function hedgeTargetBps() external view returns (uint16);
    function donationDustToken0() external view returns (uint256);
    function adjustHedgeBps() external view returns (uint16);
    function hedgeAdjustCooldown() external view returns (uint32);
    function lastHedgeAdjustAt() external view returns (uint64);
    function hfRepairTriggerBps() external view returns (uint16);
    function liqThresholdBps() external view returns (uint16);
    function reserveHfTargetBps() external view returns (uint16);
    function swapSlippageBps() external view returns (uint16);
    function criticalHedgeBps() external view returns (uint16);
}

interface ISettlementDnAaveSupply {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);
}

interface IAccountingHedgeVault {
    function hedgeManager() external view returns (address);
}

library ProtocolAccountingLib {
    error E99();
    event TokenSentForHedge(address indexed token, uint256 amount, address indexed to);
    error StrategyDataUnavailable();
    uint256 private constant BPS = 10000;
    uint160 private constant MIN_SQRT_PRICE_LIMIT_X96 = 4295128740;
    uint160 private constant MAX_SQRT_PRICE_LIMIT_X96 = 1461446703485210103287273052203988822378723970341;
    error HedgeCheck(uint8 code);
    error InvalidNegativeHedgeSwap();
    event RepayDebt(uint256 wethRepaid);
    event HedgeInventoryNormalized(uint256 amount0, uint256 amount1, bool complete);
    error E73();
    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    using SafeERC20 for IERC20;
    error Uint128Overflow();
    error E40();
    error TwapUnavailable();

    function updatePriceCache(
        AggregatorV3Interface token0PriceFeed,
        AggregatorV3Interface token1PriceFeed,
        IUniswapV3Pool pool,
        RangeOperations.RangeConfig memory cfg,
        bool twapGuardEnabled,
        uint16 maxTwapDeviationTicks,
        uint16 maxDeviationBps,
        uint32 maxAge0In,
        uint32 maxAge1In
    ) public view returns (RangeOperations.PriceCache memory newCache) {
        if (address(token0PriceFeed) == address(0) || address(token1PriceFeed) == address(0)) {
            return RangeOperations.PriceCache(0, 0, 0, 0, 0, false);
        }

        // Pas de try/catch ici, le contrat principal s'en charge
        (uint80 roundId0, int256 price0,, uint256 updatedAt0, uint80 answeredInRound0) =
            token0PriceFeed.latestRoundData();
        (uint80 roundId1, int256 price1,, uint256 updatedAt1, uint80 answeredInRound1) =
            token1PriceFeed.latestRoundData();

        if (price0 <= 0 || price1 <= 0 || answeredInRound0 < roundId0 || answeredInRound1 < roundId1) {
            return RangeOperations.PriceCache(0, 0, 0, 0, 0, false);
        }

        // audit V1 (V3) : âge max PAR FEED (heartbeats distincts). 0 => défaut 90000s (rétrocompat).
        uint256 maxAge0 = maxAge0In == 0 ? 90000 : uint256(maxAge0In);
        uint256 maxAge1 = maxAge1In == 0 ? 90000 : uint256(maxAge1In);
        if (block.timestamp - updatedAt0 > maxAge0 || block.timestamp - updatedAt1 > maxAge1) {
            return RangeOperations.PriceCache(0, 0, 0, 0, 0, false);
        }

        (uint160 sqrtPriceX96, int24 tick,,,,,) = pool.slot0();

        newCache = RangeOperations.PriceCache({
            price0: _safeUint128(uint256(price0)),
            price1: _safeUint128(uint256(price1)),
            poolSqrtPriceX96: sqrtPriceX96,
            poolTick: tick,
            timestamp: uint64(block.timestamp),
            valid: true
        });

        // audit V1 (V3 — High #1/#2) : check déviation pool/oracle INTÉGRÉ au refresh. Comme slot0 et les
        // prix Chainlink sont capturés ICI au même instant, le cache reflète le prix LIVE. Tous les appelants
        // de _updatePriceCache (mint, rebalance, executeSwap, deposit/withdraw via refreshPriceCache) héritent
        // donc automatiquement de la barrière : si le pool diverge de l'oracle au-delà du seuil, valid=false
        // → les require(valid) en aval reverteront. Centralise la protection en un seul point.
        if (maxDeviationBps > 0 && _deviationExceeds(newCache, maxDeviationBps, cfg.token0Decimals, cfg.token1Decimals))
        {
            // Preserve freshly validated oracle values only for the bounded AAVE exact-output settlement
            // and protected user-withdrawal fallback. Every normal LP/hedge path still requires valid=true.
            newCache.valid = false;
            return newCache;
        }
        if (twapGuardEnabled && _twapDeviationExceeds(pool, tick, maxTwapDeviationTicks)) {
            newCache.valid = false;
            return newCache;
        }
    }

    function _twapDeviationExceeds(IUniswapV3Pool pool, int24 spotTick, uint16 maxTwapDeviationTicks)
        private
        view
        returns (bool)
    {
        int24 twapTick = _trustedTwapTick(pool);
        int24 diff = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
        return uint24(diff) > uint24(maxTwapDeviationTicks);
    }

    function _deviationExceeds(
        RangeOperations.PriceCache memory pc,
        uint16 maxDeviationBps,
        uint8 token0Decimals,
        uint8 token1Decimals
    ) internal pure returns (bool) {
        if (maxDeviationBps == 0 || !pc.valid || pc.poolSqrtPriceX96 == 0 || pc.price0 == 0 || pc.price1 == 0) {
            return false;
        }

        // prixPool = (sqrtP/2^96)^2 en ratio token1/token0 brut, puis ajusté décimales -> échelle 1e18.
        // poolRaw = sqrtP^2 / 2^192 (token1 brut par token0 brut).
        uint256 sp = uint256(pc.poolSqrtPriceX96);
        // poolRaw (token1 brut par token0 brut, échelle 1e18) = sqrtP^2 * 1e18 / 2^192, en 2 étapes pour
        // éviter l'overflow de sqrtP^2 : (sqrtP^2 / 2^96) puis (* 1e18 / 2^96).
        uint256 poolRaw = Math.mulDiv(sp, sp, 1 << 96); // = sqrtP^2 / 2^96  (~ token1/token0 * 2^96)
        poolRaw = Math.mulDiv(poolRaw, 1e18, 1 << 96); // -> échelle 1e18
        // Corriger les décimales : prixPool_1e18 = poolRaw * 10^token0Decimals / 10^token1Decimals
        uint256 poolPrice = Math.mulDiv(poolRaw, 10 ** token0Decimals, 10 ** token1Decimals);

        // prixOracle (token1 par token0) en 1e18 = price0/price1 (mêmes décimales d'oracle -> se simplifient).
        uint256 oraclePrice = Math.mulDiv(uint256(pc.price0), 1e18, uint256(pc.price1));
        if (oraclePrice == 0) return false;

        uint256 diff = poolPrice > oraclePrice ? poolPrice - oraclePrice : oraclePrice - poolPrice;
        uint256 deviationBps = (diff * 10000) / oraclePrice;
        return deviationBps > maxDeviationBps;
    }

    function _trustedTwapTick(IUniswapV3Pool pool) private view returns (int24 twapTick) {
        (, int24 spotTick,, uint16 cardinality,,,) = pool.slot0();
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 300;
        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
            twapTick = int24(tickDelta / int56(uint56(300)));
            if (tickDelta < 0 && tickDelta % int56(uint56(300)) != 0) twapTick--;
        } catch {
            // Bootstrap uniquement. Des la deuxieme observation, un echec observe() est fail-closed.
            if (cardinality != 1) revert TwapUnavailable();
            twapTick = spotTick;
        }
    }

    function trustedTwapTick(IUniswapV3Pool pool) external view returns (int24) {
        return _trustedTwapTick(pool);
    }

    function _safeUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert Uint128Overflow();
        return uint128(value);
    }

    function getOracleLpValueUsd(address rangeManager) external view returns (uint256 valueUsd) {
        IAccountingRange rm = IAccountingRange(rangeManager);
        (uint128 price0, uint128 price1,,, uint64 timestamp, bool valid) = rm.priceCache();
        require(
            price0 > 0 && price1 > 0 && (valid || timestamp == uint64(block.timestamp)), AutonomousCheck(0x17270318)
        );
        RangeOperations.RangeConfig memory cfg = rm.config();
        uint160 oracleSqrt = _oracleSqrtPrice(price0, price1, cfg.token0Decimals, cfg.token1Decimals);
        (uint256 balance0, uint256 balance1) = _balancesAtPrice(rm, oracleSqrt, rangeManager);
        valueUsd = Math.mulDiv(balance0, price0, 10 ** cfg.token0Decimals)
            + Math.mulDiv(balance1, price1, 10 ** cfg.token1Decimals);
    }

    function _oracleSqrtPrice(uint128 price0, uint128 price1, uint8 dec0, uint8 dec1) private pure returns (uint160) {
        uint256 ratioX192 =
            Math.mulDiv(uint256(price0) * (10 ** dec1), uint256(1) << 192, uint256(price1) * (10 ** dec0));
        uint256 sqrtPriceX96 = Math.sqrt(ratioX192);
        require(sqrtPriceX96 > 0 && sqrtPriceX96 <= type(uint160).max, AutonomousCheck(0x509120d6));
        return uint160(sqrtPriceX96);
    }

    function _balancesAtPrice(IAccountingRange rm, uint160 sqrtPriceX96, address rangeManager)
        private
        view
        returns (uint256 balance0, uint256 balance1)
    {
        balance0 = IERC20(rm.token0()).balanceOf(rangeManager);
        balance1 = IERC20(rm.token1()).balanceOf(rangeManager);
        uint256[] memory positions = rm.getOwnerPositions();
        require(positions.length <= 1, AutonomousCheck(0x4b08c5a7));
        if (positions.length == 0) return (balance0, balance1);

        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,, uint128 owed0, uint128 owed1) =
            rm.positionManager().positions(positions[0]);
        (uint256 amount0, uint256 amount1) = _liquidityAmounts(liquidity, tickLower, tickUpper, sqrtPriceX96);
        return (balance0 + amount0 + owed0, balance1 + amount1 + owed1);
    }

    function _liquidityAmounts(uint128 liquidity, int24 tickLower, int24 tickUpper, uint160 sqrtPriceX96)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) return (0, 0);
        uint160 sqrtA = RangeOperations.sqrtRatioAtTickExt(tickLower);
        uint160 sqrtB = RangeOperations.sqrtRatioAtTickExt(tickUpper);
        uint256 numerator = uint256(liquidity) << 96;
        if (sqrtPriceX96 <= sqrtA) {
            amount0 = numerator / sqrtA - numerator / sqrtB;
        } else if (sqrtPriceX96 >= sqrtB) {
            amount1 = Math.mulDiv(liquidity, sqrtB - sqrtA, uint256(1) << 96);
        } else {
            amount0 = numerator / sqrtPriceX96 - numerator / sqrtB;
            amount1 = Math.mulDiv(liquidity, sqrtPriceX96 - sqrtA, uint256(1) << 96);
        }
    }

    function isWithdrawValueSufficient(address rangeManager, uint256 amount0, uint256 amount1, uint256 minValueUsd)
        external
        view
        returns (bool)
    {
        IAccountingRange rm = IAccountingRange(rangeManager);
        (uint128 price0, uint128 price1,,, uint64 timestamp,) = rm.priceCache();
        if (price0 == 0 || price1 == 0 || timestamp != uint64(block.timestamp)) return false;
        RangeOperations.RangeConfig memory cfg = rm.config();
        uint256 valueUsd = Math.mulDiv(amount0, price0, 10 ** cfg.token0Decimals)
            + Math.mulDiv(amount1, price1, 10 ** cfg.token1Decimals);
        return valueUsd >= minValueUsd;
    }

    function withdrawFromRange(
        address manager,
        address token0,
        address token1,
        uint256 principal0,
        uint256 principal1,
        address recipient,
        uint256 shareAmount,
        uint256 totalSharesBefore,
        bool isFullWithdraw
    ) external returns (uint256 amount0Sent, uint256 amount1Sent) {
        IAccountingWithdrawRange rangeManager = IAccountingWithdrawRange(manager);
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
                    liquidityToRemove = RangeOperations.mulDivUp(totalLiquidity, shareAmount, totalSharesBefore);
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
        if (isFullWithdraw && tokenId > 0) rangeManager.emergencyBurnPosition(tokenId);

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
                IERC20(token0).safeTransfer(recipient, amount0Sent);
            }
            if (amount1Sent > 0) {
                IERC20(token1).safeTransfer(recipient, amount1Sent);
            }
        }

        return (amount0Sent, amount1Sent);
    }

    function executeValidatedSwap(bool tokenInIsToken0, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        IAccountingRange rm = IAccountingRange(address(this));
        RangeOperations.RangeConfig memory config = rm.config();
        (uint128 a, uint128 b, uint160 sp, int24 tk, uint64 ts, bool v) = rm.priceCache();
        RangeOperations.PriceCache memory priceCache = RangeOperations.PriceCache(a, b, sp, tk, ts, v);
        address token0 = rm.token0();
        address token1 = rm.token1();
        RangeOperations.validateSwapAgainstOracle(
            tokenInIsToken0, amountIn, minAmountOut, priceCache, config, rm.initMultiSwapTvl()
        );
        address tokenIn = tokenInIsToken0 ? token0 : token1;
        address tokenOut = tokenInIsToken0 ? token1 : token0;
        amountOut = RangeOperations.executeSwapCore(
            tokenIn,
            tokenOut,
            amountIn,
            minAmountOut,
            config.fee,
            address(this),
            rm.swapRouter(),
            RangeOperations.boundedSwapSqrtPriceLimit(
                priceCache.poolSqrtPriceX96, config.maxSlippageBps, tokenInIsToken0
            )
        );
        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut);
    }

    function addPosition(
        mapping(uint256 => bool) storage isOwnedPosition,
        mapping(uint256 => uint32) storage positionIndex,
        mapping(uint32 => uint256) storage indexToPosition,
        uint32 positionCount,
        uint256 tokenId
    ) external returns (uint32) {
        if (!isOwnedPosition[tokenId]) {
            uint32 index = positionCount++;
            positionIndex[tokenId] = index;
            indexToPosition[index] = tokenId;
            isOwnedPosition[tokenId] = true;
        }

        return positionCount;
    }

    function removePosition(
        mapping(uint256 => bool) storage isOwnedPosition,
        mapping(uint256 => uint32) storage positionIndex,
        mapping(uint32 => uint256) storage indexToPosition,
        uint32 positionCount,
        uint256 tokenId
    ) external returns (uint32) {
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

        return positionCount;
    }

    function updateRangeCache(
        RangeOperations.PriceCache storage cache,
        RangeOperations.RangeConfig storage cfg,
        RangeOperations.ProtectionConfig storage protections,
        ProtocolSafetyLib.ProtectionOverrideState storage overridden,
        AggregatorV3Interface feed0,
        AggregatorV3Interface feed1,
        IUniswapV3Pool pool
    ) external {
        bool active = block.timestamp < overridden.until;
        RangeOperations.PriceCache memory fresh = updatePriceCache(
            feed0,
            feed1,
            pool,
            cfg,
            active ? overridden.twap : protections.sandwichDetectionEnabled,
            active ? overridden.ticks : protections.maxTwapDeviationTicks,
            protections.maxOracleDeviationBps,
            protections.maxAge0,
            protections.maxAge1
        );
        cache.price0 = fresh.price0;
        cache.price1 = fresh.price1;
        cache.poolSqrtPriceX96 = fresh.poolSqrtPriceX96;
        cache.poolTick = fresh.poolTick;
        cache.timestamp = fresh.timestamp;
        cache.valid = fresh.valid;
    }

    function depositValue(address manager, uint256 amount0, uint256 amount1) external view returns (uint256) {
        try IAccountingRange(manager).priceCache() returns (
            uint128 price0, uint128 price1, uint160, int24, uint64, bool valid
        ) {
            if (!valid) return 0;

            // Récupérer les décimales depuis RangeManager
            RangeOperations.RangeConfig memory config = IAccountingRange(manager).config();

            uint256 value0 = (amount0 * uint256(price0)) / (10 ** config.token0Decimals);
            uint256 value1 = (amount1 * uint256(price1)) / (10 ** config.token1Decimals);

            return value0 + value1;
        } catch {
            return 0;
        }
    }

    function prepareHedgeInventory(uint256 target, bool enforceThresholds, bool allowInventoryContinuation)
        external
        returns (uint256 debt, int256 effectiveShort, bool inventoryOnly, uint256 normalized0)
    {
        ISettlementDnNegativeHedgeContext context = ISettlementDnNegativeHedgeContext(address(this));
        address token0 = context.weth();
        address rangeManager = context.rangeManager();
        uint256 dustFloor = context.donationDustToken0();
        uint256 idleHm;
        (debt, effectiveShort, idleHm) = _effectiveShort(context.variableDebtWeth(), token0, rangeManager, dustFloor);
        // Above the range, only reduce a net LONG inventory. Never create a short
        // against an all-stable LP or repay the whole hedge merely because its target is zero.
        if (target == 0 && !enforceThresholds) revert HedgeCheck(44);
        bool inventoryRepay = target == 0 && effectiveShort >= 0;
        uint256 difference = inventoryRepay
            ? debt
            : effectiveShort < int256(target)
                ? uint256(int256(target) - effectiveShort)
                : uint256(effectiveShort - int256(target));
        bool pendingInventoryOnly = enforceThresholds && allowInventoryContinuation && effectiveShort < int256(target)
            && int256(debt) > effectiveShort;
        // Finishing a recorded chunk sequence never authorizes borrowing, even if
        // the last chunk also satisfies the ordinary/critical hedge thresholds.
        inventoryOnly = pendingInventoryOnly;
        // Recorded continuations only consume inventory; ordinary/critical
        // thresholds apply to every fresh debt adjustment, never to this continuation.
        if (enforceThresholds && !pendingInventoryOnly) {
            ISettlementDnAaveStrategyState hedge = ISettlementDnAaveStrategyState(address(this));
            uint256 drift = target == 0 ? type(uint256).max : difference * BPS / target;
            if (drift < hedge.adjustHedgeBps()) revert HedgeCheck(44);
            if (
                block.timestamp < uint256(hedge.lastHedgeAdjustAt()) + hedge.hedgeAdjustCooldown()
                    && drift < hedge.criticalHedgeBps()
            ) revert HedgeCheck(41);
        }
        if (!inventoryRepay && effectiveShort >= int256(target)) {
            return (debt, effectiveShort, false, 0);
        }
        uint256 idle = inventoryRepay ? idleHm : uint256(int256(debt) - effectiveShort);
        if (idle == 0) {
            if (inventoryRepay) revert HedgeCheck(44);
            return (debt, effectiveShort, false, 0);
        }
        ISettlementDnRangeManagerState(rangeManager).refreshPriceCache();
        (uint128 price0, uint128 price1, uint160 sqrtP,,, bool valid) =
            ISettlementDnRangeManagerState(rangeManager).priceCache();
        if (!(valid && price0 > 0 && price1 > 0 && sqrtP > 0)) revert InvalidNegativeHedgeSwap();

        address token1 = context.usdc();
        uint8 decimals0 = context.volatileDecimals();
        uint256 inventoryNeeded = _min(difference, idle);
        uint256 amount0 = _min(inventoryNeeded, _inventoryCap(rangeManager, price0, decimals0));
        if (amount0 == 0) revert InvalidNegativeHedgeSwap();
        // A zero-target inventory step is followed by a range decision, with no new
        // borrowing, bounty or cooldown even when the net long has been eliminated.
        inventoryOnly = target == 0 || inventoryOnly || amount0 < inventoryNeeded;
        if (inventoryRepay) {
            // A capped repayment from HM inventory removes matching assets and debt:
            // no swap, no new delta, no extra debt. It makes a large residual inventory
            // manageable by a subsequent atomic range sync without exceeding its cap.
            if (ISettlementDnAaveSupply(context.pool()).repay(token0, amount0, 2, address(this)) != amount0) {
                revert InvalidNegativeHedgeSwap();
            }
            emit RepayDebt(amount0);
            return (debt, effectiveShort, true, amount0);
        }
        if (amount0 > idleHm) {
            ISettlementDnRangeManagerState(rangeManager).sendTokenForHedge(token0, amount0 - idleHm, address(this));
        }
        uint256 slippageBps = context.swapSlippageBps();
        uint256 minOut = _inventoryMinOut(amount0, price0, price1, decimals0, context.stableDecimals(), slippageBps);
        if (minOut == 0) revert InvalidNegativeHedgeSwap();
        uint256 rawLimit = (uint256(sqrtP) * (token0 < token1 ? 20000 - slippageBps : 20000 + slippageBps)) / 20000;
        uint160 sqrtLimit = rawLimit < MIN_SQRT_PRICE_LIMIT_X96
            ? MIN_SQRT_PRICE_LIMIT_X96
            : rawLimit > MAX_SQRT_PRICE_LIMIT_X96 ? MAX_SQRT_PRICE_LIMIT_X96 : uint160(rawLimit);

        uint256 token0Before = IERC20(token0).balanceOf(address(this));
        uint256 amount1 = ISwapRouter(context.swapRouter())
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: token0,
                    tokenOut: token1,
                    fee: context.swapPoolFee(),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amount0,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: sqrtLimit
                })
            );
        if (IERC20(token0).balanceOf(address(this)) != token0Before - amount0) {
            revert InvalidNegativeHedgeSwap();
        }
        // The stable reserve is shared portfolio equity; queued user deposits stay in the Vault.
        ISettlementDnAaveSupply(context.pool())
            .supply(token1, IERC20(token1).balanceOf(address(this)), address(this), 0);
        int256 beforeShort = effectiveShort;
        (debt, effectiveShort,) = _effectiveShort(context.variableDebtWeth(), token0, rangeManager, dustFloor);
        if (effectiveShort != beforeShort + int256(amount0)) revert InvalidNegativeHedgeSwap();
        normalized0 = amount0;
        emit HedgeInventoryNormalized(amount0, amount1, amount0 == inventoryNeeded);
    }

    function _inventoryMinOut(
        uint256 amount0,
        uint128 price0,
        uint128 price1,
        uint8 decimals0,
        uint8 decimals1,
        uint256 slippageBps
    ) private pure returns (uint256) {
        return Math.mulDiv(
            Math.mulDiv(amount0, uint256(price0) * (10 ** decimals1), uint256(price1) * (10 ** decimals0)),
            BPS - slippageBps,
            BPS
        );
    }

    function _inventoryCap(address rm, uint128 price0, uint8 decimals0) private view returns (uint256) {
        return Math.mulDiv(ISettlementDnRangeManagerState(rm).initMultiSwapTvl() * 1e8, 10 ** decimals0, price0);
    }

    function _effectiveShort(address debtToken, address token0, address rangeManager, uint256 dustFloor)
        private
        view
        returns (uint256 debt, int256 effectiveShort, uint256 idleHm)
    {
        debt = IERC20(debtToken).balanceOf(address(this));
        idleHm = _netOfDust(IERC20(token0).balanceOf(address(this)), dustFloor);
        uint256 idleRm = _netOfDust(IERC20(token0).balanceOf(rangeManager), dustFloor);
        effectiveShort = int256(debt) - int256(idleHm) - int256(idleRm);
    }

    function _netOfDust(uint256 balance, uint256 dustFloor) private pure returns (uint256) {
        return balance > dustFloor ? balance - dustFloor : 0;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function optimalSwapParams(int24 lower, int24 upper)
        external
        view
        returns (RangeOperations.OptimalSwapParams memory)
    {
        IAccountingRange rm = IAccountingRange(address(this));
        (uint256 a, uint256 b) = RangeOperations.getCurrentBalances(
            rm.token0(), rm.token1(), address(this), rm.getOwnerPositions(), rm.positionManager(), rm.pool()
        );
        (uint128 p0, uint128 p1, uint160 sp, int24 tk, uint64 ts, bool valid) = rm.priceCache();
        RangeOperations.PriceCache memory pc = RangeOperations.PriceCache(p0, p1, sp, tk, ts, valid);
        return RangeOperations.calculateOptimalSwapParams(a, b, pc, rm.config(), lower, upper);
    }

    function canonicalTwaps(
        address poolAddress,
        uint64 epoch,
        uint32 epochSeconds,
        uint32 tacticalHorizonSeconds,
        uint32 strategicHorizonSeconds
    ) external view returns (int24 tacticalTick, int24 strategicTick) {
        uint32 endAgo = uint32(block.timestamp - uint256(epoch) * epochSeconds);
        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = endAgo + strategicHorizonSeconds;
        secondsAgos[1] = endAgo + tacticalHorizonSeconds;
        secondsAgos[2] = endAgo;
        (int56[] memory cumulatives,) = IUniswapV3Pool(poolAddress).observe(secondsAgos);
        strategicTick = _meanCanonicalTick(cumulatives[2] - cumulatives[0], strategicHorizonSeconds);
        tacticalTick = _meanCanonicalTick(cumulatives[2] - cumulatives[1], tacticalHorizonSeconds);
    }

    function _meanCanonicalTick(int56 delta, uint32 seconds_) private pure returns (int24 tick) {
        tick = int24(delta / int56(uint56(seconds_)));
        if (delta < 0 && delta % int56(uint56(seconds_)) != 0) tick--;
    }

    function sendTokenForHedge(
        address token,
        uint256 amount,
        address to,
        address owner,
        address vault,
        address token0,
        address token1,
        bool authorized
    ) external {
        require(token == token0 || token == token1, AutonomousCheck(0x050b2de0));
        if (amount == 0) revert E99();
        // SÉCURITÉ (audit V1) : destination FIGÉE au hedgeManager (lu depuis le vault). Avant, `to` était
        // arbitraire → une clé bot compromise pouvait envoyer le principal user idle vers une adresse
        // externe. On garde le param `to` (selector inchangé) mais il DOIT = vault.hedgeManager().
        address hm = IAccountingHedgeVault(vault).hedgeManager();
        require(to == hm && hm != address(0), "E95"); // destination figée au hedgeManager
        // Registered HM may pull only token0 for its atomic inventory normalization.
        if (!(msg.sender == owner || authorized || (msg.sender == hm && token == token0))) {
            revert E99();
        }
        IERC20(token).safeTransfer(to, amount);
        emit TokenSentForHedge(token, amount, to);
    }


}
