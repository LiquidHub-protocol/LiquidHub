// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./RangeOperations.sol";
import "./interfaces/ILiquidityRoutes.sol";

import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "./AutonomousErrors.sol";
import {TreasuryPolicyLib, ISourceInstallation} from "./TreasuryPolicyLib.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Fixed revenue and settlement rules. Linked delegatecalls retain the calling contract and never custody funds elsewhere.
/// @dev Each source owns its bounty budget; installing a new source grants no budget from existing pools.
interface IRevenueRecorder {
    function recordRevenue(address token, uint256 amount) external;
}

interface IFeeSwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256);

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
    function conversionPath(address) external view returns (bytes memory);
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



interface IHedgeRouteContext { function rangeManager() external view returns(address); }

library AutonomousRevenueLib {
    /// @dev Optional metadata must never disable debt settlement or emergency HF repair. A typed
    /// call's ABI-decoding failure can escape try/catch; inspect bounded raw responses instead.
    function liquidityHedgeFees() public view returns(uint24 preferred,uint24 alternate) {
        (bool ok,bytes memory context)=address(this).staticcall{gas:10000}(abi.encodeWithSignature("rangeManager()"));
        if(!ok||context.length!=32)return (0,0);
        address rm;assembly("memory-safe"){rm:=mload(add(context,32))}
        (ok,context)=rm.staticcall{gas:50000}(abi.encodeWithSelector(ILiquidityRange.liquidityRoutes.selector));
        if(!ok||context.length<224)return (0,0);
        uint256 lp;uint256 hedge;
        assembly("memory-safe"){lp:=mload(add(context,160))}
        if(context.length>=320)assembly("memory-safe"){hedge:=mload(add(context,320))}
        if(lp==100||lp==500||lp==3000||lp==10000)alternate=uint24(lp);
        if(hedge==100||hedge==500||hedge==3000||hedge==10000)preferred=uint24(hedge);
        else preferred=alternate;
    }
    function hedgeAlternativeFee() public view returns(uint24 preferred) { (preferred,)=liquidityHedgeFees(); }
    /// @dev implementation is address(RangeOperations) from fixed linked caller code.
    /// Failed/partial optional fills roll back; the final canonical venue keeps its price limit and full gas.
    function hedgeInventoryInput(address implementation,address router,address input,address output,uint24 fee,uint256 amount,uint256 minimum,uint160 limit)
        external returns(uint256)
    {
        (uint24 preferred,uint24 alternate)=liquidityHedgeFees();uint24[3] memory venues=[preferred,alternate,fee];
        for(uint256 i;i<3;++i){uint24 candidate=venues[i];
            if(i<2&&(candidate==0||candidate==fee||(i==1&&candidate==preferred)))continue;
            (bool ok,bytes memory ret)=implementation.delegatecall{gas:i==2?gasleft():gasleft()/2}(abi.encodeWithSelector(
                bytes4(keccak256("hedgeInventorySwap(address,address,address,uint24,uint256,uint256,uint160)")),router,input,output,candidate,amount,minimum,i==2?limit:0));
            if(ok)return abi.decode(ret,(uint256));
            if(i==2)assembly("memory-safe"){revert(add(ret,32),mload(ret))}
        }
        revert HedgeCheck(46);
    }
    function aaveExactOutput(
        address router,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 received) {
        uint256 beforeBalance = IERC20(tokenOut).balanceOf(address(this));
        // Alternate fixed V3 tier from the installed RangeManager. A failed read must never disable HF repair.
        (uint24 preferred,uint24 alternate)=liquidityHedgeFees();
        uint24[2] memory candidates=[preferred,alternate];
        for(uint256 i;i<2;++i) {
            uint24 candidate=candidates[i];
            if(candidate==0||candidate==fee||(i==1&&candidate==preferred))continue;
            // No fixed gas ceiling on an HF venue: reserve half for the next/canonical route.
            // The transaction estimator may provide more gas; no gas-price cap is introduced.
            uint256 routeGas=gasleft()/2;
            try ISwapRouter(router).exactOutputSingle{gas:routeGas}(ISwapRouter.ExactOutputSingleParams({
                tokenIn:tokenIn,tokenOut:tokenOut,fee:candidate,recipient:address(this),deadline:block.timestamp,
                amountOut:amountOut,amountInMaximum:amountInMaximum,sqrtPriceLimitX96:0
            })) returns (uint256) {
                return IERC20(tokenOut).balanceOf(address(this))-beforeBalance;
            } catch {}
        }
        ISwapRouter(router)
            .exactOutputSingle(
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountOut: amountOut,
                    amountInMaximum: amountInMaximum,
                    sqrtPriceLimitX96: sqrtPriceLimitX96
                })
            );
        received = IERC20(tokenOut).balanceOf(address(this)) - beforeBalance;
    }




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

    struct LegacyBounties {
        bool keeperBountyEnabled;
        uint256 keeperBountyAmount;
        uint256 keeperBountyDailyCap;
        bool strategyCheckpointBountyEnabled;
        uint256 strategyCheckpointBountyAmount;
        uint256 strategyCheckpointBountyDailyCap;
        bool hedgeBountyEnabled;
        uint256 hedgeBountyAmount;
        uint256 hedgeBountyDailyCap;
        bool depositBountyEnabled;
        uint256 depositBountyAmount;
        uint64 depositBountyCooldown;
        uint64 depositBountyKeeperCooldown;
        uint256 depositBountyDailyCap;
        bool conversionBountyEnabled;
        uint256 conversionBountyAmount;
        uint64 conversionBountyCooldown;
        uint64 lastConversionBountyAt;
        uint16 conversionBountyMinRatio;
    }

    struct State {
        LegacyBounties legacy;
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
        mapping(address => uint256) conversionRemainder;
        uint256 totalReserve;
        TreasuryPolicyLib.Policy policy;
    }
    event SourceInstalled(address indexed source, address indexed actor);
    event RevenueRecorded(address indexed source, address indexed token, uint256 amount);
    event BountyReserveCredited(address indexed source, uint256 revenue, uint256 reserved);
    event BountyReserveSpent(address indexed source, uint256 amount);
    event BountyFunded(address indexed source, uint256 amount);

    function install(State storage s, address source, address[] calldata actors) external {
        TreasuryPolicyLib.install(s, source, actors);
    }

    function authorize(State storage s, address actor, bool allowed, uint8 role) external {
        TreasuryPolicyLib.authorize(s, actor, allowed, role);
    }
    event SourceSealed(address indexed source);

    function sealSource(State storage s, address source) external {
        TreasuryPolicyLib.sealSource(s, source);
    }

    function record(State storage s, address usdc, address token, uint256 amount) external {
        TreasuryPolicyLib.record(s, usdc, token, amount);
    }

    /// @dev Direct commission receipts fund the local Treasury conversion budget.
    function sync(State storage s, address usdc, address token) external returns (uint256 amount) {
        return TreasuryPolicyLib.sync(s, usdc, token);
    }

    function _sync(State storage s, address usdc, address token) private returns (uint256 amount) {
        return TreasuryPolicyLib.sync(s, usdc, token);
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
        TreasuryPolicyLib.converted(s, usdc, source, token, amountIn, amountOut);
    }

    function fund(State storage s, address usdc, address source, uint256 amount) external {
        TreasuryPolicyLib.fund(s, usdc, source, amount);
    }

    function withdraw(State storage s, address usdc, address to, uint256 amount) external {
        TreasuryPolicyLib.withdraw(s, usdc, to, amount);
    }

    function spend(State storage s, address actor, uint256 amount) external {
        TreasuryPolicyLib.spend(s, actor, amount);
    }

    function _spend(State storage s, address actor, uint256 amount) private {
        TreasuryPolicyLib.spend(s, actor, amount);
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

    function payConfiguredDeposit(State storage s, address usdc, address keeper, address depositor, uint256 valueUsd)
        external
    {
        DepositPolicy memory policy = DepositPolicy(
            s.legacy.depositBountyEnabled,
            s.legacy.depositBountyAmount,
            s.legacy.depositBountyDailyCap,
            s.legacy.depositBountyCooldown,
            s.legacy.depositBountyKeeperCooldown,
            IERC20Metadata(usdc).decimals()
        );
        require(keeper != address(0) && depositor != address(0) && keeper != depositor, AutonomousCheck(0x77390cd7));
        require((s.roles[msg.sender] & 8) != 0, AutonomousCheck(0x52c79c7b));
        if (s.policy.governance != address(0)) {
            require(
                s.sourceSealed[s.sourceOf[msg.sender]]
                    && ISourceInstallation(s.sourceOf[msg.sender]).installationSealed(),
                AutonomousCheck(0x52c79c7b)
            );
            policy.enabled = true;
            (policy.amount, policy.cap) = TreasuryPolicyLib.sourceBounty(s, s.sourceOf[msg.sender], 2);
            if (policy.cooldown == 0 || policy.keeperCooldown == 0) revert AutonomousCheck(0xc5640d54);
        }
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
        TreasuryPolicyLib.debit(s, usdc, amount);
    }

    function protectedBalance(State storage s, address usdc) public view returns (uint256) {
        return TreasuryPolicyLib.protectedBalance(s, usdc);
    }

    function _credit(State storage s, address source, uint256 amount) private {
        TreasuryPolicyLib.creditRevenue(s, source, amount);
    }

    using SafeERC20 for IERC20;








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
        uint256 minimum = minAmountOut > floor ? minAmountOut : floor;
        address router =
            policy.conversionRouters(tokenIn) == address(0) ? policy.swapRouter() : policy.conversionRouters(tokenIn);
        bytes memory path = policy.conversionPath(tokenIn);
        if (path.length == 66) {
            IERC20 token = IERC20(tokenIn);
            uint256 beforeIn = token.balanceOf(address(this));
            uint256 beforeOut = IERC20(usdc).balanceOf(address(this));
            require(amountIn > 0 && minimum > 0 && beforeIn >= amountIn, AutonomousCheck(0xf58e91a9));
            token.safeApprove(router, 0);
            token.safeApprove(router, amountIn);
            IFeeSwapRouter(router)
                .exactInput(IFeeSwapRouter.ExactInputParams(path, address(this), block.timestamp, amountIn, minimum));
            require(beforeIn - token.balanceOf(address(this)) == amountIn, AutonomousCheck(0x4d8d39b2));
            amountOut = IERC20(usdc).balanceOf(address(this)) - beforeOut;
            require(amountOut >= minimum, AutonomousCheck(0x5814aad6));
            token.safeApprove(router, 0);
        } else {
            require(path.length == 0 || path.length == 43, AutonomousCheck(0xd8bea72e));
            amountOut = swap(tokenIn, usdc, router, fee, amountIn, minimum, limit);
        }
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
        uint160 sqrtLimit,
        bytes calldata path
    ) external {
        IRevenueBorrowPool pool = IRevenueBorrowPool(poolAddress);
        IERC20 weth = IERC20(token0);
        IERC20 usdc = IERC20(token1);
        IFeeSwapRouter swapRouter = IFeeSwapRouter(router);
        uint256 idle = usdc.balanceOf(address(this));
        if (idle > 0) pool.supply(address(usdc), idle, address(this), 0);
        uint256 token0Before = weth.balanceOf(address(this));
        pool.borrow(address(weth), amount0, 2, 0, address(this));
        uint256 before1=usdc.balanceOf(address(this));
        if(path.length==0){
            swapRouter.exactInputSingle(
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
        }else swapRouter.exactInput(IFeeSwapRouter.ExactInputParams(path,address(this),block.timestamp,amount0,minOut));
        uint256 amount1=usdc.balanceOf(address(this))-before1;
        if(amount1<minOut)revert HedgeCheck(46);
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

    function distributable(State storage s, address stable) external view returns (uint256) {
        return TreasuryPolicyLib.distributable(s, stable);
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
    error ConversionBountyCooldownZero();
    error ConversionBountyMinRatioZero();

    function _validLegacyBountyCap(uint256 cap) private view returns (bool) {
        return
            cap > 0
                && cap
                    <= 1000000
                        * (10 ** uint256(IERC20Metadata(IRevenueConversionPolicy(address(this)).usdc()).decimals()));
    }
    event KeeperBountyConfigured(bool enabled, uint256 amount);
    event KeeperBountyDailyCapConfigured(uint256 cap);
    event StrategyCheckpointBountyConfigured(bool enabled, uint256 amount);
    event StrategyCheckpointBountyDailyCapConfigured(uint256 cap);
    event HedgeBountyConfigured(bool enabled, uint256 amount);
    event HedgeBountyDailyCapConfigured(uint256 cap);
    event DepositBountyConfigured(bool enabled, uint256 amount);
    event DepositBountyLimitsConfigured(uint64 vaultCooldown, uint64 keeperCooldown, uint256 cap);
    event ConversionBountyConfigured(bool enabled, uint256 amount);
    event ConversionBountyCooldownConfigured(uint64 cooldown, uint16 ratio);

    function setDepositBounty(State storage s, bool _enabled, uint256 _amount) external {
        require(!IRevenueConversionPolicy(address(this)).configurationSealed(), AutonomousCheck(0x9a247fa1));
        if (_enabled) {
            require(_amount > 0, AutonomousCheck(0x2567641d));
            require(
                s.legacy.depositBountyCooldown > 0 && s.legacy.depositBountyKeeperCooldown > 0,
                AutonomousCheck(0xc5640d54)
            );
            require(_amount <= s.legacy.depositBountyDailyCap, AutonomousCheck(0x26bf5266));
        }
        s.legacy.depositBountyEnabled = _enabled;
        s.legacy.depositBountyAmount = _amount;
        emit DepositBountyConfigured(_enabled, _amount);
    }

    function setDepositBountyLimits(State storage s, uint64 _vaultCooldown, uint64 _keeperCooldown, uint256 _dailyCap)
        external
    {
        require(!IRevenueConversionPolicy(address(this)).configurationSealed(), AutonomousCheck(0x9a247fa1));
        require(_vaultCooldown <= 1 days && _keeperCooldown <= 7 days, AutonomousCheck(0x06463f6b));
        if (s.legacy.depositBountyEnabled) {
            require(_vaultCooldown > 0 && _keeperCooldown > 0, AutonomousCheck(0xc5640d54));
        }
        require(_dailyCap == 0 || _validLegacyBountyCap(_dailyCap), AutonomousCheck(0xdc524c4e));
        if (s.legacy.depositBountyEnabled) {
            require(_dailyCap >= s.legacy.depositBountyAmount, AutonomousCheck(0xb5e14be5));
        }
        s.legacy.depositBountyCooldown = _vaultCooldown;
        s.legacy.depositBountyKeeperCooldown = _keeperCooldown;
        s.legacy.depositBountyDailyCap = _dailyCap;
        emit DepositBountyLimitsConfigured(_vaultCooldown, _keeperCooldown, _dailyCap);
    }

    function setConversionBounty(State storage s, bool _enabled, uint256 _amount) external {
        require(!IRevenueConversionPolicy(address(this)).configurationSealed(), AutonomousCheck(0x9a247fa1));
        if (_enabled && _amount > 0 && s.legacy.conversionBountyCooldown == 0) revert ConversionBountyCooldownZero();
        if (_enabled && _amount > 0 && s.legacy.conversionBountyMinRatio == 0) revert ConversionBountyMinRatioZero();
        if (_enabled) require(_amount > 0 && _validLegacyBountyCap(_amount), AutonomousCheck(0xa540b0da));
        s.legacy.conversionBountyEnabled = _enabled;
        s.legacy.conversionBountyAmount = _amount;
        emit ConversionBountyConfigured(_enabled, _amount);
    }

    function setConversionBountyCooldown(State storage s, uint64 _cooldown, uint16 _minRatio) external {
        require(!IRevenueConversionPolicy(address(this)).configurationSealed(), AutonomousCheck(0x9a247fa1));
        require(_cooldown == 0 || (_cooldown >= 6 hours && _cooldown <= 30 days), AutonomousCheck(0x08938d78));
        require(_minRatio == 0 || (_minRatio >= 100 && _minRatio <= 10000), AutonomousCheck(0x77b24299));
        if (s.legacy.conversionBountyEnabled && s.legacy.conversionBountyAmount > 0 && _cooldown == 0) {
            revert ConversionBountyCooldownZero();
        }
        if (s.legacy.conversionBountyEnabled && s.legacy.conversionBountyAmount > 0 && _minRatio == 0) {
            revert ConversionBountyMinRatioZero();
        }
        s.legacy.conversionBountyCooldown = _cooldown;
        s.legacy.conversionBountyMinRatio = _minRatio;
        emit ConversionBountyCooldownConfigured(_cooldown, _minRatio);
    }

    function setLegacyBountyCap(State storage s, uint8 kind, uint256 cap) external {
        require(!IRevenueConversionPolicy(address(this)).configurationSealed(), AutonomousCheck(0x9a247fa1));
        require(cap == 0 || _validLegacyBountyCap(cap), AutonomousCheck(0xdc524c4e));
        bool enabled = kind == 0
            ? s.legacy.keeperBountyEnabled
            : kind == 1 ? s.legacy.strategyCheckpointBountyEnabled : s.legacy.hedgeBountyEnabled;
        uint256 amount = kind == 0
            ? s.legacy.keeperBountyAmount
            : kind == 1 ? s.legacy.strategyCheckpointBountyAmount : s.legacy.hedgeBountyAmount;
        if (enabled || (kind == 1 && cap > 0)) require(cap >= amount, AutonomousCheck(0xb5e14be5));
        if (kind == 0) {
            s.legacy.keeperBountyDailyCap = cap;
            emit KeeperBountyDailyCapConfigured(cap);
        } else if (kind == 1) {
            s.legacy.strategyCheckpointBountyDailyCap = cap;
            emit StrategyCheckpointBountyDailyCapConfigured(cap);
        } else {
            require(kind == 3);
            s.legacy.hedgeBountyDailyCap = cap;
            emit HedgeBountyDailyCapConfigured(cap);
        }
    }
}
