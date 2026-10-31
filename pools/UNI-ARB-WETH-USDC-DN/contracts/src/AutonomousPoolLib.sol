// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;
import "./AutonomousErrors.sol";
interface IAutonomousPool { function installationSealed() external view returns (bool); }
interface IAutonomousPause { function exitOnly() external view returns (bool); }
/// @notice Small linked checks shared by the two immutable pool implementations.
library AutonomousPoolLib {
    function requireInstallation(address vault) internal view {
        require(!IAutonomousPool(vault).installationSealed(), AutonomousCheck(0x9a247fa1));
    }
    function requireOperating(address pc) internal view {
        require(!IAutonomousPause(pc).exitOnly(), AutonomousCheck(0x18bb4c57));
    }
}
