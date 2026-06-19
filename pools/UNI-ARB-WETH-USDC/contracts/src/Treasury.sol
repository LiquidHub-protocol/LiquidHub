// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// --- Stargate v2 Interfaces ---

struct SendParam {
    uint32 dstEid; // Destination LayerZero v2 endpoint ID
    bytes32 to; // Recipient address, left-padded to bytes32
    uint256 amountLD; // Amount in local token decimals
    uint256 minAmountLD; // Minimum received (slippage guard)
    bytes extraOptions; // LayerZero executor options (empty for default)
    bytes composeMsg; // Composed message for destination (empty if none)
    bytes oftCmd; // "" = Taxi (immediate), hex"00" = Bus (batched)
}

struct MessagingFee {
    uint256 nativeFee; // Fee in native token (ETH/AVAX/MATIC/BNB)
    uint256 lzTokenFee; // Fee in ZRO token (always 0, we pay native)
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

contract Treasury is Ownable {
    using SafeERC20 for IERC20;

    error BridgeBountyCooldownZero();
    error BridgeBountyMinRatioZero();

    uint256 private constant USD_SCALE = 1e8;
    uint16 private constant DEPOSIT_BOUNTY_MIN_RATIO = 100;

    // --- Immutables ---
    IERC20 public immutable usdc;
    uint8 public immutable usdcDecimals;
    ISwapRouter public immutable swapRouter;
    IStargate public immutable stargatePool;

    // --- State ---
    uint256 public monthlyCap;
    uint256 public currentMonthWithdrawn;
    uint256 public currentMonthStart;
    bool public adminWithdrawEnabled;
    address public rescueSafe;
    address public stakingRewardsAddress;

    // --- Keeper Bounty (rebalance) ---
    bool public keeperBountyEnabled;
    uint256 public keeperBountyAmount;
    uint256 public keeperBountyDailyCap; // max rebalance bounties paid per UTC day per RangeManager
    mapping(address => uint64) public keeperBountyDay;
    mapping(address => uint256) public keeperBountyDailySpent;
    mapping(address => bool) public authorizedRangeManagers;

    // SÉCURITÉ (audit V1) : plancher oracle anti-sandwich pour les swaps de la Treasury.
    // Le Treasury est PARTAGÉ par toutes les pools d'une même chaîne → il peut swapper des tokens
    // volatils variés (WETH, WBTC, ...). Un feed Chainlink par token est déclaré par la gouvernance.
    // swapToUSDC/collectAndBridge imposent amountOutMinimum >= prix oracle × (1 − swapSlippageBps),
    // et REVERT si aucun feed n'est configuré pour tokenIn (pas de swap d'un token non oraclé).
    mapping(address => AggregatorV3Interface) public swapFeeds; // tokenIn => feed Chainlink (prix en USD)
    mapping(address => uint32) public swapFeedMaxAges; // tokenIn => heartbeat max accepte pour ce feed
    uint16 public swapSlippageBps; // slippage max toléré sur les swaps Treasury (ex 100 = 1%)

    // --- Bridge Bounty (Phase 2) — paid to whoever calls bridgeToStakers / collectAndBridge ---
    // Anti-drain protections (configurable by multisig):
    //  - cooldown:  bounty paid at most once per `bridgeBountyCooldown` seconds
    //  - min ratio: bridged amount must be >= bridgeBountyAmount * BRIDGE_BOUNTY_MIN_RATIO
    //               (default 50, ie. you must bridge >= 50× the bounty value to earn it)
    bool public bridgeBountyEnabled;
    uint256 public bridgeBountyAmount;
    uint64 public bridgeBountyCooldown; // seconds between two bounty payments
    uint64 public lastBridgeBountyAt; // unix timestamp of the last paid bounty
    uint16 public bridgeBountyMinRatio; // bounty paid only if bridged >= bountyAmount * ratio

    // --- Metrics Bounty (recordPriceSnapshot) — paye au keeper qui enregistre un snapshot de prix ---
    // Anti-spam assure on-chain par le timing regulier (maxSnapshotsPerDay) cote RangeManager.
    bool public metricsBountyEnabled;
    uint256 public metricsBountyAmount;

    // --- Hedge Bounty (adjustHedge, pools DN) — paye au keeper qui reajuste le hedge ---
    // Anti-drain: adjustHedge() est deja borne cote AaveHedgeManager par drift+cooldown, et le Treasury ajoute
    // un cap quotidien par HedgeManager. Si le cap est atteint, le caller AaveHedgeManager catch le revert et le
    // reajustement continue sans bounty.
    bool public hedgeBountyEnabled;
    uint256 public hedgeBountyAmount;
    uint256 public hedgeBountyDailyCap; // max hedge bounties paid per UTC day per HedgeManager
    mapping(address => uint64) public hedgeBountyDay;
    mapping(address => uint256) public hedgeBountyDailySpent;
    mapping(address => bool) public authorizedHedgeManagers;

    // --- Deposit Bounty (processDepositPermissionless) — paye au keeper qui traite un depot en file ---
    // Le caller est le Vault (pas le RangeManager) -> autorisation dediee authorizedVaults.
    // Anti-drain: ratio depot/bounty + cooldown/cap quotidien par Vault. Le traitement du depot reste
    // permissionless; si ces limites revert, le Vault catch et saute seulement le paiement du bounty.
    bool public depositBountyEnabled;
    uint256 public depositBountyAmount;
    uint64 public depositBountyCooldown; // seconds between two paid deposit bounties per Vault
    uint64 public depositBountyKeeperCooldown; // seconds between two paid deposit bounties for the same keeper per Vault
    uint256 public depositBountyDailyCap; // max deposit bounties paid per UTC day per Vault, in reward token units
    mapping(address => uint64) public lastDepositBountyAt;
    mapping(address => mapping(address => uint64)) public lastDepositBountyKeeperAt;
    mapping(address => uint64) public depositBountyDay;
    mapping(address => uint256) public depositBountyDailySpent;
    mapping(address => bool) public authorizedVaults;

    // --- Bridge (Stargate v2) ---
    bool public bridgeEnabled;
    uint32 public bridgeDestinationEid; // LayerZero v2 endpoint ID (e.g. 30184 = Base)
    address public bridgeDestinationAddress; // Recipient on destination chain (staking contract)
    uint16 public bridgeMinReceivedBps; // 0 = disabled, otherwise min received / sent ratio in bps

    // --- Events ---
    event AdminWithdrawal(uint256 amount, address indexed to);
    event AdminWithdrawDisabled(uint256 timestamp);
    event RescueSafeUpdated(address indexed oldSafe, address indexed newSafe);
    event StakingRewardsSet(address indexed stakingRewards);
    event FeesDistributed(uint256 amount);
    event MonthlyCapUpdated(uint256 oldCap, uint256 newCap);
    event SwappedToUSDC(address indexed tokenIn, uint24 fee, uint256 amountIn, uint256 usdcOut);
    event KeeperBountyPaid(address indexed keeper, uint256 amount);
    event KeeperBountyConfigured(bool enabled, uint256 amount);
    event KeeperBountyDailyCapConfigured(uint256 dailyCap);
    event HedgeBountyDailyCapConfigured(uint256 dailyCap);
    event BridgeBountyPaid(address indexed keeper, uint256 amount);
    event BridgeBountyConfigured(bool enabled, uint256 amount);
    event BridgeBountyCooldownConfigured(uint64 cooldown, uint16 minRatio);
    event BridgeMinReceivedConfigured(uint16 minReceivedBps);
    event BridgeConfigured(bool enabled, uint32 dstEid, address destination);
    event BridgedToStakers(uint256 amountSent, uint256 amountReceived, uint32 dstEid, bytes32 guid);
    event RangeManagerAuthorized(address indexed rangeManager, bool authorized);
    event SwapFeedConfigured(address indexed token, address feed, uint16 swapSlippageBps, uint32 maxAge);
    event CollectedAndBridged(address indexed tokenIn, uint256 swappedUSDC, uint256 bridgedUSDC, uint32 dstEid);
    event MetricsBountyPaid(address indexed keeper, uint256 amount);
    event MetricsBountyConfigured(bool enabled, uint256 amount);
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
        uint256 _monthlyCap,
        bool _keeperBountyEnabled,
        uint256 _keeperBountyAmount,
        address _stargatePool
    ) {
        require(_usdc != address(0) && _swapRouter != address(0) && _stargatePool != address(0), "Invalid address");
        usdc = IERC20(_usdc);
        usdcDecimals = IERC20Metadata(_usdc).decimals();
        require(usdcDecimals <= 18, "Invalid decimals");
        swapRouter = ISwapRouter(_swapRouter);
        monthlyCap = _monthlyCap;
        adminWithdrawEnabled = true;
        rescueSafe = msg.sender;
        currentMonthStart = block.timestamp;
        keeperBountyEnabled = _keeperBountyEnabled;
        keeperBountyAmount = _keeperBountyAmount;
        stargatePool = IStargate(_stargatePool);
    }

