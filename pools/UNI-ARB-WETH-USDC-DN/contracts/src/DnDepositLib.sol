// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./RangeOperations.sol";

/// @dev Interfaces minimales (la library reçoit les adresses en paramètre — aucun accès au storage du Vault).
interface IHedgeDep {
    function getWethDebt() external view returns (uint256); // dette token0 exacte; nom ABI historique
    function getWethBalance() external view returns (uint256);
    function getUsdcBalance() external view returns (uint256);
    function getHedgeData()
        external
        view
        returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 healthFactor, uint256 availableBorrowsBase);
    function hedgeTargetBps() external view returns (uint16);
    function criticalHedgeRangeDivisor() external view returns (uint16);
    function reserveHfTargetBps() external view returns (uint16);
    function liqThresholdBps() external view returns (uint16);
    function donationDustToken0() external view returns (uint256); // filtre dust cohérent (audit M-02)
    function supplyAndBorrow(uint256 collateralAmountUsdc, uint256 borrowAmountWeth) external;
    function sweepWethAmount(uint256 amount, address to) external;
}

interface IRmDep {
    function getCurrentBalances() external view returns (uint256, uint256); // libres + NFT (total)
    function getOptimalSwapParams() external view returns (RangeOperations.OptimalSwapParams memory);
    function sendTokenForHedge(address token, uint256 amount, address to) external;
    function vault() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function priceCache()
        external
        view
        returns (uint128 price0, uint128 price1, uint160 sqrtP, int24 tick, uint64 ts, bool valid);
    function protectionConfig() external view returns (bool, bool, bool, uint16, uint16, uint32, uint32);
    function config()
        external
        view
        returns (
            uint24 fee,
            uint8 dec0,
            uint8 dec1,
            uint16 tol,
            uint24 slip,
            uint64 lrt,
            bool oc,
            uint16 up,
            uint16 down,
            uint32 maxPos
        );
    function getOwnerPositions() external view returns (uint256[] memory);
    function positionManager() external view returns (INonfungiblePositionManager);
    function pool() external view returns (IUniswapV3Pool);
    function initMultiSwapTvl() external view returns (uint256);
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);
}

interface IVaultDep {
    function hedgeManager() external view returns (address);
}

interface IHedgeRepairContext {
    function pool() external view returns (address);
    function usdc() external view returns (address);
    function weth() external view returns (address);
    function aTokenUsdc() external view returns (address);
    function variableDebtWeth() external view returns (address);
    function swapRouter() external view returns (address);
    function rangeManager() external view returns (address);
    function swapPoolFee() external view returns (uint24);
    function liqThresholdBps() external view returns (uint16);
    function reserveHfTargetBps() external view returns (uint16);
    function swapSlippageBps() external view returns (uint16);
    function volatileDecimals() external view returns (uint8);
    function stableDecimals() external view returns (uint8);
}

interface IAavePoolDep {
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}

