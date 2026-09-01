// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./RangeOperations.sol";
import "./interfaces/IRangeStrategyEngine.sol";

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
    function criticalHedgeBps() external view returns (uint16);
    function reserveHfTargetBps() external view returns (uint16);
    function operationalHfTargetBps() external view returns (uint16);
    function hfRepairTriggerBps() external view returns (uint16);
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
    function protectionConfig() external view returns (bool, bool, uint16, uint16, uint32, uint32);
    function config()
        external
        view
        returns (uint24 fee, uint8 dec0, uint8 dec1, uint16 tol, uint24 slip, uint64 lrt, bool oc, uint32 maxPos);
    function getOwnerPositions() external view returns (uint256[] memory);
    function calculateTargetTicks() external view returns (int24 tickLower, int24 tickUpper);
    function positionManager() external view returns (INonfungiblePositionManager);
    function pool() external view returns (IUniswapV3Pool);
    function initMultiSwapTvl() external view returns (uint256);
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);
    function collectFeesForVault() external returns (uint256 fees0, uint256 fees1);
    function strategyEngine() external view returns (IRangeStrategyEngine);
    function isProtocolBotCaller(address caller) external view returns (bool);
}

interface IVaultDep {
    function hedgeManager() external view returns (address);
}

interface IHedgeRepairContext {
    function pool() external view returns (address);
    function weth() external view returns (address);
    function variableDebtWeth() external view returns (address);
    function operationalHfTargetBps() external view returns (uint16);
    function hfRepairTriggerBps() external view returns (uint16);
    function swapSlippageBps() external view returns (uint16);
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

    uint160 private constant MIN_SQRT_PRICE_LIMIT_X96 = 4295128740;
    uint160 private constant MAX_SQRT_PRICE_LIMIT_X96 = 1461446703485210103287273052203988822378723970341;

    error ProtectedVaultFunds();
    error ExactTransferRequired();
    error InvalidStrategyDecision();
    /// @dev Adresses regroupées (anti stack-too-deep).

    struct Addrs {
        address hedgeManager;
        address rangeManager;
        address token0;
        address token1;
    }

    function pullExact(address token, uint256 amount) external {
        IERC20 asset = IERC20(token);
        uint256 beforeBalance = asset.balanceOf(address(this));
        // Library calls execute by delegatecall, so msg.sender remains the depositor
        // authenticated by MultiUserVault.deposit(). No arbitrary payer is accepted.
        asset.safeTransferFrom(msg.sender, address(this), amount);
        if (asset.balanceOf(address(this)) - beforeBalance != amount) revert ExactTransferRequired();
    }

    /// @dev Execute en delegatecall depuis le Vault: seuls les soldes locaux au-dela des reserves FIFO
    ///      peuvent sortir. Le controle d'acces Safe et le nonReentrant restent portes par le Vault.
    function rescueVaultToken(
        address token,
        address token0,
        address token1,
        address to,
        uint256 amount,
        uint256 pending0,
        uint256 pending1
    ) external {
        IERC20 asset = IERC20(token);
        if (token == token0 || token == token1) {
            uint256 reserved = token == token0 ? pending0 : pending1;
            uint256 balance = asset.balanceOf(address(this));
            if (balance < reserved || amount > balance - reserved) revert ProtectedVaultFunds();
        }
        asset.safeTransfer(to, amount);
    }

    error InsufficientCollateral();
    error PreAdjustRequired();
    error InvalidSwapPlan();
    error BadOracle();
    error LpPriceDeviation();
    error LpTwapDeviation();
    error SqrtRatioAIsZero();

