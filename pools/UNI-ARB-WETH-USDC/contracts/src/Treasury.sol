// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";

// --- Stargate v2 Interfaces ---

struct SendParam {
    uint32  dstEid;         // Destination LayerZero v2 endpoint ID
    bytes32 to;             // Recipient address, left-padded to bytes32
    uint256 amountLD;       // Amount in local decimals (USDC = 6)
    uint256 minAmountLD;    // Minimum received (slippage guard)
    bytes   extraOptions;   // LayerZero executor options (empty for default)
    bytes   composeMsg;     // Composed message for destination (empty if none)
    bytes   oftCmd;         // "" = Taxi (immediate), hex"00" = Bus (batched)
}

struct MessagingFee {
    uint256 nativeFee;      // Fee in native token (ETH/AVAX/MATIC/BNB)
    uint256 lzTokenFee;     // Fee in ZRO token (always 0, we pay native)
}

struct MessagingReceipt {
    bytes32 guid;
    uint64  nonce;
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
    int256  feeAmountLD;
    string  description;
}

struct Ticket {
    uint56  ticketId;
    bytes   passengerBytes;
}

interface IStargate {
    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken)
        external view returns (MessagingFee memory fee);

    function quoteOFT(SendParam calldata _sendParam)
        external view returns (OFTLimit memory, OFTFeeDetail[] memory, OFTReceipt memory);

    function sendToken(SendParam calldata _sendParam, MessagingFee calldata _fee, address _refundAddress)
        external payable returns (MessagingReceipt memory, OFTReceipt memory, Ticket memory);
}

