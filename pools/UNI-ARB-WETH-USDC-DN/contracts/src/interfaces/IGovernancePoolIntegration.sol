// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

interface IGovernancePoolController {
    function requireAdditionalCapital(uint256 incomingUsdE8) external view;
    function technicalGovernance() external view returns (address);
    function governanceRegistry() external view returns (address);
    function governanceExposureJournal() external view returns (address);
    function depositorVoting() external view returns (address);
    function feeRebate() external view returns (address);
    function governanceHooks() external view returns (address, address, address);
    function lifecycle() external view returns (uint8);
    function applyLifecycleFromVault(uint8 action, bytes32 decisionId) external;
    function activateFromVault() external;
    function retireFromVault(bytes32 decisionId) external;
    function finalizeFromVault() external;
}

interface IGovernancePoolRegistry {
    function markPoolStarted(address vault) external;
    function notifySafetyClosure() external;
}

interface IExposureJournalHook {
    function recordExposure(address wallet, uint256 shares, uint256 creditedUsdE8, bool withdrawal) external;
}

interface IDepositorSharesHook {
    function recordShares(address wallet, uint256 balance) external;
}

interface IFeeRebateHook {
    function setShares(address wallet, uint256 balance) external;
    function shares(address wallet) external view returns (uint256);
    function recordFees(uint256 gross0, uint256 gross1, uint256 commission0, uint256 commission1) external;
}

interface IEngineVotingInstallation {
    function installDepositorVoting(address voting) external;
    function installDepositorVoting(address voting, uint32[12] calldata bounds) external;
}

interface IRetiringHedge {
    function getWethDebt() external view returns (uint256);
    function getPositionDetails() external view returns (uint256, uint256, uint256, uint256);
}
