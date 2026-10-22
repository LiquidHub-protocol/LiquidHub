// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import "./AutonomousPoolLib.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {DnDepositLib} from "./DnDepositLib.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
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

interface IRiskAavePool {
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}

interface IRiskRepairContext {
    function pool() external view returns (address);
    function weth() external view returns (address);
    function variableDebtWeth() external view returns (address);
    function operationalHfTargetBps() external view returns (uint16);
    function hfRepairTriggerBps() external view returns (uint16);
    function swapSlippageBps() external view returns (uint16);
}

interface ISafetyBotNav {
    function getOracleLpValueUsd() external view returns (uint256);
}

interface ISafetyHedgeNav {
    function getHedgeData() external view returns (uint256, uint256, uint256, uint256);
}

interface IPolicyWithdrawalPool {
    function withdraw(address, uint256, address) external returns (uint256);
}

interface IPolicyBountyTreasury {
    function payKeeperBounty(address keeper) external;
}

library ProtocolSafetyLib {
    error E19();
    event ToleranceUpdated(uint16 oldTolerance, uint16 newTolerance);
    error E73();
    error E20();
    error E21();
    error BadHealthFactor();
    error InvalidSwapPlan();
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

    error HedgeCheck(uint8 code);
    event InstallationSealed();
    event OperationalHfBufferUpdated(uint16 bufferBps);
    event HfRepairConfigUpdated(uint16 triggerBps, uint64 bountyMinUsd);
    event DonationDustUpdated(uint256 amount);

    struct HedgeState {
        uint16 liqThresholdBps;
        bool installationSealed;
        uint16 initialHfTargetBps;
        uint16 initialHfBufferBps;
        uint16 initialHfRepairTriggerBps;
        address rangeManager;
        address treasuryAddress;
        INonfungiblePositionManager lpPositionManager;
        IUniswapV3Pool lpPool;
        uint16 adjustHedgeBps;
        uint16 criticalHedgeBps;
        uint16 swapSlippageBps;
        uint16 reserveHfTargetBps;
        uint16 operationalHfBufferBps;
        uint16 hfRepairTriggerBps;
        uint64 hfRepairBountyMinUsd;
        uint256 donationDustToken0;
        uint32 hedgeAdjustCooldown;
        uint16 maxHedgeDeviationBps;
    }

    function hedgeSeal(HedgeState storage state) external {
        require(
            !state.installationSealed && state.rangeManager.code.length > 0 && state.treasuryAddress.code.length > 0,
            AutonomousCheck(0x0b2cf59a)
        );
        require(state.maxHedgeDeviationBps > 0, AutonomousCheck(0x306dc1de));
        state.installationSealed = true;
        state.initialHfTargetBps = state.reserveHfTargetBps;
        state.initialHfBufferBps = state.operationalHfBufferBps;
        state.initialHfRepairTriggerBps = state.hfRepairTriggerBps;
        emit InstallationSealed();
    }

    function hedgeConfigure(HedgeState storage state, address[4] calldata addrs, uint16[4] calldata params) external {
        if (state.installationSealed) {
            require(
                addrs[1] == state.treasuryAddress && params[0] == state.adjustHedgeBps
                    && params[3] == state.liqThresholdBps,
                AutonomousCheck(0x6ad8e783)
            );
            require(params[2] >= state.initialHfTargetBps, AutonomousCheck(0x62d3fc4a));
        }
        address currentRangeManager = state.rangeManager;
        if (
            addrs[0] == address(0) || addrs[2] == address(0) || addrs[3] == address(0)
                || (currentRangeManager != address(0)
                    && (addrs[0] != currentRangeManager
                        || addrs[2] != address(state.lpPositionManager)
                        || addrs[3] != address(state.lpPool)))
        ) revert HedgeCheck(30);
        if (params[0] < 100 || params[0] > 2000) revert HedgeCheck(31);
        if (params[1] < 10 || params[1] > 500) revert HedgeCheck(32);
        if (params[2] < 11000 || params[2] > 30000) revert HedgeCheck(33); // 1.1 .. 3.0
        if (uint256(params[2]) + state.operationalHfBufferBps > 30000) revert HedgeCheck(64);
        if (params[3] < 5000 || params[3] > 9500) revert HedgeCheck(34); // 0.5 .. 0.95
        if (params[2] <= state.hfRepairTriggerBps) revert HedgeCheck(62);

        // but cannot redirect collateral or debt accounting to replacement contracts.
        // RangeManager is the immutable destination of close/sweep paths after the initial batch.
        if (currentRangeManager == address(0)) state.rangeManager = addrs[0];
        state.treasuryAddress = addrs[1];
        state.lpPositionManager = INonfungiblePositionManager(addrs[2]);
        state.lpPool = IUniswapV3Pool(addrs[3]);
        state.adjustHedgeBps = params[0];
        if (state.criticalHedgeBps < state.adjustHedgeBps + 250) revert HedgeCheck(54);
        state.swapSlippageBps = params[1];
        state.reserveHfTargetBps = params[2];
        state.liqThresholdBps = params[3];
    }

    function hedgeBuffer(HedgeState storage state, uint16 bufferBps) external {
        require(!state.installationSealed || bufferBps >= state.initialHfBufferBps, AutonomousCheck(0xb7ba4c0b));
        if (uint256(state.reserveHfTargetBps) + bufferBps > 30000) revert HedgeCheck(64);
        state.operationalHfBufferBps = bufferBps;
        emit OperationalHfBufferUpdated(bufferBps);
    }

    function hedgeRepair(HedgeState storage state, uint16 triggerBps, uint64 bountyMinUsd) external {
        require(!state.installationSealed || bountyMinUsd == state.hfRepairBountyMinUsd, AutonomousCheck(0x6ad8e783));
        require(!state.installationSealed || triggerBps >= state.initialHfRepairTriggerBps, AutonomousCheck(0xd919dd26));
        if (triggerBps <= 10000 || triggerBps >= state.reserveHfTargetBps) revert HedgeCheck(62);
        if (bountyMinUsd < 1e8 || bountyMinUsd > 1_000_000e8) revert HedgeCheck(63);
        state.hfRepairTriggerBps = triggerBps;
        state.hfRepairBountyMinUsd = bountyMinUsd;
        emit HfRepairConfigUpdated(triggerBps, bountyMinUsd);
    }

    function hedgeCritical(HedgeState storage state, uint16 thresholdBps) external {
        require(!state.installationSealed, AutonomousCheck(0x9a247fa1));
        if (thresholdBps < 250 || thresholdBps > 3000 || thresholdBps < state.adjustHedgeBps + 250) {
            revert HedgeCheck(54);
        }
        state.criticalHedgeBps = thresholdBps;
    }

    function hedgeDust(HedgeState storage state, uint256 _donationDustToken0, uint8 volatileDecimals) external {
        require(!state.installationSealed, AutonomousCheck(0x9a247fa1));
        uint256 maxDust = volatileDecimals >= 3 ? 10 ** (uint256(volatileDecimals) - 3) : 1;
        if (_donationDustToken0 == 0 || _donationDustToken0 > maxDust) revert HedgeCheck(40);
        state.donationDustToken0 = _donationDustToken0;
        emit DonationDustUpdated(_donationDustToken0);
    }

    function hedgeCooldown(HedgeState storage state, uint32 _cooldownSeconds) external {
        require(!state.installationSealed, AutonomousCheck(0x9a247fa1));
        if (_cooldownSeconds > 86400) revert HedgeCheck(36);
        state.hedgeAdjustCooldown = _cooldownSeconds;
    }

    function hedgeDeviation(HedgeState storage state, uint16 _bps) external {
        if (_bps == 0 || _bps > 1000) revert HedgeCheck(37);
        state.maxHedgeDeviationBps = _bps;
    }

    function aavePostSettlement(
        address aavePool,
        address aToken,
        address debtToken,
        bool fullWithdraw,
        uint256 hfBefore,
        uint16 targetHfBps
    ) external view {
        if (fullWithdraw) {
            if (IERC20(debtToken).balanceOf(address(this)) > 0 || IERC20(aToken).balanceOf(address(this)) > 0) {
                revert HedgeCheck(56);
            }
            return;
        }
        (uint256 collateralBase, uint256 debtBase,,,, uint256 hfAfter) =
            IRiskAavePool(aavePool).getUserAccountData(address(this));
        uint256 targetHf = uint256(targetHfBps) * 1e14;
        if (hfAfter >= targetHf) return;
        if (hfBefore >= targetHf || hfAfter < 1e18 || debtBase == 0) revert BadHealthFactor();
        if (hfAfter >= hfBefore) return;

        uint256 collateralBalance = IERC20(aToken).balanceOf(address(this));
        uint256 debtBalance = IERC20(debtToken).balanceOf(address(this));
        if (collateralBalance == 0 || debtBalance == 0) revert BadHealthFactor();
        uint256 collateralUnitBase = Math.mulDiv(collateralBase, 1, collateralBalance, Math.Rounding.Up) + 2;
        uint256 debtUnitBase = Math.mulDiv(debtBase, 1, debtBalance, Math.Rounding.Up) + 1;
        uint256 roundingAllowance = Math.mulDiv(hfBefore, debtUnitBase, debtBase, Math.Rounding.Up)
            + Math.mulDiv(1e18, collateralUnitBase, debtBase, Math.Rounding.Up) + 1;
        if (hfBefore - hfAfter > roundingAllowance) revert BadHealthFactor();
    }

    function aaveHfRepairAmounts() external view returns (uint256 directAmount, uint256 flashAmount) {
        IRiskRepairContext context = IRiskRepairContext(address(this));
        address aavePool = context.pool();
        address debtToken = context.variableDebtWeth();
        uint16 targetHfBps = context.operationalHfTargetBps();
        uint16 triggerHfBps = context.hfRepairTriggerBps();
        uint16 swapSlippageBps = context.swapSlippageBps();
        uint256 bufferedTarget = uint256(targetHfBps) + 10;
        uint256 premiumBps = IRiskAavePool(aavePool).FLASHLOAN_PREMIUM_TOTAL();
        uint256 costBps = 10000 + uint256(swapSlippageBps) + premiumBps + 5;
        (uint256 collateralBase, uint256 debtBase,, uint256 liveThreshold,, uint256 hf) =
            IRiskAavePool(aavePool).getUserAccountData(address(this));
        if (debtBase == 0 || hf >= uint256(triggerHfBps) * 1e14) {
            return (0, 0);
        }

        uint256 protectedCollateral = uint256(liveThreshold) * collateralBase;
        uint256 required = bufferedTarget * debtBase;
        if (required <= protectedCollateral) return (0, 0);

        uint256 debtBalance = IERC20(debtToken).balanceOf(address(this));
        if (debtBalance == 0) return (0, 0);
        uint256 directNeeded =
            Math.mulDiv(debtBalance, required - protectedCollateral, bufferedTarget * debtBase, Math.Rounding.Up);
        uint256 roundingBuffer = debtBalance / debtBase + 1;
        directNeeded = debtBalance - directNeeded < roundingBuffer ? debtBalance : directNeeded + roundingBuffer;
        uint256 idle = IERC20(context.weth()).balanceOf(address(this));
        directAmount = idle < directNeeded ? idle : directNeeded;

        uint256 remainingDebtBase = debtBase;
        uint256 remainingDebtBalance = debtBalance;
        if (directAmount > 0) {
            uint256 repaidBase = Math.mulDiv(debtBase, directAmount, debtBalance);
            remainingDebtBase -= repaidBase;
            remainingDebtBalance -= directAmount;
        }
        required = bufferedTarget * remainingDebtBase;
        // Zero collateral still permits an idle repayment, but not a flash leg.
        if (required <= protectedCollateral || remainingDebtBase == 0 || protectedCollateral == 0) {
            return (directAmount, 0);
        }

        uint256 collateralCost = Math.mulDiv(uint256(liveThreshold), costBps, 10000, Math.Rounding.Up);
        if (bufferedTarget <= collateralCost) revert InvalidSwapPlan();
        uint256 repayBase =
            Math.mulDiv(required - protectedCollateral, 1, bufferedTarget - collateralCost, Math.Rounding.Up);
        flashAmount = Math.mulDiv(remainingDebtBalance, repayBase, remainingDebtBase, Math.Rounding.Up);
        if (flashAmount > remainingDebtBalance) flashAmount = remainingDebtBalance;
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

    function dnPortfolioValue(address botModule, address hedgeManager, address rangeManager)
        external
        view
        returns (uint256)
    {
        uint256 lpValue = lpPortfolioValue(botModule);

        // AAVE hedge net value (collat - dette), en USD 8 dec (meme unite que la valeur LP).
        // Audit V2: sans ce terme, currentTotalValue sous-estime la vraie valeur du protocole (collat AAVE
        // ignore) -> sharesToMint surevalue -> retrait > juste part via deposit+withdraw atomique.
        // audit V1 (M3-B-fix, retour Codex) — le bloc hedge est SORTI des try/catch internes : un revert ici
        // (FAIL-CLOSED) ne doit PAS etre avale par un catch englobant et rendre une valeur LP-seule fausse.
        if (hedgeManager != address(0)) {
            // Les soldes idle du HedgeManager font partie des actifs du Vault. Ils doivent etre ajoutes AVANT
            // la dette AAVE : saturer LP - deficit a zero plus tot sous-estimerait la NAV alors que ces actifs
            // peuvent encore couvrir une partie du deficit. Les controles HF restent appliques aux actions DN.
            try DnDepositLib.idleHedgeValueUsd(hedgeManager, address(rangeManager)) returns (uint256 idleUsd) {
                lpValue += idleUsd;
            } catch {
                revert E73();
            }

            try ISafetyHedgeNav(hedgeManager).getHedgeData() returns (
                uint256 totalCollateralBase, uint256 totalDebtBase, uint256, uint256
            ) {
                // Comptabilite signee : si AAVE devient net negatif, le deficit reduit la NAV.
                // Si le deficit couvre toute la LP, on retourne 0 pour bloquer les nouveaux mints.
                if (totalCollateralBase >= totalDebtBase) {
                    lpValue += (totalCollateralBase - totalDebtBase);
                } else {
                    uint256 deficit = totalDebtBase - totalCollateralBase;
                    if (deficit >= lpValue) return 0;
                    lpValue -= deficit;
                }
            } catch {
                // FAIL-CLOSED : hedgeManager present mais getHedgeData() en echec -> on ne peut pas evaluer
                // correctement. Retourner la valeur LP seule SOUS-ESTIMERAIT le denominateur du mint de shares
                // (hedge net positif ignore). On revert ; mint/withdraw retenteront quand AAVE repondra.
                revert E73();
            }
        }

        return lpValue;
    }

    function lpPortfolioValue(address botModule) private view returns (uint256) {
        address module = botModule;
        if (module == address(0)) revert E73();
        try ISafetyBotNav(module).getOracleLpValueUsd() returns (uint256 valueUsd) {
            return valueUsd;
        } catch {
            revert E73();
        }
    }

    function requireHfMin(address pool, uint16 target) external view {
        (,,,,, uint256 hf) = IRiskAavePool(pool).getUserAccountData(address(this));
        if (hf < uint256(target) * 1e14) revert BadHealthFactor();
    }

    function completeFlashRepayment(
        address manager,
        address poolAddress,
        address stable,
        address volatileToken,
        address collateral,
        address router,
        uint24 swapPoolFee,
        uint8 dec0,
        uint8 dec1,
        uint16 slippage,
        uint16 threshold,
        uint256 flashOwed,
        uint256 targetHfBps
    ) external {
        IPolicyWithdrawalPool pool = IPolicyWithdrawalPool(poolAddress);
        IERC20 usdc = IERC20(stable);
        IERC20 weth = IERC20(volatileToken);
        address aTokenUsdc = collateral;
        ISwapRouter swapRouter = ISwapRouter(router);
        (uint256 amountInMaximum, uint160 sqrtPriceLimitX96) =
            DnDepositLib.aaveOracleMaxToken1ForToken0(
                flashOwed, manager, dec0, dec1, slippage, address(usdc) < address(weth)
            );
        uint256 budget = usdc.balanceOf(address(this));
        (uint256 capped, uint256 toWithdraw) = DnDepositLib.aaveHfSafeSwapBudget(
            budget, amountInMaximum, address(pool), address(aTokenUsdc), threshold, targetHfBps
        );
        if (toWithdraw > 0) pool.withdraw(address(usdc), toWithdraw, address(this));
        // The oracle bound is an upper limit, not the amount the router must spend.
        // Aave may safely release less while the exact-output swap still fits the HF budget.
        if (capped == 0 || usdc.balanceOf(address(this)) < capped) revert HedgeCheck(58);
        if (
            DnDepositLib.aaveExactOutput(
                    address(swapRouter), address(usdc), address(weth), swapPoolFee, flashOwed, capped, sqrtPriceLimitX96
                ) != flashOwed
        ) revert HedgeCheck(59);
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

    function payRangeBounty(address treasuryAddress, address keeper) external {
        if (treasuryAddress == address(0)) return;
        try IPolicyBountyTreasury(treasuryAddress).payKeeperBounty(keeper) {} catch {}
    }
}
