// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import "./AutonomousErrors.sol";

import "./AutonomousRevenueLib.sol";
import {TreasuryPolicyLib} from "./TreasuryPolicyLib.sol";


import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";



contract Treasury is Ownable2Step, ReentrancyGuard {
    function rescueToken(address tokenAddr, address to, uint256 amount) external onlyRescueSafe nonReentrant {
        AutonomousRevenueLib.rescueToken(_revenue, tokenAddr, to, amount);
    }

    function setPublicConversion(address token, uint256 maxInput, uint256 minUsdc, uint64 cooldown)
        external
        onlyInstaller
    {
        AutonomousRevenueLib.validatePublicConversion(
            _revenue.policy.assets[token].installed, token, address(usdc), usdcDecimals, maxInput, minUsdc, cooldown
        );
        _revenue.policy.assets[token].maxInput = maxInput;
        _revenue.policy.assets[token].minUsdc = minUsdc;
        _revenue.policy.assets[token].cooldown = cooldown;
        emit PublicConversionConfigured(token, maxInput, minUsdc, cooldown);
    }

    function setSwapPoolFee(address token, uint24 fee) external onlyInstaller {
        TreasuryPolicyLib.validatePoolFee(_revenue.policy.assets[token].installed, token, address(usdc), fee);
        _revenue.policy.assets[token].fee = fee;
        emit SwapPoolFeeConfigured(token, fee);
    }

    function _distributableUsdc() internal view returns (uint256) {
        return AutonomousRevenueLib.distributable(_revenue, address(usdc));
    }

    function setSwapFeed(address token, address feed, uint16 _swapSlippageBps, uint32 _maxAge) external onlyInstaller {
        TreasuryPolicyLib.validateSwapFeed(
            _revenue.policy.assets[token].installed,
            address(_revenue.policy.assets[token].feed),
            token,
            feed,
            _swapSlippageBps,
            _maxAge,
            usdcDecimals
        );
        _revenue.policy.assets[token].feed = feed;
        _revenue.policy.assets[token].maxAge = _maxAge;
        _revenue.policy.assets[token].slippageBps = _swapSlippageBps;
        emit SwapFeedConfigured(token, feed, _swapSlippageBps, _maxAge);
    }



    function previewSourceFeeConversion(address source, address token)
        public
        view
        returns (uint256 amountIn, uint256 minOut, uint64 nextAt)
    {
        return AutonomousRevenueLib.previewConversion(_revenue, source, token);
    }

    function _executeFixedFeeSwap(address t, uint24 f, uint256 a, uint256 m) private returns (uint256) {
        return AutonomousRevenueLib.executeFeeSwap(t, f, a, m);
    }

    using SafeERC20 for IERC20;
    using Math for uint256;

    error ConversionBountyCooldownZero();
    error ConversionBountyMinRatioZero();


    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    // --- Immutables ---
    IERC20 public immutable usdc;
    uint8 public immutable usdcDecimals;
    ISwapRouter public immutable swapRouter;


    // --- State ---
    AutonomousRevenueLib.State private _revenue;
    uint16 public constant BOUNTY_RESERVE_BPS = 500;
    bool public configurationSealed;


    address public company;
    uint64 public nextDistributionPauseAt;
    event ConfigurationSealed();
    event AssetSealed(address indexed token);
    bool private _distributionsPaused;
    uint64 public guardianDistributionPauseUntil;
    address public rescueSafe;

    // --- Keeper Bounty (rebalance) ---

    function authorizedRangeManagers(address actor) public view returns (bool) {
        return (_revenue.roles[actor] & 1) != 0;
    }

    // SÉCURITÉ (audit V1) : plancher oracle anti-sandwich pour les swaps de la Treasury.
    // Le Treasury est PARTAGÉ par toutes les pools d'une même chaîne → il peut swapper des tokens
    // volatils variés (WETH, WBTC, ...). Un feed Chainlink par token est déclaré par la gouvernance.
    // swapToUSDC impose amountOutMinimum >= prix oracle × (1 − _revenue.policy.assets[token].slippageBps),
    // et REVERT si aucun feed n'est configuré pour tokenIn (pas de swap d'un token non oraclé).

    function lastConversionAt(address token) external view returns (uint64) {
        return _revenue.conversions[address(this)][token].started;
    }

    function lastSourceConversionAt(address source, address token) external view returns (uint64) {
        return _revenue.conversions[source][token].started;
    }
    event PublicConversionConfigured(address indexed token, uint256 maxInput, uint256 minUsdc, uint64 cooldown);

    // Anti-drain protections (configurable by multisig):
    //  - cooldown:  bounty paid at most once per `_revenue.legacy.conversionBountyCooldown` seconds
    //  - min ratio: converted USDC amount must be >= _revenue.legacy.conversionBountyAmount * CONVERSION_BOUNTY_MIN_RATIO
    //               (minimum 100, ie. the conversion must produce >= 100× the bounty value to earn it)

    // --- Strategy checkpoint bounty ---

    function authorizedStrategyEngines(address actor) public view returns (bool) {
        return (_revenue.roles[actor] & 2) != 0;
    }

    // --- Hedge Bounty (adjustHedge, pools DN) — paye au keeper qui reajuste le hedge ---
    // Anti-drain: adjustHedge() est deja borne cote AaveHedgeManager par drift+cooldown, et le Treasury ajoute
    // un cap quotidien par HedgeManager. Si le cap est atteint, le caller AaveHedgeManager catch le revert et le
    // reajustement continue sans bounty.

    function authorizedHedgeManagers(address actor) public view returns (bool) {
        return (_revenue.roles[actor] & 4) != 0;
    }

    // --- Deposit Bounty (processDepositPermissionless) — paye au keeper qui traite un depot en file ---
    // Le caller est le Vault (pas le RangeManager) -> autorisation dediee authorizedVaults.
    // Anti-drain: pas de paiement direct au deposant + ratio depot/bounty + cooldown/cap quotidien par Vault.
    // Une collusion Sybil reste inherente a une prime permissionless, mais son rendement est strictement borne.
    // Le traitement reste permissionless; si ces limites revert, le Vault saute seulement la prime.

    function lastDepositBountyAt(address actor) external view returns (uint64) {
        return _revenue.depositAt[actor];
    }

    function lastDepositBountyKeeperAt(address actor, address keeper) external view returns (uint64) {
        return _revenue.depositKeeperAt[actor][keeper];
    }

    function depositBountyDay(address actor) external view returns (uint64) {
        return _revenue.depositDay[actor];
    }

    function depositBountyDailySpent(address actor) external view returns (uint256) {
        return _revenue.depositSpent[actor];
    }

    function authorizedVaults(address actor) public view returns (bool) {
        return (_revenue.roles[actor] & 8) != 0;
    }

    // Verified local conversion rewards





    // --- Events ---
    event GovernancePolicyInstalled(address indexed governance, address indexed catalogue, address indexed registry);
    event SourceBountyConfigured(
        address indexed source,
        uint8 indexed kind,
        uint256 previousAmount,
        uint256 previousCap,
        uint256 amount,
        uint256 dailyCap,
        uint64 effectiveAt
    );
    event GovernanceBountiesConfigured(
        uint256 previousControl,
        uint256 previousAction,
        uint256 previousGlobalCap,
        uint256 previousAddressCap,
        uint256 control,
        uint256 action,
        uint256 globalCap,
        uint256 addressCap,
        uint64 effectiveAt
    );
    event GovernanceBountySkipped(address indexed keeper, bytes32 indexed actionKey, uint8 category, uint8 reason);
    event GovernanceBountyPaid(address indexed keeper, bytes32 indexed actionKey, uint8 category, uint256 amount);
    event GovernanceReserveCredited(uint256 revenue, uint256 amount);
    event AdminWithdrawal(uint256 amount, address indexed to);
    event DistributionsPauseUpdated(bool paused, address indexed caller);
    event RescueSafeUpdated(address indexed oldSafe, address indexed newSafe);

    event SwappedToUSDC(address indexed tokenIn, uint24 fee, uint256 amountIn, uint256 usdcOut);
    event KeeperBountyPaid(address indexed keeper, uint256 amount);
    event KeeperBountyConfigured(bool enabled, uint256 amount);
    event KeeperBountyDailyCapConfigured(uint256 dailyCap);
    event HedgeBountyDailyCapConfigured(uint256 dailyCap);
    event ConversionBountyPaid(address indexed keeper, uint256 amount);
    event ConversionBountySkipped(address indexed keeper, string reason);
    event ConversionBountyConfigured(bool enabled, uint256 amount);
    event ConversionBountyCooldownConfigured(uint64 cooldown, uint16 minRatio);



    event RangeManagerAuthorized(address indexed rangeManager, bool authorized);
    event SwapFeedConfigured(address indexed token, address feed, uint16 swapSlippageBps, uint32 maxAge);
    event SwapPoolFeeConfigured(address indexed token, uint24 fee);
    event StrategyCheckpointBountyPaid(address indexed keeper, address indexed engine, uint64 epoch, uint256 amount);
    event StrategyCheckpointBountyConfigured(bool enabled, uint256 amount);
    event StrategyCheckpointBountyDailyCapConfigured(uint256 dailyCap);
    event StrategyEngineAuthorized(address indexed engine, bool authorized);
    event HedgeBountyPaid(address indexed keeper, uint256 amount);
    event HedgeBountyConfigured(bool enabled, uint256 amount);
    event HedgeManagerAuthorized(address indexed hedgeManager, bool authorized);
    event DepositBountyPaid(address indexed keeper, uint256 amount);
    event DepositBountyConfigured(bool enabled, uint256 amount);
    event DepositBountyLimitsConfigured(uint64 vaultCooldown, uint64 keeperCooldown, uint256 dailyCap);
    event VaultAuthorized(address indexed vault, bool authorized);

    constructor(
        address _usdc,
        address _swapRouter,
        uint256 _initialBountyDailyCap,
        bool _keeperBountyEnabled,
        uint256 _keeperBountyAmount
    ) {
        require(
            _usdc != address(0) && _swapRouter != address(0), AutonomousCheck(0x4c9bb549)
        );
        usdc = IERC20(_usdc);
        usdcDecimals = IERC20Metadata(_usdc).decimals();
        require(usdcDecimals <= 18, AutonomousCheck(0x8a0ba966));
        require(_validBountyCap(_initialBountyDailyCap), AutonomousCheck(0xdc524c4e));
        swapRouter = ISwapRouter(_swapRouter);
        rescueSafe = msg.sender;
        company = msg.sender;
        if (_keeperBountyEnabled) {
            require(
                _keeperBountyAmount > 0 && _keeperBountyAmount <= _initialBountyDailyCap, AutonomousCheck(0x5b636e99)
            );
            _revenue.legacy.keeperBountyDailyCap = _initialBountyDailyCap;
        }
        _revenue.legacy.keeperBountyEnabled = _keeperBountyEnabled;
        _revenue.legacy.keeperBountyAmount = _keeperBountyAmount;

    }

    function renounceOwnership() public pure override {
        revert();
    }

    receive() external payable {}

    modifier onlyRescueSafe() {
        require(msg.sender == rescueSafe, AutonomousCheck(0x99b0721c));
        _;
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        super.transferOwnership(newOwner);
    }

    /// @notice Fresh-source/asset installation belongs to the company after global sealing.
    /// @dev Existing assets, actors, economics and settlement routes remain immutable.
    function installer() public view returns (address) {
        return configurationSealed ? (_revenue.policy.governance == address(0) ? company : address(0)) : owner();
    }
    modifier onlyInstaller() {
        require(msg.sender == installer(), AutonomousCheck(0x2027c175));
        _;
    }

    function setCompany(address admin) external onlyOwner {
        require(!configurationSealed && admin != address(0), AutonomousCheck(0x2c7e43eb));
        company = admin;
    }

    function sealConfiguration() external onlyOwner {
        require(!configurationSealed && pendingOwner() == address(0), AutonomousCheck(0x9a247fa1));
        configurationSealed = true;
        emit ConfigurationSealed();
    }

    function sealAsset(address token) external onlyInstaller {
        require(
            !_revenue.policy.assets[token].installed && address(_revenue.policy.assets[token].feed) != address(0),
            AutonomousCheck(0x4bb6522b)
        );
        if (token != address(usdc)) {
            require(
                _revenue.policy.assets[token].maxInput > 0 && _revenue.policy.assets[token].fee != 0,
                AutonomousCheck(0xadb5731e)
            );
        }
        _revenue.policy.assets[token].installed = true;
        emit AssetSealed(token);
    }

    function installRevenueSource(address source, address[] calldata actors) external onlyInstaller {
        AutonomousRevenueLib.install(_revenue, source, actors);
    }

    function sealRevenueSource(address source) external onlyInstaller {
        AutonomousRevenueLib.sealSource(_revenue, source);
    }

    function revenueSourceSealed(address source) external view returns (bool) {
        return _revenue.sourceSealed[source];
    }

    function recordRevenue(address token, uint256 amount) external nonReentrant {
        require(_revenue.policy.assets[token].installed, AutonomousCheck(0x82570cf2));
        AutonomousRevenueLib.record(_revenue, address(usdc), token, amount);
    }

    function syncRevenue(address token) external nonReentrant {
        require(_revenue.policy.assets[token].installed, AutonomousCheck(0x82570cf2));
        AutonomousRevenueLib.sync(_revenue, address(usdc), token);
    }

    function sourceOf(address actor) external view returns (address) {
        return _revenue.sourceOf[actor];
    }

    function pendingRevenue(address source, address token) external view returns (uint256) {
        return _revenue.pending[source][token];
    }

    function sourceBountyReserve(address source) external view returns (uint256) {
        return _revenue.reserve[source];
    }

    function cumulativeUsdcRevenue(address source) external view returns (uint256) {
        return _revenue.revenue[source];
    }

    function bountyReserveUsdc() external view returns (uint256) {
        return _bountyReserveUsdc();
    }

    function fundBounties(address source, uint256 amount) external nonReentrant {
        AutonomousRevenueLib.fund(_revenue, address(usdc), source, amount);
    }

    function _syncUsdc() private {
        AutonomousRevenueLib.sync(_revenue, address(usdc), address(usdc));
    }

    function _spendBounty(address actor, uint256 amount) private {
        _syncUsdc();
        AutonomousRevenueLib.spend(_revenue, actor, amount);
        AutonomousRevenueLib.debit(_revenue, address(usdc), amount);
    }
    address public wrappedNative;

    function setWrappedNative(address token) external onlyOwner {
        require(
            !configurationSealed && wrappedNative == address(0) && token.code.length > 0, AutonomousCheck(0xcc3783a8)
        );
        wrappedNative = token;
    }

    function wrapNativeFees() external nonReentrant {
        require(
            wrappedNative != address(0) && _revenue.policy.assets[wrappedNative].installed, AutonomousCheck(0x1740b452)
        );
        AutonomousRevenueLib.wrapNative(wrappedNative);
        AutonomousRevenueLib.sync(_revenue, address(usdc), wrappedNative);
    }

    // --- Public Functions ---

    /// @notice Swap an approved ERC-20 held by this Treasury to USDC through an owner-authorized route.
    /// @dev A zero minAmountOut uses the live oracle floor; a higher caller minimum is preserved.

    // is a separate deterministic entry point with capped input, cooldown and fixed route.




    /// @dev Pays the conversion bounty to `keeper` if enabled, the treasury holds enough USDC,
    ///      the cooldown has passed, and `convertedAmount` is large enough to justify the bounty.
    ///      Explicit no-op otherwise — never blocks the conversion itself.
    function _payConversionBounty(address keeper, uint256 convertedAmount) internal {
        try this.performConversionBountyTransfer(keeper, convertedAmount) returns (uint256 paid) {
            if (paid != 0) _revenue.legacy.lastConversionBountyAt = uint64(block.timestamp);
        } catch {
            emit ConversionBountySkipped(keeper, "payment");
        }
    }

    function _requireDistributableUsdc(uint256 amount) internal view {
        require(amount > 0 && amount <= _distributableUsdc(), AutonomousCheck(0xbac20538));
    }

    /// @notice Exact USDC balance available for permissionless distribution after every active bounty reserve.

    /// @dev No caller-selected amount, route, recipient or minimum is accepted.

    function previewFeeConversion(address token) public view returns (uint256 amountIn, uint256 minOut, uint64 nextAt) {
        return previewSourceFeeConversion(address(this), token);
    }

    function convertFeesToUSDC(address token) external nonReentrant returns (uint256 amountOut) {
        AutonomousRevenueLib.sync(_revenue, address(usdc), token);
        return _convertAvailable(address(this), token);
    }

    function convertSourceFeesToUSDC(address source, address token) external nonReentrant returns (uint256 amountOut) {
        return _convertAvailable(source, token);
    }

    function convertSourceFeeChunk(address source, address token, uint256 amountIn)
        external
        nonReentrant
        returns (uint256)
    {
        if (source == address(this)) AutonomousRevenueLib.sync(_revenue, address(usdc), token);
        (uint256 available,,) = previewSourceFeeConversion(source, token);
        require(amountIn > 0 && amountIn <= available, AutonomousCheck(0xd6a70ccf));
        (uint256 minOut,) = _oracleSwapBounds(token, amountIn);
        require(minOut >= _revenue.policy.assets[token].minUsdc, AutonomousCheck(0xd34f8e6b));
        return _convertSource(source, token, amountIn, minOut);
    }

    function _convertAvailable(address source, address token) private returns (uint256) {
        (uint256 amountIn, uint256 minOut,) = previewSourceFeeConversion(source, token);
        require(amountIn > 0, AutonomousCheck(0xb9913616));
        return _convertSource(source, token, amountIn, minOut);
    }

    function _convertSource(address source, address token, uint256 amountIn, uint256 minOut)
        private
        returns (uint256 amountOut)
    {
        _syncUsdc();
        AutonomousRevenueLib.consumeConversion(
            _revenue,
            source,
            token,
            amountIn,
            _revenue.policy.assets[token].maxInput,
            _revenue.policy.assets[token].cooldown
        );
        amountOut = _executeFixedFeeSwap(token, _revenue.policy.assets[token].fee, amountIn, minOut);
        AutonomousRevenueLib.converted(_revenue, address(usdc), source, token, amountIn, amountOut);
        _payConversionBounty(msg.sender, amountOut);
    }

    function distributableUsdc() external view returns (uint256) {
        return _distributableUsdc();
    }

    function _bountyReserveUsdc() internal view returns (uint256) {
        return AutonomousRevenueLib.protectedBalance(_revenue, address(usdc));
    }



    function adminWithdraw(uint256 amount, address to) external nonReentrant {
        require(msg.sender == company, AutonomousCheck(0x2027c175));
        AutonomousRevenueLib.withdraw(_revenue, address(usdc), to, amount);
        emit AdminWithdrawal(amount, to);
    }

    function setRescueSafe(address newSafe) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        require(newSafe != address(0), AutonomousCheck(0x24d6423c));
        emit RescueSafeUpdated(rescueSafe, newSafe);
        rescueSafe = newSafe;
    }

    /// @notice Emergency stop for revenue distributions. The rescue Safe may pause immediately;

    function distributionsPaused() public view returns (bool) {
        return _distributionsPaused && block.timestamp < guardianDistributionPauseUntil;
    }

    function setDistributionsPaused(bool value) external onlyRescueSafe {
        _setDistributionPause(value, 48 hours);
    }

    function pauseRevenueFor(uint64 duration) external onlyRescueSafe {
        _setDistributionPause(true, duration);
    }

    function _setDistributionPause(bool value, uint64 duration) private {
        if (value) {
            require(duration >= 1 hours && duration <= 48 hours, AutonomousCheck(0x2e861dfb));
            require(!distributionsPaused() && block.timestamp >= nextDistributionPauseAt, AutonomousCheck(0xaa8f7a50));
            guardianDistributionPauseUntil = uint64(block.timestamp) + duration;
            nextDistributionPauseAt = guardianDistributionPauseUntil + 24 hours;
        } else {
            require(distributionsPaused(), AutonomousCheck(0xaecd4fd1));
            guardianDistributionPauseUntil = 0;
            nextDistributionPauseAt = uint64(block.timestamp + 24 hours);
        }
        _distributionsPaused = value;
        emit DistributionsPauseUpdated(value, msg.sender);
    }

    /// @notice Recover ERC-20 tokens held here in an emergency (other than USDC).

    /// @notice Recover native ETH accidentally sent here.

    function rescueETH(address payable, uint256) external pure {
        revert AutonomousCheck(0x04d6d5a4);
    }

    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ETHRescued(address indexed to, uint256 amount);

    // --- Keeper Bounty Functions ---

    /// @notice Pay bounty to keeper who executed a rebalance. Called by authorized RangeManager.
    function payKeeperBounty(address keeper) external nonReentrant {
        TreasuryPolicyLib.payPoolBounty(_revenue, address(usdc), keeper, 0, 0);
    }

    function setKeeperBounty(bool _enabled, uint256 _amount) external onlyOwner {
        TreasuryPolicyLib.setLegacyBounty(_revenue, 0, _enabled, _amount);
    }

    function setKeeperBountyDailyCap(uint256 _dailyCap) external onlyOwner {
        AutonomousRevenueLib.setLegacyBountyCap(_revenue, 0, _dailyCap);
    }

    // --- Strategy checkpoint bounty functions ---

    /// @notice Pays au plus un bounty par epoch canonique et par moteur autorise.
    /// @dev Le moteur fixe lui-meme l'epoch; le cap quotidien borne aussi un moteur compromis.
    function payStrategyCheckpointBounty(address keeper, uint64 epoch) external nonReentrant {
        TreasuryPolicyLib.payPoolBounty(_revenue, address(usdc), keeper, 1, epoch);
    }

    function setStrategyCheckpointBounty(bool enabled, uint256 amount) external onlyOwner {
        TreasuryPolicyLib.setLegacyBounty(_revenue, 1, enabled, amount);
    }

    function setStrategyCheckpointBountyDailyCap(uint256 dailyCap) external onlyOwner {
        AutonomousRevenueLib.setLegacyBountyCap(_revenue, 1, dailyCap);
    }

    // --- Hedge Bounty Functions (adjustHedge, pools DN) ---

    /// @notice Pay bounty to keeper who adjusted the hedge. Called by authorized AaveHedgeManager.
    /// @dev Appele en try/catch par AaveHedgeManager => le cap quotidien ne bloque jamais le reajustement.
    function payHedgeBounty(address keeper) external nonReentrant {
        TreasuryPolicyLib.payPoolBounty(_revenue, address(usdc), keeper, 3, 0);
    }

    function setHedgeBounty(bool _enabled, uint256 _amount) external onlyOwner {
        TreasuryPolicyLib.setLegacyBounty(_revenue, 3, _enabled, _amount);
    }

    function setHedgeBountyDailyCap(uint256 _dailyCap) external onlyOwner {
        AutonomousRevenueLib.setLegacyBountyCap(_revenue, 3, _dailyCap);
    }

    function authorizeHedgeManager(address _hedgeManager, bool _authorized) external onlyInstaller {
        AutonomousRevenueLib.authorize(_revenue, _hedgeManager, _authorized, 4);
        emit HedgeManagerAuthorized(_hedgeManager, _authorized);
    }

    // --- Deposit Bounty Functions (processDepositPermissionless) ---

    /// @notice Pay bounty to keeper who processed a queued user deposit. Called by authorized Vault.
    /// @dev Appele en try/catch depuis le Vault => ne bloque jamais le traitement du depot.
    ///      Anti-drain: le Vault revert si la file est vide, donc paye uniquement sur depot reel.
    function payDepositBounty(address keeper, address depositor, uint256 depositValueUsd) external nonReentrant {
        AutonomousRevenueLib.payConfiguredDeposit(_revenue, address(usdc), keeper, depositor, depositValueUsd);
    }

    function setDepositBounty(bool _enabled, uint256 _amount) external onlyOwner {
        AutonomousRevenueLib.setDepositBounty(_revenue, _enabled, _amount);
    }

    function setDepositBountyLimits(uint64 _vaultCooldown, uint64 _keeperCooldown, uint256 _dailyCap)
        external
        onlyOwner
    {
        AutonomousRevenueLib.setDepositBountyLimits(_revenue, _vaultCooldown, _keeperCooldown, _dailyCap);
    }

    function authorizeVault(address _vault, bool _authorized) external onlyInstaller {
        AutonomousRevenueLib.authorize(_revenue, _vault, _authorized, 8);
        emit VaultAuthorized(_vault, _authorized);
    }

    /// @notice Configure the conversion bounty (paid to the caller of a successful local USDC conversion).
    function setConversionBounty(bool _enabled, uint256 _amount) external onlyOwner {
        AutonomousRevenueLib.setConversionBounty(_revenue, _enabled, _amount);
    }

    /// @notice Configure the anti-drain protections for the conversion bounty.
    /// @param _cooldown Minimum seconds between two paid bounties (e.g. 21600 = 6h).
    /// @param _minRatio Minimum ratio of converted USDC amount over bounty amount (e.g. 50 means
    ///        the conversion must produce at least 100× the bounty value to earn it). 0 disables bounty payment.
    function setConversionBountyCooldown(uint64 _cooldown, uint16 _minRatio) external onlyOwner {
        AutonomousRevenueLib.setConversionBountyCooldown(_revenue, _cooldown, _minRatio);
    }



    function authorizeRangeManager(address _rangeManager, bool _authorized) external onlyInstaller {
        AutonomousRevenueLib.authorize(_revenue, _rangeManager, _authorized, 1);
        emit RangeManagerAuthorized(_rangeManager, _authorized);
    }

    function authorizeStrategyEngine(address engine, bool authorized) external onlyInstaller {
        AutonomousRevenueLib.authorize(_revenue, engine, authorized, 2);
        emit StrategyEngineAuthorized(engine, authorized);
    }

    /// @notice Déclare/maj le feed Chainlink (prix USD) d'un token swappable + le slippage et heartbeat tolérés.
    /// @dev Utiliser removeSwapFeed(token) pour retirer explicitement une configuration. Slippage borné [10..1000] bps.

    function setConversionRouter(address token, address router) external onlyInstaller {
        require(
            !_revenue.policy.assets[token].installed && token != address(usdc) && router.code.length > 0,
            AutonomousCheck(0x771fd59c)
        );
        _revenue.policy.assets[token].router = router;
    }

    /// @dev Plancher anti-sandwich : USDC minimum attendu pour `amountIn` de `tokenIn`, depuis l'oracle
    ///      Chainlink (prix USD du token), minoré du slippage. Revert si aucun feed n'est configuré.
    ///      Conversion générique des décimales (token volatil, feed, USDC) — pas de hard-code.
    function _oracleSwapBounds(address token, uint256 amount) internal view returns (uint256, uint160) {
        return AutonomousRevenueLib.bounds(
            token,
            address(usdc),
            amount,
            address(_revenue.policy.assets[token].feed),
            address(_revenue.policy.assets[address(usdc)].feed),
            _revenue.policy.assets[token].maxAge,
            _revenue.policy.assets[address(usdc)].maxAge,
            _revenue.policy.assets[token].slippageBps
        );
    }

    function _validBountyCap(uint256 cap) internal view returns (bool) {
        return cap > 0 && cap <= 1_000_000 * (10 ** uint256(usdcDecimals));
    }







    function assetSealed(address token) external view returns (bool) {
        return _revenue.policy.assets[token].installed;
    }

    function conversionMaxInput(address token) external view returns (uint256) {
        return _revenue.policy.assets[token].maxInput;
    }

    function conversionMinUsdc(address token) external view returns (uint256) {
        return _revenue.policy.assets[token].minUsdc;
    }

    function conversionCooldown(address token) external view returns (uint64) {
        return _revenue.policy.assets[token].cooldown;
    }

    function swapFeeds(address token) external view returns (address) {
        return _revenue.policy.assets[token].feed;
    }

    function swapFeedMaxAges(address token) external view returns (uint32) {
        return _revenue.policy.assets[token].maxAge;
    }

    function swapFeedSlippageBps(address token) external view returns (uint16) {
        return _revenue.policy.assets[token].slippageBps;
    }

    function conversionRouters(address token) external view returns (address) {
        return _revenue.policy.assets[token].router;
    }

    function swapPoolFees(address token) external view returns (uint24) {
        return _revenue.policy.assets[token].fee;
    }

    function conversionPath(address token) external view returns (bytes memory) {
        return _revenue.policy.assets[token].path;
    }

    function keeperBountyDay(address actor) external view returns (uint64 day) {
        (day,) = TreasuryPolicyLib.sourceSpent(_revenue, actor, 0);
    }

    function keeperBountyDailySpent(address actor) external view returns (uint256 spent) {
        (, spent) = TreasuryPolicyLib.sourceSpent(_revenue, actor, 0);
    }

    function strategyCheckpointBountyDay(address actor) external view returns (uint64 day) {
        (day,) = TreasuryPolicyLib.sourceSpent(_revenue, actor, 1);
    }

    function strategyCheckpointBountyDailySpent(address actor) external view returns (uint256 spent) {
        (, spent) = TreasuryPolicyLib.sourceSpent(_revenue, actor, 1);
    }

    function hedgeBountyDay(address actor) external view returns (uint64 day) {
        (day,) = TreasuryPolicyLib.sourceSpent(_revenue, actor, 3);
    }

    function hedgeBountyDailySpent(address actor) external view returns (uint256 spent) {
        (, spent) = TreasuryPolicyLib.sourceSpent(_revenue, actor, 3);
    }

    function lastPaidStrategyCheckpointEpoch(address actor) external view returns (uint64) {
        return _revenue.policy.lastEpoch[actor];
    }

    function governancePolicy() external view returns (address governance, address catalogue, address registry) {
        TreasuryPolicyLib.Policy storage p = _revenue.policy;
        return (p.governance, p.catalogue, p.registry);
    }

    function installGovernancePolicy(address governance, address catalogue, address registry) external onlyOwner {
        TreasuryPolicyLib.installGovernancePolicy(_revenue, governance, catalogue, registry);
    }

    function installApprovedSource(bytes32 instanceId, address factory) external nonReentrant {
        TreasuryPolicyLib.installApprovedSource(_revenue, instanceId, factory);
    }

    function sourceBounty(address source, uint8 kind) external view returns (uint256 amount, uint256 cap) {
        return TreasuryPolicyLib.sourceBounty(_revenue, source, kind);
    }

    function bountyBounds(uint8 kind) external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return TreasuryPolicyLib.bountyBounds(kind, usdcDecimals);
    }

    function setSourceBounty(address source, uint8 kind, uint256 amount, uint256 dailyCap) external {
        TreasuryPolicyLib.setSourceBounty(_revenue, source, kind, amount, dailyCap);
    }

    function setGovernanceBounties(uint256 control, uint256 action, uint256 globalCap, uint256 addressCap) external {
        TreasuryPolicyLib.setGovernanceBounties(_revenue, control, action, globalCap, addressCap);
    }

    function governanceBountyState(address keeper)
        external
        view
        returns (TreasuryPolicyLib.GovSettings memory, uint256, uint256, uint256, uint256, uint256, uint64, uint256)
    {
        return TreasuryPolicyLib.governanceState(_revenue, keeper);
    }

    function governanceBountyKeyConsumed(bytes32 key) external view returns (bool) {
        return _revenue.policy.consumed[key];
    }

    function pruneBountyWindows(address keeper, uint256 max) external {
        TreasuryPolicyLib.pruneGovernance(_revenue, keeper, max);
    }

    function payGovernanceBounty(uint8 category, bytes32 actionKey, address executor)
        external
        nonReentrant
        returns (uint256 paid)
    {
        return TreasuryPolicyLib.payGovernanceBounty(_revenue, category, actionKey, executor);
    }

    function performGovernanceBountyTransfer(address keeper, uint256 amount) external {
        require(msg.sender == address(this));
        usdc.safeTransfer(keeper, amount);
    }

    function performConversionBountyTransfer(address keeper, uint256 amount) external returns (uint256) {
        return TreasuryPolicyLib.payConversionBounty(_revenue, address(usdc), keeper, amount);
    }

    function keeperBountyEnabled() external view returns (bool) {
        return _revenue.legacy.keeperBountyEnabled;
    }

    function keeperBountyAmount() external view returns (uint256) {
        return _revenue.legacy.keeperBountyAmount;
    }

    function keeperBountyDailyCap() external view returns (uint256) {
        return _revenue.legacy.keeperBountyDailyCap;
    }

    function strategyCheckpointBountyEnabled() external view returns (bool) {
        return _revenue.legacy.strategyCheckpointBountyEnabled;
    }

    function strategyCheckpointBountyAmount() external view returns (uint256) {
        return _revenue.legacy.strategyCheckpointBountyAmount;
    }

    function strategyCheckpointBountyDailyCap() external view returns (uint256) {
        return _revenue.legacy.strategyCheckpointBountyDailyCap;
    }

    function hedgeBountyEnabled() external view returns (bool) {
        return _revenue.legacy.hedgeBountyEnabled;
    }

    function hedgeBountyAmount() external view returns (uint256) {
        return _revenue.legacy.hedgeBountyAmount;
    }

    function hedgeBountyDailyCap() external view returns (uint256) {
        return _revenue.legacy.hedgeBountyDailyCap;
    }

    function depositBountyEnabled() external view returns (bool) {
        return _revenue.legacy.depositBountyEnabled;
    }

    function depositBountyAmount() external view returns (uint256) {
        return _revenue.legacy.depositBountyAmount;
    }

    function depositBountyCooldown() external view returns (uint64) {
        return _revenue.legacy.depositBountyCooldown;
    }

    function depositBountyKeeperCooldown() external view returns (uint64) {
        return _revenue.legacy.depositBountyKeeperCooldown;
    }

    function depositBountyDailyCap() external view returns (uint256) {
        return _revenue.legacy.depositBountyDailyCap;
    }

    function conversionBountyEnabled() external view returns (bool) {
        return _revenue.legacy.conversionBountyEnabled;
    }

    function conversionBountyAmount() external view returns (uint256 amount) {
        if (_revenue.policy.governance != address(0)) (amount,) = TreasuryPolicyLib.sourceBounty(_revenue, address(this), 4);
        else amount = _revenue.legacy.conversionBountyAmount;
    }

    function conversionBountyDailyCap() external view returns (uint256 cap) {
        (,cap) = TreasuryPolicyLib.sourceBounty(_revenue, address(this), 4);
    }

    function conversionBountyCooldown() external view returns (uint64) {
        return _revenue.legacy.conversionBountyCooldown;
    }

    function lastConversionBountyAt() external view returns (uint64) {
        return _revenue.legacy.lastConversionBountyAt;
    }

    function conversionBountyMinRatio() external view returns (uint16) {
        return _revenue.legacy.conversionBountyMinRatio;
    }
}
