// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "./AutonomousErrors.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Fixed revenue and settlement rules. Linked delegatecalls retain the calling contract and never custody funds elsewhere.
/// @dev Each source owns its bounty budget; installing a new source grants no budget from existing pools.
interface IRevenueRecorder {
    function recordRevenue(address token, uint256 amount) external;
}

struct RevenueSendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

struct RevenueMessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct RevenueMessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    RevenueMessagingFee fee;
}

struct RevenueOFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

struct RevenueOFTLimit {
    uint256 minAmountLD;
    uint256 maxAmountLD;
}

struct RevenueOFTFeeDetail {
    int256 feeAmountLD;
    string description;
}

struct RevenueTicket {
    uint72 ticketId;
    bytes passengerBytes;
}

interface IRevenueStargate {
    function quoteSend(RevenueSendParam calldata, bool) external view returns (RevenueMessagingFee memory);
    function quoteOFT(RevenueSendParam calldata)
        external
        view
        returns (RevenueOFTLimit memory, RevenueOFTFeeDetail[] memory, RevenueOFTReceipt memory);
    function sendToken(RevenueSendParam calldata, RevenueMessagingFee calldata, address)
        external
        payable
        returns (RevenueMessagingReceipt memory, RevenueOFTReceipt memory, RevenueTicket memory);
}

interface IFeeSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

interface IRevenueConversionPolicy {
    function configurationSealed() external view returns (bool);
    function company() external view returns (address);
    function usdc() external view returns (address);
    function assetSealed(address) external view returns (bool);
    function distributionsPaused() external view returns (bool);
    function conversionMaxInput(address) external view returns (uint256);
    function conversionCooldown(address) external view returns (uint64);
    function conversionMinUsdc(address) external view returns (uint256);
    function swapFeeds(address) external view returns (address);
    function swapFeedMaxAges(address) external view returns (uint32);
    function swapFeedSlippageBps(address) external view returns (uint16);
    function swapPoolFees(address) external view returns (uint24);
    function conversionRouters(address) external view returns (address);
    function swapRouter() external view returns (address);
}

interface IRevenueBorrowPool {
    function borrow(address, uint256, uint256, uint16, address) external;
    function supply(address, uint256, address, uint16) external;
}

interface IDirectSettlementPool {
    function repay(address, uint256, uint256, address) external returns (uint256);
    function withdraw(address, uint256, address) external returns (uint256);
}

