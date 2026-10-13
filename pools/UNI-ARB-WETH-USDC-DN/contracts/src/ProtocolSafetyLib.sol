// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import "./AutonomousErrors.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
interface IInstalledVault {
    function token0() external view returns(address);
    function token1() external view returns(address);
    function emergencySafe() external view returns (address);
    function pauseController() external view returns (address);
    function treasuryAddress() external view returns (address);
}
interface IInstalledModule {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function safe() external view returns (address);
    function vault() external view returns (address);
    function pauseController() external view returns (address);
    function directExecution() external view returns (bool);
}
interface IInstalledRange {
    function owner() external view returns (address);
    function vault() external view returns (address);
    function treasuryAddress() external view returns (address);
    function strategyEngine() external view returns (address);
}
interface IInstalledEngine {
    function owner() external view returns (address);
    function rangeManager() external view returns (address);
    function hedgeManager() external view returns (address);
}
interface IInstalledHedge {
    function vault() external view returns (address);
    function safe() external view returns (address);
    function rangeManager() external view returns (address);
    function treasuryAddress() external view returns (address);
    function installationSealed() external view returns (bool);
}
interface IInstalledRevenue {
    function configurationSealed() external view returns(bool);
    function usdc() external view returns(address);
    function wrappedNative() external view returns(address);
    function assetSealed(address token) external view returns(bool);
    function sourceOf(address actor) external view returns(address);
    function revenueSourceSealed(address source) external view returns(bool);
}
interface IRevenueRecorder { function recordRevenue(address token, uint256 amount) external; }
interface IFeeSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}
interface IDirectSettlementPool {
    function repay(address, uint256, uint256, address) external returns (uint256);
    function withdraw(address, uint256, address) external returns (uint256);
}
interface IEmergencyRange {
    function getOwnerPositions() external view returns (uint256[] memory);
    function emergencyBurnPosition(uint256 tokenId) external;
}
interface IRecoveryVault {
    function owner() external view returns (address);
    function installationSealed() external view returns (bool);
    function treasuryAddress() external view returns (address);
}
interface IRecoveryPause {
    function exitOnly() external view returns (bool);
    function safe() external view returns (address);
    function withdrawalsPaused() external view returns (bool);
}
/// @notice Linked, stateless safety checks; delegatecall preserves Treasury/Vault payer and caller identity.
library ProtocolSafetyLib {
    using SafeERC20 for IERC20;
    uint256 private constant MIN_SQRT_RATIO = 4295128739;
    uint256 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
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
    function wrapNative(address token) external {
        uint256 amount = address(this).balance;
        uint256 beforeToken = IERC20(token).balanceOf(address(this));
        (bool ok,) = token.call{value: amount}(abi.encodeWithSignature("deposit()"));
        require(ok && address(this).balance == 0 && IERC20(token).balanceOf(address(this)) - beforeToken == amount,
            AutonomousCheck(0x45f80872));
    }
    function sendCommission(address treasury, address token, uint256 amount) external {
        if (amount == 0) return;
        IERC20(token).safeApprove(treasury, 0);
        IERC20(token).safeApprove(treasury, amount);
        IRevenueRecorder(treasury).recordRevenue(token, amount);
        IERC20(token).safeApprove(treasury, 0);
    }
    function requireEmergency(address vault) external view { _requireEmergency(vault); }
    function _requireEmergency(address vault) private view {
        (bool ok, bytes memory ret) = vault.staticcall(abi.encodeWithSignature("pauseController()"));
        require(ok && ret.length == 32, AutonomousCheck(0xa6663aff));
        IRecoveryPause pc = IRecoveryPause(abi.decode(ret, (address)));
        require(pc.withdrawalsPaused() || pc.exitOnly(), AutonomousCheck(0x1d45e305));
    }
    function validateVaultInstallation(address module, address manager) external view {
        IInstalledVault v = IInstalledVault(address(this));
        address safe = v.emergencySafe(); address pc = v.pauseController(); address treasury = v.treasuryAddress();
        require(IInstalledRevenue(treasury).configurationSealed() && IInstalledRevenue(treasury).wrappedNative()!=address(0) && IInstalledRevenue(treasury).assetSealed(IInstalledRevenue(treasury).wrappedNative()) && IInstalledRevenue(treasury).assetSealed(IInstalledRevenue(treasury).usdc()) && IInstalledRevenue(treasury).sourceOf(address(this))==address(this) && IInstalledRevenue(treasury).revenueSourceSealed(address(this)) && IInstalledRevenue(treasury).assetSealed(v.token0()) && IInstalledRevenue(treasury).assetSealed(v.token1()), "Revenue source not sealed");
        IInstalledModule bot = IInstalledModule(module); IInstalledRange rm = IInstalledRange(manager);
        require(module.code.length > 0 && manager.code.length > 0, "Incomplete installation");
        require(IRecoveryVault(address(this)).owner() == safe && IRecoveryPause(pc).safe() == safe, "Safe binding");
        require(bot.owner() == safe && bot.safe() == safe && bot.pendingOwner() == address(0)
            && bot.vault() == address(this) && bot.pauseController() == pc && bot.directExecution(), "Module binding");
        require(rm.owner() == address(this) && rm.vault() == address(this) && rm.treasuryAddress() == treasury, "Range binding");
        IInstalledEngine engine = IInstalledEngine(rm.strategyEngine());
        require(engine.owner() == address(this) && engine.rangeManager() == manager, "Engine binding");
        address hedge = engine.hedgeManager();
        if (hedge != address(0)) {
            IInstalledHedge hm = IInstalledHedge(hedge);
            require(hm.installationSealed() && hm.vault() == address(this) && hm.safe() == safe
                && hm.rangeManager() == manager && hm.treasuryAddress() == treasury, "Hedge binding");
        }
    }
    function bounds(address tokenIn, address usdc, uint256 amountIn, address tokenFeed, address stableFeed,
        uint32 maxAge, uint32 usdcMaxAge, uint16 slippageBps)
        external
        view
        returns (uint256 minUsdcOut, uint160 sqrtPriceLimitX96)
    {
        AggregatorV3Interface feed = AggregatorV3Interface(tokenFeed);
        AggregatorV3Interface usdcFeed = AggregatorV3Interface(stableFeed);
        require(address(feed) != address(0) && address(usdcFeed) != address(0), AutonomousCheck(0xdabc64c6));
        require(maxAge != 0 && usdcMaxAge != 0, AutonomousCheck(0x68bcf3b3));
        require(slippageBps != 0, AutonomousCheck(0xb76e3dd6));
        (uint80 roundId, int256 px,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        (uint80 usdcRoundId, int256 usdcPx,, uint256 usdcUpdatedAt, uint80 usdcAnsweredInRound) =
            usdcFeed.latestRoundData();
        require(
            px > 0 && updatedAt != 0 && answeredInRound >= roundId && block.timestamp - updatedAt <= maxAge, AutonomousCheck(0x38ec95fb));
        require(
            usdcPx > 0 && usdcUpdatedAt != 0 && usdcAnsweredInRound >= usdcRoundId
                && block.timestamp - usdcUpdatedAt <= usdcMaxAge, AutonomousCheck(0x58421f15));
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


    function swap(address tokenIn, address usdc, address router, uint24 fee,
        uint256 amountIn, uint256 minOut, uint160 priceLimit) external returns (uint256 out) {
        IERC20 token = IERC20(tokenIn);
        uint256 beforeIn = token.balanceOf(address(this));
        uint256 beforeOut = IERC20(usdc).balanceOf(address(this));
        require(amountIn > 0 && minOut > 0 && fee > 0 && beforeIn >= amountIn, AutonomousCheck(0xf58e91a9));
        token.safeApprove(router, 0);
        token.safeApprove(router, amountIn);
        IFeeSwapRouter(router).exactInputSingle(IFeeSwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn, tokenOut: usdc, fee: fee, recipient: address(this), deadline: block.timestamp,
            amountIn: amountIn, amountOutMinimum: minOut, sqrtPriceLimitX96: priceLimit
        }));
        require(beforeIn - token.balanceOf(address(this)) == amountIn, AutonomousCheck(0x4d8d39b2));
        out = IERC20(usdc).balanceOf(address(this)) - beforeOut;
        require(out >= minOut, AutonomousCheck(0x5814aad6));
        token.safeApprove(router, 0);
    }


    function recoveryAllowed(address pc, address safe, address beneficiary, uint8 action)
        external view returns (bool) {
        if (action == 1) return msg.sender == beneficiary;
        if (action == 2) return msg.sender == safe && (IRecoveryPause(pc).withdrawalsPaused() || IRecoveryPause(pc).exitOnly());
        return msg.sender == safe && (IRecoveryPause(pc).withdrawalsPaused() || IRecoveryPause(pc).exitOnly());
    }

    function sweepBountyDelta(address treasury, address bot, address token, uint256 beforeBalance)
        external returns (uint256 amount) {
        if (token == address(0)) return 0;
        uint256 balance = IERC20(token).balanceOf(address(this));
        amount = balance > beforeBalance ? balance - beforeBalance : 0;
        if (amount > 0) IERC20(token).safeTransfer(bot, amount);
        // treasury is deliberately not called here; only this module's newly received bounty is swept.
        treasury;
    }

    function sweep(address token, address recipient) external returns (uint256 amount) {
        amount = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        require(amount > 0, AutonomousCheck(0x62d566aa));
        if (token == address(0)) {
            (bool ok,) = recipient.call{value: amount}("");
            require(ok, AutonomousCheck(0xb17cccee));
        } else IERC20(token).safeTransfer(recipient, amount);
    }

    struct PauseState { bool active; uint64 until; uint64 nextAt; }
    function setPause(PauseState storage state, address safe, bool value) external {
        _setPause(state, safe, value, 48 hours);
    }
    function setPauseFor(PauseState storage state, address safe, uint64 duration) external {
        _setPause(state, safe, true, duration);
    }
    function _setPause(PauseState storage state, address safe, bool value, uint64 duration) private {
        require(msg.sender == safe, AutonomousCheck(0x78a71317));
        if (value) {
            require(duration >= 1 hours && duration <= 48 hours, AutonomousCheck(0x2e861dfb));
            require(block.timestamp >= state.until && block.timestamp >= state.nextAt, AutonomousCheck(0xaa8f7a50));
            state.until = uint64(block.timestamp) + duration; state.nextAt = state.until + 24 hours;
        } else {
            require(state.active && block.timestamp < state.until, AutonomousCheck(0xaecd4fd1));
            state.until = 0; state.nextAt = uint64(block.timestamp + 24 hours);
        }
        state.active = value;
    }
    function executeBoundedCall(address target, bytes calldata data) external returns (bytes memory) {
        require(data.length >= 4, "E20");
        bytes4 selector = bytes4(data[:4]);
        require(!IRecoveryVault(address(this)).installationSealed()
            || _isBoundedSafetySelector(selector), "E20");
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "E20");
        return ret;
    }
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    function rescueRangeToken(address vault, address safe, address token0, address token1,
        address token, address to, uint256 amount) external {
        require(msg.sender == safe || msg.sender == vault, "E16");
        require(token != token0 && token != token1, "E41");
        _requireEmergency(vault);
        require(to != address(0) && to == IRecoveryVault(vault).treasuryAddress(), AutonomousCheck(0x5a661f56));
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }
    error InvalidRecipient();
    error ProtectedPoolToken();
    error ProtectedVaultFunds();
    error E17();
    /// @dev Pool capital is never rescuable; foreign assets use the fixed Treasury receiver.
    function rescueVaultToken(address treasury, address token, address token0, address token1, address to, uint256 amount) external {
        require(token != token0 && token != token1 && to != address(0) && to == treasury, AutonomousCheck(0x5a661f56));
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }
    function _isBoundedSafetySelector(bytes4 selector) private pure returns (bool) {
        return selector == bytes4(keccak256("configureSlippage(uint24)"))
            || selector == bytes4(keccak256("configureProtections(bool,bool,uint16)"))
            || selector == bytes4(keccak256("setOracleParams(uint16,uint32,uint32)"));
    }


    error E46();
    event PositionBurned(uint256 indexed tokenId, address indexed initiator);
    function burnPositions(address manager) external returns (uint256 count) {
        uint256[] memory positions = IEmergencyRange(manager).getOwnerPositions();
        count = positions.length;
        if (count == 0) revert E46();
        for (uint256 i; i < count; ++i) {
            IEmergencyRange(manager).emergencyBurnPosition(positions[i]);
            emit PositionBurned(positions[i], msg.sender);
        }
    }
    function emergencyShares(address manager, address token0, address token1, uint256 pending0, uint256 pending1,
        uint256 shares, uint256 total) external view returns (uint256 amount0, uint256 amount1, uint256 needed0, uint256 needed1) {
        if (IEmergencyRange(manager).getOwnerPositions().length != 0) revert E46();
        uint256 raw0 = IERC20(token0).balanceOf(address(this));
        uint256 raw1 = IERC20(token1).balanceOf(address(this));
        if (raw0 < pending0 || raw1 < pending1) revert E46();
        uint256 available0 = raw0 - pending0; uint256 available1 = raw1 - pending1;
        uint256 balance0 = IERC20(token0).balanceOf(manager); uint256 balance1 = IERC20(token1).balanceOf(manager);
        amount0 = ((available0 + balance0) * shares) / total;
        amount1 = ((available1 + balance1) * shares) / total;
        needed0 = amount0 > available0 ? amount0 - available0 : 0;
        needed1 = amount1 > available1 ? amount1 - available1 : 0;
        if (needed0 > balance0) needed0 = balance0;
        if (needed1 > balance1) needed1 = balance1;
    }
    function bountyBalance(address treasury) external view returns (address token, uint256 balance) {
        (bool ok, bytes memory ret) = treasury.staticcall(abi.encodeWithSignature("usdc()"));
        if (!ok || ret.length < 32) return (address(0), 0);
        token = abi.decode(ret, (address));
        balance = IERC20(token).balanceOf(address(this));
    }

    /// @dev Distribute only the pre-settlement idle reserve share; freshly burnt LP proceeds are excluded.
    function sendIdleShare(address token0, address token1, uint256 idle0, uint256 idle1,
        uint256 proportion, uint256 scale, address recipient) external {
        uint256 share = idle0 * proportion / scale;
        if (share > 0) IERC20(token0).safeTransfer(recipient, share);
        share = idle1 * proportion / scale;
        if (share > 0) IERC20(token1).safeTransfer(recipient, share);
    }

    /// @dev Same deterministic Aave direct settlement, executed in the HedgeManager context.
    function settleDirectly(address pool, address token0, address token1, address collateralToken,
        uint256 debtToRepay, uint256 proportion, bool full, address recipient) external {
        IDirectSettlementPool aave = IDirectSettlementPool(pool);
        if (full) aave.repay(token0, type(uint256).max, 2, address(this));
        else if (debtToRepay > 0) aave.repay(token0, debtToRepay, 2, address(this));
        if (full) aave.withdraw(token1, type(uint256).max, recipient);
        else {
            uint256 share = IERC20(collateralToken).balanceOf(address(this)) * proportion / 1e18;
            if (share > 0) {
                uint256 beforeBalance = IERC20(token1).balanceOf(address(this));
                aave.withdraw(token1, share, address(this));
                uint256 withdrawn = IERC20(token1).balanceOf(address(this)) - beforeBalance;
                if (withdrawn > 0) IERC20(token1).safeTransfer(recipient, withdrawn);
            }
        }
    }

}
