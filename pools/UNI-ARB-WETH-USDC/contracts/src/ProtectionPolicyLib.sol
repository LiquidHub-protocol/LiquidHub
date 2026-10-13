// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import "./RangeOperations.sol";
import "./AutonomousErrors.sol";
interface IProtectionVault { function installationSealed() external view returns (bool); }
library ProtectionPolicyLib {
    struct OverrideState { uint64 until; uint64 nextAt; bool twap; bool mev; uint16 ticks; }
    event TemporaryProtectionOverride(uint64 until, bool twap, bool mev, uint16 ticks);
    function configure(RangeOperations.ProtectionConfig storage cfg, OverrideState storage state,
        address vault, bool twap, bool mev, uint16 ticks) external {
        require(ticks > 0 && ticks <= 1000, AutonomousCheck(0x6e879f86));
        if (!IProtectionVault(vault).installationSealed()) {
            cfg.sandwichDetectionEnabled = twap; cfg.mevProtectionEnabled = mev; cfg.maxTwapDeviationTicks = ticks;
        } else {
            require(block.timestamp >= state.until && block.timestamp >= state.nextAt, AutonomousCheck(0x6ec26e43));
            state.twap = twap; state.mev = mev; state.ticks = ticks;
            state.until = uint64(block.timestamp + 48 hours); state.nextAt = state.until + 24 hours;
            emit TemporaryProtectionOverride(state.until, twap, mev, ticks);
        }
    }
}
