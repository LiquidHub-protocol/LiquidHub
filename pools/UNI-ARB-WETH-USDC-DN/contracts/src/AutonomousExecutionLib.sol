// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import "./RangeOperations.sol";
import "./interfaces/IRangeStrategyEngine.sol";
import "./AutonomousErrors.sol";
interface IExecutionRange {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function config() external view returns (RangeOperations.RangeConfig memory);
    function priceCache() external view returns (RangeOperations.PriceCache memory);
    function initMultiSwapTvl() external view returns (uint256);
}
interface IExecutionBot { function botAddress() external view returns (address); }
/// @notice Linked canonical guards. Caller identity and every state read remain in the RangeManager context.
library AutonomousExecutionLib {
    error E40();
    function validateEngine(address engine, address bot, address pool, address hedge, bool dn)
        external view returns (address operator) {
        operator = IExecutionBot(bot).botAddress();
        IRangeStrategyEngine candidate = IRangeStrategyEngine(engine);
        if (operator == address(0) || candidate.rangeManager() != address(this) || candidate.pool() != pool
            || candidate.hedgeManager() != hedge
            || (dn ? candidate.profile() != IRangeStrategyEngine.StrategyProfile.DELTA_NEUTRAL
                   : candidate.profile() == IRangeStrategyEngine.StrategyProfile.DELTA_NEUTRAL)) revert E40();
    }
    function currentDecision(address engine) external view returns (IRangeStrategyEngine.Decision memory decision) {
        if (engine == address(0)) revert E40();
        decision = IRangeStrategyEngine(engine).previewDecision();
        return IRangeStrategyEngine(engine).validateDecision(decision.decisionHash);
    }
    function validateDecision(address engine, bytes32 expectedHash, bool delayMainBot, uint8 action)
        external view returns (IRangeStrategyEngine.Decision memory decision) {
        decision = IRangeStrategyEngine(engine).validateDecision(expectedHash);
        require(uint8(decision.action) == action, "E90");
        if (delayMainBot) {
            IRangeStrategyEngine.Telemetry memory telemetry = IRangeStrategyEngine(engine).currentTelemetry();
            require(block.timestamp >= uint256(telemetry.checkpointTimestamp) + 1 minutes, "E03");
        }
    }

}
