// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

struct SendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

struct OFTLimit {
    uint256 minAmountLD;
    uint256 maxAmountLD;
}

struct OFTFeeDetail {
    int256 feeAmountLD;
    string description;
}

struct Ticket {
    uint72 ticketId;
    bytes passengerBytes;
}

interface IStargate {
    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken)
        external
        view
        returns (MessagingFee memory fee);

    function quoteOFT(SendParam calldata _sendParam)
        external
        view
        returns (OFTLimit memory, OFTFeeDetail[] memory, OFTReceipt memory);

    function sendToken(SendParam calldata _sendParam, MessagingFee calldata _fee, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory, Ticket memory);
}

/// @notice Dedicated treasury for frontend Velora swap commissions.
/// @dev It intentionally contains no pool bounty logic. Its only permissionless
///      surface is bridging accumulated fees to the Phase 2 staking destination.
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
    IStargate public immutable stargatePool;

    uint256 public monthlyCap;
    uint256 public currentMonthWithdrawn;
    uint256 public currentMonthStart;
    bool public adminWithdrawEnabled;
    bool public distributionsPaused;
    address public rescueSafe;
    address public stakingRewardsAddress;

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
    event AdminWithdrawDisabled(uint256 timestamp);
    event DistributionsPauseUpdated(bool paused, address indexed caller);
    event RescueSafeUpdated(address indexed oldSafe, address indexed newSafe);
    event MonthlyCapUpdated(uint256 oldCap, uint256 newCap);
    event StakingRewardsSet(address indexed stakingRewards);
    event FeesDistributed(uint256 amount);
    event SwapFeedConfigured(address indexed token, address feed, uint16 swapSlippageBps, uint32 maxAge);
    event SwappedToUSDC(address indexed tokenIn, uint256 amountIn, uint256 usdcOut);
    event BridgeConfigured(bool enabled, uint32 dstEid, address destination);
    event BridgeMinReceivedConfigured(uint16 minReceivedBps);
    event BridgeBountyConfigured(bool enabled, uint256 amount);
    event BridgeBountyCooldownConfigured(uint64 cooldown, uint16 minRatio);
    event BridgeBountyPaid(address indexed keeper, uint256 amount);
    event BridgedToStakers(uint256 amountSent, uint256 amountReceived, uint32 dstEid, bytes32 guid);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ETHRescued(address indexed to, uint256 amount);

    constructor(address _usdc, address _veloraRouter, uint256 _monthlyCap, address _stargatePool) {
        require(_usdc != address(0) && _veloraRouter.code.length > 0 && _stargatePool != address(0), "Invalid address");
        usdc = IERC20(_usdc);
        usdcDecimals = IERC20Metadata(_usdc).decimals();
        require(usdcDecimals <= 18, "Invalid decimals");
        require(_validMonthlyCap(_monthlyCap), "Invalid cap");
        veloraRouter = _veloraRouter;
        stargatePool = IStargate(_stargatePool);
        monthlyCap = _monthlyCap;
        adminWithdrawEnabled = true;
        rescueSafe = msg.sender;
        currentMonthStart = block.timestamp;
    }

    receive() external payable {}

    /// @dev Protocol commissions must never become inaccessible through an accidental governance renunciation.
    function renounceOwnership() public pure override {
        revert();
    }

    modifier onlyRescueSafe() {
        require(msg.sender == rescueSafe, "Only rescue safe");
        _;
    }

    function bridgeableUsdc() public view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 reserve = _bountyReserveUsdc();
        return balance > reserve ? balance - reserve : 0;
    }

    /// @notice Convert one configured Velora commission token to canonical USDC.
    /// @dev The owner supplies Augustus calldata built for this Treasury as payer and beneficiary.
    ///      Exact input spending and the oracle-bounded USDC balance delta are enforced on-chain.
    function swapToUSDC(address tokenIn, uint256 amountIn, uint256 minAmountOut, bytes calldata veloraCalldata)
        external
        onlyOwner
        nonReentrant
        returns (uint256 amountOut)
    {
        amountOut = _swapToUSDC(tokenIn, amountIn, minAmountOut, veloraCalldata);
    }

    function bridgeToStakers(uint256 amount) external payable nonReentrant {
        require(!adminWithdrawEnabled, "Phase 1");
        require(!distributionsPaused, "Distributions paused");
        require(bridgeEnabled, "Bridge disabled");
        require(amount > 0, "Zero amount");
        require(bridgeDestinationAddress != address(0), "Destination not set");
        _requireDistributableUsdc(amount);

        (uint256 amountSent, uint256 amountReceived, bytes32 guid, uint256 nativeFee) = _bridgeUsdc(amount);
        emit BridgedToStakers(amountSent, amountReceived, bridgeDestinationEid, guid);
        _refundNativeSurplus(nativeFee);
        _payBridgeBounty(msg.sender, amountSent);
    }

    function estimateBridgeFee(uint256 amount) external view returns (uint256 nativeFee, uint256 amountReceived) {
        SendParam memory sendParam = _sendParam(amount, 0);
        (,, OFTReceipt memory receipt) = stargatePool.quoteOFT(sendParam);
        amountReceived = receipt.amountReceivedLD;
        sendParam.minAmountLD = amountReceived;
        MessagingFee memory fee = stargatePool.quoteSend(sendParam, false);
        nativeFee = fee.nativeFee;
    }

    function adminWithdraw(uint256 amount, address to) external onlyOwner nonReentrant {
        require(adminWithdrawEnabled, "Admin withdraw disabled");
        require(amount > 0, "Zero amount");
        require(to != address(0), "Invalid recipient");

        if (block.timestamp >= currentMonthStart + 30 days) {
            currentMonthStart = block.timestamp;
            currentMonthWithdrawn = 0;
        }

        currentMonthWithdrawn += amount;
        require(currentMonthWithdrawn <= monthlyCap, "Monthly cap exceeded");
        usdc.safeTransfer(to, amount);
        emit AdminWithdrawal(amount, to);
    }

    function setMonthlyCap(uint256 newCap) external onlyOwner {
        require(_validMonthlyCap(newCap), "Invalid cap");
        emit MonthlyCapUpdated(monthlyCap, newCap);
        monthlyCap = newCap;
    }

    function disableAdminWithdraw() external onlyOwner {
        adminWithdrawEnabled = false;
        emit AdminWithdrawDisabled(block.timestamp);
    }

    function setRescueSafe(address newSafe) external onlyOwner {
        require(newSafe.code.length > 0, "Invalid safe");
        emit RescueSafeUpdated(rescueSafe, newSafe);
        rescueSafe = newSafe;
    }

    /// @notice Emergency stop for Phase 2 revenue distributions.
    /// @dev The rescue Safe may pause immediately; only governance may resume.
    function setDistributionsPaused(bool paused_) external {
        require(paused_ ? (msg.sender == rescueSafe || msg.sender == owner()) : msg.sender == owner(), "Unauthorized");
        distributionsPaused = paused_;
        emit DistributionsPauseUpdated(paused_, msg.sender);
    }

    function rescueToken(address tokenAddr, address to, uint256 amount) external onlyRescueSafe nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(tokenAddr != address(usdc), "Use adminWithdraw for USDC");
        require(address(swapFeeds[tokenAddr]) == address(0), "Use bridge flow");
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit TokenRescued(tokenAddr, to, amount);
    }

    function rescueETH(address payable to, uint256 amount) external onlyRescueSafe nonReentrant {
        require(to != address(0), "Invalid recipient");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit ETHRescued(to, amount);
    }

    function setStakingRewards(address _stakingRewards) external onlyOwner {
        require(_stakingRewards != address(0), "Invalid address");
        stakingRewardsAddress = _stakingRewards;
        emit StakingRewardsSet(_stakingRewards);
    }

    function distributeToStakers(uint256 amount) external onlyOwner nonReentrant {
        require(!adminWithdrawEnabled, "Phase 1");
        require(!distributionsPaused, "Distributions paused");
        require(stakingRewardsAddress != address(0), "Staking not set");
        require(amount > 0, "Zero amount");
        _requireDistributableUsdc(amount);
        usdc.safeTransfer(stakingRewardsAddress, amount);
        emit FeesDistributed(amount);
    }

    function setSwapFeed(address token, address feed, uint16 slippageBps, uint32 maxAge) external onlyOwner {
        require(token != address(0), "Invalid token");
        if (feed == address(0)) {
            delete swapFeeds[token];
            delete swapFeedMaxAges[token];
            delete swapSlippageBps[token];
            emit SwapFeedConfigured(token, address(0), 0, 0);
            return;
        }
        require(slippageBps >= 10 && slippageBps <= 1000, "Bad slippage");
        require(maxAge >= 3600 && maxAge <= 172800, "Bad maxAge");
        uint8 tokenDecimals = token == NATIVE_TOKEN ? 18 : IERC20Metadata(token).decimals();
        require(tokenDecimals <= 18 && AggregatorV3Interface(feed).decimals() <= 18, "Bad decimals");
        swapFeeds[token] = AggregatorV3Interface(feed);
        swapFeedMaxAges[token] = maxAge;
        swapSlippageBps[token] = slippageBps;
        emit SwapFeedConfigured(token, feed, slippageBps, maxAge);
    }

    function setBridgeConfig(bool _enabled, uint32 _dstEid, address _destination) external onlyOwner {
        if (_enabled) {
            require(_dstEid != 0, "Invalid dstEid");
            require(_destination != address(0), "Invalid destination");
            require(bridgeMinReceivedBps >= 9500, "Bridge min not configured");
        }
        bridgeEnabled = _enabled;
        bridgeDestinationEid = _dstEid;
        bridgeDestinationAddress = _destination;
        emit BridgeConfigured(_enabled, _dstEid, _destination);
    }

    function setBridgeMinReceivedBps(uint16 _minReceivedBps) external onlyOwner {
        require(_minReceivedBps == 0 || (_minReceivedBps >= 9500 && _minReceivedBps <= 10000), "Bad min received");
        if (bridgeEnabled) require(_minReceivedBps >= 9500, "Bridge active");
        bridgeMinReceivedBps = _minReceivedBps;
        emit BridgeMinReceivedConfigured(_minReceivedBps);
    }

    function setBridgeBounty(bool _enabled, uint256 _amount) external onlyOwner {
        if (_enabled) {
            require(_amount > 0 && _amount <= monthlyCap, "Invalid bounty");
            if (bridgeBountyCooldown == 0) revert BridgeBountyCooldownZero();
            if (bridgeBountyMinRatio == 0) revert BridgeBountyMinRatioZero();
        }
        bridgeBountyEnabled = _enabled;
        bridgeBountyAmount = _amount;
        emit BridgeBountyConfigured(_enabled, _amount);
    }

    function setBridgeBountyCooldown(uint64 _cooldown, uint16 _minRatio) external onlyOwner {
        require(_cooldown == 0 || (_cooldown >= 1 hours && _cooldown <= 30 days), "Bad cooldown");
        require(_minRatio == 0 || (_minRatio >= 10 && _minRatio <= 10000), "Bad ratio");
        if (bridgeBountyEnabled && bridgeBountyAmount > 0 && _cooldown == 0) revert BridgeBountyCooldownZero();
        if (bridgeBountyEnabled && bridgeBountyAmount > 0 && _minRatio == 0) revert BridgeBountyMinRatioZero();
        bridgeBountyCooldown = _cooldown;
        bridgeBountyMinRatio = _minRatio;
        emit BridgeBountyCooldownConfigured(_cooldown, _minRatio);
    }

    function _swapToUSDC(address tokenIn, uint256 amountIn, uint256 minAmountOut, bytes calldata veloraCalldata)
        internal
        returns (uint256 amountOut)
    {
        require(tokenIn != address(usdc), "Already USDC");
        require(amountIn > 0, "Zero amount");
        require(veloraCalldata.length >= 4, "Invalid calldata");

        bool isNative = tokenIn == NATIVE_TOKEN;
        IERC20 token = IERC20(tokenIn);
        uint256 balanceBefore = isNative ? address(this).balance : token.balanceOf(address(this));
        uint256 usdcBefore = usdc.balanceOf(address(this));
        require(balanceBefore >= amountIn, "Insufficient balance");

        uint256 floor = _oracleMinimumOut(tokenIn, amountIn);
        uint256 minOut = minAmountOut > floor ? minAmountOut : floor;

        if (!isNative) {
            token.safeApprove(veloraRouter, 0);
            token.safeApprove(veloraRouter, amountIn);
        }

        (bool success, bytes memory result) = veloraRouter.call{value: isNative ? amountIn : 0}(veloraCalldata);
        if (!success) _revertWithData(result);

        uint256 balanceAfter = isNative ? address(this).balance : token.balanceOf(address(this));
        uint256 usdcAfter = usdc.balanceOf(address(this));
        require(balanceAfter <= balanceBefore && balanceBefore - balanceAfter == amountIn, "Input mismatch");
        require(usdcAfter >= usdcBefore, "Output mismatch");
        amountOut = usdcAfter - usdcBefore;
        require(amountOut >= minOut, "Insufficient output");

        if (!isNative) token.safeApprove(veloraRouter, 0);
        emit SwappedToUSDC(tokenIn, amountIn, amountOut);
    }

    function _oracleMinimumOut(address tokenIn, uint256 amountIn) internal view returns (uint256 minUsdcOut) {
        AggregatorV3Interface feed = swapFeeds[tokenIn];
        AggregatorV3Interface usdcFeed = swapFeeds[address(usdc)];
        require(address(feed) != address(0) && address(usdcFeed) != address(0), "Missing feed");
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        (uint80 usdcRoundId, int256 usdcAnswer,, uint256 usdcUpdatedAt, uint80 usdcAnsweredInRound) =
            usdcFeed.latestRoundData();
        require(
            answer > 0 && updatedAt != 0 && answeredInRound >= roundId
                && block.timestamp - updatedAt <= swapFeedMaxAges[tokenIn],
            "Bad feed"
        );
        require(
            usdcAnswer > 0 && usdcUpdatedAt != 0 && usdcAnsweredInRound >= usdcRoundId
                && block.timestamp - usdcUpdatedAt <= swapFeedMaxAges[address(usdc)],
            "Bad USDC feed"
        );

        uint8 feedDecimals = feed.decimals();
        uint8 tokenDecimals = tokenIn == NATIVE_TOKEN ? 18 : IERC20Metadata(tokenIn).decimals();
        uint8 usdcFeedDecimals = usdcFeed.decimals();
        require(feedDecimals <= 18 && tokenDecimals <= 18 && usdcFeedDecimals <= 18, "Bad decimals");

        uint256 normalizedUsdcPrice = uint256(usdcAnswer);
        if (usdcFeedDecimals < feedDecimals) normalizedUsdcPrice *= 10 ** (feedDecimals - usdcFeedDecimals);
        else if (usdcFeedDecimals > feedDecimals) normalizedUsdcPrice /= 10 ** (usdcFeedDecimals - feedDecimals);
        require(normalizedUsdcPrice > 0, "Bad USDC decimals");

        uint256 usdValue = Math.mulDiv(amountIn, uint256(answer), 10 ** tokenDecimals);
        uint256 out = Math.mulDiv(usdValue, 10 ** usdcDecimals, normalizedUsdcPrice);
        uint16 slippage = swapSlippageBps[tokenIn];
        require(slippage > 0, "Missing slippage");
        minUsdcOut = out * (10_000 - slippage) / 10_000;
    }

    function _revertWithData(bytes memory result) private pure {
        if (result.length == 0) revert("Velora swap failed");
        assembly {
            revert(add(result, 32), mload(result))
        }
    }

    function _validMonthlyCap(uint256 cap) internal view returns (bool) {
        return cap > 0 && cap <= 1_000_000 * (10 ** uint256(usdcDecimals));
    }

    function _bridgeUsdc(uint256 amount)
        internal
        returns (uint256 amountSent, uint256 amountReceived, bytes32 guid, uint256 nativeFee)
    {
        SendParam memory sendParam = _sendParam(amount, 0);
        (,, OFTReceipt memory receipt) = stargatePool.quoteOFT(sendParam);
        _requireBridgeMinReceived(amount, receipt.amountReceivedLD);
        sendParam.minAmountLD = receipt.amountReceivedLD;

        MessagingFee memory fee = stargatePool.quoteSend(sendParam, false);
        require(msg.value >= fee.nativeFee, "Insufficient native fee");
        uint256 balanceBefore = usdc.balanceOf(address(this));

        usdc.safeApprove(address(stargatePool), 0);
        usdc.safeApprove(address(stargatePool), amount);

        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt,) =
            stargatePool.sendToken{value: fee.nativeFee}(sendParam, fee, msg.sender);
        usdc.safeApprove(address(stargatePool), 0);
        uint256 balanceAfter = usdc.balanceOf(address(this));
        if (
            balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount || oftReceipt.amountSentLD != amount
                || oftReceipt.amountReceivedLD < sendParam.minAmountLD
        ) revert BridgeTransferMismatch();
        return (amount, oftReceipt.amountReceivedLD, msgReceipt.guid, fee.nativeFee);
    }

    function _sendParam(uint256 amount, uint256 minAmount) internal view returns (SendParam memory) {
        return SendParam({
            dstEid: bridgeDestinationEid,
            to: bytes32(uint256(uint160(bridgeDestinationAddress))),
            amountLD: amount,
            minAmountLD: minAmount,
            extraOptions: new bytes(0),
            composeMsg: new bytes(0),
            oftCmd: ""
        });
    }

    function _requireDistributableUsdc(uint256 amount) internal view {
        require(amount <= bridgeableUsdc(), "Bounty reserve");
    }

    function _bountyReserveUsdc() internal view returns (uint256) {
        if (!bridgeBountyEnabled) return 0;
        return bridgeBountyAmount;
    }

    function _requireBridgeMinReceived(uint256 amountSent, uint256 amountReceived) internal view {
        if (bridgeMinReceivedBps == 0) return;
        require(amountReceived * 10_000 >= amountSent * bridgeMinReceivedBps, "Bridge slippage");
    }

    function _payBridgeBounty(address keeper, uint256 bridgedAmount) internal {
        if (!bridgeBountyEnabled || bridgeBountyAmount == 0) return;
        if (block.timestamp < uint256(lastBridgeBountyAt) + uint256(bridgeBountyCooldown)) return;
        uint256 ratio = uint256(bridgeBountyMinRatio);
        if (bridgeBountyCooldown == 0 || ratio == 0) return;
        if (bridgedAmount < bridgeBountyAmount * ratio) return;
        if (usdc.balanceOf(address(this)) < bridgeBountyAmount) return;
        lastBridgeBountyAt = uint64(block.timestamp);
        usdc.safeTransfer(keeper, bridgeBountyAmount);
        emit BridgeBountyPaid(keeper, bridgeBountyAmount);
    }

    function _refundNativeSurplus(uint256 usedNativeFee) internal {
        if (msg.value <= usedNativeFee) return;
        (bool ok,) = msg.sender.call{value: msg.value - usedNativeFee}("");
        require(ok, "Refund failed");
    }
}