    /// @notice Exact debt-token amount to repay through the existing flash-loan path when HF is below target.
    /// @dev Solves the repay-first equation while accounting for the collateral needed to buy back the flash
    ///      principal and premium. A small 10 bps HF buffer absorbs Aave/base-unit rounding.
    /// @dev Sizes the idle repayment first, then the residual flash repair against the conservative
    ///      post-repay debt estimate. The caller executes both atomically and verifies the final HF.
    function aaveHfRepairAmounts() external view returns (uint256 directAmount, uint256 flashAmount) {
        IHedgeRepairContext context = IHedgeRepairContext(address(this));
        address aavePool = context.pool();
        address debtToken = context.variableDebtWeth();
        uint16 targetHfBps = context.operationalHfTargetBps();
        uint16 triggerHfBps = context.hfRepairTriggerBps();
        uint16 swapSlippageBps = context.swapSlippageBps();
        uint256 bufferedTarget = uint256(targetHfBps) + 10;
        uint256 premiumBps = IAavePoolDep(aavePool).FLASHLOAN_PREMIUM_TOTAL();
        uint256 costBps = 10000 + uint256(swapSlippageBps) + premiumBps + 5;
        (uint256 collateralBase, uint256 debtBase,, uint256 liveThreshold,, uint256 hf) =
            IAavePoolDep(aavePool).getUserAccountData(address(this));
        if (debtBase == 0 || collateralBase == 0 || liveThreshold == 0 || hf >= uint256(triggerHfBps) * 1e14) {
            return (0, 0);
        }

        uint256 protectedCollateral = uint256(liveThreshold) * collateralBase;
        uint256 required = bufferedTarget * debtBase;
        if (required <= protectedCollateral) return (0, 0);

        uint256 debtBalance = IERC20(debtToken).balanceOf(address(this));
        uint256 directNeeded =
            Math.mulDiv(debtBalance, required - protectedCollateral, bufferedTarget * debtBase, Math.Rounding.Up);
        uint256 roundingBuffer = debtBalance / debtBase + 1;
        directNeeded = debtBalance - directNeeded < roundingBuffer ? debtBalance : directNeeded + roundingBuffer;
        uint256 idle = IERC20(context.weth()).balanceOf(address(this));
        directAmount = idle < directNeeded ? idle : directNeeded;

        uint256 remainingDebtBase = debtBase;
        uint256 remainingDebtBalance = debtBalance;
        if (directAmount > 0) {
            uint256 repaidBase = Math.mulDiv(debtBase, directAmount, debtBalance);
            remainingDebtBase -= repaidBase;
            remainingDebtBalance -= directAmount;
        }
        required = bufferedTarget * remainingDebtBase;
        if (required <= protectedCollateral || remainingDebtBase == 0) return (directAmount, 0);

        uint256 collateralCost = Math.mulDiv(uint256(liveThreshold), costBps, 10000, Math.Rounding.Up);
        if (bufferedTarget <= collateralCost) revert InvalidSwapPlan();
        uint256 repayBase =
            Math.mulDiv(required - protectedCollateral, 1, bufferedTarget - collateralCost, Math.Rounding.Up);
        flashAmount = Math.mulDiv(remainingDebtBalance, repayBase, remainingDebtBase, Math.Rounding.Up);
        if (flashAmount > remainingDebtBalance) flashAmount = remainingDebtBalance;
    }

    function executeDepositSwaps(
        address rangeManager,
        uint256[] calldata amountsIn,
        uint256[] calldata minAmountsOut,
        address tokenIn,
        address tokenOut,
        uint128 price0,
        uint128 price1,
        uint8 dec0,
        uint8 dec1,
        uint256 commissionRate
    ) external returns (uint256 incumbentFeesValueUsd) {
        uint256 n = amountsIn.length;
        for (uint256 i; i < n; i++) {
            IRmDep(rangeManager).executeSwap(tokenIn, tokenOut, amountsIn[i], minAmountsOut[i]);
        }
        if (n > 0) {
            (uint256 fees0, uint256 fees1) = IRmDep(rangeManager).collectFeesForVault();
            incumbentFeesValueUsd =
                ((_toUsd(fees0, price0, dec0) + _toUsd(fees1, price1, dec1)) * (10000 - commissionRate)) / 10000;
        }
    }

