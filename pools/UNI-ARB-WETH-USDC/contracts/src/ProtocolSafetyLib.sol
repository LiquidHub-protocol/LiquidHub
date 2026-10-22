// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import "./AutonomousPoolLib.sol";
import "./interfaces/IRangeStrategyEngine.sol";
import "./RangeOperations.sol";
import "./AutonomousErrors.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface IInstalledVault {
    function token0() external view returns (address);
    function token1() external view returns (address);
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
    function configurationSealed() external view returns (bool);
    function usdc() external view returns (address);
    function wrappedNative() external view returns (address);
    function assetSealed(address token) external view returns (bool);
    function sourceOf(address actor) external view returns (address);
    function revenueSourceSealed(address source) external view returns (bool);
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

/// @notice Fixed safety and execution policy; explicit storage references retain the calling pool context.
interface IProtectionVault {
    function installationSealed() external view returns (bool);
}

interface IExecutionRange {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function config() external view returns (RangeOperations.RangeConfig memory);
    function priceCache() external view returns (RangeOperations.PriceCache memory);
    function initMultiSwapTvl() external view returns (uint256);
}

interface IExecutionBot {
    function botAddress() external view returns (address);
}

library ProtocolSafetyLib {
    error E19();
    event ToleranceUpdated(uint16 oldTolerance, uint16 newTolerance);
    error E20();
    error E21();
    using SafeERC20 for IERC20;
    uint256 private constant MIN_SQRT_RATIO = 4295128739;
    uint256 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    function requireEmergency(address vault) external view {
        _requireEmergency(vault);
    }

    function _requireEmergency(address vault) private view {
        (bool ok, bytes memory ret) = vault.staticcall(abi.encodeWithSignature("pauseController()"));
        require(ok && ret.length == 32, AutonomousCheck(0xa6663aff));
        IRecoveryPause pc = IRecoveryPause(abi.decode(ret, (address)));
        require(pc.withdrawalsPaused() || pc.exitOnly(), AutonomousCheck(0x1d45e305));
    }

    function validateVaultInstallation(address module, address manager) external view {
        IInstalledVault v = IInstalledVault(address(this));
        address safe = v.emergencySafe();
        address pc = v.pauseController();
        address treasury = v.treasuryAddress();
        require(
            IInstalledRevenue(treasury).configurationSealed()
                && IInstalledRevenue(treasury).wrappedNative() != address(0)
                && IInstalledRevenue(treasury).assetSealed(IInstalledRevenue(treasury).wrappedNative())
                && IInstalledRevenue(treasury).assetSealed(IInstalledRevenue(treasury).usdc())
                && IInstalledRevenue(treasury).sourceOf(address(this)) == address(this)
                && IInstalledRevenue(treasury).revenueSourceSealed(address(this))
                && IInstalledRevenue(treasury).assetSealed(v.token0())
                && IInstalledRevenue(treasury).assetSealed(v.token1()),
            "Revenue source not sealed"
        );
        IInstalledModule bot = IInstalledModule(module);
        IInstalledRange rm = IInstalledRange(manager);
        require(module.code.length > 0 && manager.code.length > 0, "Incomplete installation");
        require(IRecoveryVault(address(this)).owner() == safe && IRecoveryPause(pc).safe() == safe, "Safe binding");
        require(
            bot.owner() == safe && bot.safe() == safe && bot.pendingOwner() == address(0)
                && bot.vault() == address(this) && bot.pauseController() == pc && bot.directExecution(),
            "Module binding"
        );
        require(
            rm.owner() == address(this) && rm.vault() == address(this) && rm.treasuryAddress() == treasury,
            "Range binding"
        );
        IInstalledEngine engine = IInstalledEngine(rm.strategyEngine());
        require(engine.owner() == address(this) && engine.rangeManager() == manager, "Engine binding");
        address hedge = engine.hedgeManager();
        if (hedge != address(0)) {
            IInstalledHedge hm = IInstalledHedge(hedge);
            require(
                hm.installationSealed() && hm.vault() == address(this) && hm.safe() == safe
                    && hm.rangeManager() == manager && hm.treasuryAddress() == treasury,
                "Hedge binding"
            );
        }
    }

    function recoveryAllowed(address pc, address safe, address beneficiary, uint8 action) external view returns (bool) {
        if (action == 1) return msg.sender == beneficiary;
        if (action == 2) {
            return msg.sender == safe && (IRecoveryPause(pc).withdrawalsPaused() || IRecoveryPause(pc).exitOnly());
        }
        return msg.sender == safe && (IRecoveryPause(pc).withdrawalsPaused() || IRecoveryPause(pc).exitOnly());
    }

    function sweepBountyDelta(address treasury, address bot, address token, uint256 beforeBalance)
        external
        returns (uint256 amount)
    {
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
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
    }

    struct PauseState {
        bool active;
        uint64 until;
        uint64 nextAt;
    }

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
            state.until = uint64(block.timestamp) + duration;
            state.nextAt = state.until + 24 hours;
        } else {
            require(state.active && block.timestamp < state.until, AutonomousCheck(0xaecd4fd1));
            state.until = 0;
            state.nextAt = uint64(block.timestamp + 24 hours);
        }
        state.active = value;
    }

    function executeBoundedCall(address target, bytes calldata data) external returns (bytes memory) {
        require(data.length >= 4, "E20");
        bytes4 selector = bytes4(data[:4]);
        require(!IRecoveryVault(address(this)).installationSealed() || _isBoundedSafetySelector(selector), "E20");
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "E20");
        return ret;
    }
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    function rescueRangeToken(
        address vault,
        address safe,
        address token0,
        address token1,
        address token,
        address to,
        uint256 amount
    ) external {
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
    function rescueVaultToken(
        address treasury,
        address token,
        address token0,
        address token1,
        address to,
        uint256 amount
    ) external {
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

    function emergencyShares(
        address manager,
        address token0,
        address token1,
        uint256 pending0,
        uint256 pending1,
        uint256 shares,
        uint256 total
    ) external view returns (uint256 amount0, uint256 amount1, uint256 needed0, uint256 needed1) {
        if (IEmergencyRange(manager).getOwnerPositions().length != 0) revert E46();
        uint256 raw0 = IERC20(token0).balanceOf(address(this));
        uint256 raw1 = IERC20(token1).balanceOf(address(this));
        if (raw0 < pending0 || raw1 < pending1) revert E46();
        uint256 available0 = raw0 - pending0;
        uint256 available1 = raw1 - pending1;
        uint256 balance0 = IERC20(token0).balanceOf(manager);
        uint256 balance1 = IERC20(token1).balanceOf(manager);
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

    /// @dev Same deterministic Aave direct settlement, executed in the HedgeManager context.

    struct ProtectionOverrideState {
        uint64 until;
        uint64 nextAt;
        bool twap;
        bool mev;
        uint16 ticks;
    }
    event TemporaryProtectionOverride(uint64 until, bool twap, bool mev, uint16 ticks);

    function configureProtections(
        RangeOperations.ProtectionConfig storage cfg,
        ProtectionOverrideState storage state,
        address vault,
        bool twap,
        bool mev,
        uint16 ticks
    ) external {
        require(ticks > 0 && ticks <= 1000, AutonomousCheck(0x6e879f86));
        if (!IProtectionVault(vault).installationSealed()) {
            cfg.sandwichDetectionEnabled = twap;
            cfg.mevProtectionEnabled = mev;
            cfg.maxTwapDeviationTicks = ticks;
        } else {
            require(block.timestamp >= state.until && block.timestamp >= state.nextAt, AutonomousCheck(0x6ec26e43));
            state.twap = twap;
            state.mev = mev;
            state.ticks = ticks;
            state.until = uint64(block.timestamp + 48 hours);
            state.nextAt = state.until + 24 hours;
            emit TemporaryProtectionOverride(state.until, twap, mev, ticks);
        }
    }

    error E40();

    struct DepositContext {
        uint256 deposit0;
        uint256 deposit1;
        address token0;
        address token1;
        bool input0;
        bool expectedZero;
        uint256 expected;
        uint256 submitted;
        RangeOperations.RangeConfig cfg;
        RangeOperations.PriceCache cache;
    }

    function validateEngine(mapping(address=>bool) storage authorizedExecutors,address previousBot,address previousOperator, address engine, address bot, address pool, address hedge, bool dn)
        external

        returns (address operator)
    {
        operator = IExecutionBot(bot).botAddress();
        IRangeStrategyEngine candidate = IRangeStrategyEngine(engine);
        if (
            operator == address(0) || candidate.rangeManager() != address(this) || candidate.pool() != pool
                || candidate.hedgeManager() != hedge
                || (dn
                        ? candidate.profile() != IRangeStrategyEngine.StrategyProfile.DELTA_NEUTRAL
                        : candidate.profile() == IRangeStrategyEngine.StrategyProfile.DELTA_NEUTRAL)
        ) revert E40();
        authorizedExecutors[previousBot]=false;
        authorizedExecutors[previousOperator]=false;
        authorizedExecutors[bot]=true;
    }

    function currentDecision(address engine) external view returns (IRangeStrategyEngine.Decision memory decision) {
        if (engine == address(0)) revert E40();
        decision = IRangeStrategyEngine(engine).previewDecision();
        return IRangeStrategyEngine(engine).validateDecision(decision.decisionHash);
    }

    function validateDecision(address engine, bytes32 expectedHash, bool delayMainBot, uint8 action)
        external
        view
        returns (IRangeStrategyEngine.Decision memory decision)
    {
        decision = IRangeStrategyEngine(engine).validateDecision(expectedHash);
        require(uint8(decision.action) == action, "E90");
        if (delayMainBot) {
            IRangeStrategyEngine.Telemetry memory telemetry = IRangeStrategyEngine(engine).currentTelemetry();
            require(block.timestamp >= uint256(telemetry.checkpointTimestamp) + 1 minutes, "E03");
        }
    }

    function validateDeposit(
        uint256 deposit0,
        uint256 deposit1,
        uint256[] calldata amounts,
        uint256[] calldata minima,
        address input,
        address output
    ) external view {
        require(amounts.length == minima.length, "len");
        IExecutionRange rm = IExecutionRange(address(this));
        DepositContext memory c;
        c.deposit0 = deposit0;
        c.deposit1 = deposit1;
        c.token0 = rm.token0();
        c.token1 = rm.token1();
        c.input0 = input == c.token0;
        c.cfg = rm.config();
        c.cache = rm.priceCache();
        (c.expectedZero, c.expected) = RangeOperations.depositSwapParams(address(this), deposit0, deposit1);
        if (amounts.length > 0) {
            require((input == c.token0 && output == c.token1) || (input == c.token1 && output == c.token0), "E43");
            uint256 swapUsd = RangeOperations.validateMinOutsAgainstOracle(
                c.input0, amounts, minima, c.cache, c.cfg, rm.initMultiSwapTvl()
            );
            uint256 depositUsd = c.deposit0 * c.cache.price0 / (10 ** c.cfg.token0Decimals) + c.deposit1
                * c.cache.price1 / (10 ** c.cfg.token1Decimals);
            require(swapUsd <= depositUsd, AutonomousCheck(0xb3deca25));
            for (uint256 i; i < amounts.length; ++i) {
                c.submitted += amounts[i];
            }
            require(c.submitted <= (c.input0 ? c.deposit0 : c.deposit1), AutonomousCheck(0xa487a9d2));
        }
        if (c.expected == 0) {
            require(c.submitted == 0, "E93");
            return;
        }
        require(c.input0 == c.expectedZero, "E94");
        uint256 tolerance = c.expected * c.cfg.toleranceBps / 10000;
        if (tolerance == 0) tolerance = 1;
        require(c.submitted + tolerance >= c.expected && c.submitted <= c.expected + tolerance, "E93");
    }

    function requireSubmittedSwapPlan(
        uint256 expectedAmountIn,
        bool expectedZeroForOne,
        bool tokenInIsToken0,
        uint256 submittedAmountIn,
        uint16 toleranceBps
    ) external pure {
        if (expectedAmountIn == 0) {
            require(submittedAmountIn == 0, "E93");
            return;
        }
        require(tokenInIsToken0 == expectedZeroForOne, "E94");
        uint256 tolerance = (expectedAmountIn * uint256(toleranceBps)) / 10000;
        if (tolerance == 0) tolerance = 1;
        require(submittedAmountIn + tolerance >= expectedAmountIn, "E93");
        require(submittedAmountIn <= expectedAmountIn + tolerance, "E93");
    }

    function configureOracleParams(
        RangeOperations.ProtectionConfig storage protectionConfig,
        uint16 _maxOracleDeviationBps,
        uint32 _maxAge0,
        uint32 _maxAge1
    ) external {
        if (_maxOracleDeviationBps == 0 || _maxOracleDeviationBps > 1000) revert E21();
        if (_maxAge0 < 3600 || _maxAge0 > 172800 || _maxAge1 < 3600 || _maxAge1 > 172800) revert E20();
        protectionConfig.maxOracleDeviationBps = _maxOracleDeviationBps;
        protectionConfig.maxAge0 = _maxAge0;
        protectionConfig.maxAge1 = _maxAge1;
    }

    function configureTolerance(RangeOperations.RangeConfig storage config, address vault, uint16 _toleranceBps)
        external
    {
        AutonomousPoolLib.requireInstallation(vault);
        if (_toleranceBps > 1000) revert E20();

        uint16 oldTolerance = config.toleranceBps;
        config.toleranceBps = _toleranceBps;

        emit ToleranceUpdated(oldTolerance, _toleranceBps);
    }

    function configureSlippage(RangeOperations.RangeConfig storage config, uint24 _maxSlippageBps) external {
        if (_maxSlippageBps < 50 || _maxSlippageBps > 500) revert E19();
        config.maxSlippageBps = _maxSlippageBps;
    }
}
