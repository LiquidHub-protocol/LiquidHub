// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
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
    uint56 ticketId;
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
contract SwapTreasury is Ownable {
    using SafeERC20 for IERC20;

    error BridgeBountyCooldownZero();
    error BridgeBountyMinRatioZero();

    uint256 private constant USD_SCALE = 1e8;

    IERC20 public immutable usdc;
    uint8 public immutable usdcDecimals;
    ISwapRouter public immutable swapRouter;
    IStargate public immutable stargatePool;

    uint256 public monthlyCap;
    uint256 public currentMonthWithdrawn;
    uint256 public currentMonthStart;
    bool public adminWithdrawEnabled;
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
    event RescueSafeUpdated(address indexed oldSafe, address indexed newSafe);
    event MonthlyCapUpdated(uint256 oldCap, uint256 newCap);
    event StakingRewardsSet(address indexed stakingRewards);
    event FeesDistributed(uint256 amount);
    event SwapFeedConfigured(address indexed token, address feed, uint16 swapSlippageBps, uint32 maxAge);
    event SwappedToUSDC(address indexed tokenIn, uint24 fee, uint256 amountIn, uint256 usdcOut);
    event BridgeConfigured(bool enabled, uint32 dstEid, address destination);
    event BridgeMinReceivedConfigured(uint16 minReceivedBps);
    event BridgeBountyConfigured(bool enabled, uint256 amount);
    event BridgeBountyCooldownConfigured(uint64 cooldown, uint16 minRatio);
    event BridgeBountyPaid(address indexed keeper, uint256 amount);
    event BridgedToStakers(uint256 amountSent, uint256 amountReceived, uint32 dstEid, bytes32 guid);
    event CollectedAndBridged(address indexed tokenIn, uint256 swappedUSDC, uint256 bridgedUSDC, uint32 dstEid);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ETHRescued(address indexed to, uint256 amount);

    constructor(address _usdc, address _swapRouter, uint256 _monthlyCap, address _stargatePool) {
        require(_usdc != address(0) && _swapRouter != address(0) && _stargatePool != address(0), "Invalid address");
        usdc = IERC20(_usdc);
        usdcDecimals = IERC20Metadata(_usdc).decimals();
        require(usdcDecimals <= 18, "Invalid decimals");
        swapRouter = ISwapRouter(_swapRouter);
        stargatePool = IStargate(_stargatePool);
        monthlyCap = _monthlyCap;
        adminWithdrawEnabled = true;
        rescueSafe = msg.sender;
        currentMonthStart = block.timestamp;
    }

    receive() external payable {}

    modifier onlyRescueSafe() {
        require(msg.sender == rescueSafe, "Only rescue safe");
        _;
    }

    function bridgeableUsdc() public view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 reserve = _bountyReserveUsdc();
        return balance > reserve ? balance - reserve : 0;
    }

    function swapToUSDC(address tokenIn, uint24 fee, uint256 amountIn, uint256 minAmountOut)
        external
        onlyOwner
        returns (uint256 amountOut)
    {
        amountOut = _swapToUSDC(tokenIn, fee, amountIn, minAmountOut);
    }

    function bridgeToStakers(uint256 amount) external payable {
        require(!adminWithdrawEnabled, "Phase 1");
        require(bridgeEnabled, "Bridge disabled");
        require(amount > 0, "Zero amount");
        require(bridgeDestinationAddress != address(0), "Destination not set");
        _requireDistributableUsdc(amount);

        (uint256 amountSent, uint256 amountReceived, bytes32 guid, uint256 nativeFee) = _bridgeUsdc(amount);
        emit BridgedToStakers(amountSent, amountReceived, bridgeDestinationEid, guid);
        _refundNativeSurplus(nativeFee);
        _payBridgeBounty(msg.sender, amountSent);
    }

    function collectAndBridge(address tokenIn, uint24 fee, uint256 amountIn, uint256 minSwapOut)
        external
        payable
        returns (uint256 usdcBridged)
    {
        require(!adminWithdrawEnabled, "Phase 1");
        require(bridgeEnabled, "Bridge disabled");
        require(bridgeDestinationAddress != address(0), "Destination not set");

        uint256 usdcAmount;
        if (tokenIn == address(usdc)) {
            usdcAmount = amountIn;
        } else {
            usdcAmount = _swapToUSDC(tokenIn, fee, amountIn, minSwapOut);
        }

        uint256 amountToBridge = _bridgeableFromAmount(usdcAmount);
        require(amountToBridge > 0, "Bounty reserve");

        (uint256 amountSent, uint256 amountReceived, bytes32 guid, uint256 nativeFee) = _bridgeUsdc(amountToBridge);
        usdcBridged = amountReceived;
        emit CollectedAndBridged(tokenIn, usdcAmount, amountSent, bridgeDestinationEid);
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

    function adminWithdraw(uint256 amount, address to) external onlyOwner {
        require(adminWithdrawEnabled, "Admin withdraw disabled");
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
        emit MonthlyCapUpdated(monthlyCap, newCap);
        monthlyCap = newCap;
    }

    function disableAdminWithdraw() external onlyOwner {
        adminWithdrawEnabled = false;
        emit AdminWithdrawDisabled(block.timestamp);
    }

    function setRescueSafe(address newSafe) external onlyOwner {
        require(newSafe != address(0), "Invalid safe");
        emit RescueSafeUpdated(rescueSafe, newSafe);
        rescueSafe = newSafe;
    }

    function rescueToken(address tokenAddr, address to, uint256 amount) external onlyRescueSafe {
        require(to != address(0), "Invalid recipient");
        require(tokenAddr != address(usdc), "Use adminWithdraw for USDC");
        require(address(swapFeeds[tokenAddr]) == address(0), "Use bridge flow");
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit TokenRescued(tokenAddr, to, amount);
    }

    function rescueETH(address payable to, uint256 amount) external onlyRescueSafe {
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

    function distributeToStakers(uint256 amount) external onlyOwner {
        require(stakingRewardsAddress != address(0), "Staking not set");
        require(amount > 0, "Zero amount");
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
        swapFeeds[token] = AggregatorV3Interface(feed);
        swapFeedMaxAges[token] = maxAge;
        swapSlippageBps[token] = slippageBps;
        emit SwapFeedConfigured(token, feed, slippageBps, maxAge);
    }

    function setBridgeConfig(bool _enabled, uint32 _dstEid, address _destination) external onlyOwner {
        if (_enabled) {
            require(_dstEid != 0, "Invalid dstEid");
            require(_destination != address(0), "Invalid destination");
        }
        bridgeEnabled = _enabled;
        bridgeDestinationEid = _dstEid;
        bridgeDestinationAddress = _destination;
        emit BridgeConfigured(_enabled, _dstEid, _destination);
    }

    function setBridgeMinReceivedBps(uint16 _minReceivedBps) external onlyOwner {
        require(_minReceivedBps == 0 || (_minReceivedBps >= 9500 && _minReceivedBps <= 10000), "Bad min received");
        bridgeMinReceivedBps = _minReceivedBps;
        emit BridgeMinReceivedConfigured(_minReceivedBps);
    }

    function setBridgeBounty(bool _enabled, uint256 _amount) external onlyOwner {
        if (_enabled) {
            require(_amount > 0, "Bounty is zero");
            if (bridgeBountyCooldown == 0) revert BridgeBountyCooldownZero();
            if (bridgeBountyMinRatio == 0) revert BridgeBountyMinRatioZero();
        }
        bridgeBountyEnabled = _enabled;
        bridgeBountyAmount = _amount;
        emit BridgeBountyConfigured(_enabled, _amount);
    }

    function setBridgeBountyCooldown(uint64 _cooldown, uint16 _minRatio) external onlyOwner {
        if (_cooldown == 0) revert BridgeBountyCooldownZero();
        if (_minRatio == 0) revert BridgeBountyMinRatioZero();
        bridgeBountyCooldown = _cooldown;
        bridgeBountyMinRatio = _minRatio;
        emit BridgeBountyCooldownConfigured(_cooldown, _minRatio);
    }

    function _swapToUSDC(address tokenIn, uint24 fee, uint256 amountIn, uint256 minAmountOut)
        internal
        returns (uint256 amountOut)
    {
        require(tokenIn != address(usdc), "Already USDC");
        require(amountIn > 0, "Zero amount");
        IERC20 token = IERC20(tokenIn);
        require(token.balanceOf(address(this)) >= amountIn, "Insufficient balance");

        uint256 floor = _oracleMinUsdcOut(tokenIn, amountIn);
        uint256 minOut = minAmountOut > floor ? minAmountOut : floor;

        token.safeApprove(address(swapRouter), 0);
        token.safeApprove(address(swapRouter), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: address(usdc),
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);
        emit SwappedToUSDC(tokenIn, fee, amountIn, amountOut);
    }

    function _oracleMinUsdcOut(address tokenIn, uint256 amountIn) internal view returns (uint256) {
        AggregatorV3Interface feed = swapFeeds[tokenIn];
        require(address(feed) != address(0), "Missing feed");
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        require(answer > 0, "Bad feed");
        require(answeredInRound >= roundId, "Stale round");
        require(block.timestamp - updatedAt <= swapFeedMaxAges[tokenIn], "Stale feed");

        uint8 feedDecimals = feed.decimals();
        uint8 tokenDecimals = IERC20Metadata(tokenIn).decimals();
        require(feedDecimals <= 18 && tokenDecimals <= 18, "Bad decimals");

        uint256 usd8 = amountIn * uint256(answer) * USD_SCALE / (10 ** tokenDecimals) / (10 ** feedDecimals);
        uint256 out = usd8 * (10 ** usdcDecimals) / USD_SCALE;
        uint16 slippage = swapSlippageBps[tokenIn];
        require(slippage > 0, "Missing slippage");
        return out * (10_000 - slippage) / 10_000;
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

        usdc.safeApprove(address(stargatePool), 0);
        usdc.safeApprove(address(stargatePool), amount);

        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt,) =
            stargatePool.sendToken{value: fee.nativeFee}(sendParam, fee, msg.sender);
        return (oftReceipt.amountSentLD, oftReceipt.amountReceivedLD, msgReceipt.guid, fee.nativeFee);
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

    function _bridgeableFromAmount(uint256 amount) internal view returns (uint256) {
        uint256 available = bridgeableUsdc();
        if (available == 0) return 0;
        return amount < available ? amount : available;
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