    /// @notice Ouvre uniquement le hedge incrémental du dépôt. USD 8 déc.
    /// @param a Adresses (hedge, rm, token0, token1)
    /// @param price0 prix token0 Chainlink (8 déc)
    /// @param price1 prix token1 Chainlink (8 déc)
    /// @param depositAmount0 token0 apporte par le depot courant
    /// @param depositAmount1 token1 apporte par le depot courant
    function openDepositHedge(
        Addrs calldata a,
        uint128 price0,
        uint128 price1,
        uint256 depositAmount0,
        uint256 depositAmount1
    ) external {
        (, uint8 dec0, uint8 dec1,,,,,) = IRmDep(a.rangeManager).config();
        // Les fonds du depot sont deja sur le RM, mais seuls les montants explicites de ce depot
        // participent au calcul et au plafond de collateral.
        (uint256 collateralUsdc, uint256 borrowWeth) = _computeDepositHedge(
            a.hedgeManager, a.rangeManager, a.token0, price0, price1, dec0, dec1, depositAmount0, depositAmount1
        );

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
        (, uint8 dec0, uint8 dec1,,,,,) = rm.config();
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

    /// @dev Calcule (collatéralUsdc, borrowWeth) du hedge incrémental. Partagé par openDepositHedge (exécution)
    ///      et getDepositSwapParams (simulation H-01). Le drift historique n'est jamais réparé aux frais du
    ///      nouveau déposant : adjustHedge/rebalance le traite, et le post-check atomique annule le dépôt si
    ///      la position globale reste hors tolérance.
    /// @dev Le calcul ne peut utiliser que la valeur et le token1 du depot courant. Les soldes libres
    ///      historiques du RM restent dans la NAV existante et ne financent jamais ce nouveau hedge.
    /// @dev AUDIT H-03 : rBps = ratio du NFT EXISTANT au prix courant (addLiquidityToPosition ajoute à CE range),
    ///      pas le range cible dynamique (getOptimalSwapParams, réservé au (re)mint).
    function _computeDepositHedge(
        address hedgeManager,
        address rangeManager,
        address token0,
        uint128 price0,
        uint128 price1,
        uint8 dec0,
        uint8 dec1,
        uint256 depositAmount0,
        uint256 depositAmount1
    ) private view returns (uint256 collateralUsdc, uint256 borrowWeth) {
        IHedgeDep hm = IHedgeDep(hedgeManager);
        IRmDep rm = IRmDep(rangeManager);
        uint256 freeRmWeth = IERC20(token0).balanceOf(rangeManager);
        (uint256 totalBal0,) = rm.getCurrentBalances();
        uint256 nftWeth = totalBal0 > freeRmWeth ? totalBal0 - freeRmWeth : 0;
        uint256 investableUsd =
            _toUsd(depositAmount0, price0, dec0) + Math.mulDiv(depositAmount1, uint256(price1), 10 ** dec1);
        uint16 rBps = _nftRatio0Bps(rangeManager); // H-03 : ratio du NFT existant

        uint256 nftUsd = _toUsd(nftWeth, price0, dec0);
        uint16 hedgeTargetBps = hm.hedgeTargetBps();
        uint16 ltvBps = uint16((uint256(hm.liqThresholdBps()) * 10000) / uint256(hm.operationalHfTargetBps()));
        (uint256 collateralUsd, uint256 borrowUsd) = RangeOperations.computeHedgeDeposit(
            RangeOperations.HedgeDepositParams({
                investableUsd: investableUsd,
                wethLpExistingUsd: nftUsd,
                debtUsd: Math.mulDiv(nftUsd, hedgeTargetBps, 10000),
                idleHmUsd: 0,
                idleRmUsd: 0,
                hedgeTargetBps: hedgeTargetBps,
                rBps: rBps,
                ltvBps: ltvBps
            })
        );
        uint256 depositToken1Usd = Math.mulDiv(depositAmount1, uint256(price1), 10 ** dec1);
        if (collateralUsd > depositToken1Usd) {
            collateralUsd = depositToken1Usd;
            borrowUsd = Math.mulDiv(collateralUsd, ltvBps, 10000);
        }
        if (collateralUsd == 0) return (0, 0);
        collateralUsdc = (collateralUsd * (10 ** dec1)) / uint256(price1);
        borrowWeth = (borrowUsd * (10 ** dec0)) / uint256(price0);
    }

    /// @dev AUDIT H-03 : part token0 (bps) du NFT EXISTANT au prix courant — c'est le ratio que
    ///      addLiquidityToPosition produira (il ajoute au range du NFT, PAS au range cible dynamique).
    ///      Sans NFT, le ratio du premier mint est derive des ticks dynamiques cibles on-chain.
    function _nftRatio0Bps(address rangeManager) private view returns (uint16) {
        IRmDep rm = IRmDep(rangeManager);
        uint256[] memory positions = rm.getOwnerPositions();
        if (positions.length > 0) {
            uint256 r = RangeOperations.nftRatio0BpsForPosition(rm.positionManager(), positions[0], _pc(rm));
            // 0 and 10_000 are valid one-sided Uniswap positions, not calculation failures.
            if (r <= 10000) return uint16(r);
        }
        (int24 tickLower, int24 tickUpper) = rm.calculateTargetTicks();
        RangeOperations.PriceCache memory pc = _pc(rm);
        uint256 ratio = RangeOperations.calculateOptimalRatio(tickLower, tickUpper, pc.poolTick, pc.poolSqrtPriceX96);
        return ratio > 10000 ? 10000 : uint16(ratio);
    }

    function _pc(IRmDep rm) private view returns (RangeOperations.PriceCache memory pc) {
        (uint128 p0, uint128 p1, uint160 sp, int24 tk, uint64 ts, bool v) = rm.priceCache();
        (bool twapEnabled,,,,,) = rm.protectionConfig();
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
        (, uint8 dec0, uint8 dec1,,,,,) = rmI.config();
        address token0 = rmI.token0();
        address hedgeManager = IVaultDep(rmI.vault()).hedgeManager();

        // Collatéral/borrow que openDepositHedge exécutera APRÈS transfert du dépôt (H-02 : on passe le dépôt
        // comme extra0/extra1 → la simulation voit les mêmes soldes que l'exécution réelle). (0,0 en std.)
        uint256 collateralUsdc;
        uint256 borrowWeth;
        if (hedgeManager != address(0)) {
            (collateralUsdc, borrowWeth) = _computeDepositHedge(
                hedgeManager, rangeManager, token0, price0, price1, dec0, dec1, depositAmount0, depositAmount1
            );
        }

        // Incremental state only: this depositor may rebalance its own transferred capital and freshly
        // borrowed token0, never historical idle balances belonging to existing shareholders.
        uint256 freeT0 = depositAmount0 + borrowWeth;
        uint256 freeT1 = depositAmount1 > collateralUsdc ? depositAmount1 - collateralUsdc : 0;

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
            amountIn = Math.mulDiv(excessUsd, 10 ** dec0, uint256(price0));
            return (true, amountIn);
        } else if (targetV0 > v0) {
            // pas assez de token0 → swap token1→token0 (excédent token1 en unités token1)
            uint256 deficitUsd = targetV0 - v0;
            amountIn = Math.mulDiv(deficitUsd, 10 ** dec1, uint256(price1));
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
        (bool expectedZeroForOne, uint256 expectedAmountIn) =
            _depositSwapParams(rangeManager, depositAmount0, depositAmount1);
        (uint256 totalSwapIn, uint16 toleranceBps, bool tokenInIsToken0) =
            _validateDepositSwapChunks(rm, swapAmountsIn, minAmountsOut, tokenIn, tokenOut, maxTotalSwapUsd);
        _requireSwapPlan(expectedAmountIn, expectedZeroForOne, tokenInIsToken0, totalSwapIn, toleranceBps);
    }

    function _validateDepositSwapChunks(
        IRmDep rm,
        uint256[] calldata swapAmountsIn,
        uint256[] calldata minAmountsOut,
        address tokenIn,
        address tokenOut,
        uint256 maxTotalSwapUsd
    ) private view returns (uint256 totalSwapIn, uint16 toleranceBps, bool tokenInIsToken0) {
        address token0 = rm.token0();
        address token1 = rm.token1();
        tokenInIsToken0 = tokenIn == token0;
        uint256 n = swapAmountsIn.length;
        if (n == 0) {
            (,,, toleranceBps,,,,) = rm.config();
            return (0, toleranceBps, tokenInIsToken0);
        }
        if (!((tokenIn == token0 && tokenOut == token1) || (tokenIn == token1 && tokenOut == token0))) {
            revert InvalidSwapPlan();
        }

        (uint128 price0, uint128 price1,,, uint64 ts, bool valid) = rm.priceCache();
        if (!valid || price0 == 0 || price1 == 0) revert InvalidSwapPlan();
        (, uint8 dec0, uint8 dec1, uint16 tol, uint24 slip,,,) = rm.config();
        toleranceBps = tol;
        RangeOperations.PriceCache memory pc = RangeOperations.PriceCache(price0, price1, 0, 0, ts, valid);
        RangeOperations.RangeConfig memory cfg = RangeOperations.RangeConfig(0, dec0, dec1, tol, slip, 0, true, 1);
        RangeOperations.validateMinOutsAgainstOracle(
            tokenInIsToken0, swapAmountsIn, minAmountsOut, pc, cfg, rm.initMultiSwapTvl(), maxTotalSwapUsd
        );
        for (uint256 i; i < n; ++i) {
            totalSwapIn += swapAmountsIn[i];
        }
    }

    function aaveHfSafeSwapBudget(
        uint256 currentBudget,
        uint256 amountInMaximum,
        address aavePool,
        address aToken,
        uint256 fallbackLiqThresholdBps,
        uint256 targetHfBps
    ) external view returns (uint256 cappedAmountInMaximum, uint256 toWithdraw) {
        return _hfSafeSwapBudget(currentBudget, amountInMaximum, aavePool, aToken, fallbackLiqThresholdBps, targetHfBps);
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

    /// @dev Executes an oracle-bounded exact-output swap and reports the output-token delta received by the
    ///      calling HedgeManager. The caller remains responsible for rejecting a partial Uniswap fill.
    function aaveExactOutput(
        address router,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 received) {
        uint256 beforeBalance = IERC20(tokenOut).balanceOf(address(this));
        ISwapRouter(router).exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: amountInMaximum,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );
        received = IERC20(tokenOut).balanceOf(address(this)) - beforeBalance;
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
            uint256 collateralAmount =
                fullWithdraw ? type(uint256).max : (IERC20(aToken).balanceOf(address(this)) * proportionX18) / 1e18;
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

    /// @notice Reads the annualized Aave variable borrow rate (RAY) used by the strategy engine.
    function strategyAaveBorrowRateRay(address hedgeManager) external view returns (bool available, uint256 rateRay) {
        (bool poolOk, bytes memory poolData) = hedgeManager.staticcall(abi.encodeWithSignature("pool()"));
        (bool assetOk, bytes memory assetData) = hedgeManager.staticcall(abi.encodeWithSignature("weth()"));
        if (!poolOk || !assetOk || poolData.length < 32 || assetData.length < 32) return (false, 0);
        address aavePool = abi.decode(poolData, (address));
        address asset = abi.decode(assetData, (address));
        (bool reserveOk, bytes memory reserveData) =
            aavePool.staticcall(abi.encodeWithSignature("getReserveData(address)", asset));
        if (!reserveOk || reserveData.length < 5 * 32) return (false, 0);
        assembly ("memory-safe") {
            rateRay := mload(add(reserveData, 0xa0))
        }
        available = rateRay > 0 && rateRay <= 10e27;
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
    ///      Le drift max effectif = min(maxDriftBps configure, seuil critique gouverne du HedgeManager).
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
        uint16 effectiveMaxDriftBps = _postCheckMaxDriftBps(hedgeManager, maxDriftBps);
        (bool ok,,) = _driftBps(hedgeManager, rangeManager, token0, price0, dec0, effectiveMaxDriftBps, dustFloorUsd);
        if (!ok) revert PreAdjustRequired();

        if (_toUsd(hm.getWethDebt(), price0, dec0) > 0) {
            (,, uint256 hf,) = hm.getHedgeData();
            uint256 hfMin = (uint256(hm.reserveHfTargetBps()) * 1e18) / 10000;
            if (hf < hfMin) revert PreAdjustRequired();
        }
    }

    /// @dev Le post-check garde le parametre .env comme plafond, puis applique le seuil critique gouverne.
    function _postCheckMaxDriftBps(address hedgeManager, uint16 configuredMaxBps) private view returns (uint16) {
        uint16 effectiveMaxBps = configuredMaxBps;
        uint16 criticalBps = IHedgeDep(hedgeManager).criticalHedgeBps();
        if (criticalBps < effectiveMaxBps) effectiveMaxBps = criticalBps;
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
    ) private view returns (bool ok, uint256 driftBps, bool rawDebtDriftExceeds_) {
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
        (ok, driftBps) = RangeOperations.checkHedgeDelta(
            debtUsd, idleHmUsd, idleRmUsd, wethInLpUsd, hm.hedgeTargetBps(), maxDriftBps, dustFloorUsd
        );
        (bool rawOk,) =
            RangeOperations.checkHedgeDelta(debtUsd, 0, 0, wethInLpUsd, hm.hedgeTargetBps(), maxDriftBps, dustFloorUsd);
        rawDebtDriftExceeds_ = !rawOk;
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
        if (!(valid && price0 > 0 && price1 > 0)) revert BadOracle();
        uint256 oraclePrice = Math.mulDiv(uint256(price0), 1e18, uint256(price1));

        uint256 diff = poolPrice > oraclePrice ? poolPrice - oraclePrice : oraclePrice - poolPrice;
        if ((diff * 10000) / oraclePrice > maxHedgeDeviationBps) revert LpPriceDeviation();

        (bool twapEnabled,,, uint16 twapBps,,) = IRmDep(rangeManager).protectionConfig();
        if (twapEnabled) {
            int24 twapTick = RangeOperations.trustedTwapTick(lpPool);
            int24 tickDiff = currentTick > twapTick ? currentTick - twapTick : twapTick - currentTick;
            if (uint24(tickDiff) > uint24(twapBps)) revert LpTwapDeviation();
        }
    }

    /// @notice Plafond token1 pour acheter `amount0Out` token0 via exactOutput, base sur price0/price1.
    /// @dev priceCache doit avoir ete rafraichi fail-closed par le caller juste avant.
    function aaveOracleMaxToken1ForToken0(
        uint256 amount0Out,
        address rangeManager,
        uint8 dec0,
        uint8 dec1,
        uint16 slippageBps,
        bool zeroForOne
    ) external view returns (uint256 amountInMaximum, uint160 sqrtPriceLimitX96) {
        return _oracleMaxToken1ForToken0(amount0Out, rangeManager, dec0, dec1, slippageBps, zeroForOne);
    }

    /// @notice Plancher token1 recu pour vendre `amount0In` token0 via exactInput.
    /// @dev Utilise par le reajustement sous-hedge: le token0 nouvellement emprunte est vendu dans
    ///      la meme transaction puis le token1 recu est fourni comme collateral. Le cache RM doit
    ///      avoir ete rafraichi par le caller juste avant.
    function aaveOracleMinToken1ForToken0(
        uint256 amount0In,
        address rangeManager,
        uint8 dec0,
        uint8 dec1,
        uint16 slippageBps,
        bool zeroForOne
    ) external view returns (uint256 amountOutMinimum, uint160 sqrtPriceLimitX96) {
        (uint128 price0, uint128 price1, uint160 sqrtP,,, bool valid) = IRmDep(rangeManager).priceCache();
        if (!(valid && price0 > 0 && price1 > 0 && sqrtP > 0)) revert BadOracle();
        uint256 theoretical = Math.mulDiv(amount0In, uint256(price0) * (10 ** dec1), uint256(price1) * (10 ** dec0));
        amountOutMinimum = Math.mulDiv(theoretical, 10000 - uint256(slippageBps), 10000);
        if (amountOutMinimum == 0) revert BadOracle();
        sqrtPriceLimitX96 = _clampSqrtPriceLimitX96(
            (uint256(sqrtP) * (zeroForOne ? 20000 - uint256(slippageBps) : 20000 + uint256(slippageBps))) / 20000
        );
    }

    function _oracleMaxToken1ForToken0(
        uint256 amount0Out,
        address rangeManager,
        uint8 dec0,
        uint8 dec1,
        uint16 slippageBps,
        bool zeroForOne
    ) private view returns (uint256 amountInMaximum, uint160 sqrtPriceLimitX96) {
        (uint128 price0, uint128 price1, uint160 sqrtP,, uint64 timestamp, bool valid) =
            IRmDep(rangeManager).priceCache();
        // This exact-output repayment path may bypass only the spot/TWAP validity bit produced by a refresh
        // in THIS transaction. Invalid/stale feeds return zero values and cannot pass; the Chainlink max-in
        // and full-fill post-check still bound every settlement and HF repair.
        if (!((valid || timestamp == uint64(block.timestamp)) && price0 > 0 && price1 > 0 && sqrtP > 0)) {
            revert BadOracle();
        }
        uint256 theoretical =
            Math.mulDiv(amount0Out, uint256(price0) * (10 ** dec1), uint256(price1) * (10 ** dec0), Math.Rounding.Up);
        amountInMaximum = Math.mulDiv(theoretical, 10000 + uint256(slippageBps), 10000, Math.Rounding.Up);
        if (amountInMaximum == 0) revert BadOracle();
        sqrtPriceLimitX96 = _clampSqrtPriceLimitX96(
            (uint256(sqrtP) * (zeroForOne ? 20000 - uint256(slippageBps) : 20000 + uint256(slippageBps))) / 20000
        );
    }

    function _clampSqrtPriceLimitX96(uint256 limit) private pure returns (uint160) {
        if (limit < MIN_SQRT_PRICE_LIMIT_X96) return MIN_SQRT_PRICE_LIMIT_X96;
        if (limit > MAX_SQRT_PRICE_LIMIT_X96) return MAX_SQRT_PRICE_LIMIT_X96;
        return uint160(limit);
    }

    /// @notice Returns the only strategy fields consumed by AaveHedgeManager and validates HEDGE_ONLY in-engine.
    /// @dev Large fixed-width structs are decoded selectively to keep AaveHedgeManager below EIP-170.
    function hedgeStrategyDecision(address rangeManager, address hedgeManager, address caller)
        external
        view
        returns (uint8 action, bytes32 decisionHash, uint64 checkpointTimestamp, bool protocolBotCaller)
    {
        IRangeStrategyEngine engine = IRmDep(rangeManager).strategyEngine();
        if (address(engine) == address(0) || engine.hedgeManager() != hedgeManager) revert InvalidStrategyDecision();
        (action, decisionHash) = _readDecision(address(engine), bytes32(0), false);
        if (action == uint8(IRangeStrategyEngine.Action.HEDGE_ONLY)) {
            (uint8 validatedAction, bytes32 validatedHash) = _readDecision(address(engine), decisionHash, true);
            if (validatedAction != action || validatedHash != decisionHash) revert InvalidStrategyDecision();
        }
        checkpointTimestamp = _readCheckpointTimestamp(address(engine));
        protocolBotCaller = _isProtocolBotCaller(rangeManager, caller);
    }

    function rawDebtDriftExceeds(uint256 debt, uint256 target, uint16 thresholdBps, uint256 dustFloor)
        external
        pure
        returns (bool)
    {
        uint256 diff = debt > target ? debt - target : target - debt;
        if (target == 0) return diff > dustFloor;
        return (diff * 10000) / target >= uint256(thresholdBps);
    }

    function strategyCanonicalTwaps(
        address pool,
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
        (int56[] memory cumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
        strategicTick = _meanStrategyTick(cumulatives[2] - cumulatives[0], strategicHorizonSeconds);
        tacticalTick = _meanStrategyTick(cumulatives[2] - cumulatives[1], tacticalHorizonSeconds);
    }

    function _readDecision(address engine, bytes32 expectedHash, bool validate)
        private
        view
        returns (uint8 action, bytes32 decisionHash)
    {
        bytes memory payload = validate
            ? abi.encodeWithSelector(IRangeStrategyEngine.validateDecision.selector, expectedHash)
            : abi.encodeWithSelector(IRangeStrategyEngine.previewDecision.selector);
        (bool ok, bytes memory result) = engine.staticcall(payload);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        if (result.length < 18 * 32) revert InvalidStrategyDecision();
        uint256 rawAction;
        assembly ("memory-safe") {
            rawAction := mload(add(result, 0x60))
            decisionHash := mload(add(result, 0x240))
        }
        if (rawAction > uint256(IRangeStrategyEngine.Action.HF_REPAIR)) revert InvalidStrategyDecision();
        action = uint8(rawAction);
    }

    function _readCheckpointTimestamp(address engine) private view returns (uint64 timestamp) {
        (bool ok, bytes memory result) =
            engine.staticcall(abi.encodeWithSelector(IRangeStrategyEngine.currentTelemetry.selector));
        if (!ok || result.length < 64) revert InvalidStrategyDecision();
        uint256 rawTimestamp;
        assembly ("memory-safe") {
            rawTimestamp := mload(add(result, 0x40))
        }
        if (rawTimestamp > type(uint64).max) revert InvalidStrategyDecision();
        timestamp = uint64(rawTimestamp);
    }

    function _isProtocolBotCaller(address rangeManager, address caller) private view returns (bool) {
        return IRmDep(rangeManager).isProtocolBotCaller(caller);
    }

    function _meanStrategyTick(int56 delta, uint32 seconds_) private pure returns (int24 tick) {
        tick = int24(delta / int56(uint56(seconds_)));
        if (delta < 0 && delta % int56(uint56(seconds_)) != 0) tick--;
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
        if (sqrtRatioAX96 == 0) revert SqrtRatioAIsZero();
        uint256 numerator = uint256(liquidity) << 96;
        return (numerator / uint256(sqrtRatioAX96)) - (numerator / uint256(sqrtRatioBX96));
    }
}
