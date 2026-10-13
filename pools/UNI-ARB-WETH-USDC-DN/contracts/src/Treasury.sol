// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import "./AutonomousErrors.sol";
import "./ProtocolSafetyLib.sol";
import "./AutonomousRevenueLib.sol";
import {RevenueBridgeLib, IRevenueStargate} from "./RevenueBridgeLib.sol";

import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// --- Stargate v2 Interfaces ---



contract Treasury is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    error BridgeBountyCooldownZero();
    error BridgeBountyMinRatioZero();
    error BridgeTransferMismatch();

    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    // --- Immutables ---
    IERC20 public immutable usdc;
    uint8 public immutable usdcDecimals;
    ISwapRouter public immutable swapRouter;
    IRevenueStargate public immutable stargatePool;

    // --- State ---
    AutonomousRevenueLib.State private _revenue;
    uint16 public constant BOUNTY_RESERVE_BPS = 500;
    bool public configurationSealed;
    mapping(address => bool) public assetSealed;
    address public revenueDestination;
    address public company;
    uint64 public nextDistributionPauseAt;
    event ConfigurationSealed();
    event AssetSealed(address indexed token);
    bool private _distributionsPaused;
    uint64 public guardianDistributionPauseUntil;
    address public rescueSafe;

    // --- Keeper Bounty (rebalance) ---
    bool public keeperBountyEnabled;
    uint256 public keeperBountyAmount;
    uint256 public keeperBountyDailyCap; // max rebalance bounties paid per UTC day per RangeManager
    mapping(address => uint64) public keeperBountyDay;
    mapping(address => uint256) public keeperBountyDailySpent;
    function authorizedRangeManagers(address actor) public view returns(bool){return (_revenue.roles[actor]&1)!=0;}

    // SÉCURITÉ (audit V1) : plancher oracle anti-sandwich pour les swaps de la Treasury.
    // Le Treasury est PARTAGÉ par toutes les pools d'une même chaîne → il peut swapper des tokens
    // volatils variés (WETH, WBTC, ...). Un feed Chainlink par token est déclaré par la gouvernance.
    // swapToUSDC impose amountOutMinimum >= prix oracle × (1 − swapFeedSlippageBps[token]),
    // et REVERT si aucun feed n'est configuré pour tokenIn (pas de swap d'un token non oraclé).
    mapping(address => uint256) public conversionMaxInput;
    mapping(address => uint256) public conversionMinUsdc;
    mapping(address => uint64) public conversionCooldown;
    function lastConversionAt(address token) external view returns (uint64) { return _revenue.conversions[address(this)][token].started; }
    function lastSourceConversionAt(address source, address token) external view returns (uint64) { return _revenue.conversions[source][token].started; }
    event PublicConversionConfigured(address indexed token, uint256 maxInput, uint256 minUsdc, uint64 cooldown);

    mapping(address => AggregatorV3Interface) public swapFeeds; // tokenIn => feed Chainlink (prix en USD)
    mapping(address => uint32) public swapFeedMaxAges; // tokenIn => heartbeat max accepte pour ce feed
    mapping(address => uint16) public swapFeedSlippageBps; // tokenIn => slippage max tolere pour le floor oracle
    mapping(address => address) public conversionRouters;
    mapping(address => uint24) public swapPoolFees; // tokenIn => fee tier Uniswap autorise par le batch de pool

    // Anti-drain protections (configurable by multisig):
    //  - cooldown:  bounty paid at most once per `bridgeBountyCooldown` seconds
    //  - min ratio: bridged amount must be >= bridgeBountyAmount * BRIDGE_BOUNTY_MIN_RATIO
    //               (default 50, ie. you must bridge >= 50× the bounty value to earn it)
    bool public bridgeBountyEnabled;
    uint256 public bridgeBountyAmount;
    uint64 public bridgeBountyCooldown; // seconds between two bounty payments
    uint64 public lastBridgeBountyAt; // unix timestamp of the last paid bounty
    uint16 public bridgeBountyMinRatio; // bounty paid only if bridged >= bountyAmount * ratio

    // --- Strategy checkpoint bounty ---
    bool public strategyCheckpointBountyEnabled;
    uint256 public strategyCheckpointBountyAmount;
    uint256 public strategyCheckpointBountyDailyCap;
    mapping(address => uint64) public strategyCheckpointBountyDay;
    mapping(address => uint256) public strategyCheckpointBountyDailySpent;
    mapping(address => uint64) public lastPaidStrategyCheckpointEpoch;
    function authorizedStrategyEngines(address actor) public view returns(bool){return (_revenue.roles[actor]&2)!=0;}

    // --- Hedge Bounty (adjustHedge, pools DN) — paye au keeper qui reajuste le hedge ---
    // Anti-drain: adjustHedge() est deja borne cote AaveHedgeManager par drift+cooldown, et le Treasury ajoute
    // un cap quotidien par HedgeManager. Si le cap est atteint, le caller AaveHedgeManager catch le revert et le
    // reajustement continue sans bounty.
    bool public hedgeBountyEnabled;
    uint256 public hedgeBountyAmount;
    uint256 public hedgeBountyDailyCap; // max hedge bounties paid per UTC day per HedgeManager
    mapping(address => uint64) public hedgeBountyDay;
    mapping(address => uint256) public hedgeBountyDailySpent;
    function authorizedHedgeManagers(address actor) public view returns(bool){return (_revenue.roles[actor]&4)!=0;}

    // --- Deposit Bounty (processDepositPermissionless) — paye au keeper qui traite un depot en file ---
    // Le caller est le Vault (pas le RangeManager) -> autorisation dediee authorizedVaults.
    // Anti-drain: pas de paiement direct au deposant + ratio depot/bounty + cooldown/cap quotidien par Vault.
    // Une collusion Sybil reste inherente a une prime permissionless, mais son rendement est strictement borne.
    // Le traitement reste permissionless; si ces limites revert, le Vault saute seulement la prime.
    bool public depositBountyEnabled;
    uint256 public depositBountyAmount;
    uint64 public depositBountyCooldown; // seconds between two paid deposit bounties per Vault
    uint64 public depositBountyKeeperCooldown; // seconds between two paid deposit bounties for the same keeper per Vault
    uint256 public depositBountyDailyCap; // max deposit bounties paid per UTC day per Vault, in reward token units
    function lastDepositBountyAt(address actor) external view returns(uint64){return _revenue.depositAt[actor];}
    function lastDepositBountyKeeperAt(address actor,address keeper) external view returns(uint64){return _revenue.depositKeeperAt[actor][keeper];}
    function depositBountyDay(address actor) external view returns(uint64){return _revenue.depositDay[actor];}
    function depositBountyDailySpent(address actor) external view returns(uint256){return _revenue.depositSpent[actor];}
    function authorizedVaults(address actor) public view returns(bool){return (_revenue.roles[actor]&8)!=0;}

    // --- Bridge (Stargate v2) ---
    bool public bridgeEnabled;
    uint32 public bridgeDestinationEid; // LayerZero v2 endpoint ID (e.g. 30184 = Base)
    address public bridgeDestinationAddress; // Recipient on destination chain (revenue Treasury)
    uint16 public bridgeMinReceivedBps; // 0 = disabled, otherwise min received / sent ratio in bps

    // --- Events ---
    event AdminWithdrawal(uint256 amount, address indexed to);
    event DistributionsPauseUpdated(bool paused, address indexed caller);
    event RescueSafeUpdated(address indexed oldSafe, address indexed newSafe);
    event FeesDistributed(uint256 amount);
    event SwappedToUSDC(address indexed tokenIn, uint24 fee, uint256 amountIn, uint256 usdcOut);
    event KeeperBountyPaid(address indexed keeper, uint256 amount);
    event KeeperBountyConfigured(bool enabled, uint256 amount);
    event KeeperBountyDailyCapConfigured(uint256 dailyCap);
    event HedgeBountyDailyCapConfigured(uint256 dailyCap);
    event BridgeBountyPaid(address indexed keeper, uint256 amount);
    event BridgeBountySkipped(address indexed keeper, string reason);
    event BridgeBountyConfigured(bool enabled, uint256 amount);
    event BridgeBountyCooldownConfigured(uint64 cooldown, uint16 minRatio);
    event BridgeMinReceivedConfigured(uint16 minReceivedBps);
    event BridgeConfigured(bool enabled, uint32 dstEid, address destination);
    event RevenueBridged(uint256 amountSent, uint256 amountReceived, uint32 dstEid, bytes32 guid);
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
        uint256 _keeperBountyAmount,
        address _stargatePool
    ) {
        require(_usdc != address(0) && _swapRouter != address(0) && _stargatePool != address(0), AutonomousCheck(0x4c9bb549));
        usdc = IERC20(_usdc);
        usdcDecimals = IERC20Metadata(_usdc).decimals();
        require(usdcDecimals <= 18, AutonomousCheck(0x8a0ba966));
        require(_validBountyCap(_initialBountyDailyCap), AutonomousCheck(0xdc524c4e));
        swapRouter = ISwapRouter(_swapRouter);
        rescueSafe = msg.sender;
        company = msg.sender;
        if (_keeperBountyEnabled) {
            require(_keeperBountyAmount > 0 && _keeperBountyAmount <= _initialBountyDailyCap, AutonomousCheck(0x5b636e99));
            keeperBountyDailyCap = _initialBountyDailyCap;
        }
        keeperBountyEnabled = _keeperBountyEnabled;
        keeperBountyAmount = _keeperBountyAmount;
        stargatePool = IRevenueStargate(_stargatePool);
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
        require(!configurationSealed, AutonomousCheck(0x9a247fa1)); super.transferOwnership(newOwner);
    }
    /// @notice Fresh-source/asset installation belongs to the company after global sealing.
    /// @dev Existing assets, actors, economics and settlement routes remain immutable.
    function installer() public view returns(address){return configurationSealed?company:owner();}
    modifier onlyInstaller(){require(msg.sender==installer(),AutonomousCheck(0x2027c175));_;}
    function setCompany(address admin) external onlyOwner {
        require(!configurationSealed && admin != address(0), AutonomousCheck(0x2c7e43eb)); company = admin;
    }
    function sealConfiguration() external onlyOwner {
        require(!configurationSealed && pendingOwner() == address(0), AutonomousCheck(0x9a247fa1));
        configurationSealed = true; emit ConfigurationSealed();
    }
    function sealAsset(address token) external onlyInstaller {
        require(!assetSealed[token] && address(swapFeeds[token]) != address(0), AutonomousCheck(0x4bb6522b));
        if (token != address(usdc)) require(conversionMaxInput[token] > 0 && swapPoolFees[token] != 0, AutonomousCheck(0xadb5731e));
        assetSealed[token] = true; emit AssetSealed(token);
    }
    function installRevenueSource(address source, address[] calldata actors) external onlyInstaller {
        AutonomousRevenueLib.install(_revenue, source, actors);
    }
    function sealRevenueSource(address source) external onlyInstaller {AutonomousRevenueLib.sealSource(_revenue,source);}
    function revenueSourceSealed(address source) external view returns(bool){return _revenue.sourceSealed[source];}
    function recordRevenue(address token, uint256 amount) external nonReentrant {
        require(assetSealed[token], AutonomousCheck(0x82570cf2));
        AutonomousRevenueLib.record(_revenue, address(usdc), token, amount);
    }
    function syncRevenue(address token) external nonReentrant { require(assetSealed[token],AutonomousCheck(0x82570cf2)); AutonomousRevenueLib.sync(_revenue, address(usdc), token); }
    function sourceOf(address actor) external view returns (address) { return _revenue.sourceOf[actor]; }
    function pendingRevenue(address source, address token) external view returns (uint256) { return _revenue.pending[source][token]; }
    function sourceBountyReserve(address source) external view returns (uint256) { return _revenue.reserve[source]; }
    function cumulativeUsdcRevenue(address source) external view returns (uint256) { return _revenue.revenue[source]; }
    function bountyReserveUsdc() external view returns (uint256) { return _bountyReserveUsdc(); }
    function fundBounties(address source, uint256 amount) external nonReentrant {
        AutonomousRevenueLib.fund(_revenue, address(usdc), source, amount);
    }
    function _syncUsdc() private { AutonomousRevenueLib.sync(_revenue, address(usdc), address(usdc)); }
    function _spendBounty(address actor, uint256 amount) private {
        _syncUsdc(); AutonomousRevenueLib.spend(_revenue, actor, amount);
        AutonomousRevenueLib.debit(_revenue, address(usdc), amount);
    }
    address public wrappedNative;
    function setWrappedNative(address token) external onlyOwner {
        require(!configurationSealed && wrappedNative == address(0) && token.code.length > 0, AutonomousCheck(0xcc3783a8)); wrappedNative = token;
    }
    function wrapNativeFees() external nonReentrant {
        require(wrappedNative != address(0) && assetSealed[wrappedNative], AutonomousCheck(0x1740b452));
        ProtocolSafetyLib.wrapNative(wrappedNative);
        AutonomousRevenueLib.sync(_revenue, address(usdc), wrappedNative);
    }
    // --- Public Functions ---

    /// @notice Swap an approved ERC-20 held by this Treasury to USDC through an owner-authorized route.
    /// @dev A zero minAmountOut uses the live oracle floor; a higher caller minimum is preserved.


    // is a separate deterministic entry point with capped input, cooldown and fixed route.


    function _executeFixedFeeSwap(address tokenIn, uint24 fee, uint256 amountIn, uint256 minAmountOut)
        private returns (uint256 amountOut) {
        require(tokenIn != address(usdc), AutonomousCheck(0x02ff93bd));
        require(fee == swapPoolFees[tokenIn] && fee != 0, AutonomousCheck(0xd8bea72e));
        (uint256 floor, uint160 limit) = _oracleSwapBounds(tokenIn, amountIn);
        amountOut = ProtocolSafetyLib.swap(tokenIn, address(usdc), conversionRouters[tokenIn] == address(0) ? address(swapRouter) : conversionRouters[tokenIn], fee, amountIn,
            minAmountOut > floor ? minAmountOut : floor, limit);
        emit SwappedToUSDC(tokenIn, fee, amountIn, amountOut);
    }

    /// @dev Uses Taxi mode (immediate delivery). Caller pays native gas for cross-chain fees via msg.value.
    function bridgeRevenue(uint256 amount) external payable nonReentrant {
        require(!distributionsPaused() && bridgeEnabled, AutonomousCheck(0x7b886e9d));
        _syncUsdc(); _requireDistributableUsdc(amount);
        AutonomousRevenueLib.debit(_revenue, address(usdc), amount);
        (uint256 received, bytes32 guid, uint256 nativeFee) = RevenueBridgeLib.send(
            address(stargatePool), address(usdc), bridgeDestinationEid, bridgeDestinationAddress, amount, bridgeMinReceivedBps);
        emit RevenueBridged(amount, received, bridgeDestinationEid, guid);
        _payBridgeBounty(msg.sender, amount); _refundNativeSurplus(nativeFee);
    }

    /// @dev Pays the bridge bounty to `keeper` if enabled, the treasury holds enough USDC,
    ///      the cooldown has passed, and `bridgedAmount` is large enough to justify the bounty.
    ///      Explicit no-op otherwise — never blocks the bridge itself.
    function _payBridgeBounty(address keeper, uint256 bridgedAmount) internal {
        if (!bridgeBountyEnabled || bridgeBountyAmount == 0) {
            emit BridgeBountySkipped(keeper, "disabled");
            return;
        }
        uint256 ratio = uint256(bridgeBountyMinRatio);
        if (bridgeBountyCooldown == 0 || ratio == 0) {
            emit BridgeBountySkipped(keeper, "unconfigured");
            return;
        }
        if (block.timestamp < uint256(lastBridgeBountyAt) + uint256(bridgeBountyCooldown)) {
            emit BridgeBountySkipped(keeper, "cooldown");
            return;
        }
        if (bridgedAmount < bridgeBountyAmount * ratio) {
            emit BridgeBountySkipped(keeper, "too-small");
            return;
        }
        if (_revenue.reserve[address(this)] < bridgeBountyAmount) {
            emit BridgeBountySkipped(keeper, "balance");
            return;
        }
        lastBridgeBountyAt = uint64(block.timestamp);
        _spendBounty(address(this), bridgeBountyAmount);
        usdc.safeTransfer(keeper, bridgeBountyAmount);
        emit BridgeBountyPaid(keeper, bridgeBountyAmount);
    }

    function _requireDistributableUsdc(uint256 amount) internal view {
        require(amount > 0 && amount <= _distributableUsdc(), AutonomousCheck(0xbac20538));
    }

    function _distributableUsdc() internal view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 reserve = _bountyReserveUsdc();
        return balance > reserve ? balance - reserve : 0;
    }

    /// @notice Exact USDC balance available for permissionless distribution after every active bounty reserve.

    /// @dev No caller-selected amount, route, recipient or minimum is accepted.
    function setPublicConversion(address token, uint256 maxInput, uint256 minUsdc, uint64 cooldown) external onlyInstaller {
        require(!assetSealed[token], AutonomousCheck(0xd3f8500a));
        require(token != address(usdc) && token.code.length > 0, AutonomousCheck(0x799c831e));
        if (maxInput != 0) {
            require(minUsdc >= 10 ** uint256(usdcDecimals), AutonomousCheck(0xd34f8e6b));
            require(cooldown >= 1 hours && cooldown <= 30 days, AutonomousCheck(0x2af0853b));
        }
        conversionMaxInput[token] = maxInput;
        conversionMinUsdc[token] = minUsdc;
        conversionCooldown[token] = cooldown;
        emit PublicConversionConfigured(token, maxInput, minUsdc, cooldown);
    }

    function previewFeeConversion(address token) public view returns (uint256 amountIn, uint256 minOut, uint64 nextAt) {
        return previewSourceFeeConversion(address(this), token);
    }
    function previewSourceFeeConversion(address source, address token) public view returns (uint256 amountIn, uint256 minOut, uint64 nextAt) {
        uint256 remaining;
        (remaining, nextAt) = AutonomousRevenueLib.conversionRemaining(_revenue, source, token, conversionMaxInput[token], conversionCooldown[token]);
        if (!assetSealed[token] || remaining == 0 || distributionsPaused()) return (0, 0, nextAt);
        amountIn = _revenue.pending[source][token];
        if (source == address(this)) {
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > _revenue.accounted[token]) amountIn += balance - _revenue.accounted[token];
        }
        if (amountIn > remaining) amountIn = remaining;
        if (amountIn == 0) return (0, 0, nextAt);
        (minOut,) = _oracleSwapBounds(token, amountIn);
        if (minOut < conversionMinUsdc[token]) return (0, 0, nextAt);
    }

    function convertFeesToUSDC(address token) external nonReentrant returns (uint256 amountOut) {
        AutonomousRevenueLib.sync(_revenue, address(usdc), token);
        return _convertAvailable(address(this), token);
    }
    function convertSourceFeesToUSDC(address source, address token) external nonReentrant returns (uint256 amountOut) {
        return _convertAvailable(source, token);
    }
    function convertSourceFeeChunk(address source, address token, uint256 amountIn) external nonReentrant returns (uint256) {
        if (source == address(this)) AutonomousRevenueLib.sync(_revenue, address(usdc), token);
        (uint256 available,,) = previewSourceFeeConversion(source, token);
        require(amountIn > 0 && amountIn <= available, AutonomousCheck(0xd6a70ccf));
        (uint256 minOut,) = _oracleSwapBounds(token, amountIn);
        require(minOut >= conversionMinUsdc[token], AutonomousCheck(0xd34f8e6b));
        return _convertSource(source, token, amountIn, minOut);
    }
    function _convertAvailable(address source, address token) private returns (uint256) {
        (uint256 amountIn, uint256 minOut,) = previewSourceFeeConversion(source, token);
        require(amountIn > 0, AutonomousCheck(0xb9913616));
        return _convertSource(source, token, amountIn, minOut);
    }
    function _convertSource(address source, address token, uint256 amountIn, uint256 minOut) private returns (uint256 amountOut) {
        _syncUsdc();
        AutonomousRevenueLib.consumeConversion(_revenue, source, token, amountIn, conversionMaxInput[token], conversionCooldown[token]);
        amountOut = _executeFixedFeeSwap(token, swapPoolFees[token], amountIn, minOut);
        AutonomousRevenueLib.converted(_revenue, address(usdc), source, token, amountIn, amountOut);
    }

    function bridgeableUsdc() external view returns (uint256) {
        return _distributableUsdc();
    }

    function _bountyReserveUsdc() internal view returns (uint256) {
        return AutonomousRevenueLib.protectedBalance(_revenue, address(usdc));
    }

    function _refundNativeSurplus(uint256 usedNativeFee) internal {
        if (msg.value <= usedNativeFee) return;
        (bool ok,) = msg.sender.call{value: msg.value - usedNativeFee}("");
        require(ok, AutonomousCheck(0xcef6850b));
    }

    /// @notice Estimate bridge fee in native token (ETH/AVAX/MATIC/BNB)
    function estimateBridgeFee(uint256 amount) external view returns (uint256 nativeFee, uint256 amountReceived) {
        return RevenueBridgeLib.quote(address(stargatePool), bridgeDestinationEid, bridgeDestinationAddress, amount);
    }


    function adminWithdraw(uint256 amount, address to) external nonReentrant {
        require(msg.sender == company, AutonomousCheck(0x2027c175));
        AutonomousRevenueLib.withdraw(_revenue, address(usdc), to, amount); emit AdminWithdrawal(amount, to);
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



    function setDistributionsPaused(bool value) external onlyRescueSafe { _setDistributionPause(value, 48 hours); }
    function pauseRevenueFor(uint64 duration) external onlyRescueSafe { _setDistributionPause(true, duration); }
    function _setDistributionPause(bool value, uint64 duration) private {
        if (value) {
            require(duration >= 1 hours && duration <= 48 hours, AutonomousCheck(0x2e861dfb));
            require(!distributionsPaused() && block.timestamp >= nextDistributionPauseAt, AutonomousCheck(0xaa8f7a50));
            guardianDistributionPauseUntil = uint64(block.timestamp) + duration;
            nextDistributionPauseAt = guardianDistributionPauseUntil + 24 hours;
        } else {
            require(distributionsPaused(), AutonomousCheck(0xaecd4fd1));
            guardianDistributionPauseUntil = 0; nextDistributionPauseAt = uint64(block.timestamp + 24 hours);
        }
        _distributionsPaused = value; emit DistributionsPauseUpdated(value, msg.sender);
    }

    /// @notice Recover ERC-20 tokens held here in an emergency (other than USDC).


    function rescueToken(address tokenAddr, address to, uint256 amount) external onlyRescueSafe nonReentrant {
        require(!configurationSealed || distributionsPaused(), AutonomousCheck(0x1d45e305));
        require(!assetSealed[tokenAddr] && address(swapFeeds[tokenAddr]) == address(0) && _revenue.accounted[tokenAddr] == 0, AutonomousCheck(0x3ad6b46e));
        require(to == company && to != address(0), AutonomousCheck(0x160fe00b));
        require(tokenAddr != address(usdc), AutonomousCheck(0xb6c29bb8));
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit TokenRescued(tokenAddr, to, amount);
    }

    /// @notice Recover native ETH accidentally sent here.

    function rescueETH(address payable, uint256) external pure { revert AutonomousCheck(0x04d6d5a4); }

    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ETHRescued(address indexed to, uint256 amount);

    // --- Keeper Bounty Functions ---

    /// @notice Pay bounty to keeper who executed a rebalance. Called by authorized RangeManager.
    function payKeeperBounty(address keeper) external {
        require(keeper != address(0), AutonomousCheck(0x7245243a));
        require(authorizedRangeManagers(msg.sender), AutonomousCheck(0x52c79c7b));
        require(keeperBountyEnabled, AutonomousCheck(0xb897c761));
        require(keeperBountyAmount > 0, AutonomousCheck(0x2567641d));
        require(usdc.balanceOf(address(this)) >= keeperBountyAmount, AutonomousCheck(0x18ecfaa5));
        _consumeKeeperBountyLimit(msg.sender);

        _spendBounty(msg.sender, keeperBountyAmount);
        usdc.safeTransfer(keeper, keeperBountyAmount);
        emit KeeperBountyPaid(keeper, keeperBountyAmount);
    }

    function setKeeperBounty(bool _enabled, uint256 _amount) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        if (_enabled) {
            require(_amount > 0 && keeperBountyDailyCap >= _amount, AutonomousCheck(0x341d3670));
        }
        keeperBountyEnabled = _enabled;
        keeperBountyAmount = _amount;
        emit KeeperBountyConfigured(_enabled, _amount);
    }

    function _consumeKeeperBountyLimit(address rangeManager) internal {
        uint64 day = uint64(block.timestamp / 1 days);
        if (keeperBountyDay[rangeManager] != day) {
            keeperBountyDay[rangeManager] = day;
            keeperBountyDailySpent[rangeManager] = 0;
        }
        uint256 newSpent = keeperBountyDailySpent[rangeManager] + keeperBountyAmount;
        if (keeperBountyDailyCap > 0) {
            require(newSpent <= keeperBountyDailyCap, AutonomousCheck(0xa92dbde6));
        }
        keeperBountyDailySpent[rangeManager] = newSpent;
    }

    function setKeeperBountyDailyCap(uint256 _dailyCap) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        require(_dailyCap == 0 || _validBountyCap(_dailyCap), AutonomousCheck(0xdc524c4e));
        if (keeperBountyEnabled) require(_dailyCap >= keeperBountyAmount, AutonomousCheck(0xb5e14be5));
        keeperBountyDailyCap = _dailyCap;
        emit KeeperBountyDailyCapConfigured(_dailyCap);
    }

    // --- Strategy checkpoint bounty functions ---

    /// @notice Pays au plus un bounty par epoch canonique et par moteur autorise.
    /// @dev Le moteur fixe lui-meme l'epoch; le cap quotidien borne aussi un moteur compromis.
    function payStrategyCheckpointBounty(address keeper, uint64 epoch) external {
        require(keeper != address(0) && epoch > lastPaidStrategyCheckpointEpoch[msg.sender], AutonomousCheck(0xca0ab3e3));
        require(authorizedStrategyEngines(msg.sender), AutonomousCheck(0x52c79c7b));
        require(strategyCheckpointBountyEnabled, AutonomousCheck(0xb897c761));
        require(strategyCheckpointBountyAmount > 0, AutonomousCheck(0x2567641d));
        require(usdc.balanceOf(address(this)) >= strategyCheckpointBountyAmount, AutonomousCheck(0x18ecfaa5));
        _consumeStrategyCheckpointBountyLimit(msg.sender);
        lastPaidStrategyCheckpointEpoch[msg.sender] = epoch;
        _spendBounty(msg.sender, strategyCheckpointBountyAmount);
        usdc.safeTransfer(keeper, strategyCheckpointBountyAmount);
        emit StrategyCheckpointBountyPaid(keeper, msg.sender, epoch, strategyCheckpointBountyAmount);
    }

    function setStrategyCheckpointBounty(bool enabled, uint256 amount) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        if (enabled) {
            require(amount > 0, AutonomousCheck(0x2567641d));
            require(strategyCheckpointBountyDailyCap >= amount, AutonomousCheck(0xac880810));
        }
        strategyCheckpointBountyEnabled = enabled;
        strategyCheckpointBountyAmount = amount;
        emit StrategyCheckpointBountyConfigured(enabled, amount);
    }

    function _consumeStrategyCheckpointBountyLimit(address engine) internal {
        uint64 day = uint64(block.timestamp / 1 days);
        if (strategyCheckpointBountyDay[engine] != day) {
            strategyCheckpointBountyDay[engine] = day;
            strategyCheckpointBountyDailySpent[engine] = 0;
        }
        uint256 newSpent = strategyCheckpointBountyDailySpent[engine] + strategyCheckpointBountyAmount;
        require(newSpent <= strategyCheckpointBountyDailyCap, AutonomousCheck(0xc5ba5b72));
        strategyCheckpointBountyDailySpent[engine] = newSpent;
    }

    function setStrategyCheckpointBountyDailyCap(uint256 dailyCap) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        require(dailyCap == 0 || _validBountyCap(dailyCap), AutonomousCheck(0xdc524c4e));
        if (strategyCheckpointBountyEnabled || dailyCap > 0) {
            require(dailyCap >= strategyCheckpointBountyAmount, AutonomousCheck(0xb5e14be5));
        }
        strategyCheckpointBountyDailyCap = dailyCap;
        emit StrategyCheckpointBountyDailyCapConfigured(dailyCap);
    }

    // --- Hedge Bounty Functions (adjustHedge, pools DN) ---

    /// @notice Pay bounty to keeper who adjusted the hedge. Called by authorized AaveHedgeManager.
    /// @dev Appele en try/catch par AaveHedgeManager => le cap quotidien ne bloque jamais le reajustement.
    function payHedgeBounty(address keeper) external {
        require(keeper != address(0), AutonomousCheck(0x7245243a));
        require(authorizedHedgeManagers(msg.sender), AutonomousCheck(0x52c79c7b));
        require(hedgeBountyEnabled, AutonomousCheck(0xb897c761));
        require(hedgeBountyAmount > 0, AutonomousCheck(0x2567641d));
        require(usdc.balanceOf(address(this)) >= hedgeBountyAmount, AutonomousCheck(0x18ecfaa5));
        _consumeHedgeBountyLimit(msg.sender);

        _spendBounty(msg.sender, hedgeBountyAmount);
        usdc.safeTransfer(keeper, hedgeBountyAmount);
        emit HedgeBountyPaid(keeper, hedgeBountyAmount);
    }

    function setHedgeBounty(bool _enabled, uint256 _amount) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        if (_enabled) {
            require(_amount > 0 && hedgeBountyDailyCap >= _amount, AutonomousCheck(0x341d3670));
        }
        hedgeBountyEnabled = _enabled;
        hedgeBountyAmount = _amount;
        emit HedgeBountyConfigured(_enabled, _amount);
    }

    function _consumeHedgeBountyLimit(address hedgeManager) internal {
        uint64 day = uint64(block.timestamp / 1 days);
        if (hedgeBountyDay[hedgeManager] != day) {
            hedgeBountyDay[hedgeManager] = day;
            hedgeBountyDailySpent[hedgeManager] = 0;
        }
        uint256 newSpent = hedgeBountyDailySpent[hedgeManager] + hedgeBountyAmount;
        if (hedgeBountyDailyCap > 0) {
            require(newSpent <= hedgeBountyDailyCap, AutonomousCheck(0xeca123c3));
        }
        hedgeBountyDailySpent[hedgeManager] = newSpent;
    }

    function setHedgeBountyDailyCap(uint256 _dailyCap) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        require(_dailyCap == 0 || _validBountyCap(_dailyCap), AutonomousCheck(0xdc524c4e));
        if (hedgeBountyEnabled) require(_dailyCap >= hedgeBountyAmount, AutonomousCheck(0xb5e14be5));
        hedgeBountyDailyCap = _dailyCap;
        emit HedgeBountyDailyCapConfigured(_dailyCap);
    }

    function authorizeHedgeManager(address _hedgeManager, bool _authorized) external onlyInstaller {
        AutonomousRevenueLib.authorize(_revenue,_hedgeManager,_authorized,4);
        emit HedgeManagerAuthorized(_hedgeManager,_authorized);
    }

    // --- Deposit Bounty Functions (processDepositPermissionless) ---

    /// @notice Pay bounty to keeper who processed a queued user deposit. Called by authorized Vault.
    /// @dev Appele en try/catch depuis le Vault => ne bloque jamais le traitement du depot.
    ///      Anti-drain: le Vault revert si la file est vide, donc paye uniquement sur depot reel.
    function payDepositBounty(address keeper,address depositor,uint256 depositValueUsd) external {
        AutonomousRevenueLib.payDeposit(_revenue,address(usdc),keeper,depositor,depositValueUsd,
          AutonomousRevenueLib.DepositPolicy(depositBountyEnabled,depositBountyAmount,depositBountyDailyCap,depositBountyCooldown,depositBountyKeeperCooldown,usdcDecimals));
    }

    function setDepositBounty(bool _enabled, uint256 _amount) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        if (_enabled) {
            require(_amount > 0, AutonomousCheck(0x2567641d));
            require(depositBountyCooldown > 0 && depositBountyKeeperCooldown > 0, AutonomousCheck(0xc5640d54));
            require(_amount <= depositBountyDailyCap, AutonomousCheck(0x26bf5266));
        }
        depositBountyEnabled = _enabled;
        depositBountyAmount = _amount;
        emit DepositBountyConfigured(_enabled, _amount);
    }

    function setDepositBountyLimits(uint64 _vaultCooldown, uint64 _keeperCooldown, uint256 _dailyCap)
        external
        onlyOwner
    {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        require(_vaultCooldown <= 1 days && _keeperCooldown <= 7 days, AutonomousCheck(0x06463f6b));
        if (depositBountyEnabled) require(_vaultCooldown > 0 && _keeperCooldown > 0, AutonomousCheck(0xc5640d54));
        require(_dailyCap == 0 || _validBountyCap(_dailyCap), AutonomousCheck(0xdc524c4e));
        if (depositBountyEnabled) require(_dailyCap >= depositBountyAmount, AutonomousCheck(0xb5e14be5));
        depositBountyCooldown = _vaultCooldown;
        depositBountyKeeperCooldown = _keeperCooldown;
        depositBountyDailyCap = _dailyCap;
        emit DepositBountyLimitsConfigured(_vaultCooldown, _keeperCooldown, _dailyCap);
    }

    function authorizeVault(address _vault, bool _authorized) external onlyInstaller {
        AutonomousRevenueLib.authorize(_revenue,_vault,_authorized,8);
        emit VaultAuthorized(_vault,_authorized);
    }

    /// @notice Configure the bridge bounty (paid to whoever calls bridgeRevenue).
    function setBridgeBounty(bool _enabled, uint256 _amount) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        if (_enabled && _amount > 0 && bridgeBountyCooldown == 0) revert BridgeBountyCooldownZero();
        if (_enabled && _amount > 0 && bridgeBountyMinRatio == 0) revert BridgeBountyMinRatioZero();
        if (_enabled) require(_amount > 0 && _validBountyCap(_amount), AutonomousCheck(0xa540b0da));
        bridgeBountyEnabled = _enabled;
        bridgeBountyAmount = _amount;
        emit BridgeBountyConfigured(_enabled, _amount);
    }

    /// @notice Configure the anti-drain protections for the bridge bounty.
    /// @param _cooldown Minimum seconds between two paid bounties (e.g. 21600 = 6h).
    /// @param _minRatio Minimum ratio of bridged amount over bounty amount (e.g. 50 means
    ///        you must bridge at least 50× the bounty value to earn it). 0 disables bounty payment.
    function setBridgeBountyCooldown(uint64 _cooldown, uint16 _minRatio) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        require(_cooldown == 0 || (_cooldown >= 1 hours && _cooldown <= 30 days), AutonomousCheck(0x08938d78));
        require(_minRatio == 0 || (_minRatio >= 10 && _minRatio <= 10000), AutonomousCheck(0x77b24299));
        if (bridgeBountyEnabled && bridgeBountyAmount > 0 && _cooldown == 0) revert BridgeBountyCooldownZero();
        if (bridgeBountyEnabled && bridgeBountyAmount > 0 && _minRatio == 0) revert BridgeBountyMinRatioZero();
        bridgeBountyCooldown = _cooldown;
        bridgeBountyMinRatio = _minRatio;
        emit BridgeBountyCooldownConfigured(_cooldown, _minRatio);
    }

    /// @notice Configure the minimum Stargate amount received ratio for bridge operations.
    /// @dev 0 disables the check. Otherwise the value must stay in [9000, 10000] bps.
    function setBridgeMinReceivedBps(uint16 _minReceivedBps) external onlyOwner {
        require(_minReceivedBps == 0 || (_minReceivedBps >= 9000 && _minReceivedBps <= 10000), AutonomousCheck(0x14dcfc69));
        if (bridgeEnabled) require(_minReceivedBps >= 9000, AutonomousCheck(0x5d2c86a7));
        bridgeMinReceivedBps = _minReceivedBps;
        emit BridgeMinReceivedConfigured(_minReceivedBps);
    }

    function authorizeRangeManager(address _rangeManager, bool _authorized) external onlyInstaller {
        AutonomousRevenueLib.authorize(_revenue,_rangeManager,_authorized,1);
        emit RangeManagerAuthorized(_rangeManager,_authorized);
    }

    function authorizeStrategyEngine(address engine, bool authorized) external onlyInstaller {
        AutonomousRevenueLib.authorize(_revenue,engine,authorized,2);
        emit StrategyEngineAuthorized(engine,authorized);
    }


    /// @notice Déclare/maj le feed Chainlink (prix USD) d'un token swappable + le slippage et heartbeat tolérés.
    /// @dev Utiliser removeSwapFeed(token) pour retirer explicitement une configuration. Slippage borné [10..1000] bps.
    function setSwapFeed(address token, address feed, uint16 _swapSlippageBps, uint32 _maxAge) external onlyInstaller {
        require(!assetSealed[token] || address(swapFeeds[token]) == feed, AutonomousCheck(0x61ac430d));
        require(token != address(0), AutonomousCheck(0x086efea7));
        require(feed != address(0), AutonomousCheck(0x422790c9));
        require(_swapSlippageBps >= 10 && _swapSlippageBps <= 1000, AutonomousCheck(0x3b5e082d));
        require(_maxAge >= 3600 && _maxAge <= 172800, AutonomousCheck(0xd357f7c0));
        require(
            IERC20Metadata(token).decimals() <= 18 && usdcDecimals <= 18 && AggregatorV3Interface(feed).decimals() <= 18, AutonomousCheck(0x8a0ba966));
        swapFeeds[token] = AggregatorV3Interface(feed);
        swapFeedMaxAges[token] = _maxAge;
        swapFeedSlippageBps[token] = _swapSlippageBps;
        emit SwapFeedConfigured(token, feed, _swapSlippageBps, _maxAge);
    }

    function setConversionRouter(address token, address router) external onlyInstaller {
        require(!assetSealed[token] && token != address(usdc) && router.code.length > 0, AutonomousCheck(0x771fd59c));
        conversionRouters[token] = router;
    }
    function setSwapPoolFee(address token, uint24 fee) external onlyInstaller {
        require(!assetSealed[token], AutonomousCheck(0xd3f8500a));
        require(token != address(0) && token != address(usdc), AutonomousCheck(0x086efea7));
        require(fee == 100 || fee == 500 || fee == 3000 || fee == 10000, AutonomousCheck(0x6d94368d));
        swapPoolFees[token] = fee;
        emit SwapPoolFeeConfigured(token, fee);
    }



    /// @dev Plancher anti-sandwich : USDC minimum attendu pour `amountIn` de `tokenIn`, depuis l'oracle
    ///      Chainlink (prix USD du token), minoré du slippage. Revert si aucun feed n'est configuré.
    ///      Conversion générique des décimales (token volatil, feed, USDC) — pas de hard-code.
    function _oracleSwapBounds(address token, uint256 amount) internal view returns (uint256, uint160) {
        return ProtocolSafetyLib.bounds(token, address(usdc), amount, address(swapFeeds[token]),
            address(swapFeeds[address(usdc)]), swapFeedMaxAges[token], swapFeedMaxAges[address(usdc)], swapFeedSlippageBps[token]);
    }

    function _validBountyCap(uint256 cap) internal view returns (bool) {
        return cap > 0 && cap <= 1_000_000 * (10 ** uint256(usdcDecimals));
    }


    function setBridgeConfig(bool _enabled, uint32 _dstEid, address _destination) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        if (_enabled) {
            require(_dstEid != 0 && _destination != address(0), AutonomousCheck(0x0f0420b8));
            require(bridgeMinReceivedBps >= 9000, AutonomousCheck(0x6767d579));
        }
        bridgeEnabled = _enabled;
        bridgeDestinationEid = _dstEid;
        bridgeDestinationAddress = _destination;
        emit BridgeConfigured(_enabled, _dstEid, _destination);
    }




    function setRevenueDestination(address destination) external onlyOwner {
        require(!configurationSealed && destination != address(0), AutonomousCheck(0x9a247fa1));
        revenueDestination = destination;
    }

    function forwardRevenue(uint256 amount) external nonReentrant {
        require(!distributionsPaused() && revenueDestination != address(0), AutonomousCheck(0x94eb4862));
        _syncUsdc(); _requireDistributableUsdc(amount);
        AutonomousRevenueLib.debit(_revenue, address(usdc), amount);
        usdc.safeTransfer(revenueDestination, amount);
        emit FeesDistributed(amount);
    }
}
