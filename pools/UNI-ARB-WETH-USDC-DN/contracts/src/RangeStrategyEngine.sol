// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IRangeStrategyEngine.sol";
import "./RangeOperations.sol";
import "./RangeStrategyDnLib.sol";

interface IRangeManagerStrategy {
    function vault() external view returns (address);
    function pool() external view returns (IUniswapV3Pool);
    function token0() external view returns (address);
    function positionManager() external view returns (INonfungiblePositionManager);
    function getOwnerPositions() external view returns (uint256[] memory);
    function refreshPriceCache() external;
    function isProtocolBotCaller(address caller) external view returns (bool);
    function priceCache()
        external
        view
        returns (uint128 price0, uint128 price1, uint160 sqrtP, int24 tick, uint64 timestamp, bool valid);
    function config()
        external
        view
        returns (
            uint24 fee,
            uint8 token0Decimals,
            uint8 token1Decimals,
            uint16 toleranceBps,
            uint24 maxSlippageBps,
            uint64 lastRebalanceTime,
            bool oraclesConfigured,
            uint32 maxPositions
        );
}

interface IStrategyCheckpointTreasury {
    function payStrategyCheckpointBounty(address keeper, uint64 epoch) external;
}

/// @title RangeStrategyEngine
/// @notice Deterministic, permissionless range intelligence for one Liquid Hub pool.
/// @dev The contract never holds funds. It combines bounded online estimators, an analytical anchor and a
///      fixed multi-scenario optimizer. Keepers submit no market data, score, debt target or ticks.
contract RangeStrategyEngine is Ownable, ReentrancyGuard, IRangeStrategyEngine {
    uint16 public constant override strategyVersion = 3;
    uint256 private constant BPS = 10_000;
    uint24 private constant MAX_VOLATILITY_TICKS = 20_000;
    uint256 private constant MAIN_BOT_KEEPER_DELAY = 60;

    error InvalidAddress();
    error InvalidConfiguration();
    error CheckpointNotDue();
    error KeeperWindowActive();
    error StrategyDataUnavailable();
    error UnauthorizedExecutionRecorder();
    error DecisionMismatch();

    struct InitialConfig {
        uint32 epochSeconds;
        uint32 tacticalHorizonSeconds;
        uint32 strategicHorizonSeconds;
        uint32 decisionValiditySeconds;
        uint32 rebalanceCooldownSeconds;
        uint32 maxOutOfRangeSeconds;
        uint16 fallbackRangeUpTicks;
        uint16 fallbackRangeDownTicks;
        uint16 minHalfRangeTicks;
        uint16 maxHalfRangeTicks;
        uint16 maxSkewBps;
        uint16 minEdgeBps;
        uint16 tailRiskBps;
        uint16 learningInfluenceBps;
        uint16 maxLearningInfluenceBps;
        uint16 maxCenterMoveBps;
        uint16 maxWidthChangeBps;
        uint16 transitionCostBps;
        uint16 dnMinStressHfBps;
        uint16 dnHedgeOnlyMinEdgeBps;
        uint16 dnMinHedgeDeltaBps;
    }

    struct StrategyConfig {
        uint32 epochSeconds;
        uint32 tacticalHorizonSeconds;
        uint32 strategicHorizonSeconds;
        uint32 decisionValiditySeconds;
        uint32 rebalanceCooldownSeconds;
        uint32 maxOutOfRangeSeconds;
        uint16 fallbackRangeUpTicks;
        uint16 fallbackRangeDownTicks;
        uint16 minHalfRangeTicks;
        uint16 maxHalfRangeTicks;
        uint16 maxSkewBps;
        uint16 minEdgeBps;
        uint16 tailRiskBps;
        uint16 maxCenterMoveBps;
        uint16 maxWidthChangeBps;
        uint16 transitionCostBps;
        uint16 dnMinStressHfBps;
        uint16 dnHedgeOnlyMinEdgeBps;
        uint16 dnMinHedgeDeltaBps;
    }

    struct MarketState {
        uint64 epoch;
        uint64 checkpointTimestamp;
        int24 canonicalTick;
        int24 tacticalTwapTick;
        int24 strategicTwapTick;
        int24 forecastTrendTicks;
        uint24 fastVolatilityTicks;
        uint24 slowVolatilityTicks;
        uint24 forecastVolatilityTicks;
        uint24 upsideSemivarianceTicks;
        uint24 downsideSemivarianceTicks;
        uint16 observedFeeRateBps;
        uint16 forecastFeeRateBps;
        uint16 uncertaintyBps;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
    }

    struct PositionState {
        bool exists;
        bool inRange;
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    struct EvaluationSummary {
        uint8 candidateCount;
        uint8 admissibleCount;
        int24 analyticalAnchorTick;
        int32 expectedFeesBps;
        int32 transitionCostBps;
        int32 riskPenaltyBps;
    }

    address public immutable override rangeManager;
    address public immutable override pool;
    address public immutable override hedgeManager;
    address public immutable override treasury;
    address private immutable _strategyToken0;
    StrategyProfile public immutable override profile;
    uint16 public immutable maxLearningInfluenceBps;
    int24 private immutable _strategyTickSpacing;

    StrategyConfig public strategyConfig;
    DecisionMode public override decisionMode;
    uint16 public learningInfluenceBps;
    uint64 private _lastCheckpointEpoch;
    uint64 internal _outOfRangeSince;
    uint64 private _hedgeRecoverySince;
    uint64 private _hedgeSignalSince;
    uint8 private _hedgeSignalDirection;
    bytes32 private _lastExecutedDecisionHash;
    Decision private _canonicalDecision;

    MarketState public marketState;
    Telemetry private _telemetry;

    uint16[4] private _trendWeights;
    uint16[3] private _volatilityWeights;
    uint16[3] private _feeWeights;
    int24[4] private _trendPredictions;
    uint24[3] private _volatilityPredictions;
    uint24[3] private _feePredictions;

    event MarketStateCheckpoint(
        uint64 indexed epoch,
        address indexed keeper,
        DecisionMode mode,
        Action action,
        ReasonCode reason,
        int24 currentTick,
        int24 targetTickLower,
        int24 targetTickUpper,
        int32 currentScoreBps,
        int32 targetScoreBps,
        uint32 edgeBps,
        uint32 thresholdBps,
        uint32 uncertaintyBps,
        uint16 learningInfluenceBps,
        bytes32 decisionHash
    );
    event StrategyExecutionRecorded(
        uint64 indexed epoch, bytes32 indexed decisionHash, Action action, address indexed keeper, address executor
    );
    event DecisionModeUpdated(DecisionMode mode);
    event LearningInfluenceUpdated(uint16 influenceBps);
    event StrategyRiskParametersUpdated(
        uint16 maxSkewBps, uint16 tailRiskBps, uint16 minEdgeBps, uint16 maxCenterMoveBps, uint16 maxWidthChangeBps
    );
    event StrategyRangeBoundsUpdated(uint16 fallbackUp, uint16 fallbackDown, uint16 minHalf, uint16 maxHalf);
    event DnHedgePolicyUpdated(uint16 hedgeOnlyMinEdgeBps, uint16 minHedgeDeltaBps);

    constructor(
        address _rangeManager,
        address _hedgeManager,
        address _treasury,
        StrategyProfile _profile,
        InitialConfig memory cfg
    ) {
        if (_rangeManager == address(0) || _treasury == address(0)) revert InvalidAddress();
        IRangeManagerStrategy rm = IRangeManagerStrategy(_rangeManager);
        address poolAddress = address(rm.pool());
        address vaultAddress = rm.vault();
        if (poolAddress == address(0) || vaultAddress == address(0)) revert InvalidAddress();
        if (_profile != StrategyProfile.DELTA_NEUTRAL || _hedgeManager == address(0) || _hedgeManager == _rangeManager)
        {
            revert InvalidConfiguration();
        }

        rangeManager = _rangeManager;
        pool = poolAddress;
        hedgeManager = _hedgeManager;
        treasury = _treasury;
        _strategyToken0 = rm.token0();
        profile = _profile;
        _strategyTickSpacing = IUniswapV3Pool(poolAddress).tickSpacing();
        if (_strategyTickSpacing <= 0) revert InvalidConfiguration();

        _validateInitialConfig(cfg);
        strategyConfig = StrategyConfig({
            epochSeconds: cfg.epochSeconds,
            tacticalHorizonSeconds: cfg.tacticalHorizonSeconds,
            strategicHorizonSeconds: cfg.strategicHorizonSeconds,
            decisionValiditySeconds: cfg.decisionValiditySeconds,
            rebalanceCooldownSeconds: cfg.rebalanceCooldownSeconds,
            maxOutOfRangeSeconds: cfg.maxOutOfRangeSeconds,
            fallbackRangeUpTicks: cfg.fallbackRangeUpTicks,
            fallbackRangeDownTicks: cfg.fallbackRangeDownTicks,
            minHalfRangeTicks: cfg.minHalfRangeTicks,
            maxHalfRangeTicks: cfg.maxHalfRangeTicks,
            maxSkewBps: cfg.maxSkewBps,
            minEdgeBps: cfg.minEdgeBps,
            tailRiskBps: cfg.tailRiskBps,
            maxCenterMoveBps: cfg.maxCenterMoveBps,
            maxWidthChangeBps: cfg.maxWidthChangeBps,
            transitionCostBps: cfg.transitionCostBps,
            dnMinStressHfBps: cfg.dnMinStressHfBps,
            dnHedgeOnlyMinEdgeBps: cfg.dnHedgeOnlyMinEdgeBps,
            dnMinHedgeDeltaBps: cfg.dnMinHedgeDeltaBps
        });
        maxLearningInfluenceBps = cfg.maxLearningInfluenceBps;
        learningInfluenceBps = cfg.learningInfluenceBps;
        decisionMode = DecisionMode.HYBRID;

        _trendWeights = [uint16(2500), 2500, 2500, 2500];
        _volatilityWeights = [uint16(3334), 3333, 3333];
        _feeWeights = [uint16(3334), 3333, 3333];
        _transferOwnership(vaultAddress);
    }

    function renounceOwnership() public pure override {
        revert InvalidAddress();
    }

    function _validateInitialConfig(InitialConfig memory cfg) private view {
        uint256 minWidth = uint256(uint24(_strategyTickSpacing)) * 5;
        if (
            cfg.epochSeconds < 300 || cfg.epochSeconds > 1 days || cfg.tacticalHorizonSeconds < 300
                || cfg.tacticalHorizonSeconds >= cfg.strategicHorizonSeconds || cfg.strategicHorizonSeconds > 7 days
                || cfg.decisionValiditySeconds != cfg.epochSeconds || cfg.rebalanceCooldownSeconds > 1 days
                || cfg.maxOutOfRangeSeconds < cfg.epochSeconds || cfg.maxOutOfRangeSeconds > 7 days
                || cfg.minHalfRangeTicks < minWidth || cfg.maxHalfRangeTicks <= cfg.minHalfRangeTicks
                || cfg.maxHalfRangeTicks > 5000 || cfg.fallbackRangeUpTicks < cfg.minHalfRangeTicks
                || cfg.fallbackRangeUpTicks > cfg.maxHalfRangeTicks || cfg.fallbackRangeDownTicks < cfg.minHalfRangeTicks
                || cfg.fallbackRangeDownTicks > cfg.maxHalfRangeTicks || cfg.maxSkewBps > 5000 || cfg.minEdgeBps == 0
                || cfg.minEdgeBps > 2000 || cfg.tailRiskBps < 100 || cfg.tailRiskBps > 5000
                || cfg.maxLearningInfluenceBps == 0 || cfg.maxLearningInfluenceBps > 5000 || cfg.learningInfluenceBps == 0
                || cfg.learningInfluenceBps > cfg.maxLearningInfluenceBps || cfg.maxCenterMoveBps > 10_000
                || cfg.maxWidthChangeBps > 10_000 || cfg.transitionCostBps > 1000 || cfg.dnMinStressHfBps < 11_000
                || cfg.dnMinStressHfBps > 30_000 || cfg.dnHedgeOnlyMinEdgeBps == 0 || cfg.dnHedgeOnlyMinEdgeBps > 5000
                || cfg.dnMinHedgeDeltaBps == 0 || cfg.dnMinHedgeDeltaBps > 2000
        ) revert InvalidConfiguration();
    }

    function checkpointDue() public view override returns (bool) {
        return uint64(block.timestamp / strategyConfig.epochSeconds) > _lastCheckpointEpoch;
    }

    function checkpointMarketState() external override nonReentrant returns (Decision memory decision) {
        StrategyConfig memory cfg = strategyConfig;
        uint64 epoch = uint64(block.timestamp / cfg.epochSeconds);
        if (epoch <= _lastCheckpointEpoch) revert CheckpointNotDue();

        IRangeManagerStrategy rm = IRangeManagerStrategy(rangeManager);
        if (
            rm.isProtocolBotCaller(msg.sender)
                && block.timestamp < uint256(epoch) * cfg.epochSeconds + MAIN_BOT_KEEPER_DELAY
        ) revert KeeperWindowActive();
        rm.refreshPriceCache();
        (uint128 price0, uint128 price1,, int24 liveTick,, bool valid) = rm.priceCache();
        if (!valid || price0 == 0 || price1 == 0) revert StrategyDataUnavailable();

        (int24 tacticalTick, int24 strategicTick) = RangeStrategyDnLib.canonicalTwaps(
            pool, epoch, cfg.epochSeconds, cfg.tacticalHorizonSeconds, cfg.strategicHorizonSeconds
        );
        uint256 feeGrowth0 = IUniswapV3Pool(pool).feeGrowthGlobal0X128();
        uint256 feeGrowth1 = IUniswapV3Pool(pool).feeGrowthGlobal1X128();
        uint64 previousTimestamp = marketState.checkpointTimestamp;
        int24 previousCanonicalTick = marketState.canonicalTick;
        uint64 elapsed = previousTimestamp == 0 ? 0 : uint64(block.timestamp) - previousTimestamp;
        int24 realizedMove = previousTimestamp == 0 ? int24(0) : _subTicks(tacticalTick, previousCanonicalTick);
        uint24 absoluteMove = _absTick(realizedMove);
        (, uint8 token0Decimals, uint8 token1Decimals,,,,,) = rm.config();
        uint16 observedFees = RangeStrategyDnLib.observedFeeRateBps(
            RangeStrategyDnLib.FeeRateInput({
                feeGrowth0: feeGrowth0,
                feeGrowth1: feeGrowth1,
                previousGrowth0: marketState.feeGrowthGlobal0X128,
                previousGrowth1: marketState.feeGrowthGlobal1X128,
                elapsed: elapsed,
                liveTick: liveTick,
                price0: price0,
                price1: price1,
                token0Decimals: token0Decimals,
                token1Decimals: token1Decimals,
                epochSeconds: cfg.epochSeconds,
                fallbackRangeDownTicks: cfg.fallbackRangeDownTicks,
                fallbackRangeUpTicks: cfg.fallbackRangeUpTicks,
                tickSpacing: _strategyTickSpacing
            })
        );

        bool learningUpdated = previousTimestamp != 0 && decisionMode == DecisionMode.HYBRID;
        if (learningUpdated) _updateExpertWeights(realizedMove, absoluteMove, observedFees);

        uint24 fastVol = _ewma(marketState.fastVolatilityTicks, absoluteMove, 5000);
        uint24 slowVol = _ewma(marketState.slowVolatilityTicks, absoluteMove, 2000);
        uint24 upside = _ewma(marketState.upsideSemivarianceTicks, realizedMove > 0 ? absoluteMove : 0, 3000);
        uint24 downside = _ewma(marketState.downsideSemivarianceTicks, realizedMove < 0 ? absoluteMove : 0, 3000);
        uint16 slowFees = uint16(_ewma(marketState.forecastFeeRateBps, observedFees, 2000));

        _setNextPredictions(
            realizedMove, tacticalTick, strategicTick, fastVol, slowVol, upside, downside, observedFees, slowFees
        );
        (int24 forecastTrend, uint24 forecastVol, uint16 forecastFees, uint16 uncertainty) = RangeOperations
            .combineStrategyForecasts(
            _trendPredictions,
            _volatilityPredictions,
            _feePredictions,
            _trendWeights,
            _volatilityWeights,
            _feeWeights,
            decisionMode == DecisionMode.HYBRID ? learningInfluenceBps : 0
        );

        marketState = MarketState({
            epoch: epoch,
            checkpointTimestamp: uint64(block.timestamp),
            canonicalTick: tacticalTick,
            tacticalTwapTick: tacticalTick,
            strategicTwapTick: strategicTick,
            forecastTrendTicks: forecastTrend,
            fastVolatilityTicks: fastVol,
            slowVolatilityTicks: slowVol,
            forecastVolatilityTicks: forecastVol,
            upsideSemivarianceTicks: upside,
            downsideSemivarianceTicks: downside,
            observedFeeRateBps: observedFees,
            forecastFeeRateBps: forecastFees,
            uncertaintyBps: uncertainty,
            feeGrowthGlobal0X128: feeGrowth0,
            feeGrowthGlobal1X128: feeGrowth1
        });
        _lastCheckpointEpoch = epoch;
        _telemetry.spotTick = liveTick;
        bool rangeExitConfirmed = _updateOutOfRangeState(liveTick, tacticalTick);

        EvaluationSummary memory summary;
        (decision, summary) = _buildDecision(rangeExitConfirmed);
        _canonicalDecision = decision;
        _telemetry = Telemetry({
            epoch: epoch,
            checkpointTimestamp: uint64(block.timestamp),
            spotTick: liveTick,
            tacticalTwapTick: tacticalTick,
            strategicTwapTick: strategicTick,
            analyticalAnchorTick: summary.analyticalAnchorTick,
            fastVolatilityTicks: fastVol,
            slowVolatilityTicks: slowVol,
            upsideSemivarianceTicks: upside,
            downsideSemivarianceTicks: downside,
            observedFeeRateBps: observedFees,
            forecastFeeRateBps: forecastFees,
            uncertaintyBps: uncertainty,
            candidateCount: summary.candidateCount,
            admissibleCandidateCount: summary.admissibleCount,
            expectedFeesBps: summary.expectedFeesBps,
            transitionCostBps: summary.transitionCostBps,
            riskPenaltyBps: summary.riskPenaltyBps,
            learningUpdated: learningUpdated,
            learningFrozen: !learningUpdated,
            decisionHash: decision.decisionHash
        });

        emit MarketStateCheckpoint(
            epoch,
            msg.sender,
            decisionMode,
            decision.action,
            decision.reason,
            decision.currentTick,
            decision.targetTickLower,
            decision.targetTickUpper,
            decision.currentScoreBps,
            decision.targetScoreBps,
            decision.edgeBps,
            decision.thresholdBps,
            decision.uncertaintyBps,
            decision.learningInfluenceBps,
            decision.decisionHash
        );

        try IStrategyCheckpointTreasury(treasury).payStrategyCheckpointBounty(msg.sender, epoch) {} catch {}
    }

    function _setNextPredictions(
        int24 realizedMove,
        int24 tacticalTick,
        int24 strategicTick,
        uint24 fastVol,
        uint24 slowVol,
        uint24 upside,
        uint24 downside,
        uint16 observedFees,
        uint16 slowFees
    ) private {
        _trendPredictions[0] = realizedMove;
        _trendPredictions[1] = _clampInt24(int256(tacticalTick) - strategicTick);
        _trendPredictions[2] = _clampInt24((int256(strategicTick) - tacticalTick) / 2);
        _trendPredictions[3] = 0;
        _volatilityPredictions[0] = fastVol;
        _volatilityPredictions[1] = slowVol;
        _volatilityPredictions[2] = upside > downside ? upside : downside;
        _feePredictions[0] = observedFees;
        _feePredictions[1] = slowFees;
        _feePredictions[2] = uint16((uint256(observedFees) + slowFees) / 2);
    }

    function _updateExpertWeights(int24 realizedMove, uint24 realizedVol, uint16 realizedFees) private {
        _trendWeights = RangeOperations.updateTrendExpertWeights(_trendWeights, _trendPredictions, realizedMove);
        _volatilityWeights =
            RangeOperations.updateUnsignedExpertWeights(_volatilityWeights, _volatilityPredictions, realizedVol, 25);
        _feeWeights = RangeOperations.updateUnsignedExpertWeights(_feeWeights, _feePredictions, realizedFees, 5);
    }

    function previewDecision() external view override returns (Decision memory decision) {
        return _liveDecision();
    }

    function validateDecision(bytes32 expectedHash) external view override returns (Decision memory decision) {
        decision = _liveDecision();
        if (decision.decisionHash != expectedHash || !decision.dataFresh) revert DecisionMismatch();
    }

    function _liveDecision() private view returns (Decision memory decision) {
        IRangeManagerStrategy rm = IRangeManagerStrategy(rangeManager);
        (,,, int24 liveTick,, bool oracleValid) = rm.priceCache();
        PositionState memory position = _positionState(liveTick);
        RangeStrategyDnLib.Context memory dn = _dnContext();
        decision = _canonicalDecision;
        if (_hfCritical(dn)) return _hfRepairDecision(decision, liveTick, position, dn);
        bool expectedPosition = decision.currentTickLower < decision.currentTickUpper;
        bool positionChanged = position.exists != expectedPosition
            || (
                expectedPosition
                    && (position.lower != decision.currentTickLower || position.upper != decision.currentTickUpper)
            );
        uint256 maxExecutionDrift = _maxExecutionDrift();
        bool rangeAction = decision.action == Action.RANGE_AND_HEDGE;
        bool strategyUnsafe = (
            rangeAction
                && (
                    !dn.configured
                        || !RangeStrategyDnLib.rangeSkewWithinBounds(
                            decision.targetTickLower,
                            decision.targetTickUpper,
                            liveTick,
                            _strategyTickSpacing,
                            strategyConfig.maxSkewBps
                        )
                )
        ) || (decision.action == Action.HEDGE_ONLY && !_hedgeControl(dn, position, liveTick).eligible);
        bool due = checkpointDue();

        if (
            !oracleValid || due || _absTick(_subTicks(liveTick, decision.currentTick)) > maxExecutionDrift
                || positionChanged || strategyUnsafe || decision.action == Action.HF_REPAIR
        ) {
            decision.action = Action.CHECKPOINT_ONLY;
            decision.reason =
                !oracleValid ? ReasonCode.ORACLE_GUARD : due ? ReasonCode.CHECKPOINT_DUE : ReasonCode.DATA_STALE;
            decision.dataFresh = false;
            return decision;
        }
        if (decision.decisionHash == _lastExecutedDecisionHash && decision.action != Action.NO_ACTION) {
            decision.action = Action.NO_ACTION;
            decision.reason = ReasonCode.DECISION_ALREADY_EXECUTED;
            return decision;
        }
        decision.dataFresh = true;
    }

    function _hfCritical(RangeStrategyDnLib.Context memory dn) private pure returns (bool) {
        return dn.debtBase > 0 && dn.hfRepairTriggerBps > 0 && dn.healthFactorBps < dn.hfRepairTriggerBps;
    }

    function _hfRepairDecision(
        Decision memory decision,
        int24 liveTick,
        PositionState memory position,
        RangeStrategyDnLib.Context memory dn
    ) private view returns (Decision memory) {
        uint64 epoch = uint64(block.timestamp / strategyConfig.epochSeconds);
        decision.epoch = epoch;
        decision.action = Action.HF_REPAIR;
        decision.reason = ReasonCode.HEALTH_FACTOR_CRITICAL;
        decision.currentTick = liveTick;
        decision.targetTickLower = position.lower;
        decision.targetTickUpper = position.upper;
        decision.dataFresh = true;
        decision.decisionHash = keccak256(abi.encodePacked(address(this), epoch, dn.healthFactorBps, dn.debtBase));
        return decision;
    }

    function _buildDecision(bool rangeExitConfirmed)
        private
        returns (Decision memory decision, EvaluationSummary memory summary)
    {
        IRangeManagerStrategy rm = IRangeManagerStrategy(rangeManager);
        (,,, int24 liveTick,, bool oracleValid) = rm.priceCache();
        int24 referenceTick = marketState.checkpointTimestamp == 0 ? liveTick : _telemetry.spotTick;
        PositionState memory position = _positionState(liveTick);
        RangeStrategyDnLib.Context memory dn = _dnContext();

        decision.epoch = marketState.epoch;
        decision.validUntil = marketState.checkpointTimestamp + strategyConfig.decisionValiditySeconds;
        decision.currentTick = referenceTick;
        decision.currentTickLower = position.lower;
        decision.currentTickUpper = position.upper;
        decision.inRange = position.exists && liveTick > position.lower && liveTick < position.upper;
        decision.learningInfluenceBps = decisionMode == DecisionMode.HYBRID ? learningInfluenceBps : 0;
        decision.uncertaintyBps = marketState.uncertaintyBps;
        bool due = checkpointDue();
        uint256 maxExecutionDrift = _maxExecutionDrift();
        decision.dataFresh = oracleValid && !due && marketState.checkpointTimestamp != 0
            && block.timestamp <= decision.validUntil && _absTick(_subTicks(liveTick, referenceTick)) <= maxExecutionDrift;

        if (_hfCritical(dn)) {
            _hedgeRecoverySince = 0;
            return (_hfRepairDecision(decision, liveTick, position, dn), summary);
        }

        if (!oracleValid) {
            decision.action = Action.NO_ACTION;
            decision.reason = ReasonCode.ORACLE_GUARD;
            return _finishDecision(decision, summary);
        }
        if (!decision.dataFresh) {
            decision.action = Action.CHECKPOINT_ONLY;
            decision.reason = due ? ReasonCode.CHECKPOINT_DUE : ReasonCode.DATA_STALE;
            return _finishDecision(decision, summary);
        }

        (int24 anchor, uint16 analyticalWidth) = RangeOperations.strategyAnalyticalRange(
            referenceTick,
            marketState.forecastTrendTicks,
            marketState.forecastVolatilityTicks,
            marketState.uncertaintyBps,
            marketState.forecastFeeRateBps,
            strategyConfig.fallbackRangeUpTicks,
            strategyConfig.fallbackRangeDownTicks,
            strategyConfig.minHalfRangeTicks,
            strategyConfig.maxHalfRangeTicks,
            strategyConfig.maxSkewBps
        );
        summary.analyticalAnchorTick = anchor;
        RangeStrategyDnLib.SearchResult memory search = RangeStrategyDnLib.searchCandidates(
            dn,
            _dnPosition(position),
            _dnRiskConfig(),
            RangeStrategyDnLib.SearchConfig({
                referenceTick: referenceTick,
                liveTick: liveTick,
                analyticalAnchor: anchor,
                tickSpacing: _strategyTickSpacing,
                forecastTrendTicks: marketState.forecastTrendTicks,
                forecastVolatilityTicks: marketState.forecastVolatilityTicks,
                analyticalWidth: analyticalWidth,
                forecastFeeRateBps: marketState.forecastFeeRateBps,
                minHalfRangeTicks: strategyConfig.minHalfRangeTicks,
                maxHalfRangeTicks: strategyConfig.maxHalfRangeTicks,
                maxSkewBps: strategyConfig.maxSkewBps,
                maxCenterMoveBps: strategyConfig.maxCenterMoveBps,
                maxWidthChangeBps: strategyConfig.maxWidthChangeBps,
                transitionCostBps: strategyConfig.transitionCostBps,
                analyticOnly: decisionMode == DecisionMode.ANALYTIC_ONLY
            })
        );
        RangeStrategyDnLib.Candidate memory current = search.current;
        RangeStrategyDnLib.Candidate memory best = search.best;
        RangeStrategyDnLib.Candidate memory bestRecovery = search.bestRecovery;
        summary.candidateCount = search.candidateCount;
        summary.admissibleCount = search.admissibleCount;

        decision.currentScoreBps = current.scoreBps;
        RangeStrategyDnLib.HedgeControl memory hedgeControl = _hedgeControl(dn, position, liveTick);
        _hedgeSignalSince = hedgeControl.signalSince;
        _hedgeSignalDirection = hedgeControl.direction;
        uint256 currentHedgeDriftBps = hedgeControl.driftBps;
        uint256 currentHedgeExposureBps = hedgeControl.exposureBps;
        bool directHedgeFeasible = hedgeControl.adjustmentFeasible;
        bool hedgeRecoveryPending = position.exists && position.inRange && !directHedgeFeasible
            && currentHedgeDriftBps >= dn.criticalHedgeBps && currentHedgeExposureBps >= strategyConfig.dnMinHedgeDeltaBps;
        if (hedgeRecoveryPending && _hedgeRecoverySince == 0) {
            _hedgeRecoverySince = uint64(block.timestamp);
        } else if (!hedgeRecoveryPending) {
            _hedgeRecoverySince = 0;
        }
        bool hedgeRecoveryPersistent = hedgeRecoveryPending
            && block.timestamp >= uint256(_hedgeRecoverySince) + strategyConfig.maxOutOfRangeSeconds;
        bool forceHedgeRecovery = hedgeRecoveryPersistent && bestRecovery.admissible
            && bestRecovery.hedgeDriftBps < currentHedgeDriftBps
            && (bestRecovery.lower != position.lower || bestRecovery.upper != position.upper);
        bool useOutOfRangeRecovery = position.exists && !position.inRange && !best.admissible && bestRecovery.admissible;
        if (!best.admissible || summary.admissibleCount == 0) {
            if (forceHedgeRecovery || useOutOfRangeRecovery) {
                best = bestRecovery;
            } else if (hedgeControl.eligible) {
                decision.action = Action.HEDGE_ONLY;
                decision.reason = ReasonCode.HEDGE_DRIFT;
            } else {
                decision.action = Action.NO_ACTION;
                decision.reason = ReasonCode.AAVE_CONSTRAINT;
            }
            if (!best.admissible) {
                decision.targetTickLower = position.lower;
                decision.targetTickUpper = position.upper;
                return _finishDecision(decision, summary);
            }
        }
        if (forceHedgeRecovery) best = bestRecovery;

        decision.targetTickLower = best.lower;
        decision.targetTickUpper = best.upper;
        decision.targetScoreBps = best.scoreBps;
        summary.expectedFeesBps = best.feesBps;
        summary.transitionCostBps = best.transitionCostBps;
        summary.riskPenaltyBps = best.riskPenaltyBps;
        int256 signedEdge = int256(best.scoreBps) - current.scoreBps;
        decision.edgeBps = signedEdge > 0 ? uint32(uint256(signedEdge)) : 0;
        uint256 threshold = uint256(strategyConfig.minEdgeBps)
            + uint256(best.transitionCostBps > 0 ? uint32(best.transitionCostBps) : 0)
            + uint256(marketState.uncertaintyBps) / 4;
        if (position.inRange) threshold *= 2;
        decision.thresholdBps = uint32(_min(threshold, type(uint32).max));

        if (!position.exists) {
            decision.action = Action.NO_ACTION;
            decision.reason = ReasonCode.INITIAL_MINT_REQUIRED;
            return _finishDecision(decision, summary);
        }

        (decision.action, decision.reason) = _selectAction(
            position,
            best,
            hedgeControl,
            forceHedgeRecovery,
            decision.edgeBps > decision.thresholdBps,
            rangeExitConfirmed,
            liveTick
        );
        return _finishDecision(decision, summary);
    }

    function _selectAction(
        PositionState memory position,
        RangeStrategyDnLib.Candidate memory best,
        RangeStrategyDnLib.HedgeControl memory hedgeControl,
        bool forceHedgeRecovery,
        bool edgeEnough,
        bool rangeExitConfirmed,
        int24 liveTick
    ) private view returns (Action action, ReasonCode reason) {
        bool sameRange = best.lower == position.lower && best.upper == position.upper;
        uint64 lastRebalanceTime;
        if (!sameRange) (,,,,, lastRebalanceTime,,) = IRangeManagerStrategy(rangeManager).config();
        return RangeStrategyDnLib.selectAction(
            RangeStrategyDnLib.ActionInput({
                range: RangeStrategyDnLib.RangeTimingInput({
                    inRange: position.inRange,
                    edgeEnough: edgeEnough,
                    criticalHedge: hedgeControl.critical,
                    exitConfirmed: rangeExitConfirmed,
                    lower: position.lower,
                    upper: position.upper,
                    liveTick: liveTick,
                    outOfRangeSince: _outOfRangeSince,
                    lastRebalanceTime: lastRebalanceTime,
                    maxOutOfRangeSeconds: strategyConfig.maxOutOfRangeSeconds,
                    rebalanceCooldownSeconds: strategyConfig.rebalanceCooldownSeconds,
                    coalesceHorizonSeconds: strategyConfig.strategicHorizonSeconds
                }),
                sameRange: sameRange,
                forceHedgeRecovery: forceHedgeRecovery,
                hedgeEligible: hedgeControl.eligible,
                hedgePending: hedgeControl.signalSince > 0 && !hedgeControl.normalConfirmed && !hedgeControl.critical
            })
        );
    }

    function _finishDecision(Decision memory decision, EvaluationSummary memory summary)
        private
        view
        returns (Decision memory, EvaluationSummary memory)
    {
        decision.decisionHash = keccak256(
            abi.encode(block.chainid, address(this), strategyVersion, decision, marketState.checkpointTimestamp)
        );
        return (decision, summary);
    }

    function _dnContext() private view returns (RangeStrategyDnLib.Context memory dn) {
        (bool rateAvailable, uint256 rateRay) = RangeStrategyDnLib.aaveBorrowRateRay(hedgeManager);
        dn = RangeStrategyDnLib.loadContext(hedgeManager, rangeManager, _strategyToken0, rateAvailable, rateRay);
    }

    function _dnPosition(PositionState memory position)
        private
        pure
        returns (RangeStrategyDnLib.Position memory converted)
    {
        converted.exists = position.exists;
        converted.inRange = position.inRange;
        converted.lower = position.lower;
        converted.upper = position.upper;
        converted.liquidity = position.liquidity;
    }

    function _dnRiskConfig() private view returns (RangeStrategyDnLib.RiskConfig memory risk) {
        risk.tailRiskBps = strategyConfig.tailRiskBps;
        risk.minStressHfBps = strategyConfig.dnMinStressHfBps;
        risk.hedgeOnlyMinEdgeBps = strategyConfig.dnHedgeOnlyMinEdgeBps;
        risk.strategicHorizonSeconds = strategyConfig.strategicHorizonSeconds;
    }

    function _hedgeControl(RangeStrategyDnLib.Context memory dn, PositionState memory position, int24 liveTick)
        private
        view
        returns (RangeStrategyDnLib.HedgeControl memory)
    {
        return RangeStrategyDnLib.hedgeControl(
            dn,
            _dnPosition(position),
            _dnRiskConfig(),
            liveTick,
            strategyConfig.dnMinHedgeDeltaBps,
            _hedgeSignalSince,
            _hedgeSignalDirection,
            strategyConfig.tacticalHorizonSeconds
        );
    }

    function _positionState(int24 liveTick) private view returns (PositionState memory position) {
        IRangeManagerStrategy rm = IRangeManagerStrategy(rangeManager);
        uint256[] memory positions = rm.getOwnerPositions();
        if (positions.length != 1) return position;
        position.exists = true;
        uint256 tokenId = positions[0];
        (,,,,, position.lower, position.upper, position.liquidity,,,,) = rm.positionManager().positions(tokenId);
        position.inRange = liveTick > position.lower && liveTick < position.upper;
    }

    function _updateOutOfRangeState(int24 liveTick, int24 tacticalTwapTick) private returns (bool confirmed) {
        PositionState memory position = _positionState(liveTick);
        (_outOfRangeSince, confirmed) = RangeStrategyDnLib.nextRangeExitState(
            _dnPosition(position),
            liveTick,
            tacticalTwapTick,
            _strategyTickSpacing,
            _outOfRangeSince,
            strategyConfig.epochSeconds
        );
    }

    function currentTelemetry() external view override returns (Telemetry memory) {
        return _telemetry;
    }

    /// @notice Exact current DN hedge state used by public and administrative observability.
    /// @dev This factual view never influences a decision and does not mutate strategy state.
    function getHedgeStrategyState()
        external
        view
        returns (
            bool positionExists,
            uint256 token0InLp,
            uint256 targetShort,
            uint256 debtToken0,
            int256 effectiveShort,
            uint256 driftBps,
            uint256 healthFactor
        )
    {
        RangeStrategyDnLib.Context memory dn = _dnContext();
        debtToken0 = dn.debtToken0;
        effectiveShort = dn.effectiveShortToken0;
        healthFactor = dn.healthFactorBps * 1e14;
        (,,, int24 liveTick,,) = IRangeManagerStrategy(rangeManager).priceCache();
        PositionState memory position = _positionState(liveTick);
        if (!position.exists) return (false, 0, 0, debtToken0, effectiveShort, 0, healthFactor);

        positionExists = true;
        (token0InLp, targetShort, driftBps) = RangeStrategyDnLib.currentHedgeState(dn, _dnPosition(position), liveTick);
    }

    function getExpertWeights()
        external
        view
        override
        returns (uint16[4] memory trend, uint16[3] memory volatility, uint16[3] memory fees)
    {
        return (_trendWeights, _volatilityWeights, _feeWeights);
    }

    function recordExecution(bytes32 decisionHash, Action action, address keeper) external override {
        bool recorderValid = action == Action.RANGE_AND_HEDGE
            ? msg.sender == rangeManager
            : (action == Action.HEDGE_ONLY || action == Action.HF_REPAIR) && msg.sender == hedgeManager;
        if (!recorderValid) revert UnauthorizedExecutionRecorder();
        Decision memory current = _liveDecision();
        if (current.decisionHash != decisionHash || current.action != action || !current.dataFresh) {
            revert DecisionMismatch();
        }
        _lastExecutedDecisionHash = action == Action.HF_REPAIR ? bytes32(0) : decisionHash;
        if (action == Action.RANGE_AND_HEDGE) {
            // The signal belongs to the range that was just replaced.
            _outOfRangeSince = 0;
        }
        _hedgeRecoverySince = 0;
        _hedgeSignalSince = 0;
        _hedgeSignalDirection = 0;
        emit StrategyExecutionRecorded(current.epoch, decisionHash, action, keeper, msg.sender);
    }

    function setDecisionMode(DecisionMode mode) external onlyOwner {
        decisionMode = mode;
        emit DecisionModeUpdated(mode);
    }

    function setLearningInfluence(uint16 influenceBps) external onlyOwner {
        if (influenceBps > maxLearningInfluenceBps) revert InvalidConfiguration();
        learningInfluenceBps = influenceBps;
        emit LearningInfluenceUpdated(influenceBps);
    }

    function setRiskParameters(
        uint16 maxSkewBps,
        uint16 tailRiskBps,
        uint16 minEdgeBps,
        uint16 maxCenterMoveBps,
        uint16 maxWidthChangeBps
    ) external onlyOwner {
        if (
            maxSkewBps > 5000 || tailRiskBps < 100 || tailRiskBps > 5000 || minEdgeBps == 0 || minEdgeBps > 2000
                || maxCenterMoveBps > BPS || maxWidthChangeBps > BPS
        ) revert InvalidConfiguration();
        strategyConfig.maxSkewBps = maxSkewBps;
        strategyConfig.tailRiskBps = tailRiskBps;
        strategyConfig.minEdgeBps = minEdgeBps;
        strategyConfig.maxCenterMoveBps = maxCenterMoveBps;
        strategyConfig.maxWidthChangeBps = maxWidthChangeBps;
        emit StrategyRiskParametersUpdated(maxSkewBps, tailRiskBps, minEdgeBps, maxCenterMoveBps, maxWidthChangeBps);
    }

    function setRangeBounds(uint16 fallbackUp, uint16 fallbackDown, uint16 minHalf, uint16 maxHalf)
        external
        onlyOwner
    {
        uint256 minimum = uint256(uint24(_strategyTickSpacing)) * 5;
        if (
            minHalf < minimum || maxHalf <= minHalf || maxHalf > 5000 || fallbackUp < minHalf || fallbackUp > maxHalf
                || fallbackDown < minHalf || fallbackDown > maxHalf
        ) revert InvalidConfiguration();
        strategyConfig.fallbackRangeUpTicks = fallbackUp;
        strategyConfig.fallbackRangeDownTicks = fallbackDown;
        strategyConfig.minHalfRangeTicks = minHalf;
        strategyConfig.maxHalfRangeTicks = maxHalf;
        emit StrategyRangeBoundsUpdated(fallbackUp, fallbackDown, minHalf, maxHalf);
    }

    function setDnHedgePolicy(uint16 hedgeOnlyMinEdgeBps, uint16 minHedgeDeltaBps) external onlyOwner {
        if (hedgeOnlyMinEdgeBps == 0 || hedgeOnlyMinEdgeBps > 5000 || minHedgeDeltaBps == 0 || minHedgeDeltaBps > 2000)
        {
            revert InvalidConfiguration();
        }
        strategyConfig.dnHedgeOnlyMinEdgeBps = hedgeOnlyMinEdgeBps;
        strategyConfig.dnMinHedgeDeltaBps = minHedgeDeltaBps;
        emit DnHedgePolicyUpdated(hedgeOnlyMinEdgeBps, minHedgeDeltaBps);
    }

    function _clampInt24(int256 value) private pure returns (int24) {
        if (value > type(int24).max) return type(int24).max;
        if (value < type(int24).min) return type(int24).min;
        return int24(value);
    }

    function _subTicks(int24 a, int24 b) private pure returns (int24) {
        return _clampInt24(int256(a) - b);
    }

    function _absTick(int24 value) private pure returns (uint24) {
        int256 signed = value;
        return uint24(uint256(signed < 0 ? -signed : signed));
    }

    function _ewma(uint256 previous, uint256 observed, uint256 alphaBps) private pure returns (uint24) {
        uint256 value = previous == 0 ? observed : (previous * (BPS - alphaBps) + observed * alphaBps) / BPS;
        return uint24(_min(value, MAX_VOLATILITY_TICKS));
    }

    function _maxExecutionDrift() private view returns (uint256) {
        return _max(uint256(strategyConfig.minHalfRangeTicks) / 2, uint256(uint24(_strategyTickSpacing)) * 2);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }
}