    receive() external payable {}

    modifier onlyRescueSafe() {
        require(msg.sender == rescueSafe, "Only rescue safe");
        _;
    }

    // --- Public Functions ---

    /// @notice Swap any ERC-20 token held by this Treasury to USDC via Uniswap V3. Callable by anyone.
    // SÉCURITÉ (audit V1) : restreint à onlyOwner (Safe). Avant, swapToUSDC était public : n'importe qui
    // pouvait déclencher un swap des tokens de la Treasury avec un minAmountOut faible / une route
    // défavorable et sandwicher la conversion des fees. C'est une opération de gestion de trésorerie
    // (rare, déclenchée via la Safe) — pas un point d'entrée permissionless.
    function swapToUSDC(address tokenIn, uint24 fee, uint256 amountIn, uint256 minAmountOut)
        external
        onlyOwner
        returns (uint256 amountOut)
    {
        require(tokenIn != address(usdc), "Already USDC");
        require(amountIn > 0, "Zero amount");
        IERC20 token = IERC20(tokenIn);
        require(token.balanceOf(address(this)) >= amountIn, "Insufficient balance");
        require(minAmountOut >= _oracleMinUsdcOut(tokenIn, amountIn), "minOut<oracle");

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
        require(amount > 0, "Zero amount");
        require(bridgeDestinationAddress != address(0), "Destination not set");
        _requireDistributableUsdc(amount);

        // Build SendParam (Taxi mode = empty oftCmd)
        SendParam memory sendParam = SendParam({
            dstEid: bridgeDestinationEid,
            to: bytes32(uint256(uint160(bridgeDestinationAddress))),
            amountLD: amount,
            minAmountLD: 0, // will be set after quoteOFT
            extraOptions: new bytes(0),
            composeMsg: new bytes(0),
            oftCmd: "" // Taxi = immediate delivery
        });

        // Get actual received amount (after Stargate fee)
        (,, OFTReceipt memory receipt) = stargatePool.quoteOFT(sendParam);
        _requireBridgeMinReceived(amount, receipt.amountReceivedLD);
        sendParam.minAmountLD = receipt.amountReceivedLD;

        // Get messaging fee in native token
        MessagingFee memory fee = stargatePool.quoteSend(sendParam, false);
        require(msg.value >= fee.nativeFee, "Insufficient native fee");

        // Approve Stargate pool to spend USDC
        usdc.safeApprove(address(stargatePool), 0);
        usdc.safeApprove(address(stargatePool), amount);

        // Execute cross-chain transfer
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt,) =
            stargatePool.sendToken{value: fee.nativeFee}(sendParam, fee, msg.sender);

