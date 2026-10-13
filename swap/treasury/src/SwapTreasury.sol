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
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface IWrappedFeeNative { function deposit() external payable; }
interface IFeeConversionRouter {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function factory() external view returns (address);
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}
interface IFeeConversionFactory { function getPool(address, address, uint24) external view returns (address); }



/// @notice Dedicated treasury for frontend Velora swap commissions.
/// @dev It intentionally contains no pool bounty logic. Its only permissionless

contract SwapTreasury is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error BridgeBountyCooldownZero();
    error BridgeBountyMinRatioZero();
    error BridgeTransferMismatch();

    /// @dev Canonical native-token placeholder used by the Velora API.
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    IERC20 public immutable usdc;
    uint8 public immutable usdcDecimals;
    address public immutable veloraRouter;
    IRevenueStargate public immutable stargatePool;

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

    mapping(address => uint256) public conversionMaxInput;
    mapping(address => uint256) public conversionMinUsdc;
    mapping(address => uint64) public conversionCooldown;
    function lastConversionAt(address token) external view returns (uint64) { return _revenue.conversions[address(this)][token].started; }
    event PublicConversionConfigured(address indexed token, uint256 maxInput, uint256 minUsdc, uint64 cooldown);
    address public conversionWrappedNative;
    mapping(address => address) public conversionRouters;
    mapping(address => uint24) public conversionPoolFees;
    event PublicConversionRouteConfigured(address indexed token, address router, uint24 fee);

    mapping(address => AggregatorV3Interface) public swapFeeds;
    mapping(address => uint32) public swapFeedMaxAges;
    mapping(address => uint16) public swapSlippageBps;

    bool public bridgeEnabled;
    uint32 public bridgeDestinationEid;
    address public bridgeDestinationAddress;
    uint16 public bridgeMinReceivedBps;

    bool public bridgeBountyEnabled;
    uint256 public bridgeBountyAmount;
    uint64 public bridgeBountyCooldown;
    uint64 public lastBridgeBountyAt;
    uint16 public bridgeBountyMinRatio;

    event AdminWithdrawal(uint256 amount, address indexed to);
    event DistributionsPauseUpdated(bool paused, address indexed caller);
    event RescueSafeUpdated(address indexed oldSafe, address indexed newSafe);
    event FeesDistributed(uint256 amount);
    event SwapFeedConfigured(address indexed token, address feed, uint16 swapSlippageBps, uint32 maxAge);
    event SwappedToUSDC(address indexed tokenIn, uint256 amountIn, uint256 usdcOut);
    event BridgeConfigured(bool enabled, uint32 dstEid, address destination);
    event BridgeMinReceivedConfigured(uint16 minReceivedBps);
    event BridgeBountyConfigured(bool enabled, uint256 amount);
    event BridgeBountyCooldownConfigured(uint64 cooldown, uint16 minRatio);
    event BridgeBountyPaid(address indexed keeper, uint256 amount);
    event RevenueBridged(uint256 amountSent, uint256 amountReceived, uint32 dstEid, bytes32 guid);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ETHRescued(address indexed to, uint256 amount);

    constructor(address _usdc, address _veloraRouter, uint256 _initialBountyDailyCap, address _stargatePool) {
        require(_usdc != address(0) && _veloraRouter.code.length > 0 && _stargatePool != address(0), AutonomousCheck(0x4c9bb549));
        usdc = IERC20(_usdc);
        usdcDecimals = IERC20Metadata(_usdc).decimals();
        require(usdcDecimals <= 18, AutonomousCheck(0x8a0ba966));
        require(_validBountyCap(_initialBountyDailyCap), AutonomousCheck(0xdc524c4e));
        veloraRouter = _veloraRouter;
        stargatePool = IRevenueStargate(_stargatePool);
        rescueSafe = msg.sender;
        company = msg.sender;
    }

    receive() external payable {}
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
        require(!configurationSealed && pendingOwner() == address(0), AutonomousCheck(0x9a247fa1)); configurationSealed = true;
        emit ConfigurationSealed();
    }
    function sealAsset(address token) external onlyInstaller {
        require(!assetSealed[token] && address(swapFeeds[token]) != address(0), AutonomousCheck(0x4bb6522b));
        if (token != address(usdc)) require(conversionMaxInput[token] > 0 && conversionRouters[token] != address(0), AutonomousCheck(0xadb5731e));
        assetSealed[token] = true; emit AssetSealed(token);
    }
    function syncRevenue() external nonReentrant { _syncUsdc(); }
    function _syncUsdc() private { AutonomousRevenueLib.sync(_revenue, address(usdc), address(usdc)); }
    function bountyReserveUsdc() external view returns (uint256) { return _bountyReserveUsdc(); }
    function sourceBountyReserve(address source) external view returns (uint256) { return _revenue.reserve[source]; }
    function cumulativeUsdcRevenue() external view returns (uint256) { return _revenue.revenue[address(this)]; }
    function fundBounties(uint256 amount) external nonReentrant {
        AutonomousRevenueLib.fund(_revenue, address(usdc), address(this), amount);
    }

    /// @dev Protocol commissions must never become inaccessible through an accidental governance renunciation.
    function renounceOwnership() public pure override {
        revert();
    }

    modifier onlyRescueSafe() {
        require(msg.sender == rescueSafe, AutonomousCheck(0x99b0721c));
        _;
    }

    /// @dev No caller-selected amount, route, recipient or minimum is accepted.
    function setPublicConversion(address token, uint256 maxInput, uint256 minUsdc, uint64 cooldown) external onlyInstaller {
        require(!assetSealed[token], AutonomousCheck(0xd3f8500a));
        require(token != address(usdc) && (token == NATIVE_TOKEN || token.code.length > 0), AutonomousCheck(0x799c831e));
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
        uint256 remaining;
        (remaining, nextAt) = AutonomousRevenueLib.conversionRemaining(_revenue, address(this), token, conversionMaxInput[token], conversionCooldown[token]);
        if (!assetSealed[token] || distributionsPaused() || remaining == 0) return (0, 0, nextAt);
        amountIn = token == NATIVE_TOKEN ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (amountIn > remaining) amountIn = remaining;
        if (amountIn == 0) return (0, 0, nextAt);
        minOut = _oracleMinimumOut(token, amountIn);
        if (minOut == 0 || minOut < conversionMinUsdc[token]) return (0, 0, nextAt);
    }

    function convertFeesToUSDC(address token) external nonReentrant returns (uint256 amountOut) {
        (uint256 amountIn, uint256 minOut,) = previewFeeConversion(token);
        require(amountIn > 0, AutonomousCheck(0xb9913616)); _syncUsdc();
        AutonomousRevenueLib.consumeConversion(_revenue, address(this), token, amountIn, conversionMaxInput[token], conversionCooldown[token]);
        amountOut = _convertFixedRoute(token, amountIn, minOut);
        // Fixed routes send all outputs here. Sync credits exactly the actual received USDC delta.
        _syncUsdc();
    }

    function convertFeeChunk(address token, uint256 amountIn) external nonReentrant returns (uint256 amountOut) {
        (uint256 available,,) = previewFeeConversion(token);
        require(amountIn > 0 && amountIn <= available, AutonomousCheck(0xd6a70ccf));
        uint256 minOut = _oracleMinimumOut(token, amountIn);
        require(minOut >= conversionMinUsdc[token], AutonomousCheck(0xd34f8e6b));
        _syncUsdc(); AutonomousRevenueLib.consumeConversion(_revenue, address(this), token, amountIn, conversionMaxInput[token], conversionCooldown[token]);
        amountOut = _convertFixedRoute(token, amountIn, minOut); _syncUsdc();
    }
    /// @notice Public execution uses a fixed V3 route, never arbitrary Augustus calldata.
    function setPublicConversionRoute(address token, address router, uint24 fee) external onlyInstaller {
        require(!assetSealed[token], AutonomousCheck(0xd3f8500a));
        require(token != address(usdc) && token.code.length > 0 && router.code.length > 0 && fee > 0, AutonomousCheck(0x2e21a5da));
        address factory = IFeeConversionRouter(router).factory();
        require(IFeeConversionFactory(factory).getPool(token, address(usdc), fee).code.length > 0, AutonomousCheck(0x7462fa0c));
        conversionRouters[token] = router;
        conversionPoolFees[token] = fee;
        emit PublicConversionRouteConfigured(token, router, fee);
    }

    function setNativeConversionRoute(address wrappedNative, address router, uint24 fee) external onlyInstaller {
        require(!assetSealed[NATIVE_TOKEN], AutonomousCheck(0xd3f8500a));
        require(wrappedNative.code.length > 0 && router.code.length > 0 && fee > 0, AutonomousCheck(0xe910ea0e));
        require(IFeeConversionFactory(IFeeConversionRouter(router).factory()).getPool(wrappedNative, address(usdc), fee).code.length > 0, AutonomousCheck(0x7462fa0c));
        conversionWrappedNative = wrappedNative;
        conversionRouters[NATIVE_TOKEN] = router;
        conversionPoolFees[NATIVE_TOKEN] = fee;
        emit PublicConversionRouteConfigured(NATIVE_TOKEN, router, fee);
    }

    function _convertFixedRoute(address tokenIn, uint256 amountIn, uint256 minOut) private returns (uint256 amountOut) {
        address router = conversionRouters[tokenIn];
        require(router != address(0), AutonomousCheck(0xf805cecb));
        address input = tokenIn;
        if (tokenIn == NATIVE_TOKEN) {
            input = conversionWrappedNative;
            require(input != address(0) && IERC20Metadata(input).decimals() == 18, AutonomousCheck(0x18b28bdc));
            uint256 beforeWrapped = IERC20(input).balanceOf(address(this));
            uint256 beforeNative = address(this).balance;
            IWrappedFeeNative(input).deposit{value: amountIn}();
            require(beforeNative - address(this).balance == amountIn
                && IERC20(input).balanceOf(address(this)) - beforeWrapped == amountIn, AutonomousCheck(0x45f80872));
        }
        (, uint160 limit) = ProtocolSafetyLib.bounds(input, address(usdc), amountIn, address(swapFeeds[tokenIn]),
            address(swapFeeds[address(usdc)]), swapFeedMaxAges[tokenIn], swapFeedMaxAges[address(usdc)], swapSlippageBps[tokenIn]);
        amountOut = ProtocolSafetyLib.swap(input, address(usdc), router, conversionPoolFees[tokenIn], amountIn, minOut, limit);
        emit SwappedToUSDC(tokenIn, amountIn, amountOut);
    }

    function bridgeableUsdc() public view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 reserve = _bountyReserveUsdc();
        return balance > reserve ? balance - reserve : 0;
    }

    /// @notice Convert one configured Velora commission token to canonical USDC.

    ///      built for this Treasury as payer and beneficiary. Configuration stays owner-only.
    ///      Exact input spending and the oracle-bounded USDC balance delta are enforced on-chain.


    function bridgeRevenue(uint256 amount) external payable nonReentrant {
        require(!distributionsPaused() && bridgeEnabled, AutonomousCheck(0x7b886e9d));
        _syncUsdc(); _requireDistributableUsdc(amount);
        AutonomousRevenueLib.debit(_revenue, address(usdc), amount);
        (uint256 received, bytes32 guid, uint256 nativeFee) = RevenueBridgeLib.send(
            address(stargatePool), address(usdc), bridgeDestinationEid, bridgeDestinationAddress, amount, bridgeMinReceivedBps);
        emit RevenueBridged(amount, received, bridgeDestinationEid, guid);
        _payBridgeBounty(msg.sender, amount); _refundNativeSurplus(nativeFee);
    }

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

    /// @dev The fixed rescue Safe manages bounded incident pauses and early resumption.
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

    function rescueToken(address tokenAddr, address to, uint256 amount) external onlyRescueSafe nonReentrant {
        require(!configurationSealed || distributionsPaused(), AutonomousCheck(0x1d45e305));
        require(!assetSealed[tokenAddr] && _revenue.accounted[tokenAddr] == 0, AutonomousCheck(0x3ad6b46e));
        require(to == company && to != address(0), AutonomousCheck(0x160fe00b));
        require(tokenAddr != address(usdc), AutonomousCheck(0xb6c29bb8));
        require(address(swapFeeds[tokenAddr]) == address(0), AutonomousCheck(0xc8f25ab5));
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit TokenRescued(tokenAddr, to, amount);
    }

    function rescueETH(address payable, uint256) external pure { revert AutonomousCheck(0x04d6d5a4); }

    function setRevenueDestination(address destination) external onlyOwner {
        require(!configurationSealed && destination != address(0), AutonomousCheck(0x9a247fa1)); revenueDestination = destination;
    }

    function forwardRevenue(uint256 amount) external nonReentrant {
        require(!distributionsPaused() && revenueDestination != address(0), AutonomousCheck(0x94eb4862));
        _syncUsdc(); _requireDistributableUsdc(amount); AutonomousRevenueLib.debit(_revenue, address(usdc), amount);
        usdc.safeTransfer(revenueDestination, amount); emit FeesDistributed(amount);
    }

    function setSwapFeed(address token, address feed, uint16 slippageBps, uint32 maxAge) external onlyInstaller {
        require(!assetSealed[token] || (feed != address(0) && address(swapFeeds[token]) == feed), AutonomousCheck(0x61ac430d));
        require(token != address(0), AutonomousCheck(0x086efea7));
        if (feed == address(0)) {
            delete swapFeeds[token];
            delete swapFeedMaxAges[token];
            delete swapSlippageBps[token];
            emit SwapFeedConfigured(token, address(0), 0, 0);
            return;
        }
        require(slippageBps >= 10 && slippageBps <= 1000, AutonomousCheck(0x3d18e4c6));
        require(maxAge >= 3600 && maxAge <= 172800, AutonomousCheck(0x47c6ab9a));
        uint8 tokenDecimals = token == NATIVE_TOKEN ? 18 : IERC20Metadata(token).decimals();
        require(tokenDecimals <= 18 && AggregatorV3Interface(feed).decimals() <= 18, AutonomousCheck(0xea6042f8));
        swapFeeds[token] = AggregatorV3Interface(feed);
        swapFeedMaxAges[token] = maxAge;
        swapSlippageBps[token] = slippageBps;
        emit SwapFeedConfigured(token, feed, slippageBps, maxAge);
    }

    function setBridgeConfig(bool _enabled, uint32 _dstEid, address _destination) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        if (_enabled) {
            require(_dstEid != 0, AutonomousCheck(0xe741cf47));
            require(_destination != address(0), AutonomousCheck(0x14f03ffa));
            require(bridgeMinReceivedBps >= 9500, AutonomousCheck(0x6767d579));
        }
        bridgeEnabled = _enabled;
        bridgeDestinationEid = _dstEid;
        bridgeDestinationAddress = _destination;
        emit BridgeConfigured(_enabled, _dstEid, _destination);
    }

    function setBridgeMinReceivedBps(uint16 _minReceivedBps) external onlyOwner {
        require(_minReceivedBps == 0 || (_minReceivedBps >= 9500 && _minReceivedBps <= 10000), AutonomousCheck(0xa29f8fbd));
        if (bridgeEnabled) require(_minReceivedBps >= 9500, AutonomousCheck(0x5d2c86a7));
        bridgeMinReceivedBps = _minReceivedBps;
        emit BridgeMinReceivedConfigured(_minReceivedBps);
    }

    function setBridgeBounty(bool _enabled, uint256 _amount) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        if (_enabled) {
            require(_amount > 0 && _validBountyCap(_amount), AutonomousCheck(0x5b636e99));
            if (bridgeBountyCooldown == 0) revert BridgeBountyCooldownZero();
            if (bridgeBountyMinRatio == 0) revert BridgeBountyMinRatioZero();
        }
        bridgeBountyEnabled = _enabled;
        bridgeBountyAmount = _amount;
        emit BridgeBountyConfigured(_enabled, _amount);
    }

    function setBridgeBountyCooldown(uint64 _cooldown, uint16 _minRatio) external onlyOwner {
        require(!configurationSealed, AutonomousCheck(0x9a247fa1));
        require(_cooldown == 0 || (_cooldown >= 1 hours && _cooldown <= 30 days), AutonomousCheck(0x434192e9));
        require(_minRatio == 0 || (_minRatio >= 10 && _minRatio <= 10000), AutonomousCheck(0x5e8a51e0));
        if (bridgeBountyEnabled && bridgeBountyAmount > 0 && _cooldown == 0) revert BridgeBountyCooldownZero();
        if (bridgeBountyEnabled && bridgeBountyAmount > 0 && _minRatio == 0) revert BridgeBountyMinRatioZero();
        bridgeBountyCooldown = _cooldown;
        bridgeBountyMinRatio = _minRatio;
        emit BridgeBountyCooldownConfigured(_cooldown, _minRatio);
    }



    function _oracleMinimumOut(address tokenIn, uint256 amountIn) internal view returns (uint256 minUsdcOut) {
        AggregatorV3Interface feed = swapFeeds[tokenIn];
        AggregatorV3Interface usdcFeed = swapFeeds[address(usdc)];
        require(address(feed) != address(0) && address(usdcFeed) != address(0), AutonomousCheck(0xb5118791));
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        (uint80 usdcRoundId, int256 usdcAnswer,, uint256 usdcUpdatedAt, uint80 usdcAnsweredInRound) =
            usdcFeed.latestRoundData();
        require(
            answer > 0 && updatedAt != 0 && answeredInRound >= roundId
                && block.timestamp - updatedAt <= swapFeedMaxAges[tokenIn], AutonomousCheck(0x52745c9d));
        require(
            usdcAnswer > 0 && usdcUpdatedAt != 0 && usdcAnsweredInRound >= usdcRoundId
                && block.timestamp - usdcUpdatedAt <= swapFeedMaxAges[address(usdc)], AutonomousCheck(0x4a4484c5));

        uint8 feedDecimals = feed.decimals();
        uint8 tokenDecimals = tokenIn == NATIVE_TOKEN ? 18 : IERC20Metadata(tokenIn).decimals();
        uint8 usdcFeedDecimals = usdcFeed.decimals();
        require(feedDecimals <= 18 && tokenDecimals <= 18 && usdcFeedDecimals <= 18, AutonomousCheck(0xea6042f8));

        uint256 normalizedUsdcPrice = uint256(usdcAnswer);
        if (usdcFeedDecimals < feedDecimals) normalizedUsdcPrice *= 10 ** (feedDecimals - usdcFeedDecimals);
        else if (usdcFeedDecimals > feedDecimals) normalizedUsdcPrice /= 10 ** (usdcFeedDecimals - feedDecimals);
        require(normalizedUsdcPrice > 0, AutonomousCheck(0xd0847386));

        uint256 usdValue = Math.mulDiv(amountIn, uint256(answer), 10 ** tokenDecimals);
        uint256 out = Math.mulDiv(usdValue, 10 ** usdcDecimals, normalizedUsdcPrice);
        uint16 slippage = swapSlippageBps[tokenIn];
        require(slippage > 0, AutonomousCheck(0x40195876));
        minUsdcOut = out * (10_000 - slippage) / 10_000;
    }



    function _validBountyCap(uint256 cap) internal view returns (bool) {
        return cap > 0 && cap <= 1_000_000 * (10 ** uint256(usdcDecimals));
    }





    function _requireDistributableUsdc(uint256 amount) internal view {
        require(amount > 0 && amount <= bridgeableUsdc(), AutonomousCheck(0xbac20538));
    }

    function _bountyReserveUsdc() internal view returns (uint256) {
        return AutonomousRevenueLib.protectedBalance(_revenue, address(usdc));
    }



    function _payBridgeBounty(address keeper, uint256 bridgedAmount) internal {
        if (!bridgeBountyEnabled || bridgeBountyAmount == 0) return;
        if (block.timestamp < uint256(lastBridgeBountyAt) + uint256(bridgeBountyCooldown)) return;
        uint256 ratio = uint256(bridgeBountyMinRatio);
        if (bridgeBountyCooldown == 0 || ratio == 0) return;
        if (bridgedAmount < bridgeBountyAmount * ratio) return;
        if (_revenue.reserve[address(this)] < bridgeBountyAmount) return;
        lastBridgeBountyAt = uint64(block.timestamp);
        AutonomousRevenueLib.spend(_revenue, address(this), bridgeBountyAmount);
        AutonomousRevenueLib.debit(_revenue, address(usdc), bridgeBountyAmount);
        usdc.safeTransfer(keeper, bridgeBountyAmount);
        emit BridgeBountyPaid(keeper, bridgeBountyAmount);
    }

    function _refundNativeSurplus(uint256 usedNativeFee) internal {
        if (msg.value <= usedNativeFee) return;
        (bool ok,) = msg.sender.call{value: msg.value - usedNativeFee}("");
        require(ok, AutonomousCheck(0xcef6850b));
    }
}