library AutonomousRevenueLib {
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event SwappedToUSDC(address indexed tokenIn, uint24 fee, uint256 amountIn, uint256 usdcOut);
    uint256 private constant BPS = 10000;
    uint160 private constant MIN_SQRT_PRICE_LIMIT_X96 = 4295128740;
    uint160 private constant MAX_SQRT_PRICE_LIMIT_X96 = 1461446703485210103287273052203988822378723970341;
    error InvalidNegativeHedgeSwap();
    error HedgeCheck(uint8 code);
    event HedgeInventoryNormalized(uint256 amount0, uint256 amount1, bool complete);
    event RepayDebt(uint256 wethRepaid);
    uint256 private constant MIN_SQRT_RATIO = 4295128739;
    uint256 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    function sendCommission(address treasury, address token, uint256 amount) external {
        if (amount == 0) return;
        IERC20(token).safeApprove(treasury, 0);
        IERC20(token).safeApprove(treasury, amount);
        IRevenueRecorder(treasury).recordRevenue(token, amount);
        IERC20(token).safeApprove(treasury, 0);
    }

    using SafeERC20 for IERC20;
    uint256 internal constant RESERVE_BPS = 500;

    struct ConversionWindow {
        uint64 started;
        uint256 spent;
    }

    struct State {
        mapping(address => mapping(address => ConversionWindow)) conversions;
        mapping(address => address) sourceOf;
        mapping(address => bool) sourceInstalled;
        mapping(address => bool) sourceSealed;
        mapping(address => uint8) roles;
        mapping(address => uint64) depositDay;
        mapping(address => uint256) depositSpent;
        mapping(address => uint64) depositAt;
        mapping(address => mapping(address => uint64)) depositKeeperAt;
        mapping(address => mapping(address => uint256)) pending;
        mapping(address => uint256) accounted;
        mapping(address => uint256) reserve;
        mapping(address => uint256) revenue;
        mapping(address => uint256) remainder;
        mapping(address => uint256) bridgeRemainder;
        uint256 totalReserve;
    }
    event SourceInstalled(address indexed source, address indexed actor);
    event RevenueRecorded(address indexed source, address indexed token, uint256 amount);
    event BountyReserveCredited(address indexed source, uint256 revenue, uint256 reserved);
    event BountyReserveSpent(address indexed source, uint256 amount);
    event BountyFunded(address indexed source, uint256 amount);

    function install(State storage s, address source, address[] calldata actors) external {
        require(
            source != address(0) && source != address(this) && !s.sourceInstalled[source] && actors.length > 0,
            AutonomousCheck(0x16001604)
        );
        s.sourceInstalled[source] = true;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            require(actor.code.length > 0 && s.sourceOf[actor] == address(0), AutonomousCheck(0x280035fb));
            s.sourceOf[actor] = source;
            emit SourceInstalled(source, actor);
        }
    }

    function authorize(State storage s, address actor, bool allowed, uint8 role) external {
        require(!s.sourceSealed[s.sourceOf[actor]], AutonomousCheck(0x9a247fa1));
        require(allowed && s.sourceOf[actor] != address(0), AutonomousCheck(0x7ea92fcb));
        require(actor.code.length > 0, AutonomousCheck(0x2c7a47d0));
        s.roles[actor] |= role;
    }
    event SourceSealed(address indexed source);

    function sealSource(State storage s, address source) external {
        require(s.sourceInstalled[source] && !s.sourceSealed[source], AutonomousCheck(0x16001604));
        s.sourceSealed[source] = true;
        emit SourceSealed(source);
    }

    function record(State storage s, address usdc, address token, uint256 amount) external {
        address source = s.sourceOf[msg.sender];
        require(source != address(0) && amount > 0, AutonomousCheck(0xdd62405b));
        _sync(s, usdc, token);
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        require(IERC20(token).balanceOf(address(this)) - beforeBalance == amount, AutonomousCheck(0xcfa42862));
        s.accounted[token] += amount;
        if (token == usdc) _credit(s, source, amount);
        else s.pending[source][token] += amount;
        emit RevenueRecorded(source, token, amount);
    }

    /// @dev Direct donations and Stargate receipts are attributed to the Treasury's own bridge budget.
    function sync(State storage s, address usdc, address token) external returns (uint256 amount) {
        return _sync(s, usdc, token);
    }

    function _sync(State storage s, address usdc, address token) private returns (uint256 amount) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= s.accounted[token], AutonomousCheck(0x05435e06));
        amount = balance - s.accounted[token];
        s.accounted[token] = balance;
        if (amount != 0) {
            if (token == usdc) _credit(s, address(this), amount);
            else s.pending[address(this)][token] += amount;
            emit RevenueRecorded(address(this), token, amount);
        }
    }

    function conversionRemaining(State storage s, address source, address token, uint256 cap, uint64 cooldown)
        public
        view
        returns (uint256 remaining, uint64 nextAt)
    {
        ConversionWindow storage w = s.conversions[source][token];
        nextAt = w.started + cooldown;
        remaining = block.timestamp >= nextAt ? cap : cap > w.spent ? cap - w.spent : 0;
    }

    function consumeConversion(
        State storage s,
        address source,
        address token,
        uint256 amount,
        uint256 cap,
        uint64 cooldown
    ) external {
        ConversionWindow storage w = s.conversions[source][token];
        if (block.timestamp >= w.started + cooldown) {
            w.started = uint64(block.timestamp);
            w.spent = 0;
        }
        require(amount > 0 && amount <= cap - w.spent, AutonomousCheck(0xc62ba7de));
        w.spent += amount;
    }

    function converted(
        State storage s,
        address usdc,
        address source,
        address token,
        uint256 amountIn,
        uint256 amountOut
    ) external {
        require(amountIn <= s.pending[source][token], AutonomousCheck(0x3f381c16));
        s.pending[source][token] -= amountIn;
        s.accounted[token] -= amountIn;
        s.accounted[usdc] += amountOut;
        _credit(s, source, amountOut);
    }

    function fund(State storage s, address usdc, address source, uint256 amount) external {
        require((source == address(this) || s.sourceInstalled[source]) && amount > 0, AutonomousCheck(0xcb003268));
        _sync(s, usdc, usdc);
        uint256 beforeBalance = IERC20(usdc).balanceOf(address(this));
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
        require(IERC20(usdc).balanceOf(address(this)) - beforeBalance == amount, AutonomousCheck(0xbd973d7e));
        s.accounted[usdc] += amount;
        s.reserve[source] += amount;
        s.totalReserve += amount;
        emit BountyFunded(source, amount);
    }

    function withdraw(State storage s, address usdc, address to, uint256 amount) external {
        require(to != address(0) && amount > 0, AutonomousCheck(0x92d7cfce));
        _sync(s, usdc, usdc);
        require(
            s.accounted[usdc] >= s.totalReserve && amount <= s.accounted[usdc] - s.totalReserve,
            AutonomousCheck(0xbac20538)
        );
        s.accounted[usdc] -= amount;
        IERC20(usdc).safeTransfer(to, amount);
    }

    function spend(State storage s, address actor, uint256 amount) external {
        _spend(s, actor, amount);
    }

    function _spend(State storage s, address actor, uint256 amount) private {
        address source = actor == address(this) ? address(this) : s.sourceOf[actor];
        require(source != address(0) && amount > 0 && s.reserve[source] >= amount, AutonomousCheck(0x933c73ff));
        s.reserve[source] -= amount;
        s.totalReserve -= amount;
        emit BountyReserveSpent(source, amount);
    }

    struct DepositPolicy {
        bool enabled;
        uint256 amount;
        uint256 cap;
        uint64 cooldown;
        uint64 keeperCooldown;
        uint8 decimals;
    }
    event DepositBountyPaid(address indexed keeper, uint256 amount);

    function payDeposit(
        State storage s,
        address usdc,
        address keeper,
        address depositor,
        uint256 valueUsd,
        DepositPolicy calldata policy
    ) external {
        require(keeper != address(0) && depositor != address(0) && keeper != depositor, AutonomousCheck(0x77390cd7));
        require((s.roles[msg.sender] & 8) != 0, AutonomousCheck(0x52c79c7b));
        require(policy.enabled, AutonomousCheck(0xb897c761));
        require(policy.amount > 0, AutonomousCheck(0x2567641d));
        require(valueUsd >= (policy.amount * 1e8 / (10 ** policy.decimals)) * 100, AutonomousCheck(0x40b07ae4));
        require(IERC20(usdc).balanceOf(address(this)) >= policy.amount, AutonomousCheck(0x18ecfaa5));
        if (policy.cooldown > 0) {
            require(block.timestamp >= uint256(s.depositAt[msg.sender]) + policy.cooldown, AutonomousCheck(0x7e8fca4d));
        }
        if (policy.keeperCooldown > 0) {
            require(
                block.timestamp >= uint256(s.depositKeeperAt[msg.sender][keeper]) + policy.keeperCooldown,
                AutonomousCheck(0x127f6dec)
            );
        }
        uint64 day = uint64(block.timestamp / 1 days);
        if (s.depositDay[msg.sender] != day) {
            s.depositDay[msg.sender] = day;
            s.depositSpent[msg.sender] = 0;
        }
        uint256 spent = s.depositSpent[msg.sender] + policy.amount;
        if (policy.cap > 0) require(spent <= policy.cap, AutonomousCheck(0xbf7d034b));
        s.depositAt[msg.sender] = uint64(block.timestamp);
        s.depositKeeperAt[msg.sender][keeper] = uint64(block.timestamp);
        s.depositSpent[msg.sender] = spent;
        _sync(s, usdc, usdc);
        _spend(s, msg.sender, policy.amount);
        require(policy.amount <= s.accounted[usdc], AutonomousCheck(0x34be11f1));
        s.accounted[usdc] -= policy.amount;
        IERC20(usdc).safeTransfer(keeper, policy.amount);
        emit DepositBountyPaid(keeper, policy.amount);
    }

    function debit(State storage s, address usdc, uint256 amount) external {
        require(amount <= s.accounted[usdc], AutonomousCheck(0x34be11f1));
        s.accounted[usdc] -= amount;
    }

    function protectedBalance(State storage s, address usdc) public view returns (uint256) {
        uint256 balance = IERC20(usdc).balanceOf(address(this));
        require(balance >= s.accounted[usdc], AutonomousCheck(0x05435e06));
        return s.totalReserve + ((balance - s.accounted[usdc]) * RESERVE_BPS + s.remainder[address(this)]) / 10000;
    }

    function _credit(State storage s, address source, uint256 amount) private {
        // Carry survives every inflow and every bounty payment; splitting receipts cannot evade the 5% allocation.
        uint256 numerator = amount * RESERVE_BPS + s.remainder[source];
        uint256 reserved = numerator / 10000;
        s.remainder[source] = numerator % 10000;
        if (source == address(this)) {
            s.reserve[source] += reserved;
        } else {
            // One fifth of the protected budget pays canonical Treasury bridge work; four fifths remain source-isolated.
            uint256 split = reserved + s.bridgeRemainder[source];
            uint256 bridgePart = split / 5;
            s.bridgeRemainder[source] = split % 5;
            s.reserve[address(this)] += bridgePart;
            s.reserve[source] += reserved - bridgePart;
        }
        s.totalReserve += reserved;
        s.revenue[source] += amount;
        emit BountyReserveCredited(source, amount, reserved);
    }

    using SafeERC20 for IERC20;
    error BridgeTransferMismatch();

    function quote(address stargate, uint32 eid, address destination, uint256 amount)
        external
        view
        returns (uint256 nativeFee, uint256 received)
    {
        RevenueSendParam memory param = _param(eid, destination, amount);
        (,, RevenueOFTReceipt memory receipt) = IRevenueStargate(stargate).quoteOFT(param);
        param.minAmountLD = receipt.amountReceivedLD;
        nativeFee = IRevenueStargate(stargate).quoteSend(param, false).nativeFee;
        received = receipt.amountReceivedLD;
    }

    function send(address stargate, address token, uint32 eid, address destination, uint256 amount, uint16 minBps)
        external
        returns (uint256 received, bytes32 guid, uint256 nativeFee)
    {
        require(destination != address(0) && eid != 0 && amount > 0 && minBps >= 9000, AutonomousCheck(0x3542e7f4));
        RevenueSendParam memory param = _param(eid, destination, amount);
        (,, RevenueOFTReceipt memory quoted) = IRevenueStargate(stargate).quoteOFT(param);
        require(quoted.amountReceivedLD * 10000 >= amount * minBps, AutonomousCheck(0x88795128));
        param.minAmountLD = quoted.amountReceivedLD;
        RevenueMessagingFee memory fee = IRevenueStargate(stargate).quoteSend(param, false);
        require(msg.value >= fee.nativeFee && fee.lzTokenFee == 0, AutonomousCheck(0x2f450712));
        IERC20 usdc = IERC20(token);
        uint256 beforeBalance = usdc.balanceOf(address(this));
        usdc.safeApprove(stargate, 0);
        usdc.safeApprove(stargate, amount);
        (RevenueMessagingReceipt memory receipt, RevenueOFTReceipt memory oft,) =
            IRevenueStargate(stargate).sendToken{value: fee.nativeFee}(param, fee, msg.sender);
        usdc.safeApprove(stargate, 0);
        uint256 afterBalance = usdc.balanceOf(address(this));
        if (
            afterBalance > beforeBalance || beforeBalance - afterBalance != amount || oft.amountSentLD != amount
                || oft.amountReceivedLD < param.minAmountLD
        ) revert BridgeTransferMismatch();
        return (oft.amountReceivedLD, receipt.guid, fee.nativeFee);
    }

    function _param(uint32 eid, address destination, uint256 amount) private pure returns (RevenueSendParam memory) {
        return RevenueSendParam(eid, bytes32(uint256(uint160(destination))), amount, 0, new bytes(0), new bytes(0), "");
    }

    function bounds(
        address tokenIn,
        address usdc,
        uint256 amountIn,
        address tokenFeed,
        address stableFeed,
        uint32 maxAge,
        uint32 usdcMaxAge,
        uint16 slippageBps
    ) public view returns (uint256 minUsdcOut, uint160 sqrtPriceLimitX96) {
        AggregatorV3Interface feed = AggregatorV3Interface(tokenFeed);
        AggregatorV3Interface usdcFeed = AggregatorV3Interface(stableFeed);
        require(address(feed) != address(0) && address(usdcFeed) != address(0), AutonomousCheck(0xdabc64c6));
        require(maxAge != 0 && usdcMaxAge != 0, AutonomousCheck(0x68bcf3b3));
        require(slippageBps != 0, AutonomousCheck(0xb76e3dd6));
        (uint80 roundId, int256 px,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        (uint80 usdcRoundId, int256 usdcPx,, uint256 usdcUpdatedAt, uint80 usdcAnsweredInRound) =
            usdcFeed.latestRoundData();
        require(
            px > 0 && updatedAt != 0 && answeredInRound >= roundId && block.timestamp - updatedAt <= maxAge,
            AutonomousCheck(0x38ec95fb)
        );
        require(
            usdcPx > 0 && usdcUpdatedAt != 0 && usdcAnsweredInRound >= usdcRoundId
                && block.timestamp - usdcUpdatedAt <= usdcMaxAge,
            AutonomousCheck(0x58421f15)
        );
        uint8 tokenDec = IERC20Metadata(tokenIn).decimals();
        uint8 feedDec = feed.decimals();
        uint8 usdcDec = IERC20Metadata(address(usdc)).decimals();
        uint8 usdcFeedDec = usdcFeed.decimals();
        require(tokenDec <= 18 && feedDec <= 18 && usdcDec <= 18 && usdcFeedDec <= 18, AutonomousCheck(0xea6042f8));
        uint256 normalizedUsdcPx = uint256(usdcPx);
        if (usdcFeedDec < feedDec) normalizedUsdcPx *= 10 ** (feedDec - usdcFeedDec);
        else if (usdcFeedDec > feedDec) normalizedUsdcPx /= 10 ** (usdcFeedDec - feedDec);
        require(normalizedUsdcPx > 0, AutonomousCheck(0xd0847386));
        uint256 usdValue = Math.mulDiv(amountIn, uint256(px), 10 ** tokenDec);
        uint256 theo = Math.mulDiv(usdValue, 10 ** usdcDec, normalizedUsdcPx);
        minUsdcOut = (theo * (10000 - slippageBps)) / 10000;

        bool zeroForOne = tokenIn < address(usdc);
        uint256 numerator = zeroForOne ? uint256(px) * (10 ** usdcDec) : normalizedUsdcPx * (10 ** tokenDec);
        uint256 denominator = zeroForOne ? normalizedUsdcPx * (10 ** tokenDec) : uint256(px) * (10 ** usdcDec);
        uint256 oracleSqrtPriceX96 = Math.sqrt(Math.mulDiv(numerator, uint256(1) << 192, denominator));
        require(oracleSqrtPriceX96 > MIN_SQRT_RATIO && oracleSqrtPriceX96 < MAX_SQRT_RATIO, AutonomousCheck(0xc7ac5ffd));
        uint256 factor = zeroForOne ? 20000 - slippageBps : 20000 + slippageBps;
        uint256 limit = (oracleSqrtPriceX96 * factor) / 20000;
        if (limit <= MIN_SQRT_RATIO) limit = MIN_SQRT_RATIO + 1;
        if (limit >= MAX_SQRT_RATIO) limit = MAX_SQRT_RATIO - 1;
        sqrtPriceLimitX96 = uint160(limit);
    }

    function swap(
        address tokenIn,
        address usdc,
        address router,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut,
        uint160 priceLimit
    ) public returns (uint256 out) {
        IERC20 token = IERC20(tokenIn);
        uint256 beforeIn = token.balanceOf(address(this));
        uint256 beforeOut = IERC20(usdc).balanceOf(address(this));
        require(amountIn > 0 && minOut > 0 && fee > 0 && beforeIn >= amountIn, AutonomousCheck(0xf58e91a9));
        token.safeApprove(router, 0);
        token.safeApprove(router, amountIn);
        IFeeSwapRouter(router)
            .exactInputSingle(
                IFeeSwapRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: usdc,
                    fee: fee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: priceLimit
                })
            );
        require(beforeIn - token.balanceOf(address(this)) == amountIn, AutonomousCheck(0x4d8d39b2));
        out = IERC20(usdc).balanceOf(address(this)) - beforeOut;
        require(out >= minOut, AutonomousCheck(0x5814aad6));
        token.safeApprove(router, 0);
    }

    function previewConversion(State storage s, address source, address token)
        external
        view
        returns (uint256 amountIn, uint256 minOut, uint64 nextAt)
    {
        IRevenueConversionPolicy policy = IRevenueConversionPolicy(address(this));
        uint256 remaining;
        (remaining, nextAt) =
            conversionRemaining(s, source, token, policy.conversionMaxInput(token), policy.conversionCooldown(token));
        if (!policy.assetSealed(token) || remaining == 0 || policy.distributionsPaused()) return (0, 0, nextAt);
        amountIn = s.pending[source][token];
        if (source == address(this)) {
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > s.accounted[token]) amountIn += balance - s.accounted[token];
        }
        if (amountIn > remaining) amountIn = remaining;
        if (amountIn == 0) return (0, 0, nextAt);
        (minOut,) = conversionBounds(policy, token, amountIn);
        if (minOut < policy.conversionMinUsdc(token)) return (0, 0, nextAt);
    }

    function executeFeeSwap(address tokenIn, uint24 fee, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        IRevenueConversionPolicy policy = IRevenueConversionPolicy(address(this));
        address usdc = policy.usdc();
        require(tokenIn != address(usdc), AutonomousCheck(0x02ff93bd));
        require(fee == policy.swapPoolFees(tokenIn) && fee != 0, AutonomousCheck(0xd8bea72e));
        (uint256 floor, uint160 limit) = conversionBounds(policy, tokenIn, amountIn);
        amountOut = swap(
            tokenIn,
            address(usdc),
            policy.conversionRouters(tokenIn) == address(0) ? policy.swapRouter() : policy.conversionRouters(tokenIn),
            fee,
            amountIn,
            minAmountOut > floor ? minAmountOut : floor,
            limit
        );
        emit SwappedToUSDC(tokenIn, fee, amountIn, amountOut);
    }

    function conversionBounds(IRevenueConversionPolicy policy, address token, uint256 amount)
        private
        view
        returns (uint256, uint160)
    {
        address usdc = policy.usdc();
        return bounds(
            token,
            usdc,
            amount,
            policy.swapFeeds(token),
            policy.swapFeeds(usdc),
            policy.swapFeedMaxAges(token),
            policy.swapFeedMaxAges(usdc),
            policy.swapFeedSlippageBps(token)
        );
    }

    function increaseEffectiveShort(
        address poolAddress,
        address token0,
        address token1,
        address router,
        uint24 swapPoolFee,
        uint256 amount0,
        uint256 minOut,
        uint160 sqrtLimit
    ) external {
        IRevenueBorrowPool pool = IRevenueBorrowPool(poolAddress);
        IERC20 weth = IERC20(token0);
        IERC20 usdc = IERC20(token1);
        IFeeSwapRouter swapRouter = IFeeSwapRouter(router);
        uint256 idle = usdc.balanceOf(address(this));
        if (idle > 0) pool.supply(address(usdc), idle, address(this), 0);
        uint256 token0Before = weth.balanceOf(address(this));
        pool.borrow(address(weth), amount0, 2, 0, address(this));
        uint256 amount1 = swapRouter.exactInputSingle(
            IFeeSwapRouter.ExactInputSingleParams({
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
        if (amount1 > 0) pool.supply(address(usdc), amount1, address(this), 0);
    }

    function wrapNative(address token) external {
        uint256 amount = address(this).balance;
        uint256 beforeToken = IERC20(token).balanceOf(address(this));
        (bool ok,) = token.call{value: amount}(abi.encodeWithSignature("deposit()"));
        require(
            ok && address(this).balance == 0 && IERC20(token).balanceOf(address(this)) - beforeToken == amount,
            AutonomousCheck(0x45f80872)
        );
    }

    function emergencyWithdrawCore(
        address token0,
        address token1,
        uint256 amount0Requested,
        uint256 amount1Requested,
        address recipient,
        address contractAddress
    ) external returns (uint256 amount0Sent, uint256 amount1Sent) {
        uint256 balance0 = IERC20(token0).balanceOf(contractAddress);
        uint256 balance1 = IERC20(token1).balanceOf(contractAddress);
        amount0Sent = amount0Requested > balance0 ? balance0 : amount0Requested;
        amount1Sent = amount1Requested > balance1 ? balance1 : amount1Requested;
        if (amount0Sent > 0) IERC20(token0).safeTransfer(recipient, amount0Sent);
        if (amount1Sent > 0) IERC20(token1).safeTransfer(recipient, amount1Sent);
    }

    function sendIdleShare(
        address token0,
        address token1,
        uint256 idle0,
        uint256 idle1,
        uint256 proportion,
        uint256 scale,
        address recipient
    ) external {
        uint256 share = idle0 * proportion / scale;
        if (share > 0) IERC20(token0).safeTransfer(recipient, share);
        share = idle1 * proportion / scale;
        if (share > 0) IERC20(token1).safeTransfer(recipient, share);
    }

    function settleDirectly(
        address pool,
        address token0,
        address token1,
        address collateralToken,
        uint256 debtToRepay,
        uint256 proportion,
        bool full,
        address recipient
    ) external {
        IDirectSettlementPool aave = IDirectSettlementPool(pool);
        if (full) aave.repay(token0, type(uint256).max, 2, address(this));
        else if (debtToRepay > 0) aave.repay(token0, debtToRepay, 2, address(this));
        if (full) {
            aave.withdraw(token1, type(uint256).max, recipient);
        } else {
            uint256 share = IERC20(collateralToken).balanceOf(address(this)) * proportion / 1e18;
            if (share > 0) {
                uint256 beforeBalance = IERC20(token1).balanceOf(address(this));
                aave.withdraw(token1, share, address(this));
                uint256 withdrawn = IERC20(token1).balanceOf(address(this)) - beforeBalance;
                if (withdrawn > 0) IERC20(token1).safeTransfer(recipient, withdrawn);
            }
        }
    }

    function consumeDailyLimit(
        mapping(address => uint64) storage daysByActor,
        mapping(address => uint256) storage spent,
        address actor,
        uint256 amount,
        uint256 cap,
        bool zeroUnlimited,
        bytes4 failure
    ) external {
        uint64 day = uint64(block.timestamp / 1 days);
        if (daysByActor[actor] != day) {
            daysByActor[actor] = day;
            spent[actor] = 0;
        }
        uint256 next = spent[actor] + amount;
        if (!zeroUnlimited || cap > 0) require(next <= cap, AutonomousCheck(failure));
        spent[actor] = next;
    }

    function refundNativeSurplus(uint256 usedNativeFee) external {
        if (msg.value <= usedNativeFee) return;
        (bool ok,) = msg.sender.call{value: msg.value - usedNativeFee}("");
        require(ok, AutonomousCheck(0xcef6850b));
    }

    function validateSwapFeed(
        bool isSealed,
        address existingFeed,
        address token,
        address feed,
        uint16 _swapSlippageBps,
        uint32 _maxAge,
        uint8 usdcDecimals
    ) external view {
        require(!isSealed || existingFeed == feed, AutonomousCheck(0x61ac430d));
        require(token != address(0), AutonomousCheck(0x086efea7));
        require(feed != address(0), AutonomousCheck(0x422790c9));
        require(_swapSlippageBps >= 10 && _swapSlippageBps <= 1000, AutonomousCheck(0x3b5e082d));
        require(_maxAge >= 3600 && _maxAge <= 172800, AutonomousCheck(0xd357f7c0));
        require(
            IERC20Metadata(token).decimals() <= 18 && usdcDecimals <= 18
                && AggregatorV3Interface(feed).decimals() <= 18,
            AutonomousCheck(0x8a0ba966)
        );
    }

    function validatePublicConversion(
        bool isSealed,
        address token,
        address stable,
        uint8 decimals,
        uint256 maxInput,
        uint256 minUsdc,
        uint64 cooldown
    ) external view {
        require(!isSealed, AutonomousCheck(0xd3f8500a));
        require(token != stable && token.code.length > 0, AutonomousCheck(0x799c831e));
        if (maxInput != 0) {
            require(minUsdc >= 10 ** uint256(decimals), AutonomousCheck(0xd34f8e6b));
            require(cooldown >= 1 hours && cooldown <= 30 days, AutonomousCheck(0x2af0853b));
        }
    }

    function validatePoolFee(bool isSealed, address token, address stable, uint24 fee) external pure {
        require(!isSealed, AutonomousCheck(0xd3f8500a));
        require(token != address(0) && token != stable, AutonomousCheck(0x086efea7));
        require(fee == 100 || fee == 500 || fee == 3000 || fee == 10000, AutonomousCheck(0x6d94368d));
    }

    function distributable(State storage s, address stable) external view returns (uint256) {
        uint256 balance = IERC20(stable).balanceOf(address(this));
        uint256 reserve = protectedBalance(s, stable);
        return balance > reserve ? balance - reserve : 0;
    }

    function rescueToken(State storage s, address tokenAddr, address to, uint256 amount) external {
        IRevenueConversionPolicy policy = IRevenueConversionPolicy(address(this));
        require(!policy.configurationSealed() || policy.distributionsPaused(), AutonomousCheck(0x1d45e305));
        require(
            !policy.assetSealed(tokenAddr) && policy.swapFeeds(tokenAddr) == address(0) && s.accounted[tokenAddr] == 0,
            AutonomousCheck(0x3ad6b46e)
        );
        require(to == policy.company() && to != address(0), AutonomousCheck(0x160fe00b));
        require(tokenAddr != policy.usdc(), AutonomousCheck(0xb6c29bb8));
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit TokenRescued(tokenAddr, to, amount);
    }
}