        emit BridgedToStakers(
            oftReceipt.amountSentLD, oftReceipt.amountReceivedLD, bridgeDestinationEid, msgReceipt.guid
        );
        _payBridgeBounty(msg.sender, oftReceipt.amountSentLD);
    }

    /// @dev Pays the bridge bounty to `keeper` if enabled, the treasury holds enough USDC,
    ///      the cooldown has passed, and `bridgedAmount` is large enough to justify the bounty.
    ///      Silent no-op otherwise — never blocks the bridge itself.
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

    /// @dev Phase 2: permissionless bridge/distribution cannot drain bounty float.
    function _requireDistributableUsdc(uint256 amount) internal view {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 reserve = _bountyReserveUsdc();
        require(balance > reserve && amount <= balance - reserve, "Bounty reserve");
    }

    function _bountyReserveUsdc() internal view returns (uint256 reserve) {
        if (keeperBountyEnabled) reserve += keeperBountyDailyCap > 0 ? keeperBountyDailyCap : keeperBountyAmount;
        if (metricsBountyEnabled) reserve += metricsBountyAmount;
        if (hedgeBountyEnabled) reserve += hedgeBountyDailyCap > 0 ? hedgeBountyDailyCap : hedgeBountyAmount;
        if (depositBountyEnabled) reserve += depositBountyDailyCap > 0 ? depositBountyDailyCap : depositBountyAmount;
        if (bridgeBountyEnabled) reserve += bridgeBountyAmount;
    }

    /// @notice Swap token to USDC + bridge to staking in one transaction. Callable by anyone.
    /// @dev Caller pays native gas for Stargate cross-chain fees via msg.value.
    function collectAndBridge(address tokenIn, uint24 fee, uint256 amountIn, uint256 minSwapOut)
        external
        payable
        returns (uint256 usdcBridged)
    {
        require(bridgeEnabled, "Bridge disabled");
        require(bridgeDestinationAddress != address(0), "Destination not set");

        // Step 1: Swap to USDC (if not already USDC)
        uint256 usdcAmount;
        if (tokenIn == address(usdc)) {
            usdcAmount = amountIn;
            _requireDistributableUsdc(amountIn);
        } else {
            require(amountIn > 0, "Zero amount");
            IERC20 token = IERC20(tokenIn);
            require(token.balanceOf(address(this)) >= amountIn, "Insufficient balance");

            token.safeApprove(address(swapRouter), 0);
            token.safeApprove(address(swapRouter), amountIn);

            // SÉCURITÉ (audit V1) : collectAndBridge est PERMISSIONLESS (décentralisation). On impose donc
            // un plancher oracle anti-sandwich : amountOutMinimum = max(minSwapOut fourni, plancher oracle).
            // Le plancher revert si aucun feed n'est configuré pour tokenIn → pas de swap d'un token non oraclé.
            uint256 floor = _oracleMinUsdcOut(tokenIn, amountIn);
            uint256 minOut = minSwapOut > floor ? minSwapOut : floor;

            ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: address(usdc),
                fee: fee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            });

            usdcAmount = swapRouter.exactInputSingle(swapParams);
            emit SwappedToUSDC(tokenIn, fee, amountIn, usdcAmount);
            _requireDistributableUsdc(usdcAmount);
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

        (,, OFTReceipt memory receipt) = stargatePool.quoteOFT(sendParam);
        _requireBridgeMinReceived(usdcAmount, receipt.amountReceivedLD);
        sendParam.minAmountLD = receipt.amountReceivedLD;

        MessagingFee memory msgFee = stargatePool.quoteSend(sendParam, false);
        require(msg.value >= msgFee.nativeFee, "Insufficient native fee");

        usdc.safeApprove(address(stargatePool), 0);
        usdc.safeApprove(address(stargatePool), usdcAmount);

        (, OFTReceipt memory oftReceipt,) =
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

        (,, OFTReceipt memory receipt) = stargatePool.quoteOFT(sendParam);
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

    /// @notice Configure the Safe allowed to perform emergency rescue actions after Phase 2.
    /// @dev Separate from owner/governance: disabling admin withdrawals must not disable rescue operations.
    function setRescueSafe(address newSafe) external onlyOwner {
        require(newSafe != address(0), "Invalid safe");
        emit RescueSafeUpdated(rescueSafe, newSafe);
        rescueSafe = newSafe;
    }

    /// @notice Recover ERC-20 tokens accidentally sent here (other than USDC).
    /// @dev USDC must go through adminWithdraw() to respect the monthly cap.
    ///      Remains available to the rescue Safe after admin withdrawals are disabled in Phase 2.
    function rescueToken(address tokenAddr, address to, uint256 amount) external onlyRescueSafe {
        require(to != address(0), "Invalid recipient");
        require(tokenAddr != address(usdc), "Use adminWithdraw for USDC");
        require(address(swapFeeds[tokenAddr]) == address(0), "Use bridge flow");
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit TokenRescued(tokenAddr, to, amount);
    }

    /// @notice Recover native ETH accidentally sent here.
    /// @dev Remains available to the rescue Safe after admin withdrawals are disabled in Phase 2.
    function rescueETH(address payable to, uint256 amount) external onlyRescueSafe {
        require(to != address(0), "Invalid recipient");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit ETHRescued(to, amount);
    }

    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ETHRescued(address indexed to, uint256 amount);

    // --- Keeper Bounty Functions ---

    /// @notice Pay bounty to keeper who executed a rebalance. Called by authorized RangeManager.
    function payKeeperBounty(address keeper) external {
        require(keeper != address(0), "Invalid keeper");
        require(authorizedRangeManagers[msg.sender], "Not authorized");
        require(keeperBountyEnabled, "Bounty disabled");
        require(keeperBountyAmount > 0, "Bounty is zero");
        require(usdc.balanceOf(address(this)) >= keeperBountyAmount, "Insufficient USDC");
        _consumeKeeperBountyLimit(msg.sender);

        usdc.safeTransfer(keeper, keeperBountyAmount);
        emit KeeperBountyPaid(keeper, keeperBountyAmount);
    }

    function setKeeperBounty(bool _enabled, uint256 _amount) external onlyOwner {
        if (_enabled && keeperBountyDailyCap > 0) {
            require(_amount <= keeperBountyDailyCap, "Bounty > daily cap");
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
            require(newSpent <= keeperBountyDailyCap, "Keeper bounty daily cap");
        }
        keeperBountyDailySpent[rangeManager] = newSpent;
    }

    function setKeeperBountyDailyCap(uint256 _dailyCap) external onlyOwner {
        if (_dailyCap > 0) {
            require(_dailyCap >= keeperBountyAmount, "Cap < bounty");
        }
        keeperBountyDailyCap = _dailyCap;
        emit KeeperBountyDailyCapConfigured(_dailyCap);
    }

    // --- Metrics Bounty Functions (recordPriceSnapshot) ---

    /// @notice Pay bounty to keeper who recorded a price snapshot. Called by authorized RangeManager.
    /// @dev Appele en try/catch cote RangeManager => ne bloque jamais le snapshot si revert ici.
    ///      Pas de daily cap Treasury dedie : la cadence est bornee on-chain par RangeManager.maxSnapshotsPerDay.
    function payMetricsBounty(address keeper) external {
        require(keeper != address(0), "Invalid keeper");
        require(authorizedRangeManagers[msg.sender], "Not authorized");
        require(metricsBountyEnabled, "Bounty disabled");
        require(metricsBountyAmount > 0, "Bounty is zero");
        require(usdc.balanceOf(address(this)) >= metricsBountyAmount, "Insufficient USDC");

        usdc.safeTransfer(keeper, metricsBountyAmount);
        emit MetricsBountyPaid(keeper, metricsBountyAmount);
    }

    function setMetricsBounty(bool _enabled, uint256 _amount) external onlyOwner {
        metricsBountyEnabled = _enabled;
        metricsBountyAmount = _amount;
        emit MetricsBountyConfigured(_enabled, _amount);
    }

    // --- Hedge Bounty Functions (adjustHedge, pools DN) ---

    /// @notice Pay bounty to keeper who adjusted the hedge. Called by authorized AaveHedgeManager.
    /// @dev Appele en try/catch par AaveHedgeManager => le cap quotidien ne bloque jamais le reajustement.
    function payHedgeBounty(address keeper) external {
        require(keeper != address(0), "Invalid keeper");
        require(authorizedHedgeManagers[msg.sender], "Not authorized");
        require(hedgeBountyEnabled, "Bounty disabled");
        require(hedgeBountyAmount > 0, "Bounty is zero");
        require(usdc.balanceOf(address(this)) >= hedgeBountyAmount, "Insufficient USDC");
        _consumeHedgeBountyLimit(msg.sender);

        usdc.safeTransfer(keeper, hedgeBountyAmount);
        emit HedgeBountyPaid(keeper, hedgeBountyAmount);
    }

    function setHedgeBounty(bool _enabled, uint256 _amount) external onlyOwner {
        if (_enabled && hedgeBountyDailyCap > 0) {
            require(_amount <= hedgeBountyDailyCap, "Bounty > daily cap");
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
            require(newSpent <= hedgeBountyDailyCap, "Hedge bounty daily cap");
        }
        hedgeBountyDailySpent[hedgeManager] = newSpent;
    }

    function setHedgeBountyDailyCap(uint256 _dailyCap) external onlyOwner {
        if (_dailyCap > 0) {
            require(_dailyCap >= hedgeBountyAmount, "Cap < bounty");
        }
        hedgeBountyDailyCap = _dailyCap;
        emit HedgeBountyDailyCapConfigured(_dailyCap);
    }

    function authorizeHedgeManager(address _hedgeManager, bool _authorized) external onlyOwner {
        authorizedHedgeManagers[_hedgeManager] = _authorized;
        emit HedgeManagerAuthorized(_hedgeManager, _authorized);
    }

    // --- Deposit Bounty Functions (processDepositPermissionless) ---

    /// @notice Pay bounty to keeper who processed a queued user deposit. Called by authorized Vault.
    /// @dev Appele en try/catch depuis le Vault => ne bloque jamais le traitement du depot.
    ///      Anti-drain: le Vault revert si la file est vide, donc paye uniquement sur depot reel.
    function payDepositBounty(address keeper, uint256 depositValueUsd) external {
        require(keeper != address(0), "Invalid keeper");
        require(authorizedVaults[msg.sender], "Not authorized");
        require(depositBountyEnabled, "Bounty disabled");
        require(depositBountyAmount > 0, "Bounty is zero");
        require(
            depositValueUsd >= _rewardAmountUsd8(depositBountyAmount) * DEPOSIT_BOUNTY_MIN_RATIO, "Deposit too small"
        );
        require(usdc.balanceOf(address(this)) >= depositBountyAmount, "Insufficient USDC");

        _consumeDepositBountyLimit(msg.sender, keeper);

        usdc.safeTransfer(keeper, depositBountyAmount);
        emit DepositBountyPaid(keeper, depositBountyAmount);
    }

    function _consumeDepositBountyLimit(address vault, address keeper) internal {
        if (depositBountyCooldown > 0) {
            require(
                block.timestamp >= uint256(lastDepositBountyAt[vault]) + uint256(depositBountyCooldown),
                "Deposit bounty cooldown"
            );
        }
        if (depositBountyKeeperCooldown > 0) {
            require(
                block.timestamp
                    >= uint256(lastDepositBountyKeeperAt[vault][keeper]) + uint256(depositBountyKeeperCooldown),
                "Deposit bounty keeper cooldown"
            );
        }

        uint64 day = uint64(block.timestamp / 1 days);
        if (depositBountyDay[vault] != day) {
            depositBountyDay[vault] = day;
            depositBountyDailySpent[vault] = 0;
        }

        uint256 newSpent = depositBountyDailySpent[vault] + depositBountyAmount;
        if (depositBountyDailyCap > 0) {
            require(newSpent <= depositBountyDailyCap, "Deposit bounty daily cap");
        }

        lastDepositBountyAt[vault] = uint64(block.timestamp);
        lastDepositBountyKeeperAt[vault][keeper] = uint64(block.timestamp);
        depositBountyDailySpent[vault] = newSpent;
    }

    function _rewardAmountUsd8(uint256 amount) internal view returns (uint256) {
        return (amount * USD_SCALE) / (10 ** usdcDecimals);
    }

    function setDepositBounty(bool _enabled, uint256 _amount) external onlyOwner {
        if (_enabled && depositBountyDailyCap > 0) {
            require(_amount <= depositBountyDailyCap, "Bounty > daily cap");
        }
        depositBountyEnabled = _enabled;
        depositBountyAmount = _amount;
        emit DepositBountyConfigured(_enabled, _amount);
    }

    function setDepositBountyLimits(uint64 _vaultCooldown, uint64 _keeperCooldown, uint256 _dailyCap)
        external
        onlyOwner
    {
        require(_vaultCooldown <= 1 days && _keeperCooldown <= 7 days, "Invalid cooldown");
        if (_dailyCap > 0) {
            require(_dailyCap >= depositBountyAmount, "Cap < bounty");
        }
        depositBountyCooldown = _vaultCooldown;
        depositBountyKeeperCooldown = _keeperCooldown;
        depositBountyDailyCap = _dailyCap;
        emit DepositBountyLimitsConfigured(_vaultCooldown, _keeperCooldown, _dailyCap);
    }

    function authorizeVault(address _vault, bool _authorized) external onlyOwner {
        authorizedVaults[_vault] = _authorized;
        emit VaultAuthorized(_vault, _authorized);
    }

    /// @notice Configure the bridge bounty (paid to whoever calls bridgeToStakers / collectAndBridge).
    function setBridgeBounty(bool _enabled, uint256 _amount) external onlyOwner {
        if (_enabled && _amount > 0 && bridgeBountyCooldown == 0) revert BridgeBountyCooldownZero();
        if (_enabled && _amount > 0 && bridgeBountyMinRatio == 0) revert BridgeBountyMinRatioZero();
        bridgeBountyEnabled = _enabled;
        bridgeBountyAmount = _amount;
        emit BridgeBountyConfigured(_enabled, _amount);
    }

    /// @notice Configure the anti-drain protections for the bridge bounty.
    /// @param _cooldown Minimum seconds between two paid bounties (e.g. 21600 = 6h).
    /// @param _minRatio Minimum ratio of bridged amount over bounty amount (e.g. 50 means
    ///        you must bridge at least 50× the bounty value to earn it). 0 disables bounty payment.
    function setBridgeBountyCooldown(uint64 _cooldown, uint16 _minRatio) external onlyOwner {
        if (bridgeBountyEnabled && bridgeBountyAmount > 0 && _cooldown == 0) revert BridgeBountyCooldownZero();
        if (bridgeBountyEnabled && bridgeBountyAmount > 0 && _minRatio == 0) revert BridgeBountyMinRatioZero();
        bridgeBountyCooldown = _cooldown;
        bridgeBountyMinRatio = _minRatio;
        emit BridgeBountyCooldownConfigured(_cooldown, _minRatio);
    }

    /// @notice Configure the minimum Stargate amount received ratio for bridge operations.
    /// @dev 0 disables the check. Otherwise the value must stay in [9000, 10000] bps.
    function setBridgeMinReceivedBps(uint16 _minReceivedBps) external onlyOwner {
        require(_minReceivedBps == 0 || (_minReceivedBps >= 9000 && _minReceivedBps <= 10000), "Invalid bridge min");
        bridgeMinReceivedBps = _minReceivedBps;
        emit BridgeMinReceivedConfigured(_minReceivedBps);
    }

    function authorizeRangeManager(address _rangeManager, bool _authorized) external onlyOwner {
        authorizedRangeManagers[_rangeManager] = _authorized;
        emit RangeManagerAuthorized(_rangeManager, _authorized);
    }

    // --- Swap oracle floor config (onlyOwner = Safe) — audit V1 ---

    /// @notice Déclare/maj le feed Chainlink (prix USD) d'un token swappable + le slippage et heartbeat tolérés.
    /// @dev feed=address(0) retire le token (ses swaps seront alors refusés). Slippage borné [10..1000] bps.
    function setSwapFeed(address token, address feed, uint16 _swapSlippageBps, uint32 _maxAge) external onlyOwner {
        require(token != address(0) && token != address(usdc), "Invalid token");
        require(_swapSlippageBps >= 10 && _swapSlippageBps <= 1000, "Invalid slippage");
        if (feed == address(0)) {
            delete swapFeeds[token];
            delete swapFeedMaxAges[token];
            emit SwapFeedConfigured(token, feed, _swapSlippageBps, 0);
            return;
        }
        require(_maxAge >= 3600 && _maxAge <= 172800, "Invalid max age");
        require(
            IERC20Metadata(token).decimals() <= 18 && usdcDecimals <= 18 && AggregatorV3Interface(feed).decimals() <= 18,
            "Invalid decimals"
        );
        swapFeeds[token] = AggregatorV3Interface(feed);
        swapFeedMaxAges[token] = _maxAge;
        swapSlippageBps = _swapSlippageBps;
        emit SwapFeedConfigured(token, feed, _swapSlippageBps, _maxAge);
    }

    /// @dev Plancher anti-sandwich : USDC minimum attendu pour `amountIn` de `tokenIn`, depuis l'oracle
    ///      Chainlink (prix USD du token), minoré du slippage. Revert si aucun feed n'est configuré.
    ///      Conversion générique des décimales (token volatil, feed, USDC) — pas de hard-code.
    function _oracleMinUsdcOut(address tokenIn, uint256 amountIn) internal view returns (uint256) {
        AggregatorV3Interface feed = swapFeeds[tokenIn];
        uint32 maxAge = swapFeedMaxAges[tokenIn];
        require(address(feed) != address(0), "No feed for token");
        require(maxAge != 0, "No max age");
        (uint80 roundId, int256 px,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        require(
            px > 0 && updatedAt != 0 && answeredInRound >= roundId && block.timestamp - updatedAt <= maxAge,
            "Bad oracle"
        );
        uint8 tokenDec = IERC20Metadata(tokenIn).decimals();
        uint8 feedDec = feed.decimals();
        uint8 usdcDec = IERC20Metadata(address(usdc)).decimals();
        // valeur_usdc = amountIn * px * 10^usdcDec / (10^tokenDec * 10^feedDec)
        uint256 theo = (amountIn * uint256(px) * (10 ** usdcDec)) / ((10 ** tokenDec) * (10 ** feedDec));
        return (theo * (10000 - swapSlippageBps)) / 10000;
    }

    // --- Bridge Configuration (onlyOwner = Safe) ---

    function setBridgeConfig(bool _enabled, uint32 _dstEid, address _destination) external onlyOwner {
        if (_enabled) {
            require(_dstEid != 0 && _destination != address(0), "Invalid bridge");
        }
        bridgeEnabled = _enabled;
        bridgeDestinationEid = _dstEid;
        bridgeDestinationAddress = _destination;
        emit BridgeConfigured(_enabled, _dstEid, _destination);
    }

    function _requireBridgeMinReceived(uint256 sentAmount, uint256 receivedAmount) internal view {
        uint16 minBps = bridgeMinReceivedBps;
        if (minBps == 0) return;
        require(receivedAmount * 10000 >= sentAmount * uint256(minBps), "Bridge slippage");
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
        _requireDistributableUsdc(amount);
        usdc.safeTransfer(stakingRewardsAddress, amount);
        emit FeesDistributed(amount);
    }
}
