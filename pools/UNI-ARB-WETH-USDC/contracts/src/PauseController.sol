// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @notice Bounded circuit breaker. It never holds or moves funds.
/// @dev Phase 1: Safe is both governance and pause guardian.
///      Phase 2: governance can move to a timelock while the Safe remains the fast pause guardian.
contract PauseController {
    error E_PAUSED();
    error E_COOLDOWN();
    error E_ACTIVE();

    address public immutable safe;
    address public governance;
    address public pendingGovernance;
    address public pauseGuardian;
    uint64 public inflowsPausedUntil;
    uint64 public withdrawalsPausedUntil;
    uint64 public depositCooldown;

    uint64 public constant MAX_INFLOWS_PAUSE = 7 days;
    uint64 public constant MAX_WITHDRAW_PAUSE = 48 hours;
    uint64 public constant MIN_DEPOSIT_COOLDOWN = 4 hours;
    uint64 public constant MAX_DEPOSIT_COOLDOWN = 7 days;

    event InflowsPaused(uint64 until);
    event InflowsUnpaused();
    event WithdrawalsPaused(uint64 until);
    event WithdrawalsUnpaused();
    event DepositCooldownUpdated(uint64 oldCooldown, uint64 newCooldown);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceTransferStarted(address indexed governance, address indexed pendingGovernance);
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    modifier onlyGovernance() {
        require(msg.sender == governance, "E_GOV");
        _;
    }

    modifier onlyPauseGuardianOrGovernance() {
        require(msg.sender == pauseGuardian || msg.sender == governance, "E_PAUSE");
        _;
    }

    constructor(address _safe, uint64 _depositCooldown) {
        require(_safe != address(0), "E_ZERO");
        safe = _safe;
        governance = _safe;
        pauseGuardian = _safe;
        _setDepositCooldown(_depositCooldown);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "E_ZERO");
        pendingGovernance = newGovernance;
        emit GovernanceTransferStarted(governance, newGovernance);
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "E_PENDING_GOV");
        address oldGovernance = governance;
        governance = msg.sender;
        pendingGovernance = address(0);
        emit GovernanceTransferred(oldGovernance, msg.sender);
    }

    function setPauseGuardian(address newGuardian) external onlyGovernance {
        require(newGuardian != address(0), "E_ZERO");
        address oldGuardian = pauseGuardian;
        pauseGuardian = newGuardian;
        emit PauseGuardianUpdated(oldGuardian, newGuardian);
    }

    function setDepositCooldown(uint64 _depositCooldown) external onlyGovernance {
        _setDepositCooldown(_depositCooldown);
    }

    function _setDepositCooldown(uint64 _depositCooldown) internal {
        require(_depositCooldown >= MIN_DEPOSIT_COOLDOWN && _depositCooldown <= MAX_DEPOSIT_COOLDOWN, "E_COOLDOWN");
        uint64 oldCooldown = depositCooldown;
        depositCooldown = _depositCooldown;
        emit DepositCooldownUpdated(oldCooldown, _depositCooldown);
    }

    function pauseInflows() external onlyPauseGuardianOrGovernance {
        if (block.timestamp < inflowsPausedUntil) revert E_ACTIVE();
        uint64 until = uint64(block.timestamp) + MAX_INFLOWS_PAUSE;
        inflowsPausedUntil = until;
        emit InflowsPaused(until);
    }

    function pauseWithdrawals() external onlyPauseGuardianOrGovernance {
        if (block.timestamp < withdrawalsPausedUntil) revert E_ACTIVE();
        uint64 until = uint64(block.timestamp) + MAX_WITHDRAW_PAUSE;
        withdrawalsPausedUntil = until;
        if (inflowsPausedUntil < until) {
            inflowsPausedUntil = until;
            emit InflowsPaused(until);
        }
        emit WithdrawalsPaused(until);
    }

    function unpauseInflows() external onlyGovernance {
        require(block.timestamp >= withdrawalsPausedUntil, "E_WITHDRAWALS");
        inflowsPausedUntil = 0;
        emit InflowsUnpaused();
    }

    function unpauseWithdrawals() external onlyGovernance {
        withdrawalsPausedUntil = 0;
        emit WithdrawalsUnpaused();
    }

    function inflowsPaused() external view returns (bool) {
        return block.timestamp < inflowsPausedUntil;
    }

    function withdrawalsPaused() external view returns (bool) {
        return block.timestamp < withdrawalsPausedUntil;
    }

    function requireInflowsActive() external view {
        if (block.timestamp < inflowsPausedUntil) revert E_PAUSED();
    }

    function requireWithdrawalsActive() external view {
        if (block.timestamp < withdrawalsPausedUntil) revert E_PAUSED();
    }

    function requireWithdrawalsActiveAfter(uint256 lastDepositTime) external view {
        if (block.timestamp < withdrawalsPausedUntil) revert E_PAUSED();
        if (lastDepositTime != 0 && block.timestamp < lastDepositTime + uint256(depositCooldown)) revert E_COOLDOWN();
    }
}
