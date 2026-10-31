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
    function priceCache() external view returns (RangeOperations.PriceCache memory);
    function getOwnerPositions() external view returns (uint256[] memory);
    function getCurrentBalances() external view returns (uint256 balance0, uint256 balance1);
    function getOptimalSwapParams() external view returns (RangeOperations.OptimalSwapParams memory);
    function initMultiSwapTvl() external view returns (uint256);
    function positionManager() external view returns (INonfungiblePositionManager);
    function refreshPriceCache() external;
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);

    function config() external view returns (RangeOperations.RangeConfig memory);
    function swapRouter() external view returns (ISwapRouter);
}

interface IAccountingWithdrawRange {
    function getOwnerPositions() external view returns (uint256[] memory);
    function positionManager() external view returns (INonfungiblePositionManager);
    function collectFeesForVault() external returns (uint256, uint256);
    function removeLiquidityForWithdraw(uint256, uint128) external;
    function emergencyBurnPosition(uint256) external;
    function transferTokensForWithdraw(uint256, uint256, address) external returns (uint256, uint256);
}

library ProtocolAccountingLib {
    error StrategyDataUnavailable();
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

        // audit V1 (V3 — High #1/#2) : check déviation pool/oracle INTÉGRÉ au refresh. slot0 et prix Chainlink
        // capturés au même instant => cache LIVE. Tous les appelants de _updatePriceCache héritent de la barrière.
        if (maxDeviationBps > 0 && _deviationExceeds(newCache, maxDeviationBps, cfg.token0Decimals, cfg.token1Decimals))
        {
            // Conserve uniquement les valeurs oracle fraiches pour le fallback de retrait protege.
            // Toutes les actions LP ordinaires continuent d'exiger valid=true.
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
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 300;
        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
            int24 twapTick = int24(tickDelta / 300);
            if (tickDelta < 0 && tickDelta % 300 != 0) twapTick--;
            int24 diff = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
            return uint24(diff) > uint24(maxTwapDeviationTicks);
        } catch {
            // Bypass uniquement au bootstrap (une seule observation initialisee). Des la deuxieme,
            // tout echec observe() invalide le cache, y compris pendant le reste du warm-up 300s.
            (,,, uint16 cardinality,,,) = pool.slot0();
            return cardinality != 1;
        }
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

    function _safeUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert Uint128Overflow();
        return uint128(value);
    }

    function getOracleLpValueUsd(address rangeManager) external view returns (uint256 valueUsd) {
        IAccountingRange rm = IAccountingRange(rangeManager);
        RangeOperations.PriceCache memory cache = rm.priceCache();
        require(
            cache.price0 > 0 && cache.price1 > 0 && (cache.valid || cache.timestamp == uint64(block.timestamp)),
            AutonomousCheck(0x17270318)
        );
        RangeOperations.RangeConfig memory cfg = rm.config();
        uint160 oracleSqrt = _oracleSqrtPrice(cache.price0, cache.price1, cfg.token0Decimals, cfg.token1Decimals);
        (uint256 balance0, uint256 balance1) = _balancesAtPrice(rm, oracleSqrt, rangeManager);
        valueUsd = Math.mulDiv(balance0, cache.price0, 10 ** cfg.token0Decimals)
            + Math.mulDiv(balance1, cache.price1, 10 ** cfg.token1Decimals);
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
        RangeOperations.PriceCache memory cache = rm.priceCache();
        if (cache.price0 == 0 || cache.price1 == 0 || cache.timestamp != uint64(block.timestamp)) return false;
        RangeOperations.RangeConfig memory cfg = rm.config();
        uint256 valueUsd = Math.mulDiv(amount0, cache.price0, 10 ** cfg.token0Decimals)
            + Math.mulDiv(amount1, cache.price1, 10 ** cfg.token1Decimals);
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
        require(recipient == address(this) || recipient == msg.sender, AutonomousCheck(0x1b1b5e7c));

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
        if (isFullWithdraw && tokenId > 0) rangeManager.emergencyBurnPosition(tokenId);

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
        RangeOperations.PriceCache memory priceCache = rm.priceCache();
        address token0 = rm.token0();
        address token1 = rm.token1();
        RangeOperations.validateSwapAgainstOracle(tokenInIsToken0, amountIn, minAmountOut, priceCache, config);
        uint256 amountUsd = (amountIn * uint256(tokenInIsToken0 ? priceCache.price0 : priceCache.price1))
            / (10 ** (tokenInIsToken0 ? config.token0Decimals : config.token1Decimals));
        require(amountUsd <= rm.initMultiSwapTvl() * 1e8, "E91");
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
        try IAccountingRange(manager).priceCache() returns (RangeOperations.PriceCache memory pc) {
            uint128 price0 = pc.price0;
            uint128 price1 = pc.price1;
            bool valid = pc.valid;
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

    function refundNativeSurplus(uint256 usedNativeFee) external {
        if (msg.value <= usedNativeFee) return;
        (bool ok,) = msg.sender.call{value: msg.value - usedNativeFee}("");
        require(ok, AutonomousCheck(0xcef6850b));
    }

    function validateSwapFeed(
        bool isSealed,
        address existingFeed,
        address token,
        address feed,
        uint16 _swapSlippageBps,
        uint32 _maxAge,
        uint8 usdcDecimals
    ) external view {
        require(!isSealed || existingFeed == feed, AutonomousCheck(0x61ac430d));
        require(token != address(0), AutonomousCheck(0x086efea7));
        require(feed != address(0), AutonomousCheck(0x422790c9));
        require(_swapSlippageBps >= 10 && _swapSlippageBps <= 1000, AutonomousCheck(0x3b5e082d));
        require(_maxAge >= 3600 && _maxAge <= 172800, AutonomousCheck(0xd357f7c0));
        require(
            IERC20Metadata(token).decimals() <= 18 && usdcDecimals <= 18
                && AggregatorV3Interface(feed).decimals() <= 18,
            AutonomousCheck(0x8a0ba966)
        );
    }

    function consumeDailyLimit(
        mapping(address => uint64) storage daysByActor,
        mapping(address => uint256) storage spent,
        address actor,
        uint256 amount,
        uint256 cap,
        bool zeroUnlimited,
        bytes4 failure
    ) external {
        uint64 day = uint64(block.timestamp / 1 days);
        if (daysByActor[actor] != day) {
            daysByActor[actor] = day;
            spent[actor] = 0;
        }
        uint256 next = spent[actor] + amount;
        if (!zeroUnlimited || cap > 0) require(next <= cap, AutonomousCheck(failure));
        spent[actor] = next;
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
        RangeOperations.PriceCache memory pc = rm.priceCache();
        return RangeOperations.calculateOptimalSwapParams(a, b, pc, rm.config(), lower, upper);
    }

    function canonicalTwaps(
        address poolAddress,
        uint64 epoch,
        uint32 epochSeconds,
        uint32 tacticalHorizonSeconds,
        uint32 strategicHorizonSeconds
    ) external view returns (int24 tacticalTick, int24 strategicTick) {
        uint256 boundary = uint256(epoch) * epochSeconds;
        uint256 offset = block.timestamp - boundary;
        if (offset > type(uint32).max) revert StrategyDataUnavailable();
        uint32 endAgo = uint32(offset);
        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = endAgo + strategicHorizonSeconds;
        secondsAgos[1] = endAgo + tacticalHorizonSeconds;
        secondsAgos[2] = endAgo;
        (int56[] memory cumulatives,) = IUniswapV3Pool(poolAddress).observe(secondsAgos);
        strategicTick = _meanTick(cumulatives[2] - cumulatives[0], strategicHorizonSeconds);
        tacticalTick = _meanTick(cumulatives[2] - cumulatives[1], tacticalHorizonSeconds);
    }

    function _meanTick(int56 delta, uint32 seconds_) private pure returns (int24 tick) {
        tick = int24(delta / int56(uint56(seconds_)));
        if (delta < 0 && delta % int56(uint56(seconds_)) != 0) tick--;
    }


}
