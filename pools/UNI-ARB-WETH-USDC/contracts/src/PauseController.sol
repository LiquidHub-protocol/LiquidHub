// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import "./AutonomousErrors.sol";

/// @notice Immutable Safe authority; bounded incident pauses and an irreversible exit-only circuit breaker.
/// @dev No custody, arbitrary calls, governance rotation or guardian rearm bypass.
contract PauseController {
    error E_PAUSED(); error E_COOLDOWN(); error E_ACTIVE();
    address public immutable safe;
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
    event InflowsPaused(uint64 until); event InflowsUnpaused();
    event WithdrawalsPaused(uint64 until); event WithdrawalsUnpaused();
    event ExitOnlyActivated(address indexed caller);
    modifier onlySafe() { require(msg.sender == safe, AutonomousCheck(0x486e7412)); _; }
    constructor(address safe_, uint64 cooldown_) {
        require(safe_ != address(0), AutonomousCheck(0xa8e86b08));
        require(cooldown_ >= MIN_DEPOSIT_COOLDOWN && cooldown_ <= MAX_DEPOSIT_COOLDOWN, AutonomousCheck(0x5e0746c8));
        safe = safe_; depositCooldown = cooldown_;
    }
    function pauseInflows() external onlySafe { _pauseInflows(MAX_INFLOWS_PAUSE); }
    function pauseInflowsFor(uint64 duration) external onlySafe { _pauseInflows(duration); }
    function _pauseInflows(uint64 duration) private {
        require(!exitOnly && duration >= MIN_PAUSE && duration <= MAX_INFLOWS_PAUSE, AutonomousCheck(0x2e861dfb));
        if (block.timestamp < inflowsPausedUntil) revert E_ACTIVE();
        inflowsPausedUntil = uint64(block.timestamp) + duration;
        emit InflowsPaused(inflowsPausedUntil);
    }
    function pauseWithdrawals() external onlySafe { _pauseWithdrawals(MAX_WITHDRAW_PAUSE); }
    function pauseWithdrawalsFor(uint64 duration) external onlySafe { _pauseWithdrawals(duration); }
    function _pauseWithdrawals(uint64 duration) private {
        require(duration >= MIN_PAUSE && duration <= MAX_WITHDRAW_PAUSE, AutonomousCheck(0x2e861dfb));
        require(block.timestamp >= nextWithdrawalPauseAt, AutonomousCheck(0x0aa99097));
        if (block.timestamp < withdrawalsPausedUntil) revert E_ACTIVE();
        withdrawalsPausedUntil = uint64(block.timestamp) + duration;
        nextWithdrawalPauseAt = withdrawalsPausedUntil + WITHDRAWAL_RECOVERY_WINDOW;
        if (inflowsPausedUntil < withdrawalsPausedUntil) {
            inflowsPausedUntil = withdrawalsPausedUntil; emit InflowsPaused(inflowsPausedUntil);
        }
        emit WithdrawalsPaused(withdrawalsPausedUntil);
    }
    function unpauseInflows() external onlySafe {
        require(!exitOnly && block.timestamp >= withdrawalsPausedUntil, AutonomousCheck(0x7caa0aa9));
        inflowsPausedUntil = 0; emit InflowsUnpaused();
    }
    function unpauseWithdrawals() external onlySafe {
        require(block.timestamp < withdrawalsPausedUntil, AutonomousCheck(0xaecd4fd1));
        withdrawalsPausedUntil = 0;
        nextWithdrawalPauseAt = uint64(block.timestamp) + WITHDRAWAL_RECOVERY_WINDOW;
        emit WithdrawalsUnpaused();
    }
    function activateExitOnly() external onlySafe {
        require(!exitOnly, AutonomousCheck(0x18bb4c57)); exitOnly = true; emit ExitOnlyActivated(msg.sender);
    }
    function inflowsPaused() external view returns (bool) { return exitOnly || block.timestamp < inflowsPausedUntil; }
    function withdrawalsPaused() external view returns (bool) { return block.timestamp < withdrawalsPausedUntil; }
    function requireInflowsActive() external view { if (exitOnly || block.timestamp < inflowsPausedUntil) revert E_PAUSED(); }
    function requireWithdrawalsActiveAfter(uint256 lastDepositTime) external view {
        if (block.timestamp < withdrawalsPausedUntil) revert E_PAUSED();
        if (!exitOnly && lastDepositTime != 0 && block.timestamp < lastDepositTime + depositCooldown) revert E_COOLDOWN();
    }
}
