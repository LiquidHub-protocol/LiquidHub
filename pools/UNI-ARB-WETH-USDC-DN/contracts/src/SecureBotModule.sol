// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;
import "./ProtocolAccountingLib.sol";
import "./AutonomousErrors.sol";
import "./AutonomousPoolLib.sol";
import "./ProtocolSafetyLib.sol";

import "./RangeOperations.sol";
import "./interfaces/IRangeStrategyEngine.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";

interface ISafe {
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool success);
}

interface IERC20Sweep {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IRangeManagerPostCheck {
    function addLiquidityToPosition() external;
    function protocolBotAddress() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function priceCache() external view returns (uint128, uint128, uint160, int24, uint64, bool);
    function config() external view returns (RangeOperations.RangeConfig memory);
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

interface IProgressiveRangeManager {
    function progressiveRebalance(
        uint8 step,
        bytes32 expectedDecisionHash,
        int24 tickLower,
        int24 tickUpper,
        uint256 amountIn,
        uint256 minAmountOut,
        address keeper
    ) external returns (int24 lower, int24 upper);

    function mintInitialPosition() external returns (uint256 tokenId, uint128 liquidity);
}

interface IProgressiveVault {
    function syncFeesForDeposits() external;
    function endRebalance() external;
    function isRebalancing() external view returns (bool);
}

interface IProgressiveStrategy {
    function checkpointDue() external view returns (bool);
    function checkpointMarketState() external;
}

interface IProgressiveHedgeGuard {
    function hfRepairTriggerBps() external view returns (uint16);
    function getHedgeData()
        external
        view
        returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 healthFactor, uint256 availableBorrowsBase);
}

contract SecureBotModule {
    function getOracleLpValueUsd() external view returns (uint256 valueUsd) {
        return ProtocolAccountingLib.getOracleLpValueUsd(rangeManager);
    }

    function isWithdrawValueSufficient(uint256 amount0, uint256 amount1, uint256 minValueUsd)
        external
        view
        returns (bool)
    {
        return ProtocolAccountingLib.isWithdrawValueSufficient(rangeManager, amount0, amount1, minValueUsd);
    }
    error InvalidCallData();
    error InvalidPrice();
    error InvalidProgressiveChunk();
    error InvalidProgressiveRecovery();
    error InvalidTarget();
    error ModulePaused();
    error ProgressiveActive();
    error ProgressiveDecisionMismatch();
    error ProgressiveEpochNotAdvanced();
    error ProgressiveInactive();
    error ProgressivePlanExpired();
    error ProgressivePlanStale();
    error ProgressivePositionExists();
    error UnauthorizedOwner();
    error VaultNotRebalancing();

    error CompoundHedgeChanged();

    address public immutable safe;
    address public immutable botAddress;
    address public immutable rangeManager;
    address public immutable strategyEngine;
    address public immutable vault;
    address public immutable pauseController;
    address public immutable hedgeManager;
    address public immutable treasury;
    address public immutable owner;

    function pendingOwner() external pure returns (address) {
        return address(0);
    }

    // Sécurité renforcée
    mapping(bytes4 => bool) private _allowedFunctions;
    uint256 public dailyLimit;
    uint256 public dailySpent;
    uint256 public lastResetDay;
    ProtocolSafetyLib.PauseState private _pauseState;
    bool public constant directExecution = true;
    uint8 public progressiveRebalanceStatus;
    int24 public progressiveTickLower;
    int24 public progressiveTickUpper;
    bytes32 public progressiveDecisionHash;
    uint64 public progressivePlanEpoch;
    uint64 private progressivePlanValidUntil;
    // All retargets share this remaining turnover cap; only Safe recovery can renew it.
    uint256 public progressiveCycleBudgetUsdE8;
    uint256 public progressiveSwapBudgetUsdE8;
    uint256 public progressiveReverseBudgetUsdE8;
    bool public progressiveInitialZeroForOne;

    // endRebalance() est exempte de la limite quotidienne: ce deverrouillage ne deplace aucun fonds.
    // Mints, depots, rebalances et ajustements hedge utilisent leurs entrees atomiques; l'ancien automate
    // module start/burn/swap/mint et les appels solveur AAVE ne sont plus exposes.
    bytes4 private constant END_REBALANCE_SELECTOR = 0x0040718e; // endRebalance()
    bytes4 private constant REFRESH_PRICE_SELECTOR = 0x0be1c372; // refreshPriceCache()
    bytes4 private constant CHECKPOINT_SELECTOR = bytes4(keccak256("checkpointMarketState()"));
    bytes4 private constant REBALANCE_SELECTOR =
        bytes4(keccak256("rebalance(bytes32,uint256[],uint256[],address,address)"));
    bytes4 private constant ADJUST_HEDGE_SELECTOR = bytes4(keccak256("adjustHedge()"));
    bytes4 private constant REPAIR_HF_SELECTOR = bytes4(keccak256("repairHealthFactor()"));

    // Events
    event FunctionExecuted(bytes4 indexed selector, uint256 dailyCount);
    event FunctionAllowed(bytes4 indexed selector, bool allowed);
    event DailyLimitUpdated(uint256 newLimit);
    event Paused(bool paused);
    event DirectExecutionUpdated(bool enabled);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event ModuleSweep(address indexed token, uint256 amount);
    event ProgressiveRebalanceStarted(bytes32 indexed decisionHash, int24 tickLower, int24 tickUpper, address keeper);
    event ProgressiveRebalanceRefreshed(bytes32 indexed decisionHash, int24 tickLower, int24 tickUpper, address keeper);
    event ProgressiveRebalanceChunk(uint256 amountIn, uint256 amountOut, address keeper);
    event ProgressiveRebalanceFinalized(bytes32 indexed decisionHash, address keeper);
    event ProgressiveRebalanceCancelled(bytes32 indexed decisionHash, address safe);

    constructor(
        address _safe,
        address _botAddress,
        address _rangeManager,
        address _strategyEngine,
        address _vault,
        address _pauseController,
        address _hedgeManager,
        address _treasury,
        uint256 _dailyLimit
    ) {
        require(
            _safe != address(0) && _botAddress != address(0) && _rangeManager != address(0)
                && _strategyEngine != address(0) && _strategyEngine.code.length > 0 && _vault != address(0)
                && _pauseController != address(0) && _hedgeManager != address(0) && _treasury != address(0),
            AutonomousCheck(0xa8e86b08)
        );
        require(_dailyLimit > 0 && _dailyLimit <= 1000, AutonomousCheck(0x30786559));
        safe = _safe;
        botAddress = _botAddress;
        rangeManager = _rangeManager;
        strategyEngine = _strategyEngine;
        vault = _vault;
        pauseController = _pauseController;
        hedgeManager = _hedgeManager;
        treasury = _treasury;
        owner = _safe; // La Safe est owner
        dailyLimit = _dailyLimit;

        // Autoriser uniquement les fonctions recurrentes du bot. En DN, le mint initial et les depots passent
        // par processDepositPermissionless(), qui ouvre/ajuste le hedge AAVE et applique le post-check dans le
        // meme chemin. L'ancien chemin multi-tx burn/swap/mint/add n'est donc pas whitelisté par défaut.
        // Fonctions RangeManager
        // configurePriceFeeds (0x6509c2dd) RETIRÉ (audit V1) : repointage oracles = gouvernance

        // Le bot rafraîchit le cache via refreshPriceCache() (ne change aucune adresse).
        _allowedFunctions[0x0be1c372] = true; // refreshPriceCache()
        _allowedFunctions[CHECKPOINT_SELECTOR] = true;
        _allowedFunctions[REBALANCE_SELECTOR] = true;

        // Fonctions MultiUserVault
        // processPendingDeposits (0x99dd7ead) RETIRÉ (audit V1) : fonction batch supprimée du Vault.
        // processSingleDeposit (0xac1df9bd) RETIRÉ en DN : le mint initial passe désormais par le bot
        // via processDepositPermissionless() pour créer le hedge AAVE atomiquement puis post-check.
        // AUDIT H-02 : le relais bot des dépôts de CROISSANCE passe par le chemin ATOMIQUE
        // processDepositPermissionless (hedge on-chain via DnDepositLib + post-check). Sélecteur à whitelister
        // sinon le fallback bot revert avant d'atteindre le Vault. Le Vault re-valide tout (paused, plafond, oracle).
        _allowedFunctions[0x76919a59] = true; // processDepositPermissionless(uint256[],uint256[],address,address)
        _allowedFunctions[0x0040718e] = true; // endRebalance()
        // withdrawReservedCollateral() RETIRÉ (audit) : fonction supprimée du Vault (réserve gérée off-chain)
        // AUDIT M-02 : decreaseLiquidityPartial(uint128) (0x41f60e3c) RETIRÉ de la whitelist — entrée publique DN
        // supprimée (trimming LP indépendant abandonné en DN strict). Plus aucune surface pour une clé bot compromise.
        // EmergencyBurnPositions et EmergencyRecoverUser ne sont PAS whitelistees ici : elles restent
        // exclusivement appelees sur le Vault par l'Emergency Safe.

        // Fonctions AaveHedgeManager (Delta Neutral AAVE V3)
        // supplyAndBorrow(uint256,uint256) reste exposée sur le HedgeManager pour le Vault,
        // mais n'est pas une action bot/keeper récurrente : DnDepositLib l'appelle depuis le Vault pendant les
        // dépôts DN atomiques. Elle n'est donc PAS whitelistée dans le module bot.
        // AUDIT H-02 : adjustHedge() permissionless, whitelisté pour le bot sans privilège d'exécution.
        // Les règles on-chain sont identiques pour tous : confirmation et cooldown sur le drift ordinaire,
        // contournement uniquement pour le drift critique ou la réparation HF urgente.
        _allowedFunctions[ADJUST_HEDGE_SELECTOR] = true;
        _allowedFunctions[REPAIR_HF_SELECTOR] = true;
        // Les appels de solveur hedge (borrow/repay/withdraw/sweeps) ne sont plus des actions bot recurrentes.
        // Ils restent appelables par le Vault/Safe quand le code du Vault en a besoin, pas via ce module.
        // closeAll (0xf6b32008) RETIRÉE (audit V1) : fonction d'URGENCE rare qui envoie TOUT
        // le hedge à un recipient → réservée à la Safe directe (jamais via le bot).

        _allowedFunctions[bytes4(keccak256("convertSourceFeeChunk(address,address,uint256)"))] = true;
        _allowedFunctions[bytes4(keccak256("convertSourceFeesToUSDC(address,address)"))] = true;
        _allowedFunctions[bytes4(keccak256("convertFeesToUSDC(address)"))] = true;
        _allowedFunctions[bytes4(keccak256("wrapNativeFees()"))] = true;
        _allowedFunctions[bytes4(keccak256("bridgeRevenue(uint256)"))] = true; // bridgeRevenue(uint256)
        _allowedFunctions[bytes4(keccak256("forwardRevenue(uint256)"))] = true; // forwardRevenue(uint256) - bridge treasury same-chain
    }

    receive() external payable {}

    event LiquidityCompounded(uint256 indexed tokenId, uint256 amount0, uint256 amount1, address indexed keeper);

    /// @notice Collect and reinvest the matched balances on the existing NFT without changing Aave exposure.
    /// @dev Unmatched balances remain available to the next canonical maintenance/deposit; no independent hedge.
    function compound() external returns (uint256 investedUsdE8) {
        AutonomousPoolLib.requireOperating(pauseController);
        _requireCurrentModule();
        if (progressiveRebalanceStatus != 0 || IProgressiveVault(vault).isRebalancing()) return 0;
        progressiveRebalanceStatus = 3;
        investedUsdE8 = _compoundPosition();
        progressiveRebalanceStatus = 0;
    }

    function _compoundPosition() private returns (uint256) {
        IRangeManagerPostCheck rm = IRangeManagerPostCheck(rangeManager);
        uint256[] memory positions = rm.getOwnerPositions();
        if (positions.length != 1) return 0;
        rm.refreshPriceCache();
        RangeOperations.PriceCache memory cache = _progressiveCache();
        (,,,,, int24 lower, int24 upper,,,,,) = rm.positionManager().positions(positions[0]);
        if (cache.poolTick <= lower || cache.poolTick >= upper) return 0;
        IProgressiveVault(vault).syncFeesForDeposits();
        address t0 = rm.token0();
        address t1 = rm.token1();
        uint256 b0 = IERC20Sweep(t0).balanceOf(rangeManager);
        uint256 b1 = IERC20Sweep(t1).balanceOf(rangeManager);
        RangeOperations.RangeConfig memory cfg = rm.config();
        if (
            Math.mulDiv(b0, cache.price0, 10 ** cfg.token0Decimals) == 0
                || Math.mulDiv(b1, cache.price1, 10 ** cfg.token1Decimals) == 0
        ) return 0;
        (uint256 wethBefore,) = rm.getCurrentBalances();
        (, uint256 debtBefore,,) = IProgressiveHedgeGuard(hedgeManager).getHedgeData();
        rm.addLiquidityToPosition();
        (uint256 wethAfter,) = rm.getCurrentBalances();
        (, uint256 debtAfter,,) = IProgressiveHedgeGuard(hedgeManager).getHedgeData();
        // V3 amount reconstruction rounds down; transferring the same token into LP can differ by at most 2 wei.
        if ((wethBefore > wethAfter ? wethBefore - wethAfter : wethAfter - wethBefore) > 2 || debtBefore != debtAfter) {
            revert CompoundHedgeChanged();
        }
        uint256 added0 = b0 - IERC20Sweep(t0).balanceOf(rangeManager);
        uint256 added1 = b1 - IERC20Sweep(t1).balanceOf(rangeManager);
        emit LiquidityCompounded(positions[0], added0, added1, msg.sender);
        return Math.mulDiv(added0, cache.price0, 10 ** cfg.token0Decimals)
            + Math.mulDiv(added1, cache.price1, 10 ** cfg.token1Decimals);
    }

    /// @notice Permissionless high-TVL path, independent from the hot-bot pause and fully bounded on-chain.
    function beginProgressiveRebalance(bytes32 expectedDecisionHash) external {
        AutonomousPoolLib.requireOperating(pauseController);
        _requireCurrentModule();
        if (progressiveRebalanceStatus != 0) revert ProgressiveActive();
        IRangeManagerPostCheck(rangeManager).refreshPriceCache();
        _requireProgressiveHfSafe();
        progressiveRebalanceStatus = 1;
        IProgressiveVault(vault).syncFeesForDeposits();
        IRangeStrategyEngine.Decision memory decision = IRangeStrategyEngine(strategyEngine).previewDecision();
        if (decision.decisionHash != expectedDecisionHash) {
            revert ProgressiveDecisionMismatch();
        }
        (progressiveSwapBudgetUsdE8, progressiveReverseBudgetUsdE8, progressiveInitialZeroForOne) =
            _requireProgressivePlan();
        (int24 lower, int24 upper) =
            IProgressiveRangeManager(rangeManager).progressiveRebalance(0, expectedDecisionHash, 0, 0, 0, 0, msg.sender);
        progressivePlanEpoch = decision.epoch;
        progressivePlanValidUntil = decision.validUntil;
        progressiveCycleBudgetUsdE8 = _progressiveAssetsUsd();
        progressiveTickLower = lower;
        progressiveTickUpper = upper;
        progressiveDecisionHash = expectedDecisionHash;
        progressiveRebalanceStatus = 2;
        emit ProgressiveRebalanceStarted(expectedDecisionHash, lower, upper, msg.sender);
    }

    function _requireProgressivePlan()
        private
        view
        returns (uint256 budgetUsdE8, uint256 reverseBudgetUsdE8, bool zeroForOne)
    {
        IRangeManagerPostCheck rm = IRangeManagerPostCheck(rangeManager);
        RangeOperations.OptimalSwapParams memory plan = rm.getOptimalSwapParams();
        (budgetUsdE8, reverseBudgetUsdE8, zeroForOne) = _progressivePlanBudget(plan);
        require(
            plan.swapNeeded && budgetUsdE8 - reverseBudgetUsdE8 > rm.initMultiSwapTvl() * 1e8,
            AutonomousCheck(0xa2c7ce0c)
        );
    }

    function _progressiveCache() private view returns (RangeOperations.PriceCache memory cache) {
        IRangeManagerPostCheck rm = IRangeManagerPostCheck(rangeManager);
        (uint128 p0, uint128 p1, uint160 sqrtP, int24 tick, uint64 timestamp, bool valid) = rm.priceCache();
        cache = RangeOperations.PriceCache(p0, p1, sqrtP, tick, timestamp, valid);
        if (!cache.valid || cache.price0 == 0 || cache.price1 == 0) revert InvalidPrice();
    }

    function _progressivePlanBudget(RangeOperations.OptimalSwapParams memory plan)
        private
        view
        returns (uint256 budgetUsdE8, uint256 reverseBudgetUsdE8, bool zeroForOne)
    {
        RangeOperations.PriceCache memory cache = _progressiveCache();
        RangeOperations.RangeConfig memory cfg = IRangeManagerPostCheck(rangeManager).config();
        uint256 amountUsd = Math.mulDiv(
            plan.amountIn,
            plan.zeroForOne ? cache.price0 : cache.price1,
            10 ** (plan.zeroForOne ? cfg.token0Decimals : cfg.token1Decimals)
        );
        uint256 marginBps = uint256(cfg.maxSlippageBps) + uint256(cfg.toleranceBps);
        reverseBudgetUsdE8 = Math.mulDiv(amountUsd, marginBps, 10000, Math.Rounding.Up);
        if (reverseBudgetUsdE8 == 0) reverseBudgetUsdE8 = 1;
        return (amountUsd + reverseBudgetUsdE8, reverseBudgetUsdE8, plan.zeroForOne);
    }

    function _progressiveAssetsUsd() private view returns (uint256) {
        IRangeManagerPostCheck rm = IRangeManagerPostCheck(rangeManager);
        RangeOperations.PriceCache memory cache = _progressiveCache();
        RangeOperations.RangeConfig memory cfg = rm.config();
        (uint256 balance0, uint256 balance1) = rm.getCurrentBalances();
        return Math.mulDiv(balance0, cache.price0, 10 ** cfg.token0Decimals)
            + Math.mulDiv(balance1, cache.price1, 10 ** cfg.token1Decimals);
    }

    /// @notice Retarget an interrupted cycle to the engine's fresh canonical initial-mint range.
    /// @dev A later epoch may renew the plan budget, never the total cycle turnover cap. A newly
    ///      governed module may recover an already locked Vault whose old NFT has been burned.
    function refreshProgressiveRebalance(bytes32 expectedDecisionHash) external {
        AutonomousPoolLib.requireOperating(pauseController);
        _refreshProgressiveRebalance(expectedDecisionHash, false);
    }

    function _refreshProgressiveRebalance(bytes32 expectedDecisionHash, bool safeRecovery) private {
        _requireCurrentModule();
        if (progressiveRebalanceStatus != 0 && progressiveRebalanceStatus != 2) revert ProgressiveActive();
        if (!IProgressiveVault(vault).isRebalancing()) revert VaultNotRebalancing();
        IRangeManagerPostCheck(rangeManager).refreshPriceCache();
        _requireProgressiveHfSafe();
        bool newCycle = progressiveRebalanceStatus == 0;
        progressiveRebalanceStatus = 3;
        IRangeManagerPostCheck rm = IRangeManagerPostCheck(rangeManager);
        if (rm.getOwnerPositions().length != 0) revert ProgressivePositionExists();
        IRangeStrategyEngine.Decision memory decision =
            IRangeStrategyEngine(strategyEngine).validateDecision(expectedDecisionHash);
        if (decision.reason != IRangeStrategyEngine.ReasonCode.INITIAL_MINT_REQUIRED) {
            revert InvalidProgressiveRecovery();
        }
        if (!(newCycle || safeRecovery || decision.decisionHash != progressiveDecisionHash)) {
            revert ProgressiveEpochNotAdvanced();
        }
        RangeOperations.PriceCache memory cache = _progressiveCache();
        if (cache.poolTick <= decision.targetTickLower || cache.poolTick >= decision.targetTickUpper) {
            revert InvalidProgressiveRecovery();
        }
        progressiveTickLower = decision.targetTickLower;
        progressiveTickUpper = decision.targetTickUpper;
        progressiveDecisionHash = expectedDecisionHash;
        progressivePlanEpoch = decision.epoch;
        progressivePlanValidUntil = decision.validUntil;
        (progressiveSwapBudgetUsdE8, progressiveReverseBudgetUsdE8, progressiveInitialZeroForOne) =
            _progressivePlanBudget(_progressiveSwapParams());
        if (newCycle || safeRecovery) progressiveCycleBudgetUsdE8 = _progressiveAssetsUsd();
        progressiveRebalanceStatus = 2;
        emit ProgressiveRebalanceRefreshed(expectedDecisionHash, progressiveTickLower, progressiveTickUpper, msg.sender);
    }

    function continueProgressiveRebalance(uint256 amountIn, uint256 minAmountOut) external {
        AutonomousPoolLib.requireOperating(pauseController);
        _requireCurrentModule();
        if (progressiveRebalanceStatus != 2 || !IProgressiveVault(vault).isRebalancing()) {
            revert ProgressiveInactive();
        }
        IRangeManagerPostCheck(rangeManager).refreshPriceCache();
        _requireProgressiveHfSafe();
        _requireCurrentProgressivePlan();
        progressiveRebalanceStatus = 3;
        RangeOperations.OptimalSwapParams memory plan = _progressiveSwapParams();
        if (!plan.swapNeeded || amountIn == 0 || amountIn > plan.amountIn) revert InvalidProgressiveChunk();
        _consumeProgressiveSwapBudget(plan.zeroForOne, amountIn);
        IRangeManagerPostCheck rm = IRangeManagerPostCheck(rangeManager);
        address tokenIn = plan.zeroForOne ? rm.token0() : rm.token1();
        address tokenOut = plan.zeroForOne ? rm.token1() : rm.token0();
        uint256 amountOut = rm.executeSwap(tokenIn, tokenOut, amountIn, minAmountOut);
        progressiveRebalanceStatus = 2;
        emit ProgressiveRebalanceChunk(amountIn, amountOut, msg.sender);
    }

    function getProgressiveSwapParams() external view returns (RangeOperations.OptimalSwapParams memory) {
        if (progressiveRebalanceStatus != 2) revert ProgressiveInactive();
        return _progressiveSwapParams();
    }

    function _progressiveSwapParams() private view returns (RangeOperations.OptimalSwapParams memory) {
        IRangeManagerPostCheck rm = IRangeManagerPostCheck(rangeManager);
        (uint128 p0, uint128 p1, uint160 sqrtP, int24 tick, uint64 timestamp, bool valid) = rm.priceCache();
        if (!valid) revert InvalidPrice();
        (uint256 balance0, uint256 balance1) = rm.getCurrentBalances();
        return RangeOperations.calculateOptimalSwapParams(
            balance0,
            balance1,
            RangeOperations.PriceCache(p0, p1, sqrtP, tick, timestamp, valid),
            rm.config(),
            progressiveTickLower,
            progressiveTickUpper
        );
    }

    function finalizeProgressiveRebalance(uint256 amountIn, uint256 minAmountOut) external {
        AutonomousPoolLib.requireOperating(pauseController);
        _requireCurrentModule();
        if (progressiveRebalanceStatus != 2 || !IProgressiveVault(vault).isRebalancing()) {
            revert ProgressiveInactive();
        }
        IRangeManagerPostCheck(rangeManager).refreshPriceCache();
        _requireProgressiveHfSafe();
        _requireCurrentProgressivePlan();
        progressiveRebalanceStatus = 3;
        if (amountIn > 0) {
            RangeOperations.OptimalSwapParams memory plan = _progressiveSwapParams();
            if (!plan.swapNeeded || amountIn > plan.amountIn) revert InvalidProgressiveChunk();
            _consumeProgressiveSwapBudget(plan.zeroForOne, amountIn);
        }
        bytes32 decisionHash = progressiveDecisionHash;
        IProgressiveRangeManager(rangeManager)
            .progressiveRebalance(
                2, bytes32(0), progressiveTickLower, progressiveTickUpper, amountIn, minAmountOut, msg.sender
            );
        _clearProgressiveRebalance();
        emit ProgressiveRebalanceFinalized(decisionHash, msg.sender);
    }

    function _clearProgressiveRebalance() private {
        delete progressivePlanEpoch;
        delete progressivePlanValidUntil;
        delete progressiveCycleBudgetUsdE8;
        delete progressiveTickLower;
        delete progressiveTickUpper;
        delete progressiveDecisionHash;
        delete progressiveSwapBudgetUsdE8;
        delete progressiveReverseBudgetUsdE8;
        delete progressiveInitialZeroForOne;
        progressiveRebalanceStatus = 0;
    }

    function _requireCurrentProgressivePlan() private view {
        if (block.timestamp > progressivePlanValidUntil) revert ProgressivePlanExpired();
        IRangeStrategyEngine.Decision memory decision = IRangeStrategyEngine(strategyEngine).previewDecision();
        if (decision.decisionHash != progressiveDecisionHash) {
            revert ProgressivePlanStale();
        }
    }

    function _consumeProgressiveSwapBudget(bool zeroForOne, uint256 amountIn) private {
        IRangeManagerPostCheck rm = IRangeManagerPostCheck(rangeManager);
        (uint128 price0, uint128 price1,,,, bool valid) = rm.priceCache();
        if (!valid) revert InvalidPrice();
        RangeOperations.RangeConfig memory cfg = rm.config();
        uint256 amountUsdE8 = Math.mulDiv(
            amountIn, zeroForOne ? price0 : price1, 10 ** (zeroForOne ? cfg.token0Decimals : cfg.token1Decimals)
        );
        require(amountUsdE8 > 0 && amountUsdE8 <= progressiveSwapBudgetUsdE8, AutonomousCheck(0xbfc64720));
        require(amountUsdE8 <= progressiveCycleBudgetUsdE8, AutonomousCheck(0x9c1914ff));
        progressiveCycleBudgetUsdE8 -= amountUsdE8;
        if (zeroForOne != progressiveInitialZeroForOne) {
            require(amountUsdE8 <= progressiveReverseBudgetUsdE8, AutonomousCheck(0xdcf7e188));
            progressiveReverseBudgetUsdE8 -= amountUsdE8;
        }
        progressiveSwapBudgetUsdE8 -= amountUsdE8;
    }

    function _requireProgressiveHfSafe() private view {
        IProgressiveHedgeGuard hedge = IProgressiveHedgeGuard(hedgeManager);
        (, uint256 debt, uint256 healthFactor,) = hedge.getHedgeData();
        if (debt == 0) return;
        require(healthFactor >= uint256(hedge.hfRepairTriggerBps()) * 1e14, AutonomousCheck(0xcf45dc37));
    }

    /// @notice Safe recovery renews the bounded cycle using the current canonical range.
    /// @dev If balancing is still needed the Vault stays locked and keepers resume the refreshed plan.
    ///      A no-swap recovery remints atomically through the normal finalization path before unlocking.
    function cancelProgressiveRebalance() external {
        require(msg.sender == owner && progressiveRebalanceStatus == 2, AutonomousCheck(0x78a71317));
        if (IRecoveryPause(pauseController).exitOnly()) {
            require(IRangeManagerPostCheck(rangeManager).getOwnerPositions().length == 0, "Close positions first");
            bytes32 stopped = progressiveDecisionHash;
            _clearProgressiveRebalance();
            IProgressiveVault(vault).endRebalance();
            emit ProgressiveRebalanceCancelled(stopped, msg.sender);
            return;
        }
        ProtocolSafetyLib.requireEmergency(vault);
        IProgressiveStrategy engine = IProgressiveStrategy(strategyEngine);
        if (engine.checkpointDue()) engine.checkpointMarketState();
        bytes32 decisionHash = IRangeStrategyEngine(strategyEngine).previewDecision().decisionHash;
        _refreshProgressiveRebalance(decisionHash, true);
        if (!_progressiveSwapParams().swapNeeded) {
            progressiveRebalanceStatus = 3;
            IProgressiveRangeManager(rangeManager)
                .progressiveRebalance(2, bytes32(0), progressiveTickLower, progressiveTickUpper, 0, 0, msg.sender);
            _clearProgressiveRebalance();
            emit ProgressiveRebalanceCancelled(decisionHash, msg.sender);
        }
    }

    function _requireCurrentModule() private view {
        require(IRangeManagerPostCheck(rangeManager).protocolBotAddress() == address(this), AutonomousCheck(0xe840bfef));
    }

    /// @notice LP/free RangeManager NAV reconstructed at the Chainlink token ratio (USD, 8 decimals).
    /// @dev Read-only and unaffected by the module kill-switch. The valuation sqrt is derived exclusively
    ///      from oracle prices; it remains exact and spot-independent even when the spot deviation guard is zero.

    /// @notice Oracle-value post-check used only by the Vault's fresh-divergence withdrawal fallback.

    modifier onlyBot() {
        require(msg.sender == botAddress, AutonomousCheck(0xa33c1783));
        if (paused()) revert ModulePaused();
        _requireCurrentModule();
        _;
    }

    modifier onlyBotAddress() {
        require(msg.sender == botAddress, AutonomousCheck(0xa33c1783));
        _requireCurrentModule();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedOwner();
        _;
    }

    modifier onlyAllowedFunction(bytes calldata data) {
        if (data.length < 4) revert InvalidCallData();
        bytes4 selector = bytes4(data[:4]);
        require(_allowedFunctions[selector], AutonomousCheck(0x50290082));
        _;
    }

    modifier withinDailyLimit() {
        _consumeDailyLimit();
        _;
    }

    /// @dev Reset journalier + incrementation du compteur sous la limite. Extrait du modifier pour
    ///      que executeVaultFunction puisse l'appeler conditionnellement (exemption endRebalance).
    function _consumeDailyLimit() private {
        _resetDailyCounterIfNeeded();
        require(dailySpent < dailyLimit, AutonomousCheck(0xf8773246));
        dailySpent++;
    }

    function _resetDailyCounterIfNeeded() private {
        uint256 currentDay = block.timestamp / 86400;
        if (currentDay != lastResetDay) {
            dailySpent = 0;
            lastResetDay = currentDay;
        }
    }

    // Fonction existante pour RangeManager
    function executeRangeManagerFunction(bytes calldata data) external onlyBot onlyAllowedFunction(data) {
        bytes4 selector = bytes4(data[:4]);
        if (selector != REFRESH_PRICE_SELECTOR && selector != REBALANCE_SELECTOR) revert InvalidTarget();
        _requireInflowsForSelector(selector);
        if (selector != REFRESH_PRICE_SELECTOR) {
            _consumeDailyLimit();
        } else {
            _resetDailyCounterIfNeeded();
        }

        _execute(rangeManager, 0, data);

        emit FunctionExecuted(selector, dailySpent);
    }

    function executeStrategyEngineFunction(bytes calldata data) external onlyBot onlyAllowedFunction(data) {
        bytes4 selector = bytes4(data[:4]);
        if (selector != CHECKPOINT_SELECTOR) revert InvalidTarget();
        _consumeDailyLimit();
        _execute(strategyEngine, 0, data);
        emit FunctionExecuted(selector, dailySpent);
    }

    // Fonctions pour MultiUserVault
    function executeVaultFunction(bytes calldata data) external onlyBot onlyAllowedFunction(data) {
        // Audit V3 (Point 2) : endRebalance() (deverrouillage, ne deplace pas de fonds) est exempte de
        // la limite quotidienne — sinon un jour de forte activite pourrait laisser le vault verrouille.
        // Toutes les autres fonctions vault (dont startRebalance) restent soumises a la limite.
        bytes4 selector = bytes4(data[:4]);
        if (selector == END_REBALANCE_SELECTOR && progressiveRebalanceStatus != 0) revert ProgressiveActive();
        _requireInflowsForSelector(selector);
        if (selector != END_REBALANCE_SELECTOR) {
            _consumeDailyLimit();
        } else {
            _resetDailyCounterIfNeeded();
        }

        _execute(vault, 0, data);

        emit FunctionExecuted(selector, dailySpent);
    }

    // Fonctions pour AaveHedgeManager (Delta Neutral). adjustHedge() est le chemin ordinaire, pausible.
    // repairHealthFactor() est un selecteur permissionless dedie qui derive l'urgence du HF Aave live:
    // lui seul contourne la pause. Aucun des deux ne consomme la limite du hot bot.
    function executeHedgeFunction(bytes calldata data) external onlyBotAddress {
        _resetDailyCounterIfNeeded();
        if (data.length < 4) revert InvalidCallData();
        bytes4 selector = bytes4(data[:4]);
        if (selector != ADJUST_HEDGE_SELECTOR && selector != REPAIR_HF_SELECTOR) revert InvalidTarget();
        if (data.length != 4) revert InvalidCallData();
        require(_allowedFunctions[selector], AutonomousCheck(0x50290082));
        if (selector == ADJUST_HEDGE_SELECTOR && paused()) revert ModulePaused();
        _execute(hedgeManager, 0, data);

        emit FunctionExecuted(selector, dailySpent);
    }

    /// @notice Execute a Treasury function (bridge operations only, per whitelist)
    function executeTreasuryFunction(bytes calldata data) external onlyBot onlyAllowedFunction(data) withinDailyLimit {
        if (paused()) revert ModulePaused();
        _execute(treasury, 0, data);

        bytes4 selector = bytes4(data[:4]);
        emit FunctionExecuted(selector, dailySpent);
    }

    /// @notice Execute a Treasury function with native ETH value (Stargate cross-chain fees)

    function executeTreasuryFunctionWithValue(bytes calldata data, uint256 value)
        external
        payable
        onlyBot
        onlyAllowedFunction(data)
        withinDailyLimit
    {
        if (paused()) revert ModulePaused();
        require(msg.value == value, AutonomousCheck(0x23a54c99));

        uint256 nativeBefore = address(this).balance - msg.value;
        (address refundToken, uint256 tokenBefore) = _treasuryUsdcBalance();
        _execute(treasury, value, data);
        if (directExecution && address(this).balance > nativeBefore) {
            uint256 refund = address(this).balance - nativeBefore;
            (bool ok,) = botAddress.call{value: refund}("");
            require(ok, AutonomousCheck(0xcef6850b));
            emit ModuleSweep(address(0), refund);
        }
        _sweepTreasuryUsdcToBot(refundToken, tokenBefore);

        bytes4 selector = bytes4(data[:4]);
        emit FunctionExecuted(selector, dailySpent);
    }

    // Fonctions d'administration (appelées par la Safe)
    function allowFunction(bytes4 selector, bool allowed) external onlyOwner {
        AutonomousPoolLib.requireInstallation(vault);
        require(_isCoreSelector(selector), AutonomousCheck(0xfac078d3));
        require(selector != REPAIR_HF_SELECTOR || allowed, AutonomousCheck(0x089ab8a5));
        _allowedFunctions[selector] = allowed;
        emit FunctionAllowed(selector, allowed);
    }

    function setDailyLimit(uint256 newLimit) external onlyOwner {
        AutonomousPoolLib.requireInstallation(vault);
        require(newLimit > 0 && newLimit <= 1000, AutonomousCheck(0xb08174c0));
        uint256 currentDay = block.timestamp / 86400;
        uint256 actualSpent = (currentDay == lastResetDay) ? dailySpent : 0;
        require(newLimit >= actualSpent, AutonomousCheck(0x08620a89));
        dailyLimit = newLimit;
        emit DailyLimitUpdated(newLimit);
    }

    /// @notice Pause d'urgence du module.

    function setPaused(bool _paused) external {
        if (msg.sender != owner && msg.sender != safe) revert UnauthorizedOwner();
        ProtocolSafetyLib.setPause(_pauseState, owner, _paused);
        emit Paused(_paused);
    }

    function pauseFor(uint64 duration) external onlyOwner {
        ProtocolSafetyLib.setPauseFor(_pauseState, safe, duration);
        emit Paused(true);
    }

    function guardianPauseUntil() external view returns (uint64) {
        return _pauseState.until;
    }

    function paused() public view returns (bool) {
        return _pauseState.active && block.timestamp < _pauseState.until;
    }

    function sweepNativeToSafe() external {
        if (msg.sender != owner) revert UnauthorizedOwner();
        uint256 amount = ProtocolSafetyLib.sweep(address(0), treasury);
        emit ModuleSweep(address(0), amount);
    }

    function sweepTokenToSafe(address token) external {
        if (msg.sender != owner) revert UnauthorizedOwner();
        uint256 amount = ProtocolSafetyLib.sweep(token, treasury);
        emit ModuleSweep(token, amount);
    }

    function _treasuryUsdcBalance() private view returns (address token, uint256 balance) {
        return ProtocolSafetyLib.bountyBalance(treasury);
    }

    function _sweepTreasuryUsdcToBot(address token, uint256 balanceBefore) private {
        uint256 amount = ProtocolSafetyLib.sweepBountyDelta(treasury, botAddress, token, balanceBefore);
        if (amount > 0) emit ModuleSweep(token, amount);
    }

    function _execute(address target, uint256 value, bytes memory data) private {
        (bool success, bytes memory reason) = target.call{value: value}(data);
        if (!success) _revertWithReason(reason);
    }

    function _revertWithReason(bytes memory reason) private pure {
        if (reason.length > 0) {
            assembly {
                revert(add(32, reason), mload(reason))
            }
        }
        revert("Execution failed");
    }

    // Fonctions de lecture
    function getDailyStats() external view returns (uint256 limit, uint256 spent, uint256 remaining, uint256 resetsIn) {
        uint256 currentDay = block.timestamp / 86400;
        uint256 actualSpent = (currentDay == lastResetDay) ? dailySpent : 0;

        // UI/monitoring countdown only; this timestamp modulo is not randomness.
        uint256 remainingToday = dailyLimit > actualSpent ? dailyLimit - actualSpent : 0;
        return (dailyLimit, actualSpent, remainingToday, 86400 - (block.timestamp % 86400));
    }

    function isFunctionAllowed(bytes4 selector) external view returns (bool) {
        return _allowedFunctions[selector];
    }

    function _requireInflowsForSelector(bytes4 selector) private view {
        if (
            selector == 0x76919a59 // processDepositPermissionless(uint256[],uint256[],address,address)
        ) {
            if (paused()) revert ModulePaused();
            address controller = pauseController;
            // Yul shl order is shl(shift, value): left-align requireInflowsActive().
            assembly ("memory-safe") {
                mstore(0x00, shl(224, 0x5ea9e82a)) // requireInflowsActive()
                if iszero(staticcall(gas(), controller, 0x00, 0x04, 0x00, 0x00)) {
                    returndatacopy(0x00, 0x00, returndatasize())
                    revert(0x00, returndatasize())
                }
            }
        }
    }

    function _isCoreSelector(bytes4 selector) private pure returns (bool) {
        return selector == 0x0be1c372 // refreshPriceCache()
            || selector == CHECKPOINT_SELECTOR || selector == REBALANCE_SELECTOR || selector == 0x76919a59 // processDepositPermissionless(uint256[],uint256[],address,address)
            || selector == 0x0040718e // endRebalance()
            || selector == ADJUST_HEDGE_SELECTOR || selector == REPAIR_HF_SELECTOR
            || selector == bytes4(keccak256("bridgeRevenue(uint256)")) // bridgeRevenue(uint256)
            || selector == bytes4(keccak256("forwardRevenue(uint256)"))
            || selector == bytes4(keccak256("convertSourceFeesToUSDC(address,address)"))
            || selector == bytes4(keccak256("convertSourceFeeChunk(address,address,uint256)"))
            || selector == bytes4(keccak256("convertFeesToUSDC(address)"))
            || selector == bytes4(keccak256("wrapNativeFees()")); // forwardRevenue(uint256)
    }
}
