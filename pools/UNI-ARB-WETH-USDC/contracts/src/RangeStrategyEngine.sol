// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IRangeStrategyEngine.sol";
import "./RangeOperations.sol";

interface IRangeManagerStrategy {
    function vault() external view returns (address);
    function pool() external view returns (IUniswapV3Pool);
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
    uint16 public constant override strategyVersion = 2;
    uint256 private constant BPS = 10_000;
    uint256 private constant EXIT_CONFIRMATION_DEPTH_BPS = 1_000;
    uint256 private constant EXIT_CONFIRMATION_MIN_SPACINGS = 2;
    uint128 private constant SAMPLE_LIQUIDITY = 1e12;
    uint16 private constant MAX_FEE_RATE_BPS = 2_000;
    uint24 private constant MAX_VOLATILITY_TICKS = 20_000;
    uint256 private constant MAIN_BOT_KEEPER_DELAY = 60;
    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;

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

    struct Candidate {
        int24 lower;
        int24 upper;
        int32 scoreBps;
        int32 feesBps;
        int32 transitionCostBps;
        int32 riskPenaltyBps;
        bool admissible;
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
    StrategyProfile public immutable override profile;
    uint16 public immutable maxLearningInfluenceBps;
    int24 private immutable _strategyTickSpacing;

    StrategyConfig public strategyConfig;
    DecisionMode public override decisionMode;
    uint16 public learningInfluenceBps;
    uint64 private _lastCheckpointEpoch;
    uint64 private _outOfRangeSince;
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
        if (_profile == StrategyProfile.DELTA_NEUTRAL || _hedgeManager != address(0)) {
            revert InvalidConfiguration();
        }

        rangeManager = _rangeManager;
        pool = poolAddress;
        hedgeManager = _hedgeManager;
        treasury = _treasury;
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
            dnMinStressHfBps: cfg.dnMinStressHfBps
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
                || cfg.maxWidthChangeBps > 10_000 || cfg.transitionCostBps > 1000 || cfg.dnMinStressHfBps != 0
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

