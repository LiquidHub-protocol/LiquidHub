// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @notice Safe-only bounded circuit breaker. It never holds or moves funds.
contract PauseController {
    error E_PAUSED();
    error E_COOLDOWN();

    address public immutable safe;
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

    modifier onlySafe() {
        require(msg.sender == safe, "E_SAFE");
        _;
    }

    constructor(address _safe, uint64 _depositCooldown) {
        require(_safe != address(0), "E_ZERO");
        safe = _safe;
        _setDepositCooldown(_depositCooldown);
    }

    function setDepositCooldown(uint64 _depositCooldown) external onlySafe {
        _setDepositCooldown(_depositCooldown);
    }

    function _setDepositCooldown(uint64 _depositCooldown) internal {
        require(_depositCooldown >= MIN_DEPOSIT_COOLDOWN && _depositCooldown <= MAX_DEPOSIT_COOLDOWN, "E_COOLDOWN");
        uint64 oldCooldown = depositCooldown;
        depositCooldown = _depositCooldown;
        emit DepositCooldownUpdated(oldCooldown, _depositCooldown);
    }

    function pauseInflows() external onlySafe {
        uint64 until = uint64(block.timestamp) + MAX_INFLOWS_PAUSE;
        inflowsPausedUntil = until;
        emit InflowsPaused(until);
    }

    function pauseWithdrawals() external onlySafe {
        uint64 until = uint64(block.timestamp) + MAX_WITHDRAW_PAUSE;
        withdrawalsPausedUntil = until;
        if (inflowsPausedUntil < until) {
            inflowsPausedUntil = until;
            emit InflowsPaused(until);
        }
        emit WithdrawalsPaused(until);
    }

    function unpauseInflows() external onlySafe {
        require(block.timestamp >= withdrawalsPausedUntil, "E_WITHDRAWALS");
        inflowsPausedUntil = 0;
        emit InflowsUnpaused();
    }

    function unpauseWithdrawals() external onlySafe {
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
