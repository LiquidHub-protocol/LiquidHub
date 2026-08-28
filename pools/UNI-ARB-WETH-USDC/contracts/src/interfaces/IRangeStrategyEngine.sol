// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Public, permissionless interface shared by Liquid Hub range engines, bots and keepers.
interface IRangeStrategyEngine {
    enum StrategyProfile {
        EXPOSED,
        DELTA_NEUTRAL,
        STABLE
    }

    enum DecisionMode {
        ANALYTIC_ONLY,
        HYBRID
    }

    enum Action {
        NO_ACTION,
        CHECKPOINT_ONLY,
        RANGE_REBALANCE,
        HEDGE_ONLY,
        RANGE_AND_HEDGE,
        HF_REPAIR
    }

    enum ReasonCode {
        NONE,
        INITIAL_MINT_REQUIRED,
        CHECKPOINT_DUE,
        DATA_STALE,
        ORACLE_GUARD,
        IN_RANGE_EDGE_LOW,
        OUT_OF_RANGE_EVALUATING,
        EDGE_SUFFICIENT,
        OUT_OF_RANGE_PERSISTENT,
        OUT_OF_RANGE_DEEP,
        COOLDOWN_ACTIVE,
        HEDGE_DRIFT,
        HEALTH_FACTOR_CRITICAL,
        AAVE_CONSTRAINT,
        NO_ADMISSIBLE_CANDIDATE,
        DECISION_ALREADY_EXECUTED
    }

    struct Decision {
        uint64 epoch;
        uint64 validUntil;
        Action action;
        ReasonCode reason;
        int24 currentTick;
        int24 currentTickLower;
        int24 currentTickUpper;
        int24 targetTickLower;
        int24 targetTickUpper;
        int32 currentScoreBps;
        int32 targetScoreBps;
        uint32 edgeBps;
        uint32 thresholdBps;
        uint32 uncertaintyBps;
        uint16 learningInfluenceBps;
        bool inRange;
        bool dataFresh;
        bytes32 decisionHash;
    }

    struct Telemetry {
        uint64 epoch;
        uint64 checkpointTimestamp;
        int24 spotTick;
        int24 tacticalTwapTick;
        int24 strategicTwapTick;
        int24 analyticalAnchorTick;
        uint24 fastVolatilityTicks;
        uint24 slowVolatilityTicks;
        uint24 upsideSemivarianceTicks;
        uint24 downsideSemivarianceTicks;
        uint16 observedFeeRateBps;
        uint16 forecastFeeRateBps;
        uint16 uncertaintyBps;
        uint8 candidateCount;
        uint8 admissibleCandidateCount;
        int32 expectedFeesBps;
        int32 transitionCostBps;
        int32 riskPenaltyBps;
        bool learningUpdated;
        bool learningFrozen;
        bytes32 decisionHash;
    }

    function rangeManager() external view returns (address);
    function pool() external view returns (address);
    function hedgeManager() external view returns (address);
    function treasury() external view returns (address);
    function profile() external view returns (StrategyProfile);
    function decisionMode() external view returns (DecisionMode);
    function strategyVersion() external pure returns (uint16);
    function checkpointDue() external view returns (bool);
    function checkpointMarketState() external returns (Decision memory decision);
    function previewDecision() external view returns (Decision memory decision);
    function validateDecision(bytes32 expectedHash) external view returns (Decision memory decision);
    function currentTelemetry() external view returns (Telemetry memory);
    function getExpertWeights()
        external
        view
        returns (uint16[4] memory trend, uint16[3] memory volatility, uint16[3] memory fees);
    function recordExecution(bytes32 decisionHash, Action action, address keeper) external;
}