        (int24 tacticalTick, int24 strategicTick) = _canonicalTwaps(epoch, cfg);
        uint256 feeGrowth0 = IUniswapV3Pool(pool).feeGrowthGlobal0X128();
        uint256 feeGrowth1 = IUniswapV3Pool(pool).feeGrowthGlobal1X128();
        uint64 previousTimestamp = marketState.checkpointTimestamp;
        int24 previousCanonicalTick = marketState.canonicalTick;
        uint64 elapsed = previousTimestamp == 0 ? 0 : uint64(block.timestamp) - previousTimestamp;
        int24 realizedMove = previousTimestamp == 0 ? int24(0) : _subTicks(tacticalTick, previousCanonicalTick);
        uint24 absoluteMove = _absTick(realizedMove);
        uint16 observedFees = _observedFeeRateBps(
            feeGrowth0,
            feeGrowth1,
            marketState.feeGrowthGlobal0X128,
            marketState.feeGrowthGlobal1X128,
            elapsed,
            liveTick,
            price0,
            price1
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
        _updateOutOfRangeState(liveTick, tacticalTick);

        EvaluationSummary memory summary;
        (decision, summary) = _buildDecision();
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

    function _canonicalTwaps(uint64 epoch, StrategyConfig memory cfg)
        private
        view
        returns (int24 tacticalTick, int24 strategicTick)
    {
        uint256 boundary = uint256(epoch) * cfg.epochSeconds;
        uint256 offset = block.timestamp - boundary;
        if (offset > type(uint32).max) revert StrategyDataUnavailable();
        uint32 endAgo = uint32(offset);
        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = endAgo + cfg.strategicHorizonSeconds;
        secondsAgos[1] = endAgo + cfg.tacticalHorizonSeconds;
        secondsAgos[2] = endAgo;
        (int56[] memory cumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
        strategicTick = _meanTick(cumulatives[2] - cumulatives[0], cfg.strategicHorizonSeconds);
        tacticalTick = _meanTick(cumulatives[2] - cumulatives[1], cfg.tacticalHorizonSeconds);
    }

    function _meanTick(int56 delta, uint32 seconds_) private pure returns (int24 tick) {
        tick = int24(delta / int56(uint56(seconds_)));
        if (delta < 0 && delta % int56(uint56(seconds_)) != 0) tick--;
    }

    function _observedFeeRateBps(
        uint256 feeGrowth0,
        uint256 feeGrowth1,
        uint256 previousGrowth0,
        uint256 previousGrowth1,
        uint64 elapsed,
        int24 liveTick,
        uint128 price0,
        uint128 price1
    ) private view returns (uint16) {
        if (elapsed == 0) return 0;
        uint256 delta0;
        uint256 delta1;
        unchecked {
            delta0 = feeGrowth0 - previousGrowth0;
            delta1 = feeGrowth1 - previousGrowth1;
        }
        uint256 amount0 = _mulQ128(delta0, SAMPLE_LIQUIDITY);
        uint256 amount1 = _mulQ128(delta1, SAMPLE_LIQUIDITY);
        (, uint8 dec0, uint8 dec1,,,,,) = IRangeManagerStrategy(rangeManager).config();
        uint256 feeValue = (amount0 * uint256(price0)) / (10 ** dec0) + (amount1 * uint256(price1)) / (10 ** dec1);

        StrategyConfig memory cfg = strategyConfig;
        (int24 lower, int24 upper) =
            _alignedRange(liveTick, int24(uint24(cfg.fallbackRangeDownTicks)), int24(uint24(cfg.fallbackRangeUpTicks)));
        (uint256 ref0, uint256 ref1) = _amountsAtTick(lower, upper, liveTick, SAMPLE_LIQUIDITY);
        uint256 referenceValue = (ref0 * uint256(price0)) / (10 ** dec0) + (ref1 * uint256(price1)) / (10 ** dec1);
        if (referenceValue == 0) return 0;
        uint256 annualizedToEpoch = (feeValue * BPS * cfg.epochSeconds) / (referenceValue * elapsed);
        if (annualizedToEpoch > MAX_FEE_RATE_BPS) annualizedToEpoch = MAX_FEE_RATE_BPS;
        return uint16(annualizedToEpoch);
    }

    function _mulQ128(uint256 x, uint128 y) private pure returns (uint256 result) {
        uint256 hi = x >> 128;
        uint256 lo = x & type(uint128).max;
        result = hi * y + ((lo * y) >> 128);
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
        decision = _canonicalDecision;
        IRangeManagerStrategy rm = IRangeManagerStrategy(rangeManager);
        (uint128 price0, uint128 price1,, int24 liveTick,, bool oracleValid) = rm.priceCache();
        PositionState memory position = _positionState(liveTick);
        bool expectedPosition = decision.currentTickLower < decision.currentTickUpper;
        bool positionChanged = position.exists != expectedPosition
            || (
                expectedPosition
                    && (position.lower != decision.currentTickLower || position.upper != decision.currentTickUpper)
            );
        uint256 maxExecutionDrift =
            _max(uint256(strategyConfig.minHalfRangeTicks) / 2, uint256(uint24(_strategyTickSpacing)) * 2);
        bool rangeUnsafe = decision.action == Action.RANGE_REBALANCE
            && (
                liveTick <= decision.targetTickLower || liveTick >= decision.targetTickUpper
                    || !_rangeSkewWithinBounds(decision.targetTickLower, decision.targetTickUpper, liveTick)
            );
        bool oracleGuard = !oracleValid || (profile == StrategyProfile.STABLE && _depegBps(price0, price1) > 200);
        bool due = checkpointDue();

        if (
            decision.decisionHash == bytes32(0) || oracleGuard || due || block.timestamp > decision.validUntil
                || _absTick(_subTicks(liveTick, decision.currentTick)) > maxExecutionDrift || positionChanged || rangeUnsafe
        ) {
            decision.action = Action.CHECKPOINT_ONLY;
            decision.reason =
                oracleGuard ? ReasonCode.ORACLE_GUARD : due ? ReasonCode.CHECKPOINT_DUE : ReasonCode.DATA_STALE;
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

    function _buildDecision() private view returns (Decision memory decision, EvaluationSummary memory summary) {
        IRangeManagerStrategy rm = IRangeManagerStrategy(rangeManager);
        (uint128 price0, uint128 price1,, int24 liveTick,, bool oracleValid) = rm.priceCache();
        int24 referenceTick = marketState.checkpointTimestamp == 0 ? liveTick : _telemetry.spotTick;
        PositionState memory position = _positionState(liveTick);

        decision.epoch = marketState.epoch;
        decision.validUntil = marketState.checkpointTimestamp + strategyConfig.decisionValiditySeconds;
        decision.currentTick = referenceTick;
        decision.currentTickLower = position.lower;
        decision.currentTickUpper = position.upper;
        decision.inRange = position.exists && liveTick > position.lower && liveTick < position.upper;
        decision.learningInfluenceBps = decisionMode == DecisionMode.HYBRID ? learningInfluenceBps : 0;
        decision.uncertaintyBps = marketState.uncertaintyBps;
        bool due = checkpointDue();
        uint256 maxExecutionDrift =
            _max(uint256(strategyConfig.minHalfRangeTicks) / 2, uint256(uint24(_strategyTickSpacing)) * 2);
        decision.dataFresh = oracleValid && !due && marketState.checkpointTimestamp != 0
            && block.timestamp <= decision.validUntil && _absTick(_subTicks(liveTick, referenceTick)) <= maxExecutionDrift;

        if (!oracleValid) {
            decision.action = Action.NO_ACTION;
            decision.reason = ReasonCode.ORACLE_GUARD;
            return _finishDecision(decision, summary);
        }
        // A Stable profile assumes two assets tracking the same reference value. A material depeg is a
        // product-risk event, not an opportunity to tighten or chase the range. Fail closed until both
        // independent oracle prices converge again; the Safe cannot bypass this guard.
        if (profile == StrategyProfile.STABLE && _depegBps(price0, price1) > 200) {
            decision.action = Action.NO_ACTION;
            decision.reason = ReasonCode.ORACLE_GUARD;
            return _finishDecision(decision, summary);
        }
        if (!decision.dataFresh) {
            decision.action = Action.CHECKPOINT_ONLY;
            decision.reason = due ? ReasonCode.CHECKPOINT_DUE : ReasonCode.DATA_STALE;
            return _finishDecision(decision, summary);
        }

        (int24 anchor, uint16 analyticalWidth) = _analyticalRange(referenceTick);
        summary.analyticalAnchorTick = anchor;
        Candidate memory current = position.exists
            ? _evaluateCandidate(
                position.lower, position.upper, referenceTick, liveTick, anchor, analyticalWidth, position, false
            )
            : Candidate(0, 0, 0, 0, 0, 0, true);
        Candidate memory best;
        best.scoreBps = type(int32).min;

        uint16[3] memory widthFactors = [uint16(7500), 10_000, 12_500];
        int16[3] memory skewFactors = [int16(-5000), 0, 5000];
        for (uint256 w; w < 3; ++w) {
            uint256 width = _clamp(
                (uint256(analyticalWidth) * widthFactors[w]) / BPS,
                strategyConfig.minHalfRangeTicks,
                strategyConfig.maxHalfRangeTicks
            );
            for (uint256 s; s < 3; ++s) {
                if (decisionMode == DecisionMode.ANALYTIC_ONLY && (w != 1 || s != 1)) continue;
                summary.candidateCount++;
                int256 skew = int256(width) * int256(skewFactors[s]) * int256(uint256(strategyConfig.maxSkewBps))
                    / int256(BPS * BPS);
                int24 center = _clampInt24(int256(anchor) + skew);
                (int24 lower, int24 upper) = _alignedRange(center, int24(uint24(width)), int24(uint24(width)));
                Candidate memory candidate = _evaluateCandidate(
                    lower, upper, referenceTick, liveTick, anchor, analyticalWidth, position, position.inRange
                );
                if (candidate.admissible) {
                    summary.admissibleCount++;
                    if (candidate.scoreBps > best.scoreBps) best = candidate;
                }
            }
        }

        decision.currentScoreBps = current.scoreBps;
        if (!best.admissible || summary.admissibleCount == 0) {
            decision.action = Action.NO_ACTION;
            decision.reason = ReasonCode.NO_ADMISSIBLE_CANDIDATE;
            decision.targetTickLower = position.lower;
            decision.targetTickUpper = position.upper;
            return _finishDecision(decision, summary);
        }

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

        bool sameRange = best.lower == position.lower && best.upper == position.upper;
        if (sameRange) {
            decision.action = Action.NO_ACTION;
            decision.reason = position.inRange ? ReasonCode.IN_RANGE_EDGE_LOW : ReasonCode.OUT_OF_RANGE_EVALUATING;
            return _finishDecision(decision, summary);
        }

        (,,,,, uint64 lastRebalanceTime,,) = rm.config();
        if (block.timestamp < uint256(lastRebalanceTime) + strategyConfig.rebalanceCooldownSeconds) {
            decision.action = Action.NO_ACTION;
            decision.reason = ReasonCode.COOLDOWN_ACTIVE;
            return _finishDecision(decision, summary);
        }

        bool forcePersistent = !position.inRange && _outOfRangeSince > 0
            && block.timestamp >= uint256(_outOfRangeSince) + strategyConfig.maxOutOfRangeSeconds;
        uint256 outsideDepth = liveTick < position.lower
            ? uint256(uint24(position.lower - liveTick))
            : liveTick > position.upper ? uint256(uint24(liveTick - position.upper)) : 0;
        uint256 currentHalfWidth =
            position.upper > position.lower ? uint256(uint24(position.upper - position.lower)) / 2 : 0;
        bool forceDeep = !position.inRange && currentHalfWidth > 0 && outsideDepth >= currentHalfWidth;
        bool edgeEnough = decision.edgeBps > decision.thresholdBps;
        bool confirmedEdge =
            edgeEnough && (position.inRange || _exitConfirmed(position, liveTick, outsideDepth, currentHalfWidth));

        if (confirmedEdge || forcePersistent || forceDeep) {
            decision.action = Action.RANGE_REBALANCE;
            decision.reason = forcePersistent
                ? ReasonCode.OUT_OF_RANGE_PERSISTENT
                : forceDeep ? ReasonCode.OUT_OF_RANGE_DEEP : ReasonCode.EDGE_SUFFICIENT;
        } else {
            decision.action = Action.NO_ACTION;
            decision.reason = position.inRange ? ReasonCode.IN_RANGE_EDGE_LOW : ReasonCode.OUT_OF_RANGE_EVALUATING;
        }
        return _finishDecision(decision, summary);
    }

    function _finishDecision(Decision memory decision, EvaluationSummary memory summary)
        private
        view
        returns (Decision memory, EvaluationSummary memory)
    {
        if (decision.decisionHash == bytes32(0)) {
            decision.decisionHash = keccak256(
                abi.encode(block.chainid, address(this), strategyVersion, decision, marketState.checkpointTimestamp)
            );
        }
        return (decision, summary);
    }

    function _analyticalRange(int24 liveTick) private view returns (int24 anchor, uint16 halfWidth) {
        StrategyConfig memory cfg = strategyConfig;
        MarketState memory state = marketState;
        uint256 fallbackWidth = (uint256(cfg.fallbackRangeUpTicks) + cfg.fallbackRangeDownTicks) / 2;
        uint256 forecastVol = state.forecastVolatilityTicks;
        uint256 uncertainty = state.uncertaintyBps;
        uint256 width = fallbackWidth + forecastVol * 2 + (fallbackWidth * uncertainty) / (BPS * 2);
        uint256 feeNarrowing = (width * _min(state.forecastFeeRateBps, 1000)) / 6000;
        if (feeNarrowing < width / 3) width -= feeNarrowing;
        if (profile == StrategyProfile.STABLE) width = (width * 7500) / BPS;
        width = _clamp(width, cfg.minHalfRangeTicks, cfg.maxHalfRangeTicks);

        int256 learnedTrend = state.forecastTrendTicks;
        int256 maxShift = int256(width * cfg.maxSkewBps / BPS);
        if (learnedTrend > maxShift) learnedTrend = maxShift;
        if (learnedTrend < -maxShift) learnedTrend = -maxShift;
        anchor = _clampInt24(int256(liveTick) + learnedTrend);
        halfWidth = uint16(width);
    }

    function _evaluateCandidate(
        int24 lower,
        int24 upper,
        int24 scoringTick,
        int24 executionTick,
        int24 analyticalAnchor,
        uint16 analyticalWidth,
        PositionState memory position,
        bool enforceMovementBounds
    ) private view returns (Candidate memory candidate) {
        candidate.lower = lower;
        candidate.upper = upper;
        bool isCurrentRange = position.exists && lower == position.lower && upper == position.upper;
        if (
            lower >= upper || lower <= MIN_TICK || upper >= MAX_TICK
                || (
                    !isCurrentRange
                        && (scoringTick <= lower || scoringTick >= upper || executionTick <= lower || executionTick >= upper)
                )
        ) {
            return candidate;
        }
        uint256 halfWidth = uint256(uint24(upper - lower)) / 2;
        if (
            !isCurrentRange
                && (halfWidth < strategyConfig.minHalfRangeTicks || halfWidth > strategyConfig.maxHalfRangeTicks)
        ) {
            return candidate;
        }
        if (!isCurrentRange && !_rangeSkewWithinBounds(lower, upper, executionTick)) return candidate;

        if (enforceMovementBounds && position.exists) {
            int256 oldCenter = (int256(position.lower) + position.upper) / 2;
            int256 newCenter = (int256(lower) + upper) / 2;
            uint256 oldWidth = uint256(uint24(position.upper - position.lower));
            uint256 centerMove = _absInt(newCenter - oldCenter);
            uint256 widthMove = _absDiff(uint256(uint24(upper - lower)), oldWidth);
            if (centerMove * BPS > oldWidth * strategyConfig.maxCenterMoveBps) return candidate;
            if (widthMove * BPS > oldWidth * strategyConfig.maxWidthChangeBps) return candidate;
        }

        uint24 volatility = marketState.forecastVolatilityTicks > 10 ? marketState.forecastVolatilityTicks : 10;
        (int32 scenarioScore, int32 expectedFees, int32 scenarioRisk) = RangeOperations.evaluateStrategyScenarios(
            RangeOperations.StrategyScenarioInput({
                lower: lower,
                upper: upper,
                liveTick: scoringTick,
                trendTicks: marketState.forecastTrendTicks,
                volatilityTicks: volatility,
                forecastFeeRateBps: marketState.forecastFeeRateBps,
                analyticalWidthTicks: analyticalWidth,
                tailRiskBps: strategyConfig.tailRiskBps
            })
        );
        int256 score = scenarioScore;
        uint256 transition = position.exists && (position.lower != lower || position.upper != upper)
            ? _transitionCost(position.lower, position.upper, lower, upper, analyticalAnchor)
            : 0;
        score -= int256(transition);

        candidate.scoreBps = _clampInt32(score);
        candidate.feesBps = expectedFees;
        candidate.transitionCostBps = _clampInt32(int256(transition));
        candidate.riskPenaltyBps = scenarioRisk;
        candidate.admissible = true;
    }

    function _amountsAtTick(int24 lower, int24 upper, int24 tick, uint128 liquidity)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return RangeOperations.strategyAmountsAtTick(lower, upper, tick, liquidity);
    }

    function _transitionCost(int24 oldLower, int24 oldUpper, int24 newLower, int24 newUpper, int24 anchor)
        private
        view
        returns (uint256)
    {
        uint256 oldWidth = uint256(uint24(oldUpper - oldLower));
        uint256 newWidth = uint256(uint24(newUpper - newLower));
        int256 oldCenter = (int256(oldLower) + oldUpper) / 2;
        int256 newCenter = (int256(newLower) + newUpper) / 2;
        uint256 movement =
            _absInt(newCenter - oldCenter) + _absDiff(oldWidth, newWidth) / 2 + _absInt(newCenter - anchor) / 4;
        return uint256(strategyConfig.transitionCostBps) + _min((movement * BPS) / _max(oldWidth, 1) / 20, 500);
    }

    function _rangeSkewWithinBounds(int24 lower, int24 upper, int24 liveTick) private view returns (bool) {
        uint256 halfWidth = uint256(uint24(upper - lower)) / 2;
        if (halfWidth == 0) return false;
        int256 center = (int256(lower) + upper) / 2;
        uint256 centerDistance = _absInt(center - int256(liveTick));
        uint256 alignmentTolerance = uint256(uint24(_strategyTickSpacing));
        return centerDistance * BPS <= halfWidth * strategyConfig.maxSkewBps + alignmentTolerance * BPS;
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

    function _updateOutOfRangeState(int24 liveTick, int24 tacticalTwapTick) private {
        PositionState memory position = _positionState(liveTick);
        if (!position.exists) {
            _outOfRangeSince = 0;
        } else if (!position.inRange && _outOfRangeSince == 0) {
            _outOfRangeSince = uint64(block.timestamp);
        } else if (position.inRange && _outOfRangeSince != 0 && _deepInsideRange(position, liveTick, tacticalTwapTick))
        {
            _outOfRangeSince = 0;
        }
    }

    function _exitConfirmed(
        PositionState memory position,
        int24 liveTick,
        uint256 outsideDepth,
        uint256 currentHalfWidth
    ) internal view returns (bool) {
        if (position.inRange) return true;
        bool twapOutsideSameSide = (liveTick <= position.lower && marketState.tacticalTwapTick <= position.lower)
            || (liveTick >= position.upper && marketState.tacticalTwapTick >= position.upper);
        bool persistedOneEpoch =
            _outOfRangeSince != 0 && block.timestamp >= uint256(_outOfRangeSince) + strategyConfig.epochSeconds;
        return twapOutsideSameSide || persistedOneEpoch || outsideDepth >= _exitConfirmationDepth(currentHalfWidth);
    }

    function _deepInsideRange(PositionState memory position, int24 liveTick, int24 tacticalTwapTick)
        private
        view
        returns (bool)
    {
        uint256 depth = uint256(uint24(_strategyTickSpacing));
        int256 resetLower = int256(position.lower) + int256(depth);
        int256 resetUpper = int256(position.upper) - int256(depth);
        return resetLower < resetUpper && int256(liveTick) > resetLower && int256(liveTick) < resetUpper
            && int256(tacticalTwapTick) > resetLower && int256(tacticalTwapTick) < resetUpper;
    }

    function _exitConfirmationDepth(uint256 halfWidth) private view returns (uint256) {
        return _max(
            uint256(uint24(_strategyTickSpacing)) * EXIT_CONFIRMATION_MIN_SPACINGS,
            halfWidth * EXIT_CONFIRMATION_DEPTH_BPS / BPS
        );
    }

    function currentTelemetry() external view override returns (Telemetry memory) {
        return _telemetry;
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
        if (msg.sender != rangeManager) revert UnauthorizedExecutionRecorder();
        Decision memory current = _liveDecision();
        if (
            decisionHash == bytes32(0) || current.decisionHash != decisionHash || current.action != action
                || !current.dataFresh || action != Action.RANGE_REBALANCE
        ) {
            revert DecisionMismatch();
        }
        _lastExecutedDecisionHash = decisionHash;
        // The signal belongs to the range that was just replaced.
        _outOfRangeSince = 0;
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

    function _alignedRange(int24 center, int24 down, int24 up) private view returns (int24 lower, int24 upper) {
        lower = _floorToSpacing(_boundedTick(int256(center) - down));
        upper = _ceilToSpacing(_boundedTick(int256(center) + up));
        if (lower <= MIN_TICK) lower = _ceilToSpacing(MIN_TICK + _strategyTickSpacing);
        if (upper >= MAX_TICK) upper = _floorToSpacing(MAX_TICK - _strategyTickSpacing);
    }

    function _floorToSpacing(int24 tick) private view returns (int24) {
        int24 remainder = tick % _strategyTickSpacing;
        if (remainder == 0) return tick;
        return tick < 0 ? tick - remainder - _strategyTickSpacing : tick - remainder;
    }

    function _ceilToSpacing(int24 tick) private view returns (int24) {
        int24 remainder = tick % _strategyTickSpacing;
        if (remainder == 0) return tick;
        return tick < 0 ? tick - remainder : tick - remainder + _strategyTickSpacing;
    }

    function _boundedTick(int256 tick) private pure returns (int24) {
        if (tick <= MIN_TICK + 1) return MIN_TICK + 1;
        if (tick >= MAX_TICK - 1) return MAX_TICK - 1;
        return int24(tick);
    }

    function _clampInt24(int256 value) private pure returns (int24) {
        if (value > type(int24).max) return type(int24).max;
        if (value < type(int24).min) return type(int24).min;
        return int24(value);
    }

    function _clampInt32(int256 value) private pure returns (int32) {
        if (value > type(int32).max) return type(int32).max;
        if (value < type(int32).min) return type(int32).min;
        return int32(value);
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

    function _absInt(int256 value) private pure returns (uint256) {
        return uint256(value < 0 ? -value : value);
    }

    function _absDiff(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _depegBps(uint256 price0, uint256 price1) private pure returns (uint256) {
        if (price0 == 0 || price1 == 0) return type(uint256).max;
        return (_absDiff(price0, price1) * BPS) / _max(price0, price1);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }

    function _clamp(uint256 value, uint256 minimum, uint256 maximum) private pure returns (uint256) {
        if (value < minimum) return minimum;
        if (value > maximum) return maximum;
        return value;
    }
}