contract Treasury is Ownable {
    using SafeERC20 for IERC20;

    // --- Immutables ---
    IERC20 public immutable usdc;
    ISwapRouter public immutable swapRouter;
    IStargate public immutable stargatePool;

    // --- State ---
    uint256 public monthlyCap;
    uint256 public currentMonthWithdrawn;
    uint256 public currentMonthStart;
    bool public adminWithdrawEnabled;
    address public stakingRewardsAddress;

    // --- Keeper Bounty (rebalance) ---
    bool public keeperBountyEnabled;
    uint256 public keeperBountyAmount;
    mapping(address => bool) public authorizedRangeManagers;

    // --- Bridge Bounty (Phase 2) — paid to whoever calls bridgeToStakers / collectAndBridge ---
    // Anti-drain protections (configurable by multisig):
    //  - cooldown:  bounty paid at most once per `bridgeBountyCooldown` seconds
    //  - min ratio: bridged amount must be >= bridgeBountyAmount * BRIDGE_BOUNTY_MIN_RATIO
    //               (default 50, ie. you must bridge >= 50× the bounty value to earn it)
    bool public bridgeBountyEnabled;
    uint256 public bridgeBountyAmount;
    uint64 public bridgeBountyCooldown;     // seconds between two bounty payments
    uint64 public lastBridgeBountyAt;       // unix timestamp of the last paid bounty
    uint16 public bridgeBountyMinRatio;     // bounty paid only if bridged >= bountyAmount * ratio

    // --- Bridge (Stargate v2) ---
    bool public bridgeEnabled;
    uint32 public bridgeDestinationEid;     // LayerZero v2 endpoint ID (e.g. 30184 = Base)
    address public bridgeDestinationAddress; // Recipient on destination chain (staking contract)

    // --- Events ---
    event AdminWithdrawal(uint256 amount, address indexed to);
    event AdminWithdrawDisabled(uint256 timestamp);
    event StakingRewardsSet(address indexed stakingRewards);
    event FeesDistributed(uint256 amount);
    event MonthlyCapUpdated(uint256 oldCap, uint256 newCap);
    event SwappedToUSDC(address indexed tokenIn, uint24 fee, uint256 amountIn, uint256 usdcOut);
    event KeeperBountyPaid(address indexed keeper, uint256 amount);
    event KeeperBountyConfigured(bool enabled, uint256 amount);
    event BridgeBountyPaid(address indexed keeper, uint256 amount);
    event BridgeBountyConfigured(bool enabled, uint256 amount);
    event BridgeBountyCooldownConfigured(uint64 cooldown, uint16 minRatio);
    event BridgeConfigured(bool enabled, uint32 dstEid, address destination);
    event BridgedToStakers(uint256 amountSent, uint256 amountReceived, uint32 dstEid, bytes32 guid);
    event RangeManagerAuthorized(address indexed rangeManager, bool authorized);
    event CollectedAndBridged(address indexed tokenIn, uint256 swappedUSDC, uint256 bridgedUSDC, uint32 dstEid);

    constructor(
        address _usdc,
        address _swapRouter,
        uint256 _monthlyCap,
        bool _keeperBountyEnabled,
        uint256 _keeperBountyAmount,
        address _stargatePool
    ) {
        usdc = IERC20(_usdc);
        swapRouter = ISwapRouter(_swapRouter);
        monthlyCap = _monthlyCap;
        adminWithdrawEnabled = true;
        currentMonthStart = block.timestamp;
        keeperBountyEnabled = _keeperBountyEnabled;
        keeperBountyAmount = _keeperBountyAmount;
        stargatePool = IStargate(_stargatePool);
    }

    receive() external payable {}

    // --- Public Functions ---

    /// @notice Swap any ERC-20 token held by this Treasury to USDC via Uniswap V3. Callable by anyone.
    function swapToUSDC(address tokenIn, uint24 fee, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        require(tokenIn != address(usdc), "Already USDC");
        require(amountIn > 0, "Zero amount");
        IERC20 token = IERC20(tokenIn);
        require(token.balanceOf(address(this)) >= amountIn, "Insufficient balance");

        // Approve swap router for this token (safe pattern: reset then set)
        token.safeApprove(address(swapRouter), 0);
        token.safeApprove(address(swapRouter), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: address(usdc),
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);
        emit SwappedToUSDC(tokenIn, fee, amountIn, amountOut);
    }

    /// @notice Bridge USDC to staking contract on destination chain via Stargate v2. Callable by anyone.
    /// @dev Uses Taxi mode (immediate delivery). Caller pays native gas for cross-chain fees via msg.value.
    function bridgeToStakers(uint256 amount) external payable {
        require(bridgeEnabled, "Bridge disabled");
        require(bridgeDestinationAddress != address(0), "Destination not set");
        require(usdc.balanceOf(address(this)) >= amount, "Insufficient USDC");

        // Build SendParam (Taxi mode = empty oftCmd)
        SendParam memory sendParam = SendParam({
            dstEid: bridgeDestinationEid,
            to: bytes32(uint256(uint160(bridgeDestinationAddress))),
            amountLD: amount,
            minAmountLD: 0, // will be set after quoteOFT
            extraOptions: new bytes(0),
            composeMsg: new bytes(0),
            oftCmd: ""  // Taxi = immediate delivery
        });

        // Get actual received amount (after Stargate fee)
        (, , OFTReceipt memory receipt) = stargatePool.quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;

        // Get messaging fee in native token
        MessagingFee memory fee = stargatePool.quoteSend(sendParam, false);
        require(msg.value >= fee.nativeFee, "Insufficient native fee");

        // Approve Stargate pool to spend USDC
        usdc.safeApprove(address(stargatePool), 0);
        usdc.safeApprove(address(stargatePool), amount);

        // Execute cross-chain transfer
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt, ) =
            stargatePool.sendToken{value: fee.nativeFee}(sendParam, fee, msg.sender);

        emit BridgedToStakers(oftReceipt.amountSentLD, oftReceipt.amountReceivedLD, bridgeDestinationEid, msgReceipt.guid);
        _payBridgeBounty(msg.sender, oftReceipt.amountSentLD);
    }

    /// @dev Pays the bridge bounty to `keeper` if enabled, the treasury holds enough USDC,
    ///      the cooldown has passed, and `bridgedAmount` is large enough to justify the bounty.
    ///      Silent no-op otherwise — never blocks the bridge itself.
    function _payBridgeBounty(address keeper, uint256 bridgedAmount) internal {
        if (!bridgeBountyEnabled || bridgeBountyAmount == 0) return;
        // Anti-drain: cooldown
        if (block.timestamp < uint256(lastBridgeBountyAt) + uint256(bridgeBountyCooldown)) return;
        // Anti-drain: minimum bridged amount relative to the bounty
        uint256 ratio = uint256(bridgeBountyMinRatio);
        if (ratio > 0 && bridgedAmount < bridgeBountyAmount * ratio) return;
        // Liquidity safety
        if (usdc.balanceOf(address(this)) < bridgeBountyAmount) return;
        lastBridgeBountyAt = uint64(block.timestamp);
        usdc.safeTransfer(keeper, bridgeBountyAmount);
        emit BridgeBountyPaid(keeper, bridgeBountyAmount);
    }

    /// @notice Swap token to USDC + bridge to staking in one transaction. Callable by anyone.
    /// @dev Caller pays native gas for Stargate cross-chain fees via msg.value.
    function collectAndBridge(
        address tokenIn,
        uint24 fee,
        uint256 amountIn,
        uint256 minSwapOut
    ) external payable returns (uint256 usdcBridged) {
        require(bridgeEnabled, "Bridge disabled");
        require(bridgeDestinationAddress != address(0), "Destination not set");

        // Step 1: Swap to USDC (if not already USDC)
        uint256 usdcAmount;
        if (tokenIn == address(usdc)) {
            usdcAmount = amountIn;
            require(usdc.balanceOf(address(this)) >= amountIn, "Insufficient USDC");
        } else {
            require(amountIn > 0, "Zero amount");
            IERC20 token = IERC20(tokenIn);
            require(token.balanceOf(address(this)) >= amountIn, "Insufficient balance");

            token.safeApprove(address(swapRouter), 0);
            token.safeApprove(address(swapRouter), amountIn);

            ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: address(usdc),
                fee: fee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minSwapOut,
                sqrtPriceLimitX96: 0
            });

            usdcAmount = swapRouter.exactInputSingle(swapParams);
            emit SwappedToUSDC(tokenIn, fee, amountIn, usdcAmount);
        }

        // Step 2: Bridge all swapped USDC via Stargate
        SendParam memory sendParam = SendParam({
            dstEid: bridgeDestinationEid,
            to: bytes32(uint256(uint160(bridgeDestinationAddress))),
            amountLD: usdcAmount,
            minAmountLD: 0,
            extraOptions: new bytes(0),
            composeMsg: new bytes(0),
            oftCmd: ""
        });

        (, , OFTReceipt memory receipt) = stargatePool.quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;

        MessagingFee memory msgFee = stargatePool.quoteSend(sendParam, false);
        require(msg.value >= msgFee.nativeFee, "Insufficient native fee");

        usdc.safeApprove(address(stargatePool), 0);
        usdc.safeApprove(address(stargatePool), usdcAmount);

        (, OFTReceipt memory oftReceipt, ) =
            stargatePool.sendToken{value: msgFee.nativeFee}(sendParam, msgFee, msg.sender);

        usdcBridged = oftReceipt.amountReceivedLD;
        emit CollectedAndBridged(tokenIn, usdcAmount, usdcBridged, bridgeDestinationEid);
        _payBridgeBounty(msg.sender, oftReceipt.amountSentLD);
    }

    /// @notice Estimate bridge fee in native token (ETH/AVAX/MATIC/BNB)
    function estimateBridgeFee(uint256 amount) external view returns (uint256 nativeFee, uint256 amountReceived) {
        SendParam memory sendParam = SendParam({
            dstEid: bridgeDestinationEid,
            to: bytes32(uint256(uint160(bridgeDestinationAddress))),
            amountLD: amount,
            minAmountLD: 0,
            extraOptions: new bytes(0),
            composeMsg: new bytes(0),
            oftCmd: ""
        });

        (, , OFTReceipt memory receipt) = stargatePool.quoteOFT(sendParam);
        amountReceived = receipt.amountReceivedLD;

        sendParam.minAmountLD = amountReceived;
        MessagingFee memory fee = stargatePool.quoteSend(sendParam, false);
        nativeFee = fee.nativeFee;
    }

    // --- Admin Functions (onlyOwner = Safe) ---

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

    /// @notice Irreversibly disable admin withdrawals (Phase 2)
    function disableAdminWithdraw() external onlyOwner {
        adminWithdrawEnabled = false;
        emit AdminWithdrawDisabled(block.timestamp);
    }

    /// @notice Recover ERC-20 tokens accidentally sent here (other than USDC).
    /// @dev USDC must go through adminWithdraw() to respect the monthly cap.
    ///      Disabled once admin withdrawals are irreversibly turned off.
    function rescueToken(address tokenAddr, address to, uint256 amount) external onlyOwner {
        require(adminWithdrawEnabled, "Admin withdraw disabled");
        require(to != address(0), "Invalid recipient");
        require(tokenAddr != address(usdc), "Use adminWithdraw for USDC");
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit TokenRescued(tokenAddr, to, amount);
    }

    /// @notice Recover native ETH accidentally sent here.
    /// @dev Disabled once admin withdrawals are irreversibly turned off.
    function rescueETH(address payable to, uint256 amount) external onlyOwner {
        require(adminWithdrawEnabled, "Admin withdraw disabled");
        require(to != address(0), "Invalid recipient");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit ETHRescued(to, amount);
    }

    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ETHRescued(address indexed to, uint256 amount);

    // --- Keeper Bounty Functions ---

    /// @notice Pay bounty to keeper who executed a rebalance. Called by authorized RangeManager.
    function payKeeperBounty(address keeper) external {
        require(authorizedRangeManagers[msg.sender], "Not authorized");
        require(keeperBountyEnabled, "Bounty disabled");
        require(keeperBountyAmount > 0, "Bounty is zero");
        require(usdc.balanceOf(address(this)) >= keeperBountyAmount, "Insufficient USDC");

        usdc.safeTransfer(keeper, keeperBountyAmount);
        emit KeeperBountyPaid(keeper, keeperBountyAmount);
    }

    function setKeeperBounty(bool _enabled, uint256 _amount) external onlyOwner {
        keeperBountyEnabled = _enabled;
        keeperBountyAmount = _amount;
        emit KeeperBountyConfigured(_enabled, _amount);
    }

    /// @notice Configure the bridge bounty (paid to whoever calls bridgeToStakers / collectAndBridge).
    function setBridgeBounty(bool _enabled, uint256 _amount) external onlyOwner {
        bridgeBountyEnabled = _enabled;
        bridgeBountyAmount = _amount;
        emit BridgeBountyConfigured(_enabled, _amount);
    }

    /// @notice Configure the anti-drain protections for the bridge bounty.
    /// @param _cooldown Minimum seconds between two paid bounties (e.g. 21600 = 6h).
    /// @param _minRatio Minimum ratio of bridged amount over bounty amount (e.g. 50 means
    ///        you must bridge at least 50× the bounty value to earn it). 0 disables the check.
    function setBridgeBountyCooldown(uint64 _cooldown, uint16 _minRatio) external onlyOwner {
        bridgeBountyCooldown = _cooldown;
        bridgeBountyMinRatio = _minRatio;
        emit BridgeBountyCooldownConfigured(_cooldown, _minRatio);
    }

    function authorizeRangeManager(address _rangeManager, bool _authorized) external onlyOwner {
        authorizedRangeManagers[_rangeManager] = _authorized;
        emit RangeManagerAuthorized(_rangeManager, _authorized);
    }

    // --- Bridge Configuration (onlyOwner = Safe) ---

    function setBridgeConfig(bool _enabled, uint32 _dstEid, address _destination) external onlyOwner {
        bridgeEnabled = _enabled;
        bridgeDestinationEid = _dstEid;
        bridgeDestinationAddress = _destination;
        emit BridgeConfigured(_enabled, _dstEid, _destination);
    }

    // --- Local Staking (same chain, Phase 2) ---

    function setStakingRewards(address _stakingRewards) external onlyOwner {
        require(_stakingRewards != address(0), "Invalid address");
        stakingRewardsAddress = _stakingRewards;
        emit StakingRewardsSet(_stakingRewards);
    }

    /// @notice Distribute USDC to local staking contract (same chain). Callable by anyone.
    function distributeToStakers(uint256 amount) external {
        require(stakingRewardsAddress != address(0), "Staking not configured");
        usdc.safeTransfer(stakingRewardsAddress, amount);
        emit FeesDistributed(amount);
    }
}
