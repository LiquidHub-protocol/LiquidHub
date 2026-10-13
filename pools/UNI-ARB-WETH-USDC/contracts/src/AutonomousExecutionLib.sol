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
    struct DepositContext {
        uint256 deposit0; uint256 deposit1; address token0; address token1; bool input0;
        bool expectedZero; uint256 expected; uint256 submitted;
        RangeOperations.RangeConfig cfg; RangeOperations.PriceCache cache;
    }
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
    function validateDeposit(uint256 deposit0, uint256 deposit1, uint256[] calldata amounts, uint256[] calldata minima,
        address input, address output) external view {
        require(amounts.length == minima.length, "len");
        IExecutionRange rm = IExecutionRange(address(this)); DepositContext memory c;
        c.deposit0 = deposit0; c.deposit1 = deposit1;
        c.token0 = rm.token0(); c.token1 = rm.token1(); c.input0 = input == c.token0;
        c.cfg = rm.config(); c.cache = rm.priceCache();
        (c.expectedZero, c.expected) = RangeOperations.depositSwapParams(address(this), deposit0, deposit1);
        if (amounts.length > 0) {
            require((input == c.token0 && output == c.token1) || (input == c.token1 && output == c.token0), "E43");
            uint256 swapUsd = RangeOperations.validateMinOutsAgainstOracle(c.input0, amounts, minima, c.cache, c.cfg, rm.initMultiSwapTvl());
            uint256 depositUsd = c.deposit0 * c.cache.price0 / (10 ** c.cfg.token0Decimals) + c.deposit1 * c.cache.price1 / (10 ** c.cfg.token1Decimals);
            require(swapUsd <= depositUsd, AutonomousCheck(0xb3deca25));
            for (uint256 i; i < amounts.length; ++i) c.submitted += amounts[i];
            require(c.submitted <= (c.input0 ? c.deposit0 : c.deposit1), AutonomousCheck(0xa487a9d2));
        }
        if (c.expected == 0) { require(c.submitted == 0, "E93"); return; }
        require(c.input0 == c.expectedZero, "E94");
        uint256 tolerance = c.expected * c.cfg.toleranceBps / 10000;
        if (tolerance == 0) tolerance = 1;
        require(c.submitted + tolerance >= c.expected && c.submitted <= c.expected + tolerance, "E93");
    }
}
