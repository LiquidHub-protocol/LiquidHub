// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IAaveV3Pool.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "./DnDepositLib.sol";

/// @dev Interface minimale du RangeManager pour lire la liste des positions LP (adjustHedge).
interface IRangeManagerHedge {
    function getOwnerPositions() external view returns (uint256[] memory);
    function refreshPriceCache() external;
}

/// @dev Interface minimale du Treasury pour le hedge bounty.
interface IHedgeTreasury {
    function payHedgeBounty(address keeper) external;
}

/// @dev Pour lire les decimales d'un token / oracle (generique, pas de hard-code).
interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title AaveHedgeManager - AAVE V3 hedge for Delta Neutral strategy
/// @notice Manages supply/borrow/repay/withdraw on AAVE V3 for the DN pool hedge.
///         Supports atomic settlement via flash loan for user withdrawals.
/// @dev Phase 1: Safe owns settings and operations through the Safe module path.
///      Phase 2: Timelock owns settings, botModule executes recurring operations directly,
///      and Safe keeps only emergency/pause powers. settleProportional is vault-only.
contract AaveHedgeManager is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===== CONTROLLERS =====
    address private safe; // emergency/pause controller (Safe in Phase 1 and Phase 2)
    address private governance; // settings owner (Safe in Phase 1, Timelock in Phase 2)
    address private botModule; // direct execution module once Phase 2 direct mode is enabled

    // ===== IMMUTABLES =====
    address public immutable vault;
    IAaveV3Pool public immutable pool;
    IERC20 public immutable usdc;
    IERC20 public immutable weth;
    IERC20 public immutable variableDebtWeth;
    ISwapRouter public immutable swapRouter;
    uint24 public immutable swapPoolFee;
    uint32 public immutable oracleMaxAge;

    // ===== STATE =====
    bool public paused;
    bool private _flashLoanActive;

    // ===== ADJUST HEDGE (permissionless, gouvernance) =====
    address public rangeManager; // pour lire la liste des positions (setter post-deploy)
    address public treasuryAddress; // pour le hedge bounty (setter post-deploy)
    INonfungiblePositionManager public lpPositionManager; // NFT manager Uniswap V3 (setter)
    IUniswapV3Pool public lpPool; // pool LP token0/token1 (setter)
    AggregatorV3Interface public ethUsdFeed; // oracle Chainlink prix de l'actif volatil (anti-MEV pour le swap repay)
    uint16 public adjustHedgeBps; // seuil de drift en bps (borne 100..2000) pour declencher un reajustement
    uint16 public swapSlippageBps; // slippage max tolere sur le swap stable->volatil (ex 100 = 1%)
    uint8 public oracleDecimals; // decimales de l'oracle prix (Chainlink = 8), lu du feed au setter
    // Reconstitution de reserve apres repay (HF cible). L'USDC libere reste sur ce contrat (reserve).
    uint16 public reserveHfTargetBps; // HF cible apres reconstitution, ex 14000 = 1.4
    uint16 public liqThresholdBps; // seuil de liquidation du collateral (AAVE), ex 8500 = 0.85
    // Cooldown on-chain entre deux reajustements (borrow OU repay). S'applique aux KEEPERS via
    // adjustHedge() permissionless ET au bot quand il passe par adjustHedge(). Le canal botModule
    // direct (borrowMore/repayDebt) N'EST PAS bloque par ce cooldown : c'est la voie surge du bot.
    // Tout reajustement (keeper ou bot) met a jour lastHedgeAdjustAt pour synchroniser le cooldown.
    uint32 public hedgeAdjustCooldown; // secondes entre deux adjustHedge() (0 = desactive)
    uint64 public lastHedgeAdjustAt; // timestamp du dernier reajustement (borrow ou repay)
    // audit V1 (V3-R4 Point 2) : ecart MAX tolere entre le prix LP (slot0 du pool) et le prix ORACLE
    // Chainlink (ethUsdFeed, l'actif volatil en USD) AVANT de calculer wethInLP dans adjustHedge().
    // adjustHedge() est permissionless : sans cette garde, un prix LP manipule (slot0) gonfle/reduit
    // wethInLP -> borrow/repay inutile -> churn AAVE + bounty vole + exposition MEV. En bps. 0 = desactive
    // (retrocompat / mode urgence). Hypothese : le stable colle a $1 (sinon les barrieres RangeManager cote
    // deposit/withdraw bloquent deja). Borne au setter : <= 1000 (10%).
    uint16 public maxHedgeDeviationBps;
    // Decimales des tokens lues directement depuis les contrats au constructeur (zero hard-code,
    // toujours disponibles des le deploiement, generiques WETH/USDC ou WBTC/USDT ou toute paire).
    uint8 public immutable volatileDecimals; // decimales du token volatil emprunte (token0)
    uint8 public immutable stableDecimals; // decimales du token stable collateral (token1)
    uint256 private constant SHARE_SCALE = 1e18; // precision settlement proportional aux shares

    // ===== DELTA-NEUTRAL STRICT (refonte hedge : pilotage sur le SHORT NET EFFECTIF) =====
    // Le hedge ne se pilote PLUS sur la dette brute mais sur effectiveShort = dette - WETH libre (HM + RM).
    // Cible = hedgeTargetBps/10000 * wethInLP (defaut 10000 = 100% = DN strict ; le WETH long de la LP est
    // entierement couvert par la dette short). H_opt (variance-min ~50%) RETIRE : trompeur pour un produit
    // "Delta Neutral". Le WETH emprunte ne doit JAMAIS rester idle (il annule la dette) -> integre a la LP au
    // mint (B1), et le repay over-hedge achete le WETH AU MARCHE (jamais depuis le buffer idle).
    uint16 public hedgeTargetBps; // cible de hedge en bps du WETH LP (defaut 10000 = 100%, borne 5000..10000)
    // Seuil dust on-chain (en token0/volatil) : une donation de WETH au RangeManager gonfle wethIdleRM et
    // fausse effectiveShort. En-dessous de ce seuil, le WETH libre du RM est IGNORE (anti-grief donation).
    uint256 public donationDustToken0;

    // Custom error sous-hedge : adjustHedge() permissionless ne corrige PAS le sous-hedge (il faudrait
    // modifier la LP, ce qu'il ne peut pas). Il REVERT -> le staticCall du keeper l'attrape (0 gas, 0 bounty).
    // La correction du sous-hedge passe par le chemin rebalance() permissionless (solveur). int256 : effective peut etre < 0.
    error UnderHedged(uint256 targetShort, int256 effectiveShort);
    error BadHealthFactor();

    event HedgeAdjusted(uint256 oldDebtWeth, uint256 targetShort, bool borrowed, address indexed keeper);
    event HedgeAdjustCooldownConfigured(uint32 cooldownSeconds);
    event MaxHedgeDeviationConfigured(uint16 bps); // audit V1 (V3-R4 Point 2)
    event AdjustHedgeConfigured(address rangeManager, address treasury, uint16 adjustHedgeBps);
    event HedgeTargetConfigured(uint16 hedgeTargetBps);
    event DonationDustConfigured(uint256 donationDustToken0);
    event ReserveRebuilt(uint256 stableReleasedToReserve);

    // ===== EVENTS =====
    event SupplyAndBorrow(uint256 usdcSupplied, uint256 wethBorrowed);
    event BorrowMore(uint256 wethBorrowed);
    event RepayAndWithdraw(uint256 wethRepaid, uint256 usdcWithdrawn);
    event RepayDebt(uint256 wethRepaid);
    event WithdrawCollateral(uint256 usdcWithdrawn, address to);
    // CloseAll est émis par _closePosition pour les DEUX chemins (closeAll ET emergencyClose). L'event
    // EmergencyClose (jamais émis) RETIRÉ (audit LOW : event mort). Le monitoring suit CloseAll.
    event CloseAll(address recipient, uint256 usdcSent);
    event SweepWeth(address to, uint256 amount);
    event SweepUsdc(address to, uint256 amount);
    event Paused(bool paused);
    event SettleProportional(uint256 wethUsed, uint256 proportionX18, address recipient, uint256 usdcRecovered);

    // ===== MODIFIERS =====
    modifier onlySafe() {
        require(msg.sender == safe, "E01");
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "E02");
        _;
    }

    modifier onlyBotModule() {
        address module = botModule;
        require(msg.sender == (module == address(0) ? safe : module), "E03");
        _;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "E04");
        _;
    }

    // REFONTE DN : le Vault peut ouvrir/réduire le hedge atomiquement au dépôt permissionless ET dans le
    // rebalance-solveur permissionless. Moindre privilege : SEULES les fonctions a montant exact + destination
    // figee (RM) sont en onlySafeOrVault (supplyAndBorrow, sweepWethAmount, repayDebt, repayAndWithdraw,
    // withdrawCollateral). borrowMore/sweep all passent par onlyBotModule ; les setters restent onlyGovernance.
    modifier onlySafeOrVault() {
        address module = botModule;
        require(msg.sender == vault || msg.sender == (module == address(0) ? safe : module), "E05");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "E06");
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
    /// @param _oracleMaxAge Max age accepted for the volatile/USD oracle used by hedge swaps.
    constructor(
        address _safe,
        address _vault,
        address _pool,
        address _usdc,
        address _weth,
        address _variableDebtWeth,
        address _swapRouter,
        uint24 _swapPoolFee,
        uint32 _oracleMaxAge
    ) {
        require(_safe != address(0), "E07");
        require(_vault != address(0), "E08");
        require(_pool != address(0), "E09");
        require(_usdc != address(0), "E10");
        require(_weth != address(0), "E11");
        require(_variableDebtWeth != address(0), "E12");
        require(_swapRouter != address(0), "E13");
        require(_swapPoolFee > 0, "E14");
        require(_oracleMaxAge >= 3600 && _oracleMaxAge <= 172800, "E15");

        safe = _safe;
        governance = _safe;
        vault = _vault;
        pool = IAaveV3Pool(_pool);
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);
        variableDebtWeth = IERC20(_variableDebtWeth);
        swapRouter = ISwapRouter(_swapRouter);
        swapPoolFee = _swapPoolFee;
        oracleMaxAge = _oracleMaxAge;
        reserveHfTargetBps = 11000;

        // Lire les decimales directement des tokens (generique : WETH/USDC, WBTC/USDT, etc.)
        volatileDecimals = IDecimals(_weth).decimals();
        stableDecimals = IDecimals(_usdc).decimals();

        // Approve max USDC and WETH to AAVE Pool for supply/repay
        IERC20(_usdc).safeApprove(_pool, type(uint256).max);
        IERC20(_weth).safeApprove(_pool, type(uint256).max);
        // Approve max USDC to SwapRouter for flash loan USDC→WETH swap
        IERC20(_usdc).safeApprove(_swapRouter, type(uint256).max);
    }

    // ===== ATOMIC SETTLEMENT (called by Vault during withdraw) =====

    /// @notice Settle AAVE hedge proportionally during atomic withdraw
    /// @dev Called by the vault after LP burn. WETH must be transferred to this contract before calling.
    ///      If WETH received < debt to repay, initiates flash loan to cover shortfall.
    /// @param wethReceived Amount of WETH transferred by vault (from LP burn)
    /// @param proportionBps Proportion of total position to settle (1e18 = 100%)
    /// @param isFullWithdraw True if this is a full withdrawal (close entire position)
    /// @param recipient Address to send recovered USDC (typically the vault)
    function settleProportional(uint256 wethReceived, uint256 proportionBps, bool isFullWithdraw, address recipient)
        external
        onlyVault
        whenNotPaused
        nonReentrant
    {
        require(recipient != address(0), "bad");
        require(proportionBps > 0 && proportionBps <= SHARE_SCALE, "E16");
        (uint256 idleWethBefore, uint256 idleUsdcBefore) = _idleBeforeSettlement(wethReceived);

        // Get current WETH debt
        uint256 totalDebt = variableDebtWeth.balanceOf(address(this));

        // If no debt, just send back any USDC collateral proportionally
        if (totalDebt == 0) {
            uint256 usdcSwept = _settleNoDebt(wethReceived, proportionBps, isFullWithdraw, recipient);
            if (!isFullWithdraw) _sendIdleShare(idleWethBefore, idleUsdcBefore, proportionBps, recipient);
            emit SettleProportional(0, proportionBps, recipient, usdcSwept);
            return;
        }

        // Calculate debt to repay
        uint256 debtToRepay;
        if (isFullWithdraw) {
            debtToRepay = totalDebt;
        } else {
            debtToRepay = (totalDebt * proportionBps) / SHARE_SCALE;
        }

        if (wethReceived >= debtToRepay) {
            // Happy path: enough WETH to repay directly
            _settleDirectly(debtToRepay, proportionBps, isFullWithdraw, recipient);
        } else {
            // Shortfall: need flash loan + USDC→WETH swap to cover repayment
            // Flash loan the exact shortfall. The executeOperation callback will:
            //   1. Repay AAVE debt with wethFromLP + flashLoaned WETH
            //   2. Withdraw USDC collateral from AAVE
            //   3. Swap just enough USDC → WETH to repay flash loan (amount + premium)
            //   4. Send remaining USDC to vault
            uint256 shortfall = debtToRepay - wethReceived;

            _flashLoanActive = true;
            bytes memory params =
                abi.encode(debtToRepay, proportionBps, isFullWithdraw, recipient, isFullWithdraw ? 0 : idleWethBefore);
            pool.flashLoanSimple(address(this), address(weth), shortfall, params, 0);
            _flashLoanActive = false;
        }

        // Partial withdraw: never sweep pre-existing idle WETH from the HedgeManager.
        if (isFullWithdraw) {
            uint256 remainingWeth = weth.balanceOf(address(this));
            if (remainingWeth > 0) weth.safeTransfer(recipient, remainingWeth);
        } else {
            if (wethReceived > debtToRepay) {
                weth.safeTransfer(recipient, wethReceived - debtToRepay);
            }
            _sendIdleShare(idleWethBefore, idleUsdcBefore, proportionBps, recipient);
        }

        // On full withdraw, sweep any USDC residual (e.g. stuck after a failed borrowMore)
        // The funds belong to the sole remaining user
        if (isFullWithdraw) {
            uint256 usdcResidual = usdc.balanceOf(address(this));
            if (usdcResidual > 0) {
                usdc.safeTransfer(recipient, usdcResidual);
            }
        }

        emit SettleProportional(wethReceived, proportionBps, recipient, 0);
    }

    /// @notice Emergency settle called by vault during EmergencyRecoverUser
    /// @dev Same as settleProportional but works even when paused.
    ///      Uses the same flash loan + swap logic as executeOperation.
    function emergencySettleForVault(
        uint256 wethReceived,
        uint256 proportionBps,
        bool isFullWithdraw,
        address recipient
    ) external onlyVault nonReentrant {
        require(recipient != address(0), "bad");
        require(proportionBps > 0 && proportionBps <= SHARE_SCALE, "E16");
        (uint256 idleWethBefore, uint256 idleUsdcBefore) = _idleBeforeSettlement(wethReceived);

        uint256 totalDebt = variableDebtWeth.balanceOf(address(this));

        if (totalDebt == 0) {
            _settleNoDebt(wethReceived, proportionBps, isFullWithdraw, recipient);
            if (!isFullWithdraw) _sendIdleShare(idleWethBefore, idleUsdcBefore, proportionBps, recipient);
            return;
        }

        uint256 debtToRepay = isFullWithdraw ? totalDebt : (totalDebt * proportionBps) / SHARE_SCALE;

        if (wethReceived >= debtToRepay) {
            _settleDirectly(debtToRepay, proportionBps, isFullWithdraw, recipient);
        } else {
            // Flash loan the exact shortfall (swap covers repayment in executeOperation)
            uint256 shortfall = debtToRepay - wethReceived;
            _flashLoanActive = true;
            bytes memory params =
                abi.encode(debtToRepay, proportionBps, isFullWithdraw, recipient, isFullWithdraw ? 0 : idleWethBefore);
            pool.flashLoanSimple(address(this), address(weth), shortfall, params, 0);
            _flashLoanActive = false;
        }

        if (isFullWithdraw) {
            uint256 remainingWeth = weth.balanceOf(address(this));
            if (remainingWeth > 0) weth.safeTransfer(recipient, remainingWeth);
        } else {
            if (wethReceived > debtToRepay) {
                weth.safeTransfer(recipient, wethReceived - debtToRepay);
            }
            _sendIdleShare(idleWethBefore, idleUsdcBefore, proportionBps, recipient);
        }

        // On full withdraw, sweep any USDC residual
        if (isFullWithdraw) {
            uint256 usdcResidual = usdc.balanceOf(address(this));
            if (usdcResidual > 0) usdc.safeTransfer(recipient, usdcResidual);
        }
    }

    /// @notice AAVE V3 flash loan callback
    /// @dev Called by AAVE Pool during flashLoanSimple. Repays debt, withdraws collateral,
    ///      swaps USDC→WETH to cover flash loan repayment, then sends remaining USDC to vault.
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        require(msg.sender == address(pool), "E17");
        require(initiator == address(this), "E18");
        require(_flashLoanActive, "E19");
        require(asset == address(weth), "E20");

        (uint256 debtToRepay, uint256 proportionBps, bool isFullWithdraw, address recipient, uint256 protectedIdleWeth)
        = abi.decode(params, (uint256, uint256, bool, address, uint256));

        uint256 usdcBefore = usdc.balanceOf(address(this));

        // Step 1: Repay WETH debt (we now have wethFromLP + flashLoan amount)
        if (isFullWithdraw) {
            pool.repay(address(weth), type(uint256).max, 2, address(this));
        } else {
            pool.repay(address(weth), debtToRepay, 2, address(this));
        }

        // Step 2: Withdraw USDC collateral proportionally
        if (isFullWithdraw) {
            pool.withdraw(address(usdc), type(uint256).max, address(this));
        } else {
            // Calculate proportional USDC to withdraw based on current AAVE collateral.
            // After partial debt repay, remaining debt prevents full collateral withdrawal
            // (AAVE would revert with HF < 1). Use getUserAccountData to get actual collateral.
            (uint256 totalCollateralBase,,,,,) = pool.getUserAccountData(address(this));
            // totalCollateralBase: AAVE base currency (8 decimales). Conversion generique vers le
            // token stable via ses decimales reelles (lues au constructeur), gere stableDecimals </> 8.
            _refreshRangePriceCache();
            uint256 proportionalUsdc = (_aaveBaseToStable(totalCollateralBase) * proportionBps) / SHARE_SCALE;
            if (proportionalUsdc > 0) {
                pool.withdraw(address(usdc), proportionalUsdc, address(this));
            }
        }

        uint256 usdcRecovered = usdc.balanceOf(address(this)) - usdcBefore;

        // Step 3: Swap USDC → WETH to cover flash loan repayment
        // After repaying AAVE debt, AAVE needs amount + premium back. For partial settlements,
        // pre-existing idle WETH is protected so the current withdraw cannot be subsidized by reserves
        // that belong pro-rata to all users.
        uint256 flashLoanOwed = amount + premium;
        uint256 wethBalance = weth.balanceOf(address(this));

        uint256 wethRequired = flashLoanOwed + protectedIdleWeth;
        if (wethBalance < wethRequired) {
            uint256 wethNeeded = wethRequired - wethBalance;
            // SÉCURITÉ (audit V1 — High 3) : plafond anti-sandwich via oracle Chainlink (et NON
            // usdc.balanceOf entier). Sans ce plafond, ce swap (déclenché pendant un withdraw DN) était
            // sandwichable, au détriment direct du user qui retire. Même logique que _acquireWethForRepay.
            uint256 amountInMaximum = _oracleMaxUsdcForWeth(wethNeeded);
            if (amountInMaximum > usdcRecovered) amountInMaximum = usdcRecovered;
            require(amountInMaximum > 0, "E21");
            // exactOutputSingle: swap minimum USDC to get exactly wethNeeded WETH, plafonné à l'oracle.
            swapRouter.exactOutputSingle(
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: address(usdc),
                    tokenOut: address(weth),
                    fee: swapPoolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountOut: wethNeeded,
                    amountInMaximum: amountInMaximum,
                    sqrtPriceLimitX96: 0
                })
            );
        }
        // AAVE will pull flashLoanOwed WETH from this contract (max approve in constructor)

        // Step 4: Send only USDC attributable to this settlement, never pre-existing reserve.
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
    ///      préexistante sur le contrat serait fournie involontairement à AAVE (retour audit). onlySafeOrVault :
    ///      le Vault l'appelle au dépôt permissionless hedgé. Flow : Vault envoie USDC ici -> supply EXACT ->
    ///      borrow WETH -> WETH reste ici pour sweep (montant exact) vers la LP.
    /// @param collateralAmountUsdc Montant EXACT d'USDC à supply (doit être <= solde présent)
    /// @param borrowAmountWeth Montant de WETH à emprunter (wei)
    function supplyAndBorrow(uint256 collateralAmountUsdc, uint256 borrowAmountWeth)
        external
        onlySafeOrVault
        whenNotPaused
        nonReentrant
    {
        require(collateralAmountUsdc > 0, "E22");
        require(borrowAmountWeth > 0, "E23");
        require(usdc.balanceOf(address(this)) >= collateralAmountUsdc, "E24");

        // Supply EXACTEMENT collateralAmountUsdc (pas tout le solde)
        pool.supply(address(usdc), collateralAmountUsdc, address(this), 0);

        // Borrow WETH (variable rate = 2)
        pool.borrow(address(weth), borrowAmountWeth, 2, 0, address(this));
        _requireHfMin();

        emit SupplyAndBorrow(collateralAmountUsdc, borrowAmountWeth);
    }

    /// @notice Borrow additional WETH (after new collateral has been supplied)
    /// @dev Used when ETH exposure increases after rebalance or new deposit
    /// @param borrowAmountWeth Amount of WETH to borrow additionally
    function borrowMore(uint256 borrowAmountWeth) external onlyBotModule whenNotPaused nonReentrant {
        _doBorrowMore(borrowAmountWeth);
    }

    /// @dev Coeur de borrowMore, reutilise par adjustHedge (permissionless). Pas de modifier.
    function _doBorrowMore(uint256 borrowAmountWeth) private {
        require(borrowAmountWeth > 0, "E23");

        // Supply any pending USDC first (if vault sent more collateral)
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcBalance > 0) {
            pool.supply(address(usdc), usdcBalance, address(this), 0);
        }

        // Borrow more WETH
        pool.borrow(address(weth), borrowAmountWeth, 2, 0, address(this));
        _requireHfMin();

        // Repousser le cooldown adjustHedge: un reajustement (keeper OU bot via onlySafe) vient
        // d'avoir lieu, le prochain adjustHedge() permissionless devra attendre hedgeAdjustCooldown.
        lastHedgeAdjustAt = uint64(block.timestamp);

        emit BorrowMore(borrowAmountWeth);
    }

    function _requireHfMin() private view {
        (,,,,, uint256 hf) = pool.getUserAccountData(address(this));
        if (hf < uint256(reserveHfTargetBps) * 1e14) revert BadHealthFactor();
    }

    /// @notice Repay WETH debt and withdraw USDC collateral
    /// @dev Used after user withdrawal -- watcher sends WETH here, then calls this
    /// @param repayAmountWeth Amount of WETH to repay (must be on this contract)
    /// @param withdrawAmountUsdc Amount of USDC collateral to withdraw
    function repayAndWithdraw(uint256 repayAmountWeth, uint256 withdrawAmountUsdc)
        external
        onlySafeOrVault
        whenNotPaused
        nonReentrant
    {
        require(repayAmountWeth > 0 || withdrawAmountUsdc > 0, "E26");

        // Repay WETH debt
        if (repayAmountWeth > 0) {
            pool.repay(address(weth), repayAmountWeth, 2, address(this));
        }

        // Withdraw USDC collateral (stays on this contract for sweep)
        if (withdrawAmountUsdc > 0) {
            pool.withdraw(address(usdc), withdrawAmountUsdc, address(this));
        }
        _requireHfMin();

        emit RepayAndWithdraw(repayAmountWeth, withdrawAmountUsdc);
    }

    /// @notice Repay WETH debt only (no collateral withdrawal)
    /// @dev Used during rebalance when ETH exposure decreases
    /// @param repayAmountWeth Amount of WETH to repay
    function repayDebt(uint256 repayAmountWeth) external onlySafeOrVault whenNotPaused nonReentrant {
        _doRepayDebt(repayAmountWeth);
    }

    /// @dev Coeur de repayDebt, reutilise par adjustHedge (permissionless). Pas de modifier.
    ///      NE reset PAS lastHedgeAdjustAt : un repay depuis buffer (onlySafe, nettoyage bilan) ne change
    ///      PAS effectiveShort (dette -x ET idle -x) => ce n'est pas un ajustement delta, donc pas de reset
    ///      cooldown. Le reset est fait explicitement par adjustHedge() sur le chemin over-hedge corrige.
    function _doRepayDebt(uint256 repayAmountWeth) private {
        require(repayAmountWeth > 0, "E27");

        pool.repay(address(weth), repayAmountWeth, 2, address(this));

        emit RepayDebt(repayAmountWeth);
    }

    /// @notice Withdraw USDC collateral to a specific address
    /// @dev Used to send recovered collateral to users
    /// @param amountUsdc Amount of USDC to withdraw from AAVE
    /// @param to Destination address
    function withdrawCollateral(uint256 amountUsdc, address to) external onlySafeOrVault whenNotPaused nonReentrant {
        require(amountUsdc > 0, "E28");
        // SÉCURITÉ (audit V1) : destination FIGÉE au rangeManager (cf. sweepWeth/sweepUsdc). Le bot retire
        // du collatéral AAVE uniquement vers le RM (reconstitution réserve). Anti-exfiltration clé bot.
        require(to == rangeManager && rangeManager != address(0), "E29");

        pool.withdraw(address(usdc), amountUsdc, to);
        _requireHfMin();

        emit WithdrawCollateral(amountUsdc, to);
    }

    // ===== ADJUST HEDGE (permissionless) =====

    /// @notice Configure le reajustement permissionless du hedge (gouvernance, via Safe).
    /// @dev addrs : [0]=rangeManager [1]=treasury [2]=positionManager [3]=lpPool [4]=oracle prix volatil.
    ///      params : [0]=adjustHedgeBps(100..2000) [1]=swapSlippageBps(10..500) [2]=reserveHfTargetBps(11000..30000) [3]=liqThresholdBps(5000..9500).
    ///      Les decimales des tokens sont deja lues au constructeur ; celle de l'oracle est lue du feed ici.
    ///      Parametres groupes en tableaux pour eviter stack-too-deep.
    function setAdjustHedgeConfig(address[5] calldata addrs, uint16[4] calldata params) external onlyGovernance {
        require(
            addrs[0] != address(0) && addrs[2] != address(0) && addrs[3] != address(0) && addrs[4] != address(0), "E30"
        );
        require(params[0] >= 100 && params[0] <= 2000, "E31"); // 1% .. 20% (defaut 300 = 3%)
        require(params[1] >= 10 && params[1] <= 500, "E32");
        require(params[2] >= 11000 && params[2] <= 30000, "E33"); // 1.1 .. 3.0
        require(params[3] >= 5000 && params[3] <= 9500, "E34"); // 0.5 .. 0.95
        rangeManager = addrs[0];
        treasuryAddress = addrs[1];
        lpPositionManager = INonfungiblePositionManager(addrs[2]);
        lpPool = IUniswapV3Pool(addrs[3]);
        ethUsdFeed = AggregatorV3Interface(addrs[4]);
        oracleDecimals = IDecimals(addrs[4]).decimals(); // lu du feed (Chainlink = 8), generique
        adjustHedgeBps = params[0];
        swapSlippageBps = params[1];
        reserveHfTargetBps = params[2];
        liqThresholdBps = params[3];
        if (hedgeTargetBps == 0) hedgeTargetBps = 10000; // defaut DN strict si jamais configure
        // SECURITE (retour audit) : ne JAMAIS laisser ces deux protections desactivees par defaut.
        // adjustHedge() permissionless est dangereux sans cooldown (drain bounty/churn) ni garde de
        // deviation slot0 (manipulation de targetShort). On pose des defauts surs si non encore configures
        // (le setter dedie peut les ajuster ensuite).
        if (hedgeAdjustCooldown == 0) hedgeAdjustCooldown = 1200; // 20 min par defaut
        if (maxHedgeDeviationBps == 0) maxHedgeDeviationBps = 500; // 5% par defaut
        emit AdjustHedgeConfigured(addrs[0], addrs[1], params[0]);
    }

    /// @notice Ajuste le seuil de drift en bps (gouvernance). Doit accepter le defaut 300 (3%).
    function setAdjustHedgeBps(uint16 _adjustHedgeBps) external onlyGovernance {
        require(_adjustHedgeBps >= 100 && _adjustHedgeBps <= 2000, "E31");
        adjustHedgeBps = _adjustHedgeBps;
    }

    /// @notice Cible de hedge en bps du WETH LP (10000 = 100% = DN strict). Gouvernance.
    /// @dev H_opt retire : la cible n'est plus calculee on-chain, elle est gouvernee. Borne 5000..10000
    ///      (jamais sous 50% : en-dessous ce n'est plus un "Delta Neutral" honnete).
    function setHedgeTargetBps(uint16 _hedgeTargetBps) external onlyGovernance {
        require(_hedgeTargetBps >= 5000 && _hedgeTargetBps <= 10000, "E35");
        hedgeTargetBps = _hedgeTargetBps;
        emit HedgeTargetConfigured(_hedgeTargetBps);
    }

    /// @notice Seuil dust (token0/volatil) sous lequel le WETH libre du RangeManager est ignore dans
    ///         effectiveShort (anti-grief donation). Gouvernance.
    function setDonationDustToken0(uint256 _donationDustToken0) external onlyGovernance {
        donationDustToken0 = _donationDustToken0;
        emit DonationDustConfigured(_donationDustToken0);
    }

    /// @notice Configure le cooldown on-chain entre deux adjustHedge() permissionless (gouvernance).
    /// @dev 0 = desactive (retrocompat). Borne haute 24h. Ne bloque PAS le canal surge botModule du bot.
    function setHedgeAdjustCooldown(uint32 _cooldownSeconds) external onlyGovernance {
        require(_cooldownSeconds <= 86400, "E36");
        hedgeAdjustCooldown = _cooldownSeconds;
        emit HedgeAdjustCooldownConfigured(_cooldownSeconds);
    }

    /// @notice (audit V1 — V3-R4 Point 2) Ecart max LP(slot0) vs oracle Chainlink avant adjustHedge (gouvernance).
    /// @dev En bps. 0 = desactive (mode urgence documente). Borne <= 1000 (10%) pour ne pas neutraliser la garde.
    function setMaxHedgeDeviationBps(uint16 _bps) external onlyGovernance {
        require(_bps <= 1000, "E37");
        maxHedgeDeviationBps = _bps;
        emit MaxHedgeDeviationConfigured(_bps);
    }

    /// @notice Transfere la gouvernance des reglages vers une nouvelle adresse (ex: Timelock Phase 2).
    function transferOwnership(address newOwner) external onlyGovernance {
        require(newOwner != address(0), "E38");
        governance = newOwner;
    }

    /// @notice Configure le module bot autorise pour les operations directes Phase 2.
    function setBotModule(address newModule) external onlyGovernance {
        require(newModule != address(0), "E39");
        botModule = newModule;
    }

    /// @notice Ajuste le slippage max du swap repay (gouvernance).
    function setSwapSlippageBps(uint16 _swapSlippageBps) external onlyGovernance {
        require(_swapSlippageBps >= 10 && _swapSlippageBps <= 500, "E32");
        swapSlippageBps = _swapSlippageBps;
    }

    /// @notice Reajuste le hedge AAVE de facon PERMISSIONLESS — UNIQUEMENT pour resorber un OVER-HEDGE.
    /// @dev Pilotage sur le SHORT NET EFFECTIF (effectiveShort = dette - WETH libre HM - WETH libre RM),
    ///      pas la dette brute. Cible = hedgeTargetBps/10000 * wethInLP (gouvernee, defaut 100% = DN strict ;
    ///      H_opt RETIRE). Le keeper ne fournit AUCUN parametre de decision.
    ///      - UNDER-HEDGED (effectiveShort < targetShort, inclut effectiveShort < 0) : REVERT UnderHedged.
    ///        adjustHedge() ne peut pas corriger un sous-hedge (il faudrait modifier la LP) -> 0 gas keeper
    ///        (staticCall), 0 bounty. La correction passe par le chemin rebalance() permissionless (solveur).
    ///      - OVER-HEDGED (effectiveShort > targetShort) : repay de l'exces, WETH achete AU MARCHE (oracle-borne),
    ///        JAMAIS depuis le buffer idle (repay-buffer = no-op delta). Bounty paye ici seulement.
    ///      Garde-fous : require(drift>=adjustHedgeBps) ET cooldown ecoule. Verifie le HF apres action.
    ///      Le canal botModule/direct (borrowMore/repayDebt) du bot n'est PAS soumis au cooldown (voie surge) ;
    ///      la correction du SOUS-HEDGE se fait via rebalance-solveur permissionless, pas via adjustHedge().
    function adjustHedge() external whenNotPaused nonReentrant {
        require(rangeManager != address(0) && adjustHedgeBps > 0, "E40");

        // 0. Cooldown on-chain (keepers + bot via ce chemin): limite la frequence des reajustements
        // permissionless. Verifie EN TETE pour echouer tot (gas) avant la lecture LP. Le bot conserve
        // un canal surge non bride via borrowMore/repayDebt botModule (qui ne portent pas ce require).
        require(block.timestamp >= uint256(lastHedgeAdjustAt) + uint256(hedgeAdjustCooldown), "E41");

        // 1. Lire la position LP on-chain (tokenId via RangeManager, puis composition via le NFT/pool)
        uint256[] memory positions = IRangeManagerHedge(rangeManager).getOwnerPositions();
        require(positions.length > 0, "E42");
        (uint256 wethInLP, int24 tickLower, int24 tickUpper) =
            DnDepositLib.aaveLpToken0AndTicks(positions[0], lpPositionManager, lpPool);
        require(wethInLP > 0 && tickUpper > tickLower, "E42");

        // 1b. audit V1 (V3-R4 Point 2) : garde anti-manipulation du prix LP. wethInLP derive du slot0 ; si le
        // pool a ete pousse loin de l'oracle Chainlink, on refuse de reajuster (sinon repay inutile +
        // bounty + churn AAVE + MEV). Lecture slot0 authoritative ici, comparee a ethUsdFeed.
        (uint160 sqrtPriceX96Now,,,,,,) = lpPool.slot0();
        DnDepositLib.aaveRequireLpNotDeviated(
            sqrtPriceX96Now,
            maxHedgeDeviationBps,
            volatileDecimals,
            stableDecimals,
            oracleDecimals,
            oracleMaxAge,
            ethUsdFeed
        );

        // 2. Cible de SHORT (DN strict par defaut) : targetShort = hedgeTargetBps/10000 * wethInLP
        uint256 targetShort = (wethInLP * uint256(hedgeTargetBps)) / 10000;
        require(targetShort > 0, "E43");

        // 3. SHORT NET EFFECTIF (signe) = dette - WETH libre (HM) - WETH libre (RM), filtre dust sur LES DEUX.
        //    int256 OBLIGATOIRE : si idle > dette (ex. donation), effectiveShort < 0 => sous-hedge AGGRAVE.
        //    Anti-grief donation : on ne compte que la PART AU-DELA du seuil dust (pas tout-ou-rien), et on
        //    filtre AUSSI le WETH du HedgeManager (sinon une donation au HM force un sous-hedge artificiel = DoS).
        uint256 currentDebtWeth = variableDebtWeth.balanceOf(address(this));
        uint256 idleHM = _netOfDust(weth.balanceOf(address(this)));
        uint256 idleRM = _netOfDust(weth.balanceOf(rangeManager));
        int256 effectiveShort = int256(currentDebtWeth) - int256(idleHM) - int256(idleRM);

        // 4. Regle de signe (unique) :
        //    effectiveShort < targetShort  => UNDER-HEDGED (trop long, inclut effectiveShort < 0)
        //    effectiveShort > targetShort  => OVER-HEDGED  (trop short)
        if (effectiveShort < int256(targetShort)) {
            // UNDER-HEDGED : adjustHedge() permissionless NE PEUT PAS corriger (il faudrait modifier la LP).
            // On REVERT (custom error) : le staticCall keeper l'attrape => 0 gas, 0 bounty, 0 reset cooldown.
            // La correction passe par le chemin rebalance() permissionless (solveur). NB: pas d'event ici.
            revert UnderHedged(targetShort, effectiveShort);
        }

        // OVER-HEDGED : effectiveShort > targetShort. On reduit le short reel en repayant de la dette.
        // diff = exces de short a resorber.
        uint256 diff = uint256(effectiveShort - int256(targetShort));
        uint256 driftBps = (diff * 10000) / targetShort;
        require(driftBps >= uint256(adjustHedgeBps), "E44");

        // IMPORTANT : le WETH de repay vient DU MARCHE (achat oracle-borne), JAMAIS du buffer idle.
        // Repayer depuis le buffer (idleHM) ne change pas effectiveShort (dette -x ET idle -x) => no-op delta.
        // _acquireWethForRepay achete exactement `diff` WETH via swap USDC->WETH protege par l'oracle.
        _acquireWethForRepay(diff);
        _doRepayDebt(diff);

        // Reset du cooldown : un VRAI ajustement delta (over-hedge corrige) vient d'avoir lieu.
        lastHedgeAdjustAt = uint64(block.timestamp);

        // Reconstitution de reserve: apres repay le collateral est surdimensionne.
        // On libere l'excedent (vers HF cible) qui RESTE sur ce contrat comme reserve.
        _rebuildReserve();

        // 6. Securite: le health factor doit rester sain apres reajustement
        _requireHfMin();

        // 7. Bounty (silent: ne bloque jamais le reajustement si treasury vide/desactive).
        //    Paye UNIQUEMENT sur ce chemin over-hedge corrige (jamais sur sous-hedge qui revert).
        if (treasuryAddress != address(0)) {
            try IHedgeTreasury(treasuryAddress).payHedgeBounty(msg.sender) {} catch {}
        }

        emit HedgeAdjusted(currentDebtWeth, targetShort, false, msg.sender);
    }

    /// @dev Filtre dust anti-grief donation : retourne la PART du solde AU-DELA du seuil donationDustToken0
    ///      (pas tout-ou-rien → pas de discontinuité exploitable au franchissement du seuil). Appliqué au
    ///      WETH libre du HedgeManager ET du RangeManager dans le calcul d'effectiveShort.
    function _netOfDust(uint256 balance) private view returns (uint256) {
        return balance > donationDustToken0 ? balance - donationDustToken0 : 0;
    }

    /// @dev Apres un repay, libere le collateral AAVE excedentaire (au-dela du HF cible) vers ce
    ///      contrat, ou il reste comme reserve (sert aux futurs swaps repay). N'envoie RIEN ailleurs.
    ///      Tout est en base AAVE (8 decimales) ; garde-fou: ne libere que si le HF projete >= cible.
    function _rebuildReserve() private {
        (uint256 collBase, uint256 debtBase,, uint256 liveLiqThreshold,,) = pool.getUserAccountData(address(this));
        if (debtBase == 0 || collBase == 0) return;
        uint256 threshold = liveLiqThreshold > 0 ? liveLiqThreshold : uint256(liqThresholdBps);

        // Collateral cible = debt * HF_cible / seuil_liquidation (tout en bps -> se simplifie)
        // collTargetBase = debtBase * reserveHfTargetBps / liqThresholdBps
        uint256 collTargetBase = (debtBase * uint256(reserveHfTargetBps)) / threshold;
        if (collBase <= collTargetBase) return; // pas d'excedent

        uint256 excessBase = collBase - collTargetBase;
        // Garde-fou: HF projete apres retrait = (collBase - excessBase) * liqThreshold / debtBase doit
        // rester >= cible. Par construction collBase-excessBase = collTargetBase, donc HF projete = cible.
        // On retire l'excedent converti en token stable, vers ce contrat (reserve).
        _refreshRangePriceCache();
        uint256 excessStable = _aaveBaseToStable(excessBase);
        if (excessStable == 0) return;
        pool.withdraw(address(usdc), excessStable, address(this));
        emit ReserveRebuilt(excessStable);
    }

    /// @dev Refresh fail-closed du cache oracle/slot0 RangeManager avant les conversions AAVE base -> token1.
    ///      Le HedgeManager doit être autorise comme executor RangeManager dans le batch Safe DN.
    ///      En emergency partiel, ce choix privilegie la securite comptable : oracle indisponible => revert/retry
    ///      plutot qu'un remboursement calcule sur un prix potentiellement obsolete.
    function _refreshRangePriceCache() private {
        IRangeManagerHedge(rangeManager).refreshPriceCache();
    }

    /// @dev Convertit un montant en base AAVE (8 decimales) vers le token stable, gere stableDecimals </> 8.
    function _aaveBaseToStable(uint256 baseAmount) private view returns (uint256) {
        return DnDepositLib.aaveBaseToStable(baseAmount, rangeManager, stableDecimals);
    }

    function _settleNoDebt(uint256 wethReceived, uint256 proportionBps, bool isFullWithdraw, address recipient)
        private
        returns (uint256 usdcSwept)
    {
        (uint256 totalCollateralBase,,,,,) = pool.getUserAccountData(address(this));
        if (totalCollateralBase > 0) {
            if (isFullWithdraw) {
                pool.withdraw(address(usdc), type(uint256).max, recipient);
            } else {
                uint256 usdcBal = usdc.balanceOf(address(this));
                pool.withdraw(address(usdc), type(uint256).max, address(this));
                uint256 totalUsdcWithdrawn = usdc.balanceOf(address(this)) - usdcBal;
                uint256 proportionalUsdc = (totalUsdcWithdrawn * proportionBps) / SHARE_SCALE;
                uint256 toResupply = totalUsdcWithdrawn - proportionalUsdc;
                if (toResupply > 0) pool.supply(address(usdc), toResupply, address(this), 0);
                if (proportionalUsdc > 0) usdc.safeTransfer(recipient, proportionalUsdc);
            }
        }

        if (isFullWithdraw) {
            uint256 wethBal = weth.balanceOf(address(this));
            if (wethBal > 0) weth.safeTransfer(recipient, wethBal);
            usdcSwept = usdc.balanceOf(address(this));
            if (usdcSwept > 0) usdc.safeTransfer(recipient, usdcSwept);
        } else if (wethReceived > 0) {
            // Partial settle: never sweep pre-existing idle WETH from the HedgeManager.
            weth.safeTransfer(recipient, wethReceived);
        }
    }

    /// @dev Snapshot des reserves idle AVANT settlement. `wethReceived` vient du burn LP courant et ne doit
    ///      pas etre inclus dans la reserve partagee entre tous les users.
    function _idleBeforeSettlement(uint256 wethReceived) private view returns (uint256 idleWeth, uint256 idleUsdc) {
        uint256 wethBal = weth.balanceOf(address(this));
        idleWeth = wethBal > wethReceived ? wethBal - wethReceived : 0;
        idleUsdc = usdc.balanceOf(address(this));
    }

    /// @dev Distribue au retrait partiel la quote-part des soldes idle deja presents sur le HedgeManager.
    ///      Sans cela, ces reserves sont comptabilisees dans la NAV mais le premier retrait partiel ne recoit
    ///      pas sa part; inversement, le callback flash-loan protege `idleWethBefore` pour eviter une subvention.
    function _sendIdleShare(uint256 idleWethBefore, uint256 idleUsdcBefore, uint256 proportionBps, address recipient)
        private
    {
        uint256 share = (idleWethBefore * proportionBps) / SHARE_SCALE;
        if (share > 0) weth.safeTransfer(recipient, share);
        share = (idleUsdcBefore * proportionBps) / SHARE_SCALE;
        if (share > 0) usdc.safeTransfer(recipient, share);
    }

    /// @dev Obtient `wethNeeded` WETH pour le repay en swappant de l'USDC (retire d'AAVE si besoin),
    ///      avec protection de slippage via l'oracle Chainlink ETH/USD (anti-MEV pour appel keeper).
    /// @dev Plafond USDC (anti-sandwich) pour acheter `wethNeeded` WETH : coût théorique Chainlink majoré
    ///      du slippage toléré. Réutilisé par _acquireWethForRepay ET par le callback flash loan
    ///      executeOperation (audit V1 — High 3 : le callback utilisait balanceOf entier, sandwichable).
    function _oracleMaxUsdcForWeth(uint256 wethNeeded) private view returns (uint256 amountInMaximum) {
        (uint80 roundId, int256 px,, uint256 updatedAt, uint80 answeredInRound) = ethUsdFeed.latestRoundData();
        require(px > 0 && answeredInRound >= roundId && block.timestamp - updatedAt <= oracleMaxAge, "E45");
        // Conversion generique (pas de hard-code de decimales) :
        // cout_stable = wethNeeded * px * 10^stableDec / (10^volatileDec * 10^oracleDec)
        uint256 usdcTheoretical =
            (wethNeeded * uint256(px) * (10 ** stableDecimals)) / ((10 ** volatileDecimals) * (10 ** oracleDecimals));
        amountInMaximum = (usdcTheoretical * (10000 + swapSlippageBps)) / 10000;
        require(amountInMaximum > 0, "E46");
    }

    function _acquireWethForRepay(uint256 wethNeeded) private {
        // Cout theorique majore du slippage (plafond anti-sandwich via oracle Chainlink).
        uint256 amountInMaximum = _oracleMaxUsdcForWeth(wethNeeded);

        // S'assurer d'avoir assez d'USDC sur le contrat ; sinon retirer du collateral AAVE
        uint256 usdcBal = usdc.balanceOf(address(this));
        if (usdcBal < amountInMaximum) {
            pool.withdraw(address(usdc), amountInMaximum - usdcBal, address(this));
        }

        // exactOutputSingle: obtenir exactement wethNeeded WETH, en depensant au plus amountInMaximum USDC
        // (revert si le marche est plus defavorable que oracle + slippage => protection anti-sandwich)
        swapRouter.exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                fee: swapPoolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: wethNeeded,
                amountInMaximum: amountInMaximum,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @notice Close entire position: repay all debt + withdraw all collateral
    /// @dev Used for full teardown. Sends all recovered USDC to recipient.
    ///      Requires enough WETH on this contract to repay full debt.
    /// @param recipient Address to receive all recovered USDC
    function closeAll(address recipient) external onlySafe whenNotPaused nonReentrant {
        require(recipient != address(0), "bad");

        _closePosition(recipient);
    }

    /// @notice Emergency close: same as closeAll but works even when paused
    /// @param recipient Address to receive all recovered USDC
    function emergencyClose(address recipient) external onlySafe nonReentrant {
        require(recipient != address(0), "bad");

        _closePosition(recipient);
    }

    /// @notice Send all WETH held on this contract to the RangeManager (emergency operator sweep)
    /// @dev Conservé en onlyBotModule + selector inchangé (whitelist module). Destination FIGÉE au RM.
    ///      Pour le dépôt hedgé permissionless, utiliser sweepWethAmount (montant EXACT) — sweeper TOUT
    ///      le solde injecterait un buffer/donation préexistant dans la LP et fausserait le post-check.
    function sweepWeth(address to) external onlyBotModule whenNotPaused nonReentrant {
        require(to == rangeManager && rangeManager != address(0), "E29");
        uint256 balance = weth.balanceOf(address(this));
        require(balance > 0, "E47");
        weth.safeTransfer(to, balance);
        emit SweepWeth(to, balance);
    }

    /// @notice Send an EXACT amount of WETH to the RangeManager (refonte DN : dépôt/solveur hedgé).
    /// @dev onlySafeOrVault. Montant EXACT (= le WETH nouvellement emprunté), destination FIGÉE au RM.
    ///      Évite d'injecter un buffer/donation préexistant dans la LP (post-check faussé / DoS donation).
    /// @param amount Montant EXACT de WETH à envoyer (wei)
    /// @param to Destination — DOIT valoir rangeManager
    function sweepWethAmount(uint256 amount, address to) external onlySafeOrVault whenNotPaused nonReentrant {
        require(to == rangeManager && rangeManager != address(0), "E29");
        require(amount > 0, "E48");
        require(weth.balanceOf(address(this)) >= amount, "E49");
        weth.safeTransfer(to, amount);
        emit SweepWeth(to, amount);
    }

    /// @notice Send all USDC held on this contract to an address
    /// @dev Used to recover USDC after collateral withdrawal
    /// @param to Destination address
    function sweepUsdc(address to) external onlyBotModule whenNotPaused nonReentrant {
        // SÉCURITÉ (audit V1) : destination FIGÉE au rangeManager (cf. sweepWeth). Anti-exfiltration
        // par clé bot compromise. Le param `to` est conservé (selector inchangé) mais DOIT = rangeManager.
        require(to == rangeManager && rangeManager != address(0), "E29");

        uint256 balance = usdc.balanceOf(address(this));
        require(balance > 0, "E50");

        usdc.safeTransfer(to, balance);

        emit SweepUsdc(to, balance);
    }

    // ===== ADMIN =====

    function setPaused(bool _paused) external onlySafe {
        paused = _paused;
        emit Paused(_paused);
    }

    // ===== VIEW FUNCTIONS =====

    /// @notice Get the health factor of this contract's AAVE position
    /// @return healthFactor in 1e18 scale (1e18 = 1.0, < 1e18 = liquidatable)
    function getHealthFactor() external view returns (uint256) {
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(address(this));
        return healthFactor;
    }

    /// @notice Get full hedge data for dashboard
    /// @return totalCollateralBase Total collateral in base currency (USD, 8 decimals)
    /// @return totalDebtBase Total debt in base currency (USD, 8 decimals)
    /// @return healthFactor Health factor in 1e18 scale
    /// @return availableBorrowsBase Available borrows in base currency (USD, 8 decimals)
    function getHedgeData()
        external
        view
        returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 healthFactor, uint256 availableBorrowsBase)
    {
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,, healthFactor) =
            pool.getUserAccountData(address(this));
    }

    /// @notice Get WETH balance held on this contract (ready for LP or repay)
    function getWethBalance() external view returns (uint256) {
        return weth.balanceOf(address(this));
    }

    /// @notice Get USDC balance held on this contract (ready to supply or send)
    function getUsdcBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice Get current WETH debt (variable debt token balance)
    function getWethDebt() external view returns (uint256) {
        return variableDebtWeth.balanceOf(address(this));
    }

    // ===== INTERNAL =====

    /// @dev Settle hedge directly when enough WETH is available (no flash loan needed)
    function _settleDirectly(uint256 debtToRepay, uint256 proportionBps, bool isFullWithdraw, address recipient)
        internal
    {
        // Repay WETH debt
        if (isFullWithdraw) {
            pool.repay(address(weth), type(uint256).max, 2, address(this));
        } else {
            pool.repay(address(weth), debtToRepay, 2, address(this));
        }

        // Withdraw USDC collateral
        if (isFullWithdraw) {
            pool.withdraw(address(usdc), type(uint256).max, recipient);
        } else {
            // Calculate proportional USDC to withdraw based on current AAVE collateral.
            // We cannot use type(uint256).max here because remaining debt prevents
            // full collateral withdrawal (AAVE would revert with HF < 1).
            (uint256 totalCollateralBase,,,,,) = pool.getUserAccountData(address(this));
            // totalCollateralBase: AAVE base currency (8 decimales). Conversion generique vers le
            // token stable via ses decimales reelles (lues au constructeur), gere stableDecimals </> 8.
            _refreshRangePriceCache();
            uint256 proportionalUsdc = (_aaveBaseToStable(totalCollateralBase) * proportionBps) / SHARE_SCALE;
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

    /// @dev Internal close position logic shared by closeAll and emergencyClose.
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
