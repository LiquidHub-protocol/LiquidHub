// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IAaveV3Pool.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "./DnDepositLib.sol";
import "./interfaces/IRangeStrategyEngine.sol";

/// @dev Interface minimale du RangeManager pour lire la liste des positions LP (adjustHedge).
interface IRangeManagerHedge {
    function prepareHedgeAdjustment() external returns (uint256 tokenId);
    function refreshPriceCache() external;
    function getOwnerPositions() external view returns (uint256[] memory);
    function strategyEngine() external view returns (IRangeStrategyEngine);
}

/// @dev Interface minimale du Treasury pour le hedge bounty.
interface IHedgeTreasury {
    function payHedgeBounty(address keeper) external;
}

/// @dev Pour lire les decimales d'un token (generique, pas de hard-code).
interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title AaveHedgeManager - AAVE V3 hedge for Delta Neutral strategy
/// @notice Manages supply/borrow/repay/withdraw on AAVE V3 for the DN pool hedge.
///         Supports atomic settlement via flash loan for user withdrawals.
/// @dev Phase 1: Safe owns settings. Phase 2: Timelock owns settings and the Safe keeps only
///      emergency/pause powers. Recurring strategy actions are permissionless and engine-validated.
contract AaveHedgeManager is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===== CONTROLLERS =====
    address public safe; // emergency/pause controller (Safe in Phase 1 and Phase 2)
    address public governance; // settings owner (Safe in Phase 1, Timelock in Phase 2)
    address public pendingGovernance;

    // ===== IMMUTABLES =====
    address public immutable vault;
    IAaveV3Pool public immutable pool;
    IERC20 public immutable usdc;
    IERC20 public immutable weth;
    IERC20 public immutable aTokenUsdc;
    IERC20 public immutable variableDebtWeth;
    ISwapRouter public immutable swapRouter;
    uint24 public immutable swapPoolFee;

    // ===== STATE =====
    bool public paused;
    bool private _flashLoanActive;

    // ===== ADJUST HEDGE (permissionless, gouvernance) =====
    address public rangeManager; // pour lire la liste des positions (setter post-deploy)
    address public treasuryAddress; // pour le hedge bounty (setter post-deploy)
    INonfungiblePositionManager public lpPositionManager; // NFT manager Uniswap V3 (setter)
    IUniswapV3Pool public lpPool; // pool LP token0/token1 (setter)
    uint16 public adjustHedgeBps; // normal HEDGE_ONLY drift threshold, governed within hard bounds
    uint16 public criticalHedgeBps = 600; // stricter final range-sync/post-deposit drift ceiling
    uint16 public swapSlippageBps; // slippage max tolere sur le swap token1->token0 (ex 100 = 1%)
    // Reconstitution de reserve apres repay (HF cible). L'USDC libere reste sur ce contrat (reserve).
    uint16 public reserveHfTargetBps; // HF cible apres reconstitution, ex 15000 = 1.5
    // Marge operationnelle au-dessus du minimum dur. Elle absorbe les mouvements de prix et interets entre
    // checkpoints sans relever le seuil de securite qui fait revert une transaction atomique.
    uint16 public operationalHfBufferBps;
    // Hysteresis de securite: une baisse sous la cible ne suffit pas a declencher un micro-repay.
    // La reparation HF urgente devient permissionless uniquement sous ce seuil, puis remonte vers la cible.
    uint16 public hfRepairTriggerBps;
    // Minimum de dette effectivement remboursee, valorisee en base AAVE USD 8 decimales, pour payer le bounty.
    // Une reparation plus petite reste executee mais ne peut pas vider le budget de bounties par micro-churn.
    uint64 public hfRepairBountyMinUsd;
    uint16 public liqThresholdBps; // seuil de liquidation du collateral (AAVE), ex 8500 = 0.85
    // Cooldown on-chain entre deux reajustements de drift normaux, identique pour keepers et bot.
    // Seule la branche de reparation HF sous hfRepairTriggerBps le contourne, avant ce garde-fou.
    uint32 public hedgeAdjustCooldown = 14400; // 4 h entre deux ajustements ordinaires ; les urgences contournent ce delai
    uint64 public lastHedgeAdjustAt; // timestamp du dernier reajustement (borrow ou repay)
    // audit V1 (V3-R4 Point 2) : ecart MAX tolere entre le prix LP (slot0 du pool) et le ratio ORACLE
    // token0/token1 du RangeManager AVANT de calculer token0InLP dans adjustHedge().
    // adjustHedge() est permissionless : sans cette garde, un prix LP manipule (slot0) gonfle/reduit
    // token0InLP -> borrow/repay inutile -> churn AAVE + bounty vole + exposition MEV. En bps. 0 = desactive
    // (retrocompat / mode urgence). Aucune hypothese stablecoin: price0 ET price1 sont lus dans le cache RM.
    uint16 public maxHedgeDeviationBps = 50;
    // Decimales des tokens lues directement depuis les contrats au constructeur (zero hard-code,
    // toujours disponibles des le deploiement, generiques WETH/USDC ou WBTC/USDT ou toute paire).
    uint8 public immutable volatileDecimals; // decimales du token volatil emprunte (token0)
    uint8 public immutable stableDecimals; // decimales du token1 collateral (nom historique)
    uint256 private constant SHARE_SCALE = 1e18; // precision settlement proportional aux shares
    uint256 private constant MAIN_BOT_KEEPER_DELAY = 60;

    // ===== DELTA-NEUTRAL STRICT (refonte hedge : pilotage sur le SHORT NET EFFECTIF) =====
    // Le hedge ne se pilote PLUS sur la dette brute mais sur effectiveShort = dette - token0 libre (HM + RM).
    // Cible = hedgeTargetBps/10000 * token0InLP (defaut 10000 = 100% = DN strict ; le token0 long de la LP est
    // entierement couvert par la dette short). H_opt (variance-min ~50%) RETIRE : trompeur pour un produit
    // "Delta Neutral". Le token0 emprunte ne doit JAMAIS rester idle (il annule la dette) -> integre a la LP au
    // mint (B1), et le repay over-hedge achete le token0 AU MARCHE (jamais depuis le buffer idle).
    uint16 public constant hedgeTargetBps = 10000; // cible DN stricte: 100% du token0 LP
    // Seuil dust on-chain (en token0/volatil) : une donation de token0 au RangeManager gonfle idleRM et
    // fausse effectiveShort. En-dessous de ce seuil, le token0 libre du RM est IGNORE (anti-grief donation).
    uint256 public donationDustToken0;

    error BadHealthFactor();
    error HedgeCheck(uint8 code);

    event HedgeAdjusted(uint256 oldDebtWeth, uint256 targetShort, bool borrowed, address indexed keeper);
    event HedgeAdjustmentSkipped(uint256 currentDebtWeth, uint256 targetShort, uint256 driftBps);
    event HealthFactorRepaired(
        uint256 healthFactorBefore,
        uint256 healthFactorAfter,
        uint256 debtRepaidBase,
        bool bountyEligible,
        address indexed keeper
    );
    event HfRepairConfigUpdated(uint16 triggerBps, uint64 bountyMinUsd);
    event OperationalHfBufferUpdated(uint16 bufferBps);

    // ===== EVENTS =====
    event SupplyAndBorrow(uint256 usdcSupplied, uint256 wethBorrowed);
    event RepayDebt(uint256 wethRepaid);
    // CloseAll est émis par _closePosition. L'ancien alias de fermeture d'urgence a ete retire: closeAll est deja
    // onlySafe/nonReentrant et sert de fermeture d'urgence unique.
    event CloseAll(address recipient, uint256 usdcSent);
    event SweepWeth(address to, uint256 amount);
    event Paused(bool paused);
    event SafeUpdated(address indexed previousSafe, address indexed newSafe);
    event DonationDustUpdated(uint256 value);
    event GovernanceTransferStarted(address indexed currentGovernance, address indexed pendingGovernance);
    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);
    event SettleProportional(uint256 wethUsed, uint256 proportionX18, address recipient, uint256 usdcRecovered);

    // ===== MODIFIERS =====
    modifier onlySafe() {
        if (msg.sender != safe) revert HedgeCheck(1);
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert HedgeCheck(2);
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert HedgeCheck(4);
        _;
    }

    // REFONTE DN : le Vault peut ouvrir/réduire le hedge atomiquement au dépôt permissionless ET dans le
    // rebalance-solveur permissionless. Moindre privilege : SEULES la Safe d'urgence (toutes phases) et le Vault
    // accedent aux primitives exactes. Les actions recurrentes sont permissionless et validees par le moteur.
    // Les setters restent onlyGovernance.
    modifier onlySafeOrVault() {
        if (msg.sender != safe && msg.sender != vault) revert HedgeCheck(5);
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert HedgeCheck(6);
        _;
    }

    // ===== CONSTRUCTOR =====
    /// @param _safe Gnosis Safe address (emergency/pause controller, initial governance)
    /// @param _vault MultiUserVault address (authorized caller for settleProportional)
    /// @param _pool AAVE V3 Pool on Arbitrum (0x794a61358D6845594F94dc1DB02A252b5b4814aD)
    /// @param _usdc USDC on Arbitrum (0xaf88d065e77c8cC2239327C5EDb3A432268e5831)
    /// @param _weth WETH on Arbitrum (0x82aF49447D8a07e3bd95BD0d56f35241523fBab1)
    /// @param _variableDebtWeth AAVE V3 variable debt WETH token on Arbitrum
    /// @param _swapRouter Uniswap V3 SwapRouter address (0xE592427A0AEce92De3Edee1F18E0157C05861564 on Arbitrum)
    /// @param _swapPoolFee Uniswap V3 pool fee tier for token0/token1 pair (500 = 0.05%, 3000 = 0.30%)
    constructor(
        address _safe,
        address _vault,
        address _pool,
        address _usdc,
        address _weth,
        address _aTokenUsdc,
        address _variableDebtWeth,
        address _swapRouter,
        uint24 _swapPoolFee
    ) {
        require(_safe != address(0), "E07");
        require(_vault != address(0), "E08");
        require(_pool != address(0), "E09");
        require(_usdc != address(0), "E10");
        require(_weth != address(0), "E11");
        require(_aTokenUsdc != address(0), "E15");
        require(_variableDebtWeth != address(0), "E12");
        require(_swapRouter != address(0), "E13");
        require(_swapPoolFee > 0, "E14");

        safe = _safe;
        governance = _safe;
        vault = _vault;
        pool = IAaveV3Pool(_pool);
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);
        aTokenUsdc = IERC20(_aTokenUsdc);
        variableDebtWeth = IERC20(_variableDebtWeth);
        swapRouter = ISwapRouter(_swapRouter);
        swapPoolFee = _swapPoolFee;
        reserveHfTargetBps = 11000;
        operationalHfBufferBps = 0;
        hfRepairTriggerBps = 10500;
        hfRepairBountyMinUsd = 25e8; // 25 USD, base AAVE a 8 decimales
        // Lire les decimales directement des tokens (generique : WETH/USDC, WBTC/USDT, etc.).
        // Les bornes evitent les exponentiations non realistes dans les conversions oracle.
        uint8 volatileDec = IDecimals(_weth).decimals();
        uint8 stableDec = IDecimals(_usdc).decimals();
        require(volatileDec <= 18 && stableDec <= 18, "E51");
        volatileDecimals = volatileDec;
        stableDecimals = stableDec;

        // Approve max token1 and token0 to AAVE Pool for supply/repay
        IERC20(_usdc).safeApprove(_pool, type(uint256).max);
        IERC20(_weth).safeApprove(_pool, type(uint256).max);
        // Approve both pair tokens to SwapRouter for the oracle-bounded hedge adjustments.
        IERC20(_usdc).safeApprove(_swapRouter, type(uint256).max);
        IERC20(_weth).safeApprove(_swapRouter, type(uint256).max);
    }

    // ===== ATOMIC SETTLEMENT (called by Vault during withdraw) =====

    /// @notice Settle AAVE hedge proportionally during atomic withdraw
    /// @dev Called by the vault after LP burn. token0 must be transferred to this contract before calling.
    ///      If token0 received < debt to repay, initiates flash loan to cover shortfall.
    /// @param wethReceived Amount of token0 transferred by vault (from LP burn). Name is historical.
    /// @param proportionBps Proportion of total position to settle (1e18 = 100%)
    /// @param isFullWithdraw True if this is a full withdrawal (close entire position)
    /// @param recipient Address to send recovered USDC (typically the vault)
    function settleProportional(uint256 wethReceived, uint256 proportionBps, bool isFullWithdraw, address recipient)
        external
        onlyVault
        nonReentrant
    {
        _settleProportional(wethReceived, proportionBps, isFullWithdraw, recipient);
    }

    /// @notice Emergency settle called by vault during EmergencyRecoverUser
    /// @dev Uses the same flash loan + swap logic as executeOperation, with the emergency vault flow.
    function emergencySettleForVault(
        uint256 wethReceived,
        uint256 proportionBps,
        bool isFullWithdraw,
        address recipient
    ) external onlyVault nonReentrant {
        _settleProportional(wethReceived, proportionBps, isFullWithdraw, recipient);
    }

    function _settleProportional(uint256 wethReceived, uint256 proportionBps, bool isFullWithdraw, address recipient)
        private
    {
        if (recipient == address(0)) revert HedgeCheck(16);
        if (proportionBps == 0 || proportionBps > SHARE_SCALE) revert HedgeCheck(16);
        (uint256 idleWethBefore, uint256 idleUsdcBefore) = _idleBeforeSettlement(wethReceived);
        uint256 recipientUsdcBefore = usdc.balanceOf(recipient);

        uint256 totalDebt = variableDebtWeth.balanceOf(address(this));

        if (totalDebt == 0) {
            DnDepositLib.settleAaveNoDebt(
                address(pool),
                address(usdc),
                address(aTokenUsdc),
                address(weth),
                wethReceived,
                proportionBps,
                isFullWithdraw,
                recipient
            );
            if (!isFullWithdraw) _sendIdleShare(idleWethBefore, idleUsdcBefore, proportionBps, recipient);
            _postSettlement(isFullWithdraw);
            emit SettleProportional(0, proportionBps, recipient, usdc.balanceOf(recipient) - recipientUsdcBefore);
            return;
        }

        uint256 debtToRepay = isFullWithdraw ? totalDebt : (totalDebt * proportionBps) / SHARE_SCALE;
        // The withdrawing account owns this fraction of pre-existing idle token0. Consume it before
        // borrowing from Aave; the remainder stays protected for the other users in the flash callback.
        uint256 idleWethShare = isFullWithdraw ? idleWethBefore : (idleWethBefore * proportionBps) / SHARE_SCALE;
        uint256 availableWeth = wethReceived + idleWethShare;

        if (availableWeth >= debtToRepay) {
            _settleDirectly(debtToRepay, proportionBps, isFullWithdraw, recipient);
        } else {
            uint256 shortfall = debtToRepay - availableWeth;
            _flashLoanActive = true;
            bytes memory params =
                abi.encode(debtToRepay, proportionBps, isFullWithdraw, recipient, idleWethBefore - idleWethShare);
            pool.flashLoanSimple(address(this), address(weth), shortfall, params, 0);
            _flashLoanActive = false;
        }

        if (isFullWithdraw) {
            uint256 remainingWeth = weth.balanceOf(address(this));
            if (remainingWeth > 0) weth.safeTransfer(recipient, remainingWeth);
        } else {
            if (availableWeth > debtToRepay) weth.safeTransfer(recipient, availableWeth - debtToRepay);
            _sendIdleShare(0, idleUsdcBefore, proportionBps, recipient);
        }

        // On full withdraw, sweep any USDC residual
        if (isFullWithdraw) {
            uint256 usdcResidual = usdc.balanceOf(address(this));
            if (usdcResidual > 0) usdc.safeTransfer(recipient, usdcResidual);
        }

        _postSettlement(isFullWithdraw);

        emit SettleProportional(wethReceived, proportionBps, recipient, usdc.balanceOf(recipient) - recipientUsdcBefore);
    }

    function _postSettlement(bool isFullWithdraw) private view {
        if (isFullWithdraw) {
            if (variableDebtWeth.balanceOf(address(this)) > 0 || aTokenUsdc.balanceOf(address(this)) > 0) {
                revert HedgeCheck(56);
            }
        } else {
            _requireHfMin();
        }
    }

    /// @notice AAVE V3 flash loan callback
    /// @dev Called by AAVE Pool during flashLoanSimple. Repays debt, withdraws collateral,
    ///      swaps token1->token0 to cover flash loan repayment, then sends remaining token1 to vault.
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        if (msg.sender != address(pool)) revert HedgeCheck(17);
        if (initiator != address(this)) revert HedgeCheck(18);
        if (!_flashLoanActive) revert HedgeCheck(19);
        if (asset != address(weth)) revert HedgeCheck(20);

        (uint256 debtToRepay, uint256 proportionBps, bool isFullWithdraw, address recipient, uint256 protectedIdleWeth)
        = abi.decode(params, (uint256, uint256, bool, address, uint256));

        uint256 usdcBefore = usdc.balanceOf(address(this));

        // Step 1: Repay token0 debt (we now have token0 from LP + flashLoan amount)
        if (isFullWithdraw) {
            pool.repay(address(weth), type(uint256).max, 2, address(this));
        } else {
            pool.repay(address(weth), debtToRepay, 2, address(this));
        }

        // recipient=0 is the permissionless HF-repair mode. Debt is repaid first, then only the collateral
        // made safely withdrawable by that repay funds the oracle-bounded flash repayment.
        if (recipient == address(0)) {
            _completeHfRepair(amount + premium);
            return true;
        }

        // Step 2: Withdraw token1 collateral proportionally
        if (isFullWithdraw) {
            pool.withdraw(address(usdc), type(uint256).max, address(this));
        } else {
            // Calculate proportional token1 to withdraw based on current AAVE collateral.
            // After partial debt repay, remaining debt prevents full collateral withdrawal
            // (AAVE would revert with HF < 1). Use getUserAccountData to get actual collateral.
            uint256 proportionalUsdc = DnDepositLib.aaveCollateralShare(address(aTokenUsdc), proportionBps);
            if (proportionalUsdc > 0) {
                pool.withdraw(address(usdc), proportionalUsdc, address(this));
            }
        }

        uint256 usdcRecovered = usdc.balanceOf(address(this)) - usdcBefore;

        // Step 3: Swap token1 -> token0 to cover flash loan repayment
        // After repaying AAVE debt, AAVE needs amount + premium back. For partial settlements,
        // pre-existing idle token0 is protected so the current withdraw cannot be subsidized by reserves
        // that belong pro-rata to all users.
        uint256 flashLoanOwed = amount + premium;
        uint256 wethBalance = weth.balanceOf(address(this));

        uint256 wethRequired = flashLoanOwed + protectedIdleWeth;
        if (wethBalance < wethRequired) {
            uint256 wethNeeded = wethRequired - wethBalance;
            // SÉCURITÉ (audit V1 — High 3) : plafond anti-sandwich via oracle Chainlink (et NON
            // token1 balance entier). Sans ce plafond, ce swap (déclenché pendant un withdraw DN) était
            // sandwichable, au détriment direct du user qui retire. Même logique que _acquireWethForRepay.
            (uint256 amountInMaximum, uint160 sqrtPriceLimitX96) = _oracleMaxUsdcForWeth(wethNeeded);
            if (!isFullWithdraw && amountInMaximum > usdcRecovered) amountInMaximum = usdcRecovered;
            if (amountInMaximum == 0) revert HedgeCheck(21);
            // Uniswap V3 autorise un exact-output partiel lorsqu'une limite sqrt est fournie. Refuser ce cas
            // pour que le flash-loan ne puisse jamais consommer le token0 idle protege des autres utilisateurs.
            if (
                DnDepositLib.aaveExactOutput(
                    address(swapRouter),
                    address(usdc),
                    address(weth),
                    swapPoolFee,
                    wethNeeded,
                    amountInMaximum,
                    sqrtPriceLimitX96
                ) != wethNeeded
            ) revert HedgeCheck(59);
        }
        // AAVE will pull flashLoanOwed token0 from this contract (max approve in constructor)

        // Step 4: Send only token1 attributable to this settlement, never pre-existing reserve.
        uint256 usdcAfter = usdc.balanceOf(address(this));
        uint256 usdcToSend = usdcAfter > usdcBefore ? usdcAfter - usdcBefore : 0;
        if (usdcToSend > 0) {
            usdc.safeTransfer(recipient, usdcToSend);
        }

        return true;
    }

    // ===== MAIN FUNCTIONS =====

    /// @notice Supply an EXACT collateral amount and borrow WETH.
    /// @dev REFONTE DN : montant de collatéral EXPLICITE (plus "tout le solde") — sinon une réserve USDC
    ///      préexistante sur le contrat serait fournie involontairement à AAVE (retour audit). Le Vault seul
    ///      l'appelle au dépôt permissionless hedgé. Flow : Vault envoie USDC ici -> supply EXACT ->
    ///      borrow WETH -> WETH reste ici pour sweep (montant exact) vers la LP.
    /// @param collateralAmountUsdc Montant EXACT d'USDC à supply (doit être <= solde présent)
    /// @param borrowAmountWeth Montant de WETH à emprunter (wei)
    function supplyAndBorrow(uint256 collateralAmountUsdc, uint256 borrowAmountWeth)
        external
        onlyVault
        whenNotPaused
        nonReentrant
    {
        if (collateralAmountUsdc == 0) revert HedgeCheck(22);
        if (borrowAmountWeth == 0) revert HedgeCheck(23);
        if (usdc.balanceOf(address(this)) < collateralAmountUsdc) revert HedgeCheck(24);

        // Supply EXACTEMENT collateralAmountUsdc (pas tout le solde)
        _supplyStable(collateralAmountUsdc);

        // Borrow WETH (variable rate = 2)
        pool.borrow(address(weth), borrowAmountWeth, 2, 0, address(this));
        _requireHfMin();

        emit SupplyAndBorrow(collateralAmountUsdc, borrowAmountWeth);
    }

    function _requireHfMin() private view {
        (,,,,, uint256 hf) = pool.getUserAccountData(address(this));
        if (hf < uint256(reserveHfTargetBps) * 1e14) revert BadHealthFactor();
    }

    function operationalHfTargetBps() public view returns (uint16) {
        return reserveHfTargetBps + operationalHfBufferBps;
    }

    /// @notice Repay token0 debt only (no collateral withdrawal)
    /// @dev Used during rebalance when ETH exposure decreases
    /// @param repayAmountWeth Amount of token0 to repay. Name is historical.
    function repayDebt(uint256 repayAmountWeth) external onlySafeOrVault nonReentrant {
        _doRepayDebt(repayAmountWeth);
    }

    /// @dev Coeur de repayDebt, reutilise par adjustHedge (permissionless). Pas de modifier.
    ///      NE reset PAS lastHedgeAdjustAt : un repay depuis buffer (onlySafe, nettoyage bilan) ne change
    ///      PAS effectiveShort (dette -x ET idle -x) => ce n'est pas un ajustement delta, donc pas de reset
    ///      cooldown. Le reset est fait explicitement par adjustHedge() sur le chemin over-hedge corrige.
    function _doRepayDebt(uint256 repayAmountWeth) private {
        if (repayAmountWeth == 0) revert HedgeCheck(27);

        pool.repay(address(weth), repayAmountWeth, 2, address(this));

        emit RepayDebt(repayAmountWeth);
    }

    // ===== ADJUST HEDGE (permissionless) =====

    /// @notice Configure le reajustement permissionless du hedge (gouvernance, via Safe).
    /// @dev addrs : [0]=rangeManager [1]=treasury [2]=positionManager [3]=lpPool.
    ///      params : [0]=adjustHedgeBps(100..2000) [1]=swapSlippageBps(10..500)
    ///      [2]=reserveHfTargetBps(11000..30000) [3]=liqThresholdBps(5000..9500).
    ///      Le contrat lit les prix actifs via RangeManager.refreshPriceCache()/priceCache(), donc aucun feed
    ///      oracle n'est recâblé ici.
    ///      Parametres groupes en tableaux pour eviter stack-too-deep.
    function setAdjustHedgeConfig(address[4] calldata addrs, uint16[4] calldata params) external onlyGovernance {
        address currentRangeManager = rangeManager;
        if (
            addrs[0] == address(0) || addrs[2] == address(0) || addrs[3] == address(0)
                || (
                    currentRangeManager != address(0)
                        && (
                            addrs[0] != currentRangeManager || addrs[2] != address(lpPositionManager)
                                || addrs[3] != address(lpPool)
                        )
                )
        ) revert HedgeCheck(30);
        if (params[0] < 100 || params[0] > 2000) revert HedgeCheck(31);
        if (params[1] < 10 || params[1] > 500) revert HedgeCheck(32);
        if (params[2] < 11000 || params[2] > 30000) revert HedgeCheck(33); // 1.1 .. 3.0
        if (uint256(params[2]) + operationalHfBufferBps > 30000) revert HedgeCheck(64);
        if (params[3] < 5000 || params[3] > 9500) revert HedgeCheck(34); // 0.5 .. 0.95
        if (params[2] <= hfRepairTriggerBps) revert HedgeCheck(62);
        // Topology is installed once by the Phase 1 batch. Governance may tune risk parameters later,
        // but cannot redirect collateral or debt accounting to replacement contracts.
        // RangeManager is the immutable destination of close/sweep paths after the initial batch.
        if (currentRangeManager == address(0)) rangeManager = addrs[0];
        treasuryAddress = addrs[1];
        lpPositionManager = INonfungiblePositionManager(addrs[2]);
        lpPool = IUniswapV3Pool(addrs[3]);
        adjustHedgeBps = params[0];
        if (criticalHedgeBps < adjustHedgeBps + 250) revert HedgeCheck(54);
        swapSlippageBps = params[1];
        reserveHfTargetBps = params[2];
        liqThresholdBps = params[3];
    }

    /// @notice Configure la marge de HF conservee en fonctionnement normal au-dessus du minimum dur.
    function setOperationalHfBufferBps(uint16 bufferBps) external onlyGovernance {
        if (uint256(reserveHfTargetBps) + bufferBps > 30000) revert HedgeCheck(64);
        operationalHfBufferBps = bufferBps;
        emit OperationalHfBufferUpdated(bufferBps);
    }

    /// @notice Configure l'hysteresis de reparation HF et le minimum USD donnant droit au bounty.
    /// @dev La reparation reste permissionless et ignore le cooldown sous `triggerBps`. Elle vise ensuite
    ///      `reserveHfTargetBps` (+ buffer d'arrondi). `bountyMinUsd` est exprime en USD AAVE 8 decimales.
    function setHfRepairConfig(uint16 triggerBps, uint64 bountyMinUsd) external onlyGovernance {
        if (triggerBps <= 10000 || triggerBps >= reserveHfTargetBps) revert HedgeCheck(62);
        if (bountyMinUsd < 1e8 || bountyMinUsd > 1_000_000e8) revert HedgeCheck(63);
        hfRepairTriggerBps = triggerBps;
        hfRepairBountyMinUsd = bountyMinUsd;
        emit HfRepairConfigUpdated(triggerBps, bountyMinUsd);
    }

    /// @notice Configure the critical/final delta threshold used by strict post-checks.
    function setCriticalHedgeBps(uint16 thresholdBps) external onlyGovernance {
        if (thresholdBps < 250 || thresholdBps > 3000 || thresholdBps < adjustHedgeBps + 250) {
            revert HedgeCheck(54);
        }
        criticalHedgeBps = thresholdBps;
    }

    /// @notice Seuil dust (token0/volatil) sous lequel le token0 libre du RangeManager est ignore dans
    ///         effectiveShort (anti-grief donation). Gouvernance.
    function setDonationDustToken0(uint256 _donationDustToken0) external onlyGovernance {
        uint256 maxDust = volatileDecimals >= 3 ? 10 ** (uint256(volatileDecimals) - 3) : 1;
        if (_donationDustToken0 == 0 || _donationDustToken0 > maxDust) revert HedgeCheck(40);
        donationDustToken0 = _donationDustToken0;
        emit DonationDustUpdated(_donationDustToken0);
    }

    /// @notice Configure le cooldown on-chain entre deux adjustHedge() permissionless (gouvernance).
    /// @dev 0 = desactive (retrocompat). Borne haute 24h. Le même cooldown s'applique au bot et aux keepers ;
    ///      seules la réparation HF et une dérive supérieure au seuil critique le contournent.
    function setHedgeAdjustCooldown(uint32 _cooldownSeconds) external onlyGovernance {
        if (_cooldownSeconds > 86400) revert HedgeCheck(36);
        hedgeAdjustCooldown = _cooldownSeconds;
    }

    /// @notice (audit V1 — V3-R4 Point 2) Ecart max LP(slot0) vs oracle Chainlink avant adjustHedge (gouvernance).
    /// @dev En bps. 0 = desactive (mode urgence documente). Borne <= 1000 (10%) pour ne pas neutraliser la garde.
    function setMaxHedgeDeviationBps(uint16 _bps) external onlyGovernance {
        if (_bps > 1000) revert HedgeCheck(37);
        maxHedgeDeviationBps = _bps;
    }

    /// @notice Transfere la gouvernance des reglages vers une nouvelle adresse (ex: Timelock Phase 2).
    function transferOwnership(address newOwner) external onlyGovernance {
        if (newOwner == address(0)) revert HedgeCheck(38);
        pendingGovernance = newOwner;
        emit GovernanceTransferStarted(governance, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingGovernance) revert HedgeCheck(55);
        address previousGovernance = governance;
        governance = msg.sender;
        pendingGovernance = address(0);
        emit GovernanceTransferred(previousGovernance, msg.sender);
    }

    /// @notice Rotates the emergency Safe without transferring governance settings.
    function setSafe(address newSafe) external onlyGovernance {
        if (newSafe == address(0)) revert HedgeCheck(38);
        address previousSafe = safe;
        safe = newSafe;
        emit SafeUpdated(previousSafe, newSafe);
    }

    /// @notice Executes the exact HEDGE_ONLY or HF_REPAIR action currently authorized by RangeStrategyEngine.
    /// @dev Permissionless; keepers submit no target debt, price, score or range. Gas-capped ordinary callers
    ///      use this mixed entry point; emergency fee exemptions use repairHealthFactor() below.
    function adjustHedge() external nonReentrant {
        _executeCanonicalHedge();
    }

    /// @notice Executes only a currently authorized HF_REPAIR action.
    /// @dev Dedicated permissionless selector for pause/gas exemptions. It derives eligibility directly from
    ///      live Aave account data, so a strategy-engine failure cannot block safety repair and a late transaction
    ///      can never fall through to HEDGE_ONLY after another keeper has already restored the HF.
    function repairHealthFactor() external nonReentrant {
        _repairHealthFactor(msg.sender);
    }

    function _executeCanonicalHedge() private {
        if (rangeManager == address(0) || adjustHedgeBps == 0) revert HedgeCheck(40);
        _refreshRangePriceCache();
        (uint8 rawAction, bytes32 decisionHash, uint64 checkpointTimestamp, bool protocolBotCaller) =
            DnDepositLib.hedgeStrategyDecision(rangeManager, address(this), msg.sender);
        IRangeStrategyEngine.Action action = IRangeStrategyEngine.Action(rawAction);
        IRangeStrategyEngine engine = IRangeManagerHedge(rangeManager).strategyEngine();

        if (action == IRangeStrategyEngine.Action.HF_REPAIR) {
            engine.recordExecution(decisionHash, action, msg.sender);
            _repairHealthFactor(msg.sender);
            return;
        }

        if (action != IRangeStrategyEngine.Action.HEDGE_ONLY) revert HedgeCheck(44);
        if (protocolBotCaller && block.timestamp < uint256(checkpointTimestamp) + MAIN_BOT_KEEPER_DELAY) {
            revert HedgeCheck(41);
        }
        engine.recordExecution(decisionHash, action, msg.sender);
        this.executeHedgeAdjustment(msg.sender, true, true);
    }

    /// @notice Atomically synchronizes debt after RangeManager minted a newly selected DN range.
    /// @dev This path is part of RANGE_AND_HEDGE and cannot be called independently or earn a second bounty.
    function syncAfterRangeChange(address keeper) external nonReentrant {
        if (msg.sender != rangeManager) revert HedgeCheck(4);
        this.executeHedgeAdjustment(keeper, false, false);
    }

    function _repairHealthFactor(address keeper) private {
        (, uint256 debtBaseBefore,,,, uint256 hfBefore) = pool.getUserAccountData(address(this));
        (uint256 directRepair, uint256 flashRepair) = DnDepositLib.aaveHfRepairAmounts();
        if (directRepair == 0 && flashRepair == 0) revert HedgeCheck(44);
        if (directRepair > 0) _doRepayDebt(directRepair);
        if (flashRepair > 0) {
            _flashLoanActive = true;
            pool.flashLoanSimple(
                address(this), address(weth), flashRepair, abi.encode(flashRepair, 0, false, address(0), 0), 0
            );
            _flashLoanActive = false;
        }
        _requireHfMin();
        (, uint256 debtBaseAfter,,,, uint256 hfAfter) = pool.getUserAccountData(address(this));
        uint256 debtRepaidBase = debtBaseBefore > debtBaseAfter ? debtBaseBefore - debtBaseAfter : 0;
        bool bountyEligible = debtRepaidBase >= uint256(hfRepairBountyMinUsd);
        if (bountyEligible && treasuryAddress != address(0)) {
            try IHedgeTreasury(treasuryAddress).payHedgeBounty(keeper) {} catch {}
        }
        emit HealthFactorRepaired(hfBefore, hfAfter, debtRepaidBase, bountyEligible, keeper);
    }

    /// @dev Shared settlement entry point. It is externally dispatched to prevent the large Aave path from being
    ///      duplicated by the optimizer, but only this contract may invoke it from a nonReentrant parent action.
    function executeHedgeAdjustment(address keeper, bool enforceThresholds, bool payBounty) external {
        if (msg.sender != address(this)) revert HedgeCheck(4);
        uint256 tokenId;
        if (enforceThresholds) {
            tokenId = IRangeManagerHedge(rangeManager).prepareHedgeAdjustment();
        } else {
            _refreshRangePriceCache();
            uint256[] memory positions = IRangeManagerHedge(rangeManager).getOwnerPositions();
            if (positions.length != 1) revert HedgeCheck(42);
            tokenId = positions[0];
        }
        if (tokenId == 0) revert HedgeCheck(42);

        (uint256 token0InLP, int24 tickLower, int24 tickUpper) =
            DnDepositLib.aaveLpToken0AndTicks(tokenId, lpPositionManager, lpPool);
        if (tickUpper <= tickLower) revert HedgeCheck(61);

        // 1b. audit V1 (V3-R4 Point 2) : garde anti-manipulation du prix LP. token0InLP derive du slot0 ; si le
        // pool a ete pousse loin du ratio oracle token0/token1, on refuse de reajuster (sinon repay inutile +
        // bounty + churn AAVE + MEV). Le cache RM vient d'etre rafraichi par prepareHedgeAdjustment().
        (uint160 sqrtPriceX96Now, int24 currentTickNow,,,,,) = lpPool.slot0();
        DnDepositLib.aaveRequireLpNotDeviated(
            rangeManager,
            lpPool,
            sqrtPriceX96Now,
            currentTickNow,
            maxHedgeDeviationBps,
            volatileDecimals,
            stableDecimals
        );

        // 2. Cible de SHORT (DN strict par defaut) : targetShort = hedgeTargetBps/10000 * token0InLP.
        //    Hors range haut, token0InLP peut etre nul. Le repay courant est alors refuse : le rebalance
        //    atomique doit conserver la dette existante et reconstruire la position centree. La reparation
        //    urgente du HF reste disponible plus haut, independamment de cette garde.
        //    token0 peut etre WETH, WBTC ou tout autre volatil de la pool ; les decimales viennent de la config.
        uint256 targetShort = (token0InLP * uint256(hedgeTargetBps)) / 10000;

        // 3. SHORT NET EFFECTIF (signe) = dette - token0 libre (HM) - token0 libre (RM), filtre dust sur LES DEUX.
        //    int256 OBLIGATOIRE : si idle > dette (ex. donation), effectiveShort < 0 => sous-hedge AGGRAVE.
        //    Anti-grief donation : on ne compte que la PART AU-DELA du seuil dust (pas tout-ou-rien), et on
        //    filtre AUSSI le token0 du HedgeManager (sinon une donation au HM force un sous-hedge artificiel = DoS).
        (uint256 currentDebtWeth, int256 effectiveShort) =
            DnDepositLib.aaveEffectiveShort(address(variableDebtWeth), address(weth), rangeManager, donationDustToken0);

        // Une exposition nette negative signifie que les soldes token0 idle depassent la dette (donation,
        // fees non reinvesties ou etat transitoire). Ne jamais emprunter un montant dicte par ces soldes:
        // le rebalance atomique doit d'abord les integrer a la composition LP.
        if (effectiveShort < 0) revert HedgeCheck(57);
        bool borrowed = effectiveShort < int256(targetShort);
        uint256 diff =
            borrowed ? uint256(int256(targetShort) - effectiveShort) : uint256(effectiveShort - int256(targetShort));
        if (targetShort == 0) revert HedgeCheck(44);
        uint256 driftBps = (diff * 10000) / targetShort;
        if (
            enforceThresholds && block.timestamp < uint256(lastHedgeAdjustAt) + uint256(hedgeAdjustCooldown)
                && driftBps < uint256(criticalHedgeBps)
        ) revert HedgeCheck(41);
        if (enforceThresholds && driftBps < uint256(adjustHedgeBps)) revert HedgeCheck(44);
        bool bountyEligible =
            DnDepositLib.rawDebtDriftExceeds(currentDebtWeth, targetShort, adjustHedgeBps, donationDustToken0);

        if (diff == 0) {
            _requireHfMin();
            return;
        }

        if (borrowed) {
            _increaseEffectiveShort(diff);
        } else {
            // Repay d'abord grace au flash loan, puis seulement retirer le collateral rendu disponible.
            _flashLoanActive = true;
            pool.flashLoanSimple(address(this), address(weth), diff, abi.encode(diff, 0, false, address(0), 0), 0);
            _flashLoanActive = false;
        }

        // Reset du cooldown : un vrai ajustement du delta vient d'avoir lieu.
        lastHedgeAdjustAt = uint64(block.timestamp);

        _rebuildReserve();

        _requireHfMin();

        // Bounty silent, uniquement apres correction et post-checks complets.
        if (payBounty && bountyEligible && treasuryAddress != address(0)) {
            try IHedgeTreasury(treasuryAddress).payHedgeBounty(keeper) {} catch {}
        }

        emit HedgeAdjusted(currentDebtWeth, targetShort, borrowed, keeper);
    }

    /// @dev Apres un repay, libere le collateral AAVE excedentaire (au-dela du HF cible) vers ce
    ///      contrat, ou il reste comme reserve (sert aux futurs swaps repay). N'envoie RIEN ailleurs.
    ///      Tout est en base AAVE (8 decimales) ; garde-fou: ne libere que si le HF projete >= cible.
    function _rebuildReserve() private {
        _refreshRangePriceCache();
        uint256 excessStable = DnDepositLib.aaveReserveExcessStable(
            address(pool), address(aTokenUsdc), liqThresholdBps, operationalHfTargetBps()
        );
        if (excessStable == 0) return;
        pool.withdraw(address(usdc), excessStable, address(this));
    }

    /// @dev Refresh fail-closed du cache oracle/slot0 RangeManager avant les conversions AAVE base -> token1.
    ///      Le HedgeManager doit être autorise comme executor RangeManager dans le batch Safe DN.
    ///      En emergency partiel, ce choix privilegie la securite comptable : oracle indisponible => revert/retry
    ///      plutot qu'un remboursement calcule sur un prix potentiellement obsolete.
    function _refreshRangePriceCache() private {
        IRangeManagerHedge(rangeManager).refreshPriceCache();
    }

    /// @dev Snapshot des reserves idle AVANT settlement. `wethReceived` vient du burn LP courant et ne doit
    ///      pas etre inclus dans la reserve partagee entre tous les users.
    function _idleBeforeSettlement(uint256 wethReceived) private view returns (uint256 idleWeth, uint256 idleUsdc) {
        uint256 wethBal = weth.balanceOf(address(this));
        idleWeth = wethBal > wethReceived ? wethBal - wethReceived : 0;
        idleUsdc = usdc.balanceOf(address(this));
    }

    function _sendIdleShare(uint256 idleWethBefore, uint256 idleUsdcBefore, uint256 proportionBps, address recipient)
        private
    {
        uint256 share = (idleWethBefore * proportionBps) / SHARE_SCALE;
        if (share > 0) weth.safeTransfer(recipient, share);
        share = (idleUsdcBefore * proportionBps) / SHARE_SCALE;
        if (share > 0) usdc.safeTransfer(recipient, share);
    }

    /// @dev Plafond token1 (anti-sandwich) pour acheter `wethNeeded` token0 : coût théorique oracle majoré
    ///      du slippage toléré. Utilisé par les callbacks flash loan de settlement et d'ajustement.
    function _oracleMaxUsdcForWeth(uint256 wethNeeded)
        private
        returns (uint256 amountInMaximum, uint160 sqrtPriceLimitX96)
    {
        _refreshRangePriceCache();
        (amountInMaximum, sqrtPriceLimitX96) = DnDepositLib.aaveOracleMaxToken1ForToken0(
            wethNeeded, rangeManager, volatileDecimals, stableDecimals, swapSlippageBps, address(usdc) < address(weth)
        );
    }

    /// @dev Finishes a permissionless HF repair after the flash-loaned token0 has repaid debt.
    ///      Only collateral made safely withdrawable by that repay may fund the oracle-bounded swap.
    function _completeHfRepair(uint256 flashOwed) private {
        (uint256 amountInMaximum, uint160 sqrtPriceLimitX96) = _oracleMaxUsdcForWeth(flashOwed);
        uint256 budget = usdc.balanceOf(address(this));
        (uint256 capped, uint256 toWithdraw) = DnDepositLib.aaveHfSafeSwapBudget(
            budget, amountInMaximum, address(pool), address(aTokenUsdc), liqThresholdBps, operationalHfTargetBps()
        );
        if (toWithdraw > 0) pool.withdraw(address(usdc), toWithdraw, address(this));
        if (capped < amountInMaximum || usdc.balanceOf(address(this)) < amountInMaximum) revert HedgeCheck(58);
        if (
            DnDepositLib.aaveExactOutput(
                address(swapRouter),
                address(usdc),
                address(weth),
                swapPoolFee,
                flashOwed,
                amountInMaximum,
                sqrtPriceLimitX96
            ) != flashOwed
        ) revert HedgeCheck(59);
    }

    /// @dev Tente de corriger un sous-hedge sans modifier la LP: emprunte token0, le vend integralement avec
    ///      protection oracle/spot/TWAP, puis fournit le produit token1 comme collateral. Le delta net
    ///      augmente exactement de `amount0`; une execution partielle ou un HF final sous la cible fait revert
    ///      toute la tx. Le repli de liveness est le rebalance atomique, qui réduit token0InLP sans ajouter de dette.
    function _increaseEffectiveShort(uint256 amount0) private {
        _refreshRangePriceCache();
        (uint256 minOut, uint160 sqrtLimit) = DnDepositLib.aaveOracleMinToken1ForToken0(
            amount0, rangeManager, volatileDecimals, stableDecimals, swapSlippageBps, address(weth) < address(usdc)
        );
        // A previous debt reduction can leave token1 outside Aave as the shared operating reserve. Supply it
        // before borrowing so valid headroom is not hidden from Aave, then _rebuildReserve() restores the
        // configured operating buffer after the atomic borrow/swap/supply sequence.
        _supplyStable(usdc.balanceOf(address(this)));
        uint256 token0Before = weth.balanceOf(address(this));
        pool.borrow(address(weth), amount0, 2, 0, address(this));
        uint256 amount1 = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(usdc),
                fee: swapPoolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount0,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: sqrtLimit
            })
        );
        if (weth.balanceOf(address(this)) != token0Before) revert HedgeCheck(46);
        _supplyStable(amount1);
    }

    function _supplyStable(uint256 amount) private {
        if (amount > 0) pool.supply(address(usdc), amount, address(this), 0);
    }

    /// @notice Close entire position: repay all debt + withdraw all collateral
    /// @dev Used for full teardown. The ABI parameter is retained, but the destination is fixed to RangeManager.
    ///      Requires enough WETH on this contract to repay full debt.
    /// @param recipient Address to receive all recovered USDC
    function closeAll(address recipient) external onlySafe nonReentrant {
        if (recipient != rangeManager) revert HedgeCheck(29);

        _closePosition(recipient);
    }

    /// @notice Send an EXACT amount of WETH to the RangeManager (refonte DN : dépôt/solveur hedgé).
    /// @dev onlySafeOrVault. Montant EXACT (= le WETH nouvellement emprunté), destination FIGÉE au RM.
    ///      Évite d'injecter un buffer/donation préexistant dans la LP (post-check faussé / DoS donation).
    /// @param amount Montant EXACT de WETH à envoyer (wei)
    /// @param to Destination — DOIT valoir rangeManager
    function sweepWethAmount(uint256 amount, address to) external onlySafeOrVault nonReentrant {
        if (to != rangeManager || rangeManager == address(0)) revert HedgeCheck(29);
        if (amount == 0) revert HedgeCheck(48);
        if (weth.balanceOf(address(this)) < amount) revert HedgeCheck(49);
        weth.safeTransfer(to, amount);
        emit SweepWeth(to, amount);
    }

    // ===== ADMIN =====

    /// @notice Emergency-only pause for new AAVE hedge openings.
    /// @dev This is NOT the protocol PauseController. When enabled, it blocks supplyAndBorrow()
    ///      only. Settlement, adjustHedge, repay/withdraw, close and sweeps remain available so the
    ///      active position can be maintained or de-risked.
    function setPaused(bool _paused) external {
        // Phase 1: governance == Safe. Phase 2: Safe peut arreter, gouvernance seule peut reprendre.
        if (msg.sender != governance) {
            if (msg.sender != safe) revert HedgeCheck(1);
            if (!_paused) revert HedgeCheck(2);
        }
        paused = _paused;
        emit Paused(_paused);
    }

    // ===== VIEW FUNCTIONS =====

    /// @notice Get full hedge data for dashboard
    /// @return totalCollateralBase Token1 collateral valued with the RangeManager oracle (USD, 8 decimals)
    /// @return totalDebtBase Token0 debt valued with the RangeManager oracle (USD, 8 decimals)
    /// @return healthFactor Health factor in 1e18 scale
    /// @return availableBorrowsBase Available borrows in base currency (USD, 8 decimals)
    function getHedgeData()
        external
        view
        returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 healthFactor, uint256 availableBorrowsBase)
    {
        (,, availableBorrowsBase,,, healthFactor) = pool.getUserAccountData(address(this));
        (totalCollateralBase, totalDebtBase) = DnDepositLib.aaveHedgeValuesUsd(
            address(aTokenUsdc), address(variableDebtWeth), rangeManager, stableDecimals, volatileDecimals
        );
    }

    /// @notice Stable reserve and live Aave limits consumed by RangeStrategyEngine projections.
    function getStrategyReserveData()
        external
        view
        returns (uint256 idleStable, uint16 operationalTargetBps, uint16 liveLtvBps)
    {
        (,,,, uint256 liveLtv,) = pool.getUserAccountData(address(this));
        idleStable = usdc.balanceOf(address(this));
        operationalTargetBps = operationalHfTargetBps();
        if (liveLtv == 0 && operationalTargetBps > 0) {
            liveLtv = uint256(liqThresholdBps) * 10_000 / operationalTargetBps;
        }
        liveLtvBps = uint16(liveLtv);
    }

    /// @notice Get token0 balance held on this contract (ready for LP or repay). ABI name is historical.
    function getWethBalance() external view returns (uint256) {
        return weth.balanceOf(address(this));
    }

    /// @notice Get token1 balance held on this contract (ready to supply or send). ABI name is historical.
    function getUsdcBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice Get current token0 debt (variable debt token balance). ABI name is historical.
    function getWethDebt() external view returns (uint256) {
        return variableDebtWeth.balanceOf(address(this));
    }

    // ===== INTERNAL =====

    /// @dev Settle hedge directly when enough token0 is available (no flash loan needed)
    function _settleDirectly(uint256 debtToRepay, uint256 proportionBps, bool isFullWithdraw, address recipient)
        internal
    {
        // Repay token0 debt
        if (isFullWithdraw) {
            pool.repay(address(weth), type(uint256).max, 2, address(this));
        } else if (debtToRepay > 0) {
            pool.repay(address(weth), debtToRepay, 2, address(this));
        }

        // Withdraw USDC collateral
        if (isFullWithdraw) {
            pool.withdraw(address(usdc), type(uint256).max, recipient);
        } else {
            // Calculate proportional USDC to withdraw based on current AAVE collateral.
            // We cannot use type(uint256).max here because remaining debt prevents
            // full collateral withdrawal (AAVE would revert with HF < 1).
            uint256 proportionalUsdc = DnDepositLib.aaveCollateralShare(address(aTokenUsdc), proportionBps);
            if (proportionalUsdc > 0) {
                uint256 usdcBefore = usdc.balanceOf(address(this));
                pool.withdraw(address(usdc), proportionalUsdc, address(this));
                uint256 usdcWithdrawn = usdc.balanceOf(address(this)) - usdcBefore;
                if (usdcWithdrawn > 0) {
                    usdc.safeTransfer(recipient, usdcWithdrawn);
                }
            }
        }
    }

    /// @dev Internal close position logic used by closeAll.
    ///      If idle token0 is insufficient, use the same AAVE flash-loan settlement path as withdrawals.
    function _closePosition(address recipient) internal {
        uint256 totalDebt = variableDebtWeth.balanceOf(address(this));
        uint256 wethBalance = weth.balanceOf(address(this));
        if (totalDebt > 0) {
            if (wethBalance >= totalDebt) {
                pool.repay(address(weth), type(uint256).max, 2, address(this));
            } else {
                _flashLoanActive = true;
                pool.flashLoanSimple(
                    address(this),
                    address(weth),
                    totalDebt - wethBalance,
                    abi.encode(totalDebt, SHARE_SCALE, true, recipient, 0),
                    0
                );
                _flashLoanActive = false;
            }
        }

        // Withdraw all USDC collateral (only if there is collateral)
        (uint256 collateralBase,,,,,) = pool.getUserAccountData(address(this));
        if (collateralBase > 0) {
            pool.withdraw(address(usdc), type(uint256).max, address(this));
        }

        // Send all USDC to recipient
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcBalance > 0) {
            usdc.safeTransfer(recipient, usdcBalance);
        }
        wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 0) weth.safeTransfer(recipient, wethBalance);

        emit CloseAll(recipient, usdcBalance);
    }
}