/// @title DnDepositLib
/// @notice Library externe (EIP-170) portant l'ouverture du hedge + le post-check au dépôt DN permissionless.
/// @dev Déportée hors du MultiUserVault (qui dépassait la limite de bytecode). Les fonctions sont `external`
///      et appelées en DELEGATECALL par le Vault → le code s'exécute dans le contexte du Vault (les
///      external-calls sortent donc bien depuis l'adresse du Vault, qui est `onlySafeOrVault` côté HedgeManager).
///      Aucun accès storage : tout est passé en paramètres. Calcul pur délégué à RangeOperations.
library DnDepositLib {
    using SafeERC20 for IERC20;
    /// @dev Adresses regroupées (anti stack-too-deep).
    struct Addrs {
        address hedgeManager;
        address rangeManager;
        address token0;
        address token1;
    }

    error InsufficientCollateral();
    error PreAdjustRequired();
    error InvalidSwapPlan();

    /// @notice Exact debt-token amount to repay through the existing flash-loan path when HF is below target.
    /// @dev Solves the repay-first equation while accounting for the collateral needed to buy back the flash
    ///      principal and premium. A small 10 bps HF buffer absorbs Aave/base-unit rounding.
    function aaveHfRepairAmount() external view returns (uint256 amount) {
        IHedgeRepairContext context = IHedgeRepairContext(address(this));
        address aavePool = context.pool();
        address debtToken = context.variableDebtWeth();
        uint16 targetHfBps = context.reserveHfTargetBps();
        uint16 swapSlippageBps = context.swapSlippageBps();
        (uint256 collateralBase, uint256 debtBase,, uint256 liveThreshold,, uint256 hf) =
            IAavePoolDep(aavePool).getUserAccountData(address(this));
        if (debtBase == 0 || collateralBase == 0 || liveThreshold == 0) return 0;
        uint256 bufferedTarget = uint256(targetHfBps) + 10;
        if (hf >= bufferedTarget * 1e14) return 0;

        uint256 premiumBps = IAavePoolDep(aavePool).FLASHLOAN_PREMIUM_TOTAL();
        uint256 costBps = 10000 + uint256(swapSlippageBps) + premiumBps + 5;
        uint256 collateralCost = Math.mulDiv(uint256(liveThreshold), costBps, 10000, Math.Rounding.Up);
        if (bufferedTarget <= collateralCost) revert InvalidSwapPlan();
        uint256 required = bufferedTarget * debtBase;
        uint256 protectedCollateral = uint256(liveThreshold) * collateralBase;
        if (required <= protectedCollateral) return 0;
        uint256 repayBase = Math.mulDiv(
            required - protectedCollateral, 1, bufferedTarget - collateralCost, Math.Rounding.Up
        );
        uint256 debtBalance = IERC20(debtToken).balanceOf(address(this));
        amount = Math.mulDiv(debtBalance, repayBase, debtBase, Math.Rounding.Up);
        if (amount > debtBalance) amount = debtBalance;
    }

    /// @notice Completes an HF repair after the callback has repaid Aave debt with flash-loaned token0.
    /// @dev Executed by DELEGATECALL in the HedgeManager context. The oracle maximum is funded only from
    ///      collateral that became safely withdrawable after the repay; no user-facing recipient is involved.
    function aaveCompleteHfRepair(uint256 flashOwed) external {
        IHedgeRepairContext context = IHedgeRepairContext(address(this));
        address aavePool = context.pool();
        address collateralToken = context.usdc();
        address aToken = context.aTokenUsdc();
        address debtToken = context.weth();
        address router = context.swapRouter();
        address rangeManager = context.rangeManager();
        uint16 targetHfBps = context.reserveHfTargetBps();
        uint16 slippageBps = context.swapSlippageBps();
        uint256 amountInMaximum =
            _oracleMaxToken1ForToken0(
                flashOwed, rangeManager, context.volatileDecimals(), context.stableDecimals(), slippageBps
            );
        uint256 currentBudget = IERC20(collateralToken).balanceOf(address(this));
        (uint256 capped, uint256 toWithdraw) = _hfSafeSwapBudget(
            currentBudget, amountInMaximum, aavePool, aToken, context.liqThresholdBps(), targetHfBps
        );
        if (toWithdraw > 0) IAavePoolDep(aavePool).withdraw(collateralToken, toWithdraw, address(this));
        if (capped < amountInMaximum || IERC20(collateralToken).balanceOf(address(this)) < amountInMaximum) {
            revert InsufficientCollateral();
        }
        ISwapRouter(router).exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: collateralToken,
                tokenOut: debtToken,
                fee: context.swapPoolFee(),
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: flashOwed,
                amountInMaximum: amountInMaximum,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function executeDepositSwaps(
        address rangeManager,
        address token0,
        uint256[] calldata amountsIn,
        uint256[] calldata minAmountsOut,
        address tokenIn,
        address tokenOut,
        uint128 price0,
        uint128 price1,
        uint8 dec0,
        uint8 dec1,
        uint256 depositTokenIn
    ) external returns (uint256 depositLossUsd, uint256 incumbentLossUsd) {
        uint256 totalLossUsd;
        uint256 totalIn;
        bool zeroForOne = tokenIn == token0;
        uint256 n = amountsIn.length;
        for (uint256 i; i < n; i++) {
            uint256 amountOut =
                IRmDep(rangeManager).executeSwap(tokenIn, tokenOut, amountsIn[i], minAmountsOut[i]);
            uint256 valueIn = zeroForOne ? _toUsd(amountsIn[i], price0, dec0) : _toUsd(amountsIn[i], price1, dec1);
            uint256 valueOut = zeroForOne ? _toUsd(amountOut, price1, dec1) : _toUsd(amountOut, price0, dec0);
            if (valueIn > valueOut) totalLossUsd += valueIn - valueOut;
            totalIn += amountsIn[i];
        }
        depositLossUsd = totalLossUsd;
        if (depositTokenIn < totalIn) {
            depositLossUsd = (totalLossUsd * depositTokenIn) / totalIn;
            incumbentLossUsd = totalLossUsd - depositLossUsd;
        }
    }

    /// @notice Ouvre le hedge au dépôt (cible GLOBALE : corrige aussi le drift existant). USD 8 déc.
    /// @param a Adresses (hedge, rm, token0, token1)
    /// @param price0 prix token0 Chainlink (8 déc)
    /// @param price1 prix token1 Chainlink (8 déc)
    /// @param dec0 décimales token0
    /// @param dec1 décimales token1
    function openDepositHedge(Addrs calldata a, uint128 price0, uint128 price1, uint8 dec0, uint8 dec1) external {
        // Exécution : les fonds du dépôt sont DÉJÀ sur le RM (_processOneDeposit a précédé) → extra0=extra1=0.
        (uint256 collateralUsdc, uint256 borrowWeth) =
            _computeDepositHedge(a.hedgeManager, a.rangeManager, a.token0, a.token1, price0, price1, dec0, dec1, 0, 0);

        if (collateralUsdc == 0) return; // déjà assez short → dépôt LP-seul (post-check tranchera)

        if (IERC20(a.token1).balanceOf(a.rangeManager) < collateralUsdc) revert InsufficientCollateral();

        IRmDep(a.rangeManager).sendTokenForHedge(a.token1, collateralUsdc, a.hedgeManager);
        IHedgeDep(a.hedgeManager).supplyAndBorrow(collateralUsdc, borrowWeth);
        IHedgeDep(a.hedgeManager).sweepWethAmount(borrowWeth, a.rangeManager);
    }

    /// @notice Valeur USD 8 dec des tokens idle detenus par le HedgeManager.
    /// @dev Fail-closed par design : si le HedgeManager ne repond pas, l'appelant revert.
    function idleHedgeValueUsd(address hedgeManager, address rangeManager) external view returns (uint256 valueUsd) {
        IRmDep rm = IRmDep(rangeManager);
        IHedgeDep hm = IHedgeDep(hedgeManager);
        (uint128 price0, uint128 price1,,,, bool valid) = rm.priceCache();
        if (!valid) return 0;
        (, uint8 dec0, uint8 dec1,,,,,,,) = rm.config();
        valueUsd = _toUsd(hm.getWethBalance(), price0, dec0);
        valueUsd += (hm.getUsdcBalance() * uint256(price1)) / (10 ** dec1);
    }

    function aaveEffectiveShort(address debtToken, address token0, address rangeManager, uint256 dustFloor)
        external
        view
        returns (uint256 debt, int256 effectiveShort)
    {
        debt = IERC20(debtToken).balanceOf(address(this));
        uint256 idleHm = _dust(IERC20(token0).balanceOf(address(this)), dustFloor);
        uint256 idleRm = _dust(IERC20(token0).balanceOf(rangeManager), dustFloor);
        effectiveShort = int256(debt) - int256(idleHm) - int256(idleRm);
    }

    /// @dev Calcule (collatéralUsdc, borrowWeth) du hedge au dépôt. Partagé par openDepositHedge (exécution) et
    ///      getDepositSwapParams (simulation H-01). Formule globale exacte (computeHedgeDeposit). Renvoie (0,0) si
    ///      déjà assez short.
    /// @dev AUDIT H-02 : `extra0`/`extra1` = montants du dépôt à venir, à AJOUTER aux soldes RM pour simuler
    ///      l'état POST-transfert (comme openDepositHedge, appelé après _processOneDeposit). openDepositHedge
    ///      passe (0,0) (les fonds sont déjà sur le RM) ; getDepositSwapParams passe (deposit0, deposit1).
    /// @dev AUDIT H-03 : rBps = ratio du NFT EXISTANT au prix courant (addLiquidityToPosition ajoute à CE range),
    ///      pas le range cible dynamique (getOptimalSwapParams, réservé au (re)mint).
    function _computeDepositHedge(
        address hedgeManager,
        address rangeManager,
        address token0,
        address token1,
        uint128 price0,
        uint128 price1,
        uint8 dec0,
        uint8 dec1,
        uint256 extra0,
        uint256 extra1
    ) private view returns (uint256 collateralUsdc, uint256 borrowWeth) {
        IHedgeDep hm = IHedgeDep(hedgeManager);
        IRmDep rm = IRmDep(rangeManager);
        uint256 dustTok0 = hm.donationDustToken0();
        uint256 debtUsd = _toUsd(hm.getWethDebt(), price0, dec0);
        uint256 freeRmWeth = IERC20(token0).balanceOf(rangeManager) + extra0; // + dépôt token0 (post-transfert)
        uint256 idleHmUsd = _toUsd(_dust(hm.getWethBalance(), dustTok0), price0, dec0);
        uint256 idleRmUsd = _toUsd(_dust(freeRmWeth, dustTok0), price0, dec0);
        (uint256 totalBal0,) = rm.getCurrentBalances();
        // totalBal0 inclut le NFT + le token0 libre ACTUEL (hors extra0) -> NFT = totalBal0 - libre actuel.
        uint256 curFreeRmWeth = freeRmWeth - extra0;
        uint256 nftWeth = totalBal0 > curFreeRmWeth ? totalBal0 - curFreeRmWeth : 0;
        uint256 investableUsd = ((IERC20(token1).balanceOf(rangeManager) + extra1) * uint256(price1)) / (10 ** dec1);
        uint16 rBps = _nftRatio0Bps(rangeManager); // H-03 : ratio du NFT existant

        (uint256 collateralUsd, uint256 borrowUsd) = RangeOperations.computeHedgeDeposit(
            RangeOperations.HedgeDepositParams({
                investableUsd: investableUsd,
                wethLpExistingUsd: _toUsd(nftWeth, price0, dec0),
                debtUsd: debtUsd,
                idleHmUsd: idleHmUsd,
                idleRmUsd: idleRmUsd,
                hedgeTargetBps: hm.hedgeTargetBps(),
                rBps: rBps,
                ltvBps: uint16((uint256(hm.liqThresholdBps()) * 10000) / uint256(hm.reserveHfTargetBps()))
            })
        );
        if (collateralUsd == 0) return (0, 0);
        collateralUsdc = (collateralUsd * (10 ** dec1)) / uint256(price1);
        borrowWeth = (borrowUsd * (10 ** dec0)) / uint256(price0);
    }

    /// @dev AUDIT H-03 : part token0 (bps) du NFT EXISTANT au prix courant — c'est le ratio que
    ///      addLiquidityToPosition produira (il ajoute au range du NFT, PAS au range cible dynamique).
    ///      Fallback sur targetRatio0Bps si pas de NFT (ne devrait pas arriver au dépôt de croissance).
    function _nftRatio0Bps(address rangeManager) private view returns (uint16) {
        IRmDep rm = IRmDep(rangeManager);
        uint256[] memory positions = rm.getOwnerPositions();
        if (positions.length > 0) {
            uint256 r = RangeOperations.nftRatio0BpsForPosition(rm.positionManager(), positions[0], _pc(rm));
            if (r > 0 && r <= 10000) return uint16(r);
        }
        uint256 fb = rm.getOptimalSwapParams().targetRatio0Bps; // fallback : range cible dynamique
        return fb > 10000 ? 10000 : uint16(fb);
    }

    function _pc(IRmDep rm) private view returns (RangeOperations.PriceCache memory pc) {
        (uint128 p0, uint128 p1, uint160 sp, int24 tk, uint64 ts, bool v) = rm.priceCache();
        (bool twapEnabled,,,,,,) = rm.protectionConfig();
        if (twapEnabled) {
            tk = RangeOperations.trustedTwapTick(rm.pool());
            sp = RangeOperations.sqrtRatioAtTickExt(tk);
        }
        pc = RangeOperations.PriceCache({
            price0: p0,
            price1: p1,
            poolSqrtPriceX96: sp,
            poolTick: tk,
            timestamp: ts,
            valid: v
        });
    }

    /// @notice AUDIT H-01 : plan de swap du PROCHAIN DÉPÔT, calculé sur l'état FUTUR (post-transfert du dépôt +
    ///         post-ouverture du hedge), PAS sur l'état rebalance/post-burn de getOptimalSwapParams (qui inclut
    ///         le NFT et ignore le dépôt + le token0 emprunté -> 0 swap erroné ou swap sur fonds bloqués).
    /// @dev    Simule : freeT0 = RM_t0 + dépôt_t0 + borrowToken0 ; freeT1 = RM_t1 + dépôt_t1 - collateralToken1.
    ///         Puis dimensionne le swap vers le ratio du range. Renvoie (zeroForOne, amountIn) en unités natives.
    ///         No-op (false,0) si pool std (hedgeManager==0) → le caller retombe sur getOptimalSwapParams.
    /// @return zeroForOne true si swap token0→token1
    /// @return amountIn montant à swapper (unités natives du token d'entrée), 0 si aucun swap
    function getDepositSwapParams(address rangeManager, uint256 depositAmount0, uint256 depositAmount1)
        external
        view
        returns (bool zeroForOne, uint256 amountIn)
    {
        return _depositSwapParams(rangeManager, depositAmount0, depositAmount1);
    }

    function _depositSwapParams(address rangeManager, uint256 depositAmount0, uint256 depositAmount1)
        private
        view
        returns (bool zeroForOne, uint256 amountIn)
    {
        IRmDep rmI = IRmDep(rangeManager);
        (uint128 price0, uint128 price1,,,, bool valid) = rmI.priceCache();
        if (!valid) return (false, 0);
        (, uint8 dec0, uint8 dec1,,,,,,,) = rmI.config();
        address token0 = rmI.token0();
        address token1 = rmI.token1();
        address hedgeManager = IVaultDep(rmI.vault()).hedgeManager();

        // Collatéral/borrow que openDepositHedge exécutera APRÈS transfert du dépôt (H-02 : on passe le dépôt
        // comme extra0/extra1 → la simulation voit les mêmes soldes que l'exécution réelle). (0,0 en std.)
        uint256 collateralUsdc;
        uint256 borrowWeth;
        if (hedgeManager != address(0)) {
            (collateralUsdc, borrowWeth) = _computeDepositHedge(
                hedgeManager, rangeManager, token0, token1, price0, price1, dec0, dec1, depositAmount0, depositAmount1
            );
        }

        // État LIBRE futur (post-transfert dépôt + post-hedge).
        uint256 freeT0 = IERC20(token0).balanceOf(rangeManager) + depositAmount0 + borrowWeth;
        uint256 freeT1c = IERC20(token1).balanceOf(rangeManager) + depositAmount1;
        uint256 freeT1 = freeT1c > collateralUsdc ? freeT1c - collateralUsdc : 0;

        // Valeurs USD (8 déc). AUDIT H-03 : ratio cible = celui du NFT EXISTANT (addLiquidityToPosition ajoute
        // à CE range), pas le range cible dynamique.
        uint256 v0 = _toUsd(freeT0, price0, dec0);
        uint256 v1 = (freeT1 * uint256(price1)) / (10 ** dec1);
        uint256 tot = v0 + v1;
        if (tot == 0) return (false, 0);
        uint256 targetV0 = (tot * _nftRatio0Bps(rangeManager)) / 10000;

        if (v0 > targetV0) {
            // trop de token0 → swap token0→token1 de l'excédent (converti en unités token0)
            uint256 excessUsd = v0 - targetV0;
            amountIn = (excessUsd * (10 ** dec0)) / uint256(price0);
            return (true, amountIn);
        } else if (targetV0 > v0) {
            // pas assez de token0 → swap token1→token0 (excédent token1 en unités token1)
            uint256 deficitUsd = targetV0 - v0;
            amountIn = (deficitUsd * (10 ** dec1)) / uint256(price1);
            return (false, amountIn);
        }
        return (false, 0);
    }

    function validateDepositSwapPlan(
        address rangeManager,
        uint256 depositAmount0,
        uint256 depositAmount1,
        uint256[] calldata swapAmountsIn,
        uint256[] calldata minAmountsOut,
        address tokenIn,
        address tokenOut,
        uint256 maxTotalSwapUsd
    ) external view {
        if (swapAmountsIn.length != minAmountsOut.length) revert InvalidSwapPlan();
        IRmDep rm = IRmDep(rangeManager);
        address token0 = rm.token0();
        address token1 = rm.token1();
        bool tokenInIsToken0 = tokenIn == token0;
        (bool expectedZeroForOne, uint256 expectedAmountIn) =
            _depositSwapParams(rangeManager, depositAmount0, depositAmount1);
        uint256 n = swapAmountsIn.length;
        uint256 totalSwapIn;
        uint16 toleranceBps;
        if (n > 0) {
            if (!((tokenIn == token0 && tokenOut == token1) || (tokenIn == token1 && tokenOut == token0))) {
                revert InvalidSwapPlan();
            }
            (uint128 price0, uint128 price1,,, uint64 ts, bool valid) = rm.priceCache();
            if (!valid || price0 == 0 || price1 == 0) revert InvalidSwapPlan();
            (, uint8 dec0, uint8 dec1, uint16 tol, uint24 slip,,,,,) = rm.config();
            toleranceBps = tol;
            RangeOperations.PriceCache memory pc = RangeOperations.PriceCache(price0, price1, 0, 0, ts, valid);
            RangeOperations.RangeConfig memory cfg =
                RangeOperations.RangeConfig(0, dec0, dec1, tol, slip, 0, true, 0, 0, 1);
            uint256 chunkCapUsd = rm.initMultiSwapTvl() * 1e8;
            uint256 priceInUsd = tokenInIsToken0 ? uint256(price0) : uint256(price1);
            uint256 decIn = tokenInIsToken0 ? dec0 : dec1;
            uint256 totalSwapUsd;
            for (uint256 i; i < n; ++i) {
                uint256 amt = swapAmountsIn[i];
                totalSwapIn += amt;
                uint256 chunkUsd = (amt * priceInUsd) / (10 ** decIn);
                if (chunkCapUsd > 0 && chunkUsd > chunkCapUsd) revert InvalidSwapPlan();
                totalSwapUsd += chunkUsd;
                if (maxTotalSwapUsd > 0 && totalSwapUsd > maxTotalSwapUsd) revert InvalidSwapPlan();
                uint256 floor = RangeOperations.oracleMinOut(tokenInIsToken0, amt, pc, cfg, slip);
                if (minAmountsOut[i] < floor) revert InvalidSwapPlan();
            }
        } else {
            (,,, toleranceBps,,,,,,) = rm.config();
        }
        _requireSwapPlan(expectedAmountIn, expectedZeroForOne, tokenInIsToken0, totalSwapIn, toleranceBps);
    }

    function aaveHfSafeSwapBudget(
        uint256 currentBudget,
        uint256 amountInMaximum,
        address aavePool,
        address aToken,
        uint256 fallbackLiqThresholdBps,
        uint256 targetHfBps
    ) external view returns (uint256 cappedAmountInMaximum, uint256 toWithdraw) {
        return _hfSafeSwapBudget(
            currentBudget, amountInMaximum, aavePool, aToken, fallbackLiqThresholdBps, targetHfBps
        );
    }

    function _hfSafeSwapBudget(
        uint256 currentBudget,
        uint256 amountInMaximum,
        address aavePool,
        address aToken,
        uint256 fallbackLiqThresholdBps,
        uint256 targetHfBps
    ) private view returns (uint256 cappedAmountInMaximum, uint256 toWithdraw) {
        cappedAmountInMaximum = amountInMaximum;
        if (currentBudget >= amountInMaximum) return (cappedAmountInMaximum, 0);

        (uint256 collateralBase, uint256 debtBase,, uint256 liveThreshold,,) =
            IAavePoolDep(aavePool).getUserAccountData(address(this));
        if (debtBase == 0) {
            uint256 needed = amountInMaximum - currentBudget;
            uint256 collateralBalance = IERC20(aToken).balanceOf(address(this));
            toWithdraw = needed < collateralBalance ? needed : collateralBalance;
            uint256 zeroDebtBudget = currentBudget + toWithdraw;
            if (cappedAmountInMaximum > zeroDebtBudget) cappedAmountInMaximum = zeroDebtBudget;
            return (cappedAmountInMaximum, toWithdraw);
        }
        uint256 liquidationThresholdBps = liveThreshold > 0 ? liveThreshold : fallbackLiqThresholdBps;
        if (collateralBase == 0 || liquidationThresholdBps == 0) {
            cappedAmountInMaximum = currentBudget < amountInMaximum ? currentBudget : amountInMaximum;
            return (cappedAmountInMaximum, 0);
        }
        uint256 minCollateralBase = (debtBase * targetHfBps + liquidationThresholdBps - 1) / liquidationThresholdBps;
        if (collateralBase > minCollateralBase) {
            uint256 collateralBalance = IERC20(aToken).balanceOf(address(this));
            uint256 maxWithdraw = (collateralBalance * (collateralBase - minCollateralBase)) / collateralBase;
            toWithdraw = amountInMaximum - currentBudget;
            if (toWithdraw > maxWithdraw) toWithdraw = maxWithdraw;
        }
        uint256 budget = currentBudget + toWithdraw;
        if (cappedAmountInMaximum > budget) cappedAmountInMaximum = budget;
    }

    function aaveCollateralShare(address aToken, uint256 proportionX18) external view returns (uint256) {
        return (IERC20(aToken).balanceOf(address(this)) * proportionX18) / 1e18;
    }

    function settleAaveNoDebt(
        address aavePool,
        address collateralToken,
        address aToken,
        address debtToken,
        uint256 debtTokenReceived,
        uint256 proportionX18,
        bool fullWithdraw,
        address recipient
    ) external {
        if (IERC20(aToken).balanceOf(address(this)) > 0) {
            uint256 collateralAmount = fullWithdraw
                ? type(uint256).max
                : (IERC20(aToken).balanceOf(address(this)) * proportionX18) / 1e18;
            if (collateralAmount > 0) {
                IAavePoolDep(aavePool).withdraw(collateralToken, collateralAmount, recipient);
            }
        }

        if (fullWithdraw) {
            uint256 balance = IERC20(debtToken).balanceOf(address(this));
            if (balance > 0) IERC20(debtToken).safeTransfer(recipient, balance);
            balance = IERC20(collateralToken).balanceOf(address(this));
            if (balance > 0) IERC20(collateralToken).safeTransfer(recipient, balance);
        } else if (debtTokenReceived > 0) {
            IERC20(debtToken).safeTransfer(recipient, debtTokenReceived);
        }
    }

    function aaveHedgeValuesUsd(
        address aToken,
        address debtToken,
        address rangeManager,
        uint8 stableDecimals,
        uint8 volatileDecimals
    ) external view returns (uint256 collateralUsd, uint256 debtUsd) {
        (uint128 price0, uint128 price1,,,, bool valid) = IRmDep(rangeManager).priceCache();
        if (!valid || price0 == 0 || price1 == 0) revert InvalidSwapPlan();
        collateralUsd = (IERC20(aToken).balanceOf(address(this)) * uint256(price1)) / (10 ** stableDecimals);
        debtUsd = (IERC20(debtToken).balanceOf(address(this)) * uint256(price0)) / (10 ** volatileDecimals);
    }

    function aaveReserveExcessStable(
        address aavePool,
        address aToken,
        uint256 fallbackLiqThresholdBps,
        uint256 targetHfBps
    ) external view returns (uint256 excessStable) {
        (uint256 collateralBase, uint256 debtBase,, uint256 liveThreshold,,) =
            IAavePoolDep(aavePool).getUserAccountData(address(this));
        if (debtBase == 0 || collateralBase == 0) return 0;
        uint256 liquidationThresholdBps = liveThreshold > 0 ? liveThreshold : fallbackLiqThresholdBps;
        if (liquidationThresholdBps == 0) return 0;
        uint256 collateralTargetBase = (debtBase * targetHfBps + liquidationThresholdBps - 1) / liquidationThresholdBps;
        if (collateralBase <= collateralTargetBase) return 0;
        return (IERC20(aToken).balanceOf(address(this)) * (collateralBase - collateralTargetBase)) / collateralBase;
    }

    function _requireSwapPlan(
        uint256 expectedAmountIn,
        bool expectedZeroForOne,
        bool tokenInIsToken0,
        uint256 submittedAmountIn,
        uint16 toleranceBps
    ) private pure {
        if (expectedAmountIn == 0) {
            if (submittedAmountIn != 0) revert InvalidSwapPlan();
            return;
        }
        if (tokenInIsToken0 != expectedZeroForOne) revert InvalidSwapPlan();
        uint256 tolerance = (expectedAmountIn * uint256(toleranceBps)) / 10000;
        if (tolerance == 0) tolerance = 1;
        if (submittedAmountIn + tolerance < expectedAmountIn) revert InvalidSwapPlan();
        if (submittedAmountIn > expectedAmountIn + tolerance) revert InvalidSwapPlan();
    }

    /// @notice AUDIT M-01 : plan de swap d'un REBALANCE DN compatible avec la dette AAVE FIXE. rebalance() ne
    ///         touche pas AAVE -> pour passer le post-check, la LP remintée doit avoir token0InLP ~= effectiveShort/H
    ///         (le short net est fixé par la dette). On calcule le swap depuis les balances TOTALES post-burn
    ///         (libres + NFT, via getCurrentBalances qui reflète l'état post-burn) vers cette cible token0.
    /// @dev    À utiliser par le keeper quand le rebalance est déclenché par drift DN (sous-hedge in-range) —
    ///         le plan range standard (getOptimalSwapParams) ne viserait pas la compo compatible dette fixe.
    ///         Renvoie (zeroForOne, amountIn natif). No-op si std/HF nul.
    function getRebalanceSwapParams(address rangeManager) external view returns (bool zeroForOne, uint256 amountIn) {
        IRmDep rm = IRmDep(rangeManager);
        address hedgeManager = IVaultDep(rm.vault()).hedgeManager();
        if (hedgeManager == address(0)) return (false, 0);
        IHedgeDep hm = IHedgeDep(hedgeManager);
        (uint128 price0, uint128 price1,,,, bool valid) = rm.priceCache();
        if (!valid) return (false, 0);
        (, uint8 dec0, uint8 dec1,,,,,,,) = rm.config();
        // The RM balance is already included in totalBal0 below. Subtracting it here would count the same
        // token0 twice; only idle token0 held by the HedgeManager reduces the fixed short before reconstruction.
        // Si idle >= dette, la cible token0 LP est 0 : le rebalance doit pouvoir vendre le token0 LP restant
        // vers token1 au lieu de retourner "no swap", sinon le post-check DN resterait impossible a satisfaire.
        uint256 dustTok0 = hm.donationDustToken0();
        uint256 debtUsd = _toUsd(hm.getWethDebt(), price0, dec0);
        uint256 idleUsd = _toUsd(_dust(hm.getWethBalance(), dustTok0), price0, dec0);
        uint256 effShortUsd = debtUsd > idleUsd ? debtUsd - idleUsd : 0;

        uint256 H = hm.hedgeTargetBps();
        if (H == 0) return (false, 0);
        // Cible : token0InLP_usd tel que H * token0InLP = effectiveShort => token0InLP_usd = effectiveShort * 10000 / H.
        uint256 targetWethLpUsd = (effShortUsd * 10000) / H;

        // Balances TOTALES post-burn (libres + NFT) = capital disponible pour reconstruire la LP.
        (uint256 totalBal0, uint256 totalBal1) = rm.getCurrentBalances();
        uint256 v0 = _toUsd(totalBal0, price0, dec0);
        // On vise v0 == targetWethLpUsd (le reste part en token1). Borne : on ne peut pas dépasser le capital total.
        uint256 totUsd = v0 + (totalBal1 * uint256(price1)) / (10 ** dec1);
        uint256 targetV0 = targetWethLpUsd > totUsd ? totUsd : targetWethLpUsd;

        if (v0 > targetV0) {
            amountIn = ((v0 - targetV0) * (10 ** dec0)) / uint256(price0); // swap token0->token1 (reduit token0InLP)
            return (true, amountIn);
        } else if (targetV0 > v0) {
            amountIn = ((targetV0 - v0) * (10 ** dec1)) / uint256(price1); // swap token1→token0
            return (false, amountIn);
        }
        return (false, 0);
    }

    /// @notice Post-check DN après addLiquidity (DÉPÔT). Revert PreAdjustRequired si hors tolérance/HF.
    /// @dev maxDriftBps est un plafond configuré ; le seuil effectif est resserré au seuil critique dynamique
    ///      quand le range courant est étroit, afin qu'un dépôt ne puisse pas ressortir déjà "critique".
    function postCheckDepositHedge(
        Addrs calldata a,
        uint128 price0,
        uint8 dec0,
        uint16 maxDriftBps,
        uint256 dustFloorUsd
    ) external view {
        _postCheck(a.hedgeManager, a.rangeManager, a.token0, price0, dec0, maxDriftBps, dustFloorUsd);
    }

    /// @notice Post-check DN du REBALANCE permissionless. Args plats (RangeManager appelle avec address(this),
    ///         pas de struct → économie bytecode côté RangeManager). Résout hedgeManager via vault. No-op si
    ///         pool std (hedgeManager==0). Greffé à la fin de RangeManager.rebalance() : compo LP mal dimensionnée
    ///         par le keeper → revert toute la tx (burn/mint rollback, pas de bounty).
    function postCheckRebalanceHedge(
        address rangeManager,
        address token0,
        uint128 price0,
        uint8 dec0,
        uint16 maxDriftBps,
        uint256 dustFloorUsd
    ) external view {
        address hedgeManager = IVaultDep(IRmDep(rangeManager).vault()).hedgeManager();
        if (hedgeManager == address(0)) return;
        _postCheck(hedgeManager, rangeManager, token0, price0, dec0, maxDriftBps, dustFloorUsd);
    }

    /// @dev Cœur du post-check DN (partagé dépôt + rebalance). Audit H-03/M-02 : dette EXACTE (getWethDebt),
    ///      wethInLp = NFT seulement (total − libre RM, pas de double comptage avec idleRm), filtre dust cohérent.
    ///      Le drift max effectif = min(maxDriftBps configuré, seuil critique dynamique range/divisor).
    function _postCheck(
        address hedgeManager,
        address rangeManager,
        address token0,
        uint128 price0,
        uint8 dec0,
        uint16 maxDriftBps,
        uint256 dustFloorUsd
    ) private view {
        IHedgeDep hm = IHedgeDep(hedgeManager);
        uint16 effectiveMaxDriftBps = _postCheckMaxDriftBps(hedgeManager, rangeManager, maxDriftBps);
        (bool ok,) = _driftBps(hedgeManager, rangeManager, token0, price0, dec0, effectiveMaxDriftBps, dustFloorUsd);
        if (!ok) revert PreAdjustRequired();

        if (_toUsd(hm.getWethDebt(), price0, dec0) > 0) {
            (,, uint256 hf,) = hm.getHedgeData();
            uint256 hfMin = (uint256(hm.reserveHfTargetBps()) * 1e18) / 10000;
            if (hf < hfMin) revert PreAdjustRequired();
        }
    }

    /// @dev Le post-check garde le paramètre .env comme plafond, puis se resserre automatiquement avec le range.
    function _postCheckMaxDriftBps(address hedgeManager, address rangeManager, uint16 configuredMaxBps)
        private
        view
        returns (uint16)
    {
        uint16 effectiveMaxBps = configuredMaxBps;
        try IHedgeDep(hedgeManager).criticalHedgeRangeDivisor() returns (uint16 divisor) {
            uint16 criticalBps = _rangeHedgeThresholdBps(rangeManager, divisor, 250);
            if (criticalBps < effectiveMaxBps) effectiveMaxBps = criticalBps;
        } catch {}
        return effectiveMaxBps;
    }

    /// @dev Cœur de lecture du drift DN on-chain (effectiveShort vs cible). Retourne (ok, driftBps).
    ///      Audit H-03/M-02 : dette exacte, NFT-only, filtre dust cohérent. Partagé post-check + trigger H-06.
    function _driftBps(
        address hedgeManager,
        address rangeManager,
        address token0,
        uint128 price0,
        uint8 dec0,
        uint16 maxDriftBps,
        uint256 dustFloorUsd
    ) private view returns (bool ok, uint256 driftBps) {
        IHedgeDep hm = IHedgeDep(hedgeManager);
        IRmDep rm = IRmDep(rangeManager);
        uint256 dustTok0 = hm.donationDustToken0();
        uint256 debtUsd = _toUsd(hm.getWethDebt(), price0, dec0);
        uint256 freeRmWeth = IERC20(token0).balanceOf(rangeManager);
        uint256 idleHmUsd = _toUsd(_dust(hm.getWethBalance(), dustTok0), price0, dec0);
        uint256 idleRmUsd = _toUsd(_dust(freeRmWeth, dustTok0), price0, dec0);
        (uint256 totalBal0,) = rm.getCurrentBalances();
        uint256 nftWeth = totalBal0 > freeRmWeth ? totalBal0 - freeRmWeth : 0;
        uint256 wethInLpUsd = _toUsd(nftWeth, price0, dec0);
        return RangeOperations.checkHedgeDelta(
            debtUsd, idleHmUsd, idleRmUsd, wethInLpUsd, hm.hedgeTargetBps(), maxDriftBps, dustFloorUsd
        );
    }

    /// @notice AUDIT H-06 : indique si le drift DN dépasse `critBps` (sous/sur-hedge critique), pour autoriser
    ///         un rebalance() permissionless MÊME quand la LP est in-range (sinon un sous-hedge sévère ne pourrait
    ///         être corrigé par personne : adjustHedge revert UnderHedged, et rebalance exige needsRebalance de range).
    ///         Args plats (RangeManager appelle avec address(this)). No-op→false si pool std (hedgeManager==0).
    function dnHedgeDriftExceeds(
        address rangeManager,
        address token0,
        uint128 price0,
        uint8 dec0,
        uint16 critBps,
        uint256 dustFloorUsd
    ) external view returns (bool) {
        address hedgeManager = IVaultDep(IRmDep(rangeManager).vault()).hedgeManager();
        if (hedgeManager == address(0)) return false;
        uint16 effectiveCritBps = critBps;
        try IHedgeDep(hedgeManager).criticalHedgeRangeDivisor() returns (uint16 divisor) {
            uint16 dynamicCritBps = _rangeHedgeThresholdBps(rangeManager, divisor, 250);
            if (dynamicCritBps < effectiveCritBps) effectiveCritBps = dynamicCritBps;
        } catch {}
        (bool ok,) = _driftBps(hedgeManager, rangeManager, token0, price0, dec0, effectiveCritBps, dustFloorUsd);
        return !ok; // ok == drift <= seuil critique effectif ; donc !ok == drift > seuil critique (critique)
    }

    /// @notice Seuil dynamique depuis la config range d'un RangeManager.
    function rangeHedgeThresholdBps(address rangeManager, uint16 rangeDivisor, uint16 floorBps)
        external
        view
        returns (uint16)
    {
        return _rangeHedgeThresholdBps(rangeManager, rangeDivisor, floorBps);
    }

    /// @notice Calcule un seuil hedge dynamique depuis la largeur du range courant.
    /// @dev threshold = max(floorBps, (rangeUpBps + rangeDownBps) / rangeDivisor).
    ///      Exemple: divisor=4 => range ±2% (400 bps wide) => 100 bps ; range ±5% => 250 bps.
    function dynamicHedgeThresholdBps(uint16 rangeUpBps, uint16 rangeDownBps, uint16 rangeDivisor, uint16 floorBps)
        external
        pure
        returns (uint16)
    {
        return _dynamicHedgeThresholdBps(rangeUpBps, rangeDownBps, rangeDivisor, floorBps);
    }

    function _rangeHedgeThresholdBps(address rangeManager, uint16 rangeDivisor, uint16 floorBps)
        private
        view
        returns (uint16)
    {
        if (rangeManager == address(0)) return floorBps;
        (bool ok, bytes memory data) = rangeManager.staticcall(abi.encodeWithSelector(IRmDep.config.selector));
        if (!ok || data.length < 320) return floorBps;
        (,,,,,,, uint16 rangeUpBps, uint16 rangeDownBps,) =
            abi.decode(data, (uint24, uint8, uint8, uint16, uint24, uint64, bool, uint16, uint16, uint32));
        return _dynamicHedgeThresholdBps(rangeUpBps, rangeDownBps, rangeDivisor, floorBps);
    }

    function _dynamicHedgeThresholdBps(uint16 rangeUpBps, uint16 rangeDownBps, uint16 rangeDivisor, uint16 floorBps)
        private
        pure
        returns (uint16)
    {
        if (rangeDivisor == 0) return floorBps;
        uint256 threshold = (uint256(rangeUpBps) + uint256(rangeDownBps)) / uint256(rangeDivisor);
        if (threshold < uint256(floorBps)) threshold = uint256(floorBps);
        if (threshold > type(uint16).max) threshold = type(uint16).max;
        return uint16(threshold);
    }

    /// @notice Composition token0 du NFT LP + ticks, utilisée par AaveHedgeManager.adjustHedge().
    /// @dev Déport bytecode DN-only : évite une troisième library et laisse le settlement critique dans le manager.
    function aaveLpToken0AndTicks(uint256 tokenId, INonfungiblePositionManager lpPositionManager, IUniswapV3Pool lpPool)
        external
        view
        returns (uint256 token0InLP, int24 tickLower, int24 tickUpper)
    {
        uint128 liquidity;
        (,,,,, tickLower, tickUpper, liquidity,,,,) = lpPositionManager.positions(tokenId);
        if (liquidity == 0) return (0, tickLower, tickUpper);

        int24 currentTick = RangeOperations.trustedTwapTick(lpPool);
        uint160 sqrtPriceX96 = RangeOperations.sqrtRatioAtTickExt(currentTick);
        uint160 sqrtRatioA = RangeOperations.sqrtRatioAtTickExt(tickLower);
        uint160 sqrtRatioB = RangeOperations.sqrtRatioAtTickExt(tickUpper);

        if (currentTick < tickLower) {
            token0InLP = _aaveAmount0ForLiquidity(sqrtRatioA, sqrtRatioB, liquidity);
        } else if (currentTick >= tickUpper) {
            token0InLP = 0; // hors range haut : 100% token1
        } else {
            token0InLP = _aaveAmount0ForLiquidity(sqrtPriceX96, sqrtRatioB, liquidity);
        }
    }

    /// @notice Garde anti-manipulation LP/oracle pour AaveHedgeManager.adjustHedge().
    /// @dev Compare le prix pool token1/token0 au ratio oracle price0/price1 du RangeManager.
    ///      Aucune hypothese "token1 stable" : fonctionne aussi si token1 est un actif non stable.
    function aaveRequireLpNotDeviated(
        address rangeManager,
        IUniswapV3Pool lpPool,
        uint160 sqrtPriceX96,
        int24 currentTick,
        uint16 maxHedgeDeviationBps,
        uint8 volatileDecimals,
        uint8 stableDecimals
    ) external view {
        if (maxHedgeDeviationBps == 0 || sqrtPriceX96 == 0) return;

        uint256 sp = uint256(sqrtPriceX96);
        uint256 poolRaw = Math.mulDiv(sp, sp, 1 << 96);
        poolRaw = Math.mulDiv(poolRaw, 1e18, 1 << 96);
        uint256 poolPrice = Math.mulDiv(poolRaw, 10 ** volatileDecimals, 10 ** stableDecimals);

        (uint128 price0, uint128 price1,,,, bool valid) = IRmDep(rangeManager).priceCache();
        require(valid && price0 > 0 && price1 > 0, "Bad oracle");
        uint256 oraclePrice = Math.mulDiv(uint256(price0), 1e18, uint256(price1));

        uint256 diff = poolPrice > oraclePrice ? poolPrice - oraclePrice : oraclePrice - poolPrice;
        require((diff * 10000) / oraclePrice <= maxHedgeDeviationBps, "LP price deviation");

        (bool twapEnabled,,, uint16 twapBps,,,) = IRmDep(rangeManager).protectionConfig();
        if (twapEnabled) {
            int24 twapTick = RangeOperations.trustedTwapTick(lpPool);
            int24 tickDiff = currentTick > twapTick ? currentTick - twapTick : twapTick - currentTick;
            require(uint24(tickDiff) <= uint24(twapBps), "LP TWAP");
        }
    }

    /// @notice Plafond token1 pour acheter `amount0Out` token0 via exactOutput, base sur price0/price1.
    /// @dev priceCache doit avoir ete rafraichi fail-closed par le caller juste avant.
    function aaveOracleMaxToken1ForToken0(
        uint256 amount0Out,
        address rangeManager,
        uint8 dec0,
        uint8 dec1,
        uint16 slippageBps
    ) external view returns (uint256 amountInMaximum) {
        return _oracleMaxToken1ForToken0(amount0Out, rangeManager, dec0, dec1, slippageBps);
    }

    function _oracleMaxToken1ForToken0(
        uint256 amount0Out,
        address rangeManager,
        uint8 dec0,
        uint8 dec1,
        uint16 slippageBps
    ) private view returns (uint256 amountInMaximum) {
        (uint128 price0, uint128 price1,,,, bool valid) = IRmDep(rangeManager).priceCache();
        require(valid && price0 > 0 && price1 > 0, "Bad oracle");
        uint256 theoretical = Math.mulDiv(amount0Out, uint256(price0) * (10 ** dec1), uint256(price1) * (10 ** dec0));
        amountInMaximum = Math.mulDiv(theoretical, 10000 + uint256(slippageBps), 10000);
        require(amountInMaximum > 0, "Bad oracle");
    }

    // ===== helpers internes (inlinés dans la library) =====
    function _toUsd(uint256 amount0, uint128 price0, uint8 dec0) private pure returns (uint256) {
        return (amount0 * uint256(price0)) / (10 ** dec0);
    }

    /// @dev Filtre dust anti-grief donation : PART du solde au-delà du seuil (token0). Cohérent avec
    ///      AaveHedgeManager._netOfDust (audit M-02) — appliqué aux 2 balances idle dans tous les chemins DN.
    function _dust(uint256 balance, uint256 dustFloorTok0) private pure returns (uint256) {
        return balance > dustFloorTok0 ? balance - dustFloorTok0 : 0;
    }

    /// @dev Montant de token0 pour une liquidite Uniswap V3 entre deux sqrtRatios.
    function _aaveAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        private
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        require(sqrtRatioAX96 > 0, "sqrtA=0");
        uint256 numerator = uint256(liquidity) << 96;
        return (numerator / uint256(sqrtRatioAX96)) - (numerator / uint256(sqrtRatioBX96));
    }
}
