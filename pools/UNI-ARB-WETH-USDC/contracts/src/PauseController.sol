// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;
import "./AutonomousErrors.sol";

interface IPauseGovernanceVault {
    function installationSealed() external view returns (bool);
    function reportSafetyClosure() external;
    function totalShares() external view returns (uint256);
    function getPendingDepositsCount() external view returns (uint256);
    function rangeManager() external view returns (address);
}

interface IPauseRange {
    function getOwnerPositions() external view returns (uint256[] memory);
    function strategyEngine() external view returns (address);
}
interface IPauseEngine { function hedgeManager() external view returns (address); }
interface IPoolMarketRisk { function validateAdditionalCapital(bytes calldata configuration,uint256 incomingUsdE8) external view; }
interface IPauseHedge { function getWethDebt() external view returns (uint256); }

/// @notice Immutable Safe authority; bounded incident pauses and an irreversible exit-only circuit breaker.
/// @dev No custody, arbitrary calls, governance rotation or guardian rearm bypass.
contract PauseController {
    error E_PAUSED();
    uint64 public maxPoolTvlUsd=5_000_000;
    event PoolTvlCapUpdated(uint64 capUsd);
    error E_COOLDOWN();
    error E_ACTIVE();
    address public immutable safe;
    address private immutable _installer;
    address public vault;
    address public technicalGovernance;
    address public governanceRegistry;
    address public governanceExposureJournal;
    address public depositorVoting;
    address public feeRebate;
    address public marketRiskGate;
    bytes public marketRiskConfiguration;
    bool public governanceActivated;
    uint8 public lifecycle; // Active, Retiring, Retired. Retirement is not exit-only.
    uint8 public safetyReason;
    bytes32 public safetyEvidence;
    uint64 public immutable depositCooldown;
    uint64 public inflowsPausedUntil;
    uint64 public withdrawalsPausedUntil;
    uint64 public nextWithdrawalPauseAt;
    bool public exitOnly;
    uint64 public constant MIN_PAUSE = 1 hours;
    uint64 public constant MAX_INFLOWS_PAUSE = 7 days;
    uint64 public constant MAX_WITHDRAW_PAUSE = 48 hours;
    uint64 public constant WITHDRAWAL_RECOVERY_WINDOW = 24 hours;
    uint64 public constant MIN_DEPOSIT_COOLDOWN = 4 hours;
    uint64 public constant MAX_DEPOSIT_COOLDOWN = 7 days;
    event InflowsPaused(uint64 until);
    event InflowsUnpaused();
    event WithdrawalsPaused(uint64 until);
    event WithdrawalsUnpaused();
    event ExitOnlyActivated(address indexed caller);
    event VaultBound(address indexed vault);
    event GovernanceInstalled(address indexed governance, address registry, address voting, address journal, address rebate);
    event PoolLifecycleChanged(uint8 state, bool safety, bytes32 evidence);
    modifier onlySafe() {
        require(msg.sender == safe, AutonomousCheck(0x486e7412));
        _;
    }

    constructor(address safe_, uint64 cooldown_) {
        require(safe_ != address(0), AutonomousCheck(0xa8e86b08));
        require(cooldown_ >= MIN_DEPOSIT_COOLDOWN && cooldown_ <= MAX_DEPOSIT_COOLDOWN, AutonomousCheck(0x5e0746c8));
        safe = safe_;
        _installer = msg.sender;
        depositCooldown = cooldown_;
    }

    /// @notice Installation-only binding; no recurring authority for the creator.
    function bindVault(address vault_) external {
        require((msg.sender == safe || msg.sender == _installer) && vault == address(0)
            && vault_.code.length > 0, AutonomousCheck(0x9a247fa1));
        (bool ok, bytes memory data) = vault_.staticcall(abi.encodeWithSignature("pauseController()"));
        require(ok && data.length == 32 && abi.decode(data, (address)) == address(this),
            AutonomousCheck(0x2c7e43eb));
        vault = vault_;
        emit VaultBound(vault_);
    }

    function installGovernance(address governance, address registry, address voting, address journal, address rebate)
        external {
        require((msg.sender == safe || msg.sender == _installer) && technicalGovernance == address(0)
            && vault != address(0) && !IPauseGovernanceVault(vault).installationSealed()
            && governance.code.length != 0 && registry.code.length != 0 && voting.code.length != 0
            && journal.code.length != 0 && rebate.code.length != 0, AutonomousCheck(0x9a247fa1));
        technicalGovernance = governance;
        governanceRegistry = registry;
        depositorVoting = voting;
        governanceExposureJournal = journal;
        feeRebate = rebate;
        emit GovernanceInstalled(governance, registry, voting, journal, rebate);
    }

    function installMarketRiskGate(address gate,bytes calldata configuration) external {
        require((msg.sender==safe||msg.sender==_installer)&&marketRiskGate==address(0)
            &&vault!=address(0)&&!IPauseGovernanceVault(vault).installationSealed()
            &&gate.code.length!=0&&configuration.length!=0&&configuration.length<=16384,
            AutonomousCheck(0x9a247fa1));
        marketRiskGate=gate;
        marketRiskConfiguration=configuration;
    }

    /// @notice Admission ceiling only: appreciation, queued deposits, exits and maintenance remain unaffected.
    /// @dev Raising this cap is an explicit Safe decision after liquidity qualification, never an automatic TVL reaction.
    function setMaxPoolTvlUsd(uint64 capUsd) external {
        require(msg.sender==safe||(msg.sender==_installer&&(vault==address(0)
            ||!IPauseGovernanceVault(vault).installationSealed())),AutonomousCheck(0x486e7412));
        require(capUsd>=50_000&&capUsd<=1_000_000_000,AutonomousCheck(0x9a247fa1));
        maxPoolTvlUsd=capUsd;emit PoolTvlCapUpdated(capUsd);
    }

    /// @notice Admission checks apply to new invested capital only, never exits or HF repair.
    function requireAdditionalCapital(uint256 incomingUsdE8) external view {
        address gate=marketRiskGate;
        if(gate!=address(0)) IPoolMarketRisk(gate).validateAdditionalCapital(marketRiskConfiguration,incomingUsdE8);
    }

    function governanceHooks() external view returns (address journal, address voting, address rebate) {
        return (governanceExposureJournal, depositorVoting, feeRebate);
    }

    function applyLifecycleFromVault(uint8 action, bytes32 decisionId) external {
        require(msg.sender == vault && technicalGovernance != address(0), AutonomousCheck(0x486e7412));
        if (action == 0) {
            require(!governanceActivated && lifecycle == 0 && !exitOnly, AutonomousCheck(0x486e7412));
            governanceActivated = true;
        } else if (action == 1) {
            require(governanceActivated && lifecycle == 0 && decisionId != bytes32(0), AutonomousCheck(0x486e7412));
            lifecycle = 1;
            emit PoolLifecycleChanged(1, false, decisionId);
        } else {
            IPauseGovernanceVault source = IPauseGovernanceVault(vault);
            require(action == 2 && lifecycle == 1 && source.totalShares() <= 1_000_000
                && source.getPendingDepositsCount() == 0, AutonomousCheck(0x9a247fa1));
            IPauseRange rm = IPauseRange(source.rangeManager());
            require(rm.getOwnerPositions().length == 0, AutonomousCheck(0x9a247fa1));
            address hedge = IPauseEngine(rm.strategyEngine()).hedgeManager();
            require(hedge == address(0) || IPauseHedge(hedge).getWethDebt() == 0, AutonomousCheck(0x9a247fa1));
            lifecycle = 2;
            emit PoolLifecycleChanged(2, exitOnly, safetyEvidence);
        }
    }

    function closeForSafety(uint8 reason, bytes32 evidence) external onlySafe {
        require(technicalGovernance != address(0) && reason >= 1 && reason <= 3 && evidence != bytes32(0),
            AutonomousCheck(0x2c7e43eb));
        if (exitOnly) return;
        safetyReason = reason;
        safetyEvidence = evidence;
        exitOnly = true;
        lifecycle = 1;
        // A chain-local, bounded notification; never waits for a vote or remote acknowledgement.
        IPauseGovernanceVault(vault).reportSafetyClosure();
        emit ExitOnlyActivated(msg.sender);
        emit PoolLifecycleChanged(1, true, evidence);
    }

    function pauseInflows() external onlySafe {
        _pauseInflows(MAX_INFLOWS_PAUSE);
    }

    function pauseInflowsFor(uint64 duration) external onlySafe {
        _pauseInflows(duration);
    }

    function _pauseInflows(uint64 duration) private {
        require(!exitOnly && duration >= MIN_PAUSE && duration <= MAX_INFLOWS_PAUSE, AutonomousCheck(0x2e861dfb));
        if (block.timestamp < inflowsPausedUntil) revert E_ACTIVE();
        inflowsPausedUntil = uint64(block.timestamp) + duration;
        emit InflowsPaused(inflowsPausedUntil);
    }

    function pauseWithdrawals() external onlySafe {
        _pauseWithdrawals(MAX_WITHDRAW_PAUSE);
    }

    function pauseWithdrawalsFor(uint64 duration) external onlySafe {
        _pauseWithdrawals(duration);
    }

    function _pauseWithdrawals(uint64 duration) private {
        require(duration >= MIN_PAUSE && duration <= MAX_WITHDRAW_PAUSE, AutonomousCheck(0x2e861dfb));
        require(block.timestamp >= nextWithdrawalPauseAt, AutonomousCheck(0x0aa99097));
        if (block.timestamp < withdrawalsPausedUntil) revert E_ACTIVE();
        withdrawalsPausedUntil = uint64(block.timestamp) + duration;
        nextWithdrawalPauseAt = withdrawalsPausedUntil + WITHDRAWAL_RECOVERY_WINDOW;
        if (inflowsPausedUntil < withdrawalsPausedUntil) {
            inflowsPausedUntil = withdrawalsPausedUntil;
            emit InflowsPaused(inflowsPausedUntil);
        }
        emit WithdrawalsPaused(withdrawalsPausedUntil);
    }

    function unpauseInflows() external onlySafe {
        require(!exitOnly && block.timestamp >= withdrawalsPausedUntil, AutonomousCheck(0x7caa0aa9));
        inflowsPausedUntil = 0;
        emit InflowsUnpaused();
    }

    function unpauseWithdrawals() external onlySafe {
        require(block.timestamp < withdrawalsPausedUntil, AutonomousCheck(0xaecd4fd1));
        withdrawalsPausedUntil = 0;
        nextWithdrawalPauseAt = uint64(block.timestamp) + WITHDRAWAL_RECOVERY_WINDOW;
        emit WithdrawalsUnpaused();
    }

    function activateExitOnly() external onlySafe {
        require(technicalGovernance == address(0), AutonomousCheck(0x486e7412));
        require(!exitOnly, AutonomousCheck(0x18bb4c57));
        exitOnly = true;
        emit ExitOnlyActivated(msg.sender);
    }

    function inflowsPaused() external view returns (bool) {
        return _inflowsStopped();
    }

    function withdrawalsPaused() external view returns (bool) {
        return block.timestamp < withdrawalsPausedUntil;
    }

    function requireInflowsActive() external view {
        if (_inflowsStopped()) revert E_PAUSED();
    }

    function _inflowsStopped() private view returns (bool) {
        return exitOnly || lifecycle != 0 || block.timestamp < inflowsPausedUntil
            || (technicalGovernance != address(0) && !governanceActivated);
    }

    function requireWithdrawalsActiveAfter(uint256 lastDepositTime) external view {
        if (block.timestamp < withdrawalsPausedUntil) revert E_PAUSED();
        if (!exitOnly && lastDepositTime != 0 && block.timestamp < lastDepositTime + depositCooldown) {
            revert E_COOLDOWN();
        }
    }
}
