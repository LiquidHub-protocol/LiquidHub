// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import "./AutonomousErrors.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
/// @notice Bounded Safe DN policy in the HedgeManager's storage. No calls or transfers of principal.
library HedgeRiskPolicyLib {
    error HedgeCheck(uint8 code);
    event InstallationSealed();
    event OperationalHfBufferUpdated(uint16 bufferBps);
    event HfRepairConfigUpdated(uint16 triggerBps, uint64 bountyMinUsd);
    event DonationDustUpdated(uint256 amount);
    struct State {
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
    function seal(State storage state) external {
        require(!state.installationSealed && state.rangeManager.code.length > 0 && state.treasuryAddress.code.length > 0, AutonomousCheck(0x0b2cf59a));
        require(state.maxHedgeDeviationBps > 0, AutonomousCheck(0x306dc1de));
        state.installationSealed = true;
        state.initialHfTargetBps = state.reserveHfTargetBps; state.initialHfBufferBps = state.operationalHfBufferBps;
        state.initialHfRepairTriggerBps = state.hfRepairTriggerBps; emit InstallationSealed();


    }
    function configure(State storage state, address[4] calldata addrs, uint16[4] calldata params) external {
        if (state.installationSealed) {
            require(addrs[1] == state.treasuryAddress && params[0] == state.adjustHedgeBps && params[3] == state.liqThresholdBps, AutonomousCheck(0x6ad8e783));
            require(params[2] >= state.initialHfTargetBps, AutonomousCheck(0x62d3fc4a));
        }
        address currentRangeManager = state.rangeManager;
        if (
            addrs[0] == address(0) || addrs[2] == address(0) || addrs[3] == address(0)
                || (
                    currentRangeManager != address(0)
                        && (
                            addrs[0] != currentRangeManager || addrs[2] != address(state.lpPositionManager)
                                || addrs[3] != address(state.lpPool)
                        )
                )
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
    function buffer(State storage state, uint16 bufferBps) external {
        require(!state.installationSealed || bufferBps >= state.initialHfBufferBps, AutonomousCheck(0xb7ba4c0b));
        if (uint256(state.reserveHfTargetBps) + bufferBps > 30000) revert HedgeCheck(64);
        state.operationalHfBufferBps = bufferBps;
        emit OperationalHfBufferUpdated(bufferBps);

    }
    function repair(State storage state, uint16 triggerBps, uint64 bountyMinUsd) external {
        require(!state.installationSealed || bountyMinUsd == state.hfRepairBountyMinUsd, AutonomousCheck(0x6ad8e783));
        require(!state.installationSealed || triggerBps >= state.initialHfRepairTriggerBps, AutonomousCheck(0xd919dd26));
        if (triggerBps <= 10000 || triggerBps >= state.reserveHfTargetBps) revert HedgeCheck(62);
        if (bountyMinUsd < 1e8 || bountyMinUsd > 1_000_000e8) revert HedgeCheck(63);
        state.hfRepairTriggerBps = triggerBps;
        state.hfRepairBountyMinUsd = bountyMinUsd;
        emit HfRepairConfigUpdated(triggerBps, bountyMinUsd);

    }
    function critical(State storage state, uint16 thresholdBps) external {
        require(!state.installationSealed, AutonomousCheck(0x9a247fa1));
        if (thresholdBps < 250 || thresholdBps > 3000 || thresholdBps < state.adjustHedgeBps + 250) {
            revert HedgeCheck(54);
        }
        state.criticalHedgeBps = thresholdBps;

    }
    function dust(State storage state, uint256 _donationDustToken0, uint8 volatileDecimals) external {
        require(!state.installationSealed, AutonomousCheck(0x9a247fa1));
        uint256 maxDust = volatileDecimals >= 3 ? 10 ** (uint256(volatileDecimals) - 3) : 1;
        if (_donationDustToken0 == 0 || _donationDustToken0 > maxDust) revert HedgeCheck(40);
        state.donationDustToken0 = _donationDustToken0;
        emit DonationDustUpdated(_donationDustToken0);

    }
    function cooldown(State storage state, uint32 _cooldownSeconds) external {
        require(!state.installationSealed, AutonomousCheck(0x9a247fa1));
        if (_cooldownSeconds > 86400) revert HedgeCheck(36);
        state.hedgeAdjustCooldown = _cooldownSeconds;

    }
    function deviation(State storage state, uint16 _bps) external {
        if (_bps == 0 || _bps > 1000) revert HedgeCheck(37);
        state.maxHedgeDeviationBps = _bps;

    }
}
