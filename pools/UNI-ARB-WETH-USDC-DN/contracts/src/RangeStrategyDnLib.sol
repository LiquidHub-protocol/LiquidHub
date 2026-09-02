// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./RangeOperations.sol";
import "./interfaces/IRangeStrategyEngine.sol";

interface IDnRangeManagerState {
    function refreshPriceCache() external;
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

interface IDnNegativeHedgeContext {
    function pool() external view returns (address);
    function weth() external view returns (address);
    function usdc() external view returns (address);
    function variableDebtWeth() external view returns (address);
    function rangeManager() external view returns (address);
    function swapRouter() external view returns (address);
    function swapPoolFee() external view returns (uint24);
    function volatileDecimals() external view returns (uint8);
    function stableDecimals() external view returns (uint8);
    function donationDustToken0() external view returns (uint256);
    function swapSlippageBps() external view returns (uint16);
}

interface IDnAaveSupply {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IDnAaveStrategyState {
    function getHedgeData()
        external
        view
        returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 healthFactor, uint256 availableBorrowsBase);
    function getWethDebt() external view returns (uint256);
    function getStrategyReserveData()
        external
        view
        returns (uint256 idleStable, uint16 operationalTargetBps, uint16 liveLtvBps);
    function hedgeTargetBps() external view returns (uint16);
    function donationDustToken0() external view returns (uint256);
    function adjustHedgeBps() external view returns (uint16);
    function hedgeAdjustCooldown() external view returns (uint32);
    function lastHedgeAdjustAt() external view returns (uint64);
    function hfRepairTriggerBps() external view returns (uint16);
    function liqThresholdBps() external view returns (uint16);
    function reserveHfTargetBps() external view returns (uint16);
    function swapSlippageBps() external view returns (uint16);
    function criticalHedgeBps() external view returns (uint16);
}

/// @title RangeStrategyDnLib
/// @notice Stateless Delta Neutral projection math used by RangeStrategyEngine.
/// @dev The library has no storage, owner, funds or upgrade path. Its linked bytecode is fixed at deployment.
library RangeStrategyDnLib {
    uint256 private constant BPS = 10_000;
    uint256 private constant EXIT_CONFIRMATION_DEPTH_BPS = 1_000;
    uint256 private constant EXIT_CONFIRMATION_MIN_SPACINGS = 2;
    uint256 private constant HEDGE_RESET_RATIO_BPS = 7_500;
    uint16 private constant MAX_FEE_RATE_BPS = 2_000;
    uint128 private constant SAMPLE_LIQUIDITY = 1e12;
    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;
    uint160 private constant MIN_SQRT_PRICE_LIMIT_X96 = 4295128740;
    uint160 private constant MAX_SQRT_PRICE_LIMIT_X96 = 1461446703485210103287273052203988822378723970341;

    error InvalidNegativeHedgeSwap();

    function canonicalTwaps(
        address pool,
        uint64 epoch,
        uint32 epochSeconds,
        uint32 tacticalHorizonSeconds,
        uint32 strategicHorizonSeconds
    ) external view returns (int24 tacticalTick, int24 strategicTick) {
        uint32 endAgo = uint32(block.timestamp - uint256(epoch) * epochSeconds);
        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = endAgo + strategicHorizonSeconds;
        secondsAgos[1] = endAgo + tacticalHorizonSeconds;
        secondsAgos[2] = endAgo;
        (int56[] memory cumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
        strategicTick = _meanCanonicalTick(cumulatives[2] - cumulatives[0], strategicHorizonSeconds);
        tacticalTick = _meanCanonicalTick(cumulatives[2] - cumulatives[1], tacticalHorizonSeconds);
    }

    function aaveBorrowRateRay(address hedgeManager) external view returns (bool available, uint256 rateRay) {
        (bool poolOk, bytes memory poolData) = hedgeManager.staticcall(abi.encodeWithSignature("pool()"));
        (bool assetOk, bytes memory assetData) = hedgeManager.staticcall(abi.encodeWithSignature("weth()"));
        if (!poolOk || !assetOk || poolData.length < 32 || assetData.length < 32) return (false, 0);
        address aavePool = abi.decode(poolData, (address));
        address asset = abi.decode(assetData, (address));
        (bool reserveOk, bytes memory reserveData) =
            aavePool.staticcall(abi.encodeWithSignature("getReserveData(address)", asset));
        if (!reserveOk || reserveData.length < 5 * 32) return (false, 0);
        assembly ("memory-safe") {
            rateRay := mload(add(reserveData, 0xa0))
        }
        available = rateRay > 0 && rateRay <= 10e27;
    }

    /// @dev Called by delegatecall from AaveHedgeManager. It sells only the exact token0 excess held by that
    ///      manager, with the same live oracle and sqrt-price bounds as an ordinary under-hedge adjustment.
    function normalizeNegativeEffectiveShort() external returns (uint256 debt, int256 effectiveShort) {
        IDnNegativeHedgeContext context = IDnNegativeHedgeContext(address(this));
        address token0 = context.weth();
        address rangeManager = context.rangeManager();
        uint256 dustFloor = context.donationDustToken0();
        uint256 idleHm;
        (debt, effectiveShort, idleHm) = _effectiveShort(context.variableDebtWeth(), token0, rangeManager, dustFloor);
        if (effectiveShort >= 0) return (debt, effectiveShort);

        uint256 excessToken0 = uint256(-effectiveShort);
        if (idleHm < excessToken0) return (debt, effectiveShort);

        IDnRangeManagerState(rangeManager).refreshPriceCache();
        (uint128 price0, uint128 price1, uint160 sqrtP,,, bool valid) = IDnRangeManagerState(rangeManager).priceCache();
        if (!(valid && price0 > 0 && price1 > 0 && sqrtP > 0)) revert InvalidNegativeHedgeSwap();

        address token1 = context.usdc();
        uint256 theoretical = Math.mulDiv(
            excessToken0,
            uint256(price0) * (10 ** context.stableDecimals()),
            uint256(price1) * (10 ** context.volatileDecimals())
        );
        uint256 slippageBps = context.swapSlippageBps();
        uint256 minOut = Math.mulDiv(theoretical, BPS - slippageBps, BPS);
        if (minOut == 0) revert InvalidNegativeHedgeSwap();
        uint256 rawLimit = (uint256(sqrtP) * (token0 < token1 ? 20000 - slippageBps : 20000 + slippageBps)) / 20000;
        uint160 sqrtLimit = rawLimit < MIN_SQRT_PRICE_LIMIT_X96
            ? MIN_SQRT_PRICE_LIMIT_X96
            : rawLimit > MAX_SQRT_PRICE_LIMIT_X96 ? MAX_SQRT_PRICE_LIMIT_X96 : uint160(rawLimit);

        uint256 token0Before = IERC20(token0).balanceOf(address(this));
        uint256 amount1 = ISwapRouter(context.swapRouter()).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token0,
                tokenOut: token1,
                fee: context.swapPoolFee(),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: excessToken0,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: sqrtLimit
            })
        );
        if (IERC20(token0).balanceOf(address(this)) != token0Before - excessToken0) {
            revert InvalidNegativeHedgeSwap();
        }
        if (amount1 > 0) IDnAaveSupply(context.pool()).supply(token1, amount1, address(this), 0);
        (debt, effectiveShort,) = _effectiveShort(context.variableDebtWeth(), token0, rangeManager, dustFloor);
    }

    function _meanCanonicalTick(int56 delta, uint32 seconds_) private pure returns (int24 tick) {
        tick = int24(delta / int56(uint56(seconds_)));
        if (delta < 0 && delta % int56(uint56(seconds_)) != 0) tick--;
    }

    function _effectiveShort(address debtToken, address token0, address rangeManager, uint256 dustFloor)
        private
        view
        returns (uint256 debt, int256 effectiveShort, uint256 idleHm)
    {
        debt = IERC20(debtToken).balanceOf(address(this));
        idleHm = _netOfDust(IERC20(token0).balanceOf(address(this)), dustFloor);
        uint256 idleRm = _netOfDust(IERC20(token0).balanceOf(rangeManager), dustFloor);
        effectiveShort = int256(debt) - int256(idleHm) - int256(idleRm);
    }

    function _netOfDust(uint256 balance, uint256 dustFloor) private pure returns (uint256) {
        return balance > dustFloor ? balance - dustFloor : 0;
    }

    struct Context {
        bool configured;
        uint256 collateralBase;
        uint256 debtBase;
        uint256 healthFactorBps;
        uint256 availableBorrowsBase;
        uint256 idleStableBase;
        uint256 debtToken0;
        int256 effectiveShortToken0;
        uint128 price0;
        uint128 price1;
        uint8 token0Decimals;
        uint8 token1Decimals;
        uint256 variableBorrowRateRay;
        uint16 hedgeTargetBps;
        uint16 adjustThresholdBps;
        uint16 hfRepairTriggerBps;
        uint16 liquidationThresholdBps;
        uint16 reserveHfTargetBps;
        uint16 operationalHfTargetBps;
        uint16 borrowLtvBps;
        uint16 swapSlippageBps;
        uint16 criticalHedgeBps;
        uint32 cooldownSeconds;
        uint64 lastAdjustmentAt;
    }

    struct Position {
        bool exists;
        bool inRange;
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    struct RiskConfig {
        uint16 tailRiskBps;
        uint16 minStressHfBps;
        uint16 hedgeOnlyMinEdgeBps;
        uint32 strategicHorizonSeconds;
    }

    struct Projection {
        bool admissible;
        uint256 debtBase;
        uint256 collateralBase;
        uint256 hedgeDriftBps;
    }

    struct Candidate {
        int24 lower;
        int24 upper;
        int32 scoreBps;
        int32 feesBps;
        int32 transitionCostBps;
        int32 riskPenaltyBps;
        uint32 hedgeDriftBps;
        bool admissible;
    }

    struct SearchConfig {
        int24 referenceTick;
        int24 liveTick;
        int24 analyticalAnchor;
        int24 tickSpacing;
        int24 forecastTrendTicks;
        uint24 forecastVolatilityTicks;
        uint16 analyticalWidth;
        uint16 forecastFeeRateBps;
        uint16 minHalfRangeTicks;
        uint16 maxHalfRangeTicks;
        uint16 maxSkewBps;
        uint16 maxCenterMoveBps;
        uint16 maxWidthChangeBps;
        uint16 transitionCostBps;
        bool analyticOnly;
    }

    struct SearchResult {
        Candidate current;
        Candidate best;
        Candidate bestRecovery;
        uint8 candidateCount;
        uint8 admissibleCount;
    }

    struct HedgeControl {
        uint256 driftBps;
        uint256 exposureBps;
        uint64 signalSince;
        uint8 direction;
        bool adjustmentFeasible;
        bool normalConfirmed;
        bool critical;
        bool eligible;
    }

    struct RangeTimingInput {
        bool inRange;
        bool edgeEnough;
        bool criticalHedge;
        bool exitConfirmed;
        int24 lower;
        int24 upper;
        int24 liveTick;
        uint64 outOfRangeSince;
        uint64 lastRebalanceTime;
        uint32 maxOutOfRangeSeconds;
        uint32 rebalanceCooldownSeconds;
        uint32 coalesceHorizonSeconds;
    }

    struct RangeTiming {
        bool forcePersistent;
        bool forceDeep;
        bool exitConfirmed;
        bool urgent;
        bool cooldownActive;
        bool coalesceHedge;
    }

    function loadContext(
        address hedgeManager,
        address rangeManager,
        address token0,
        bool rateAvailable,
        uint256 rateRay
    ) external view returns (Context memory context) {
        IDnAaveStrategyState hedge = IDnAaveStrategyState(hedgeManager);
        try hedge.getHedgeData() returns (uint256 collateral, uint256 debtBase, uint256 hf, uint256 available) {
            context.collateralBase = collateral;
            context.debtBase = debtBase;
            context.healthFactorBps = hf / 1e14;
            context.availableBorrowsBase = available;
        } catch {
            return context;
        }
        context.hfRepairTriggerBps = hedge.hfRepairTriggerBps();
        if (
            context.debtBase > 0 && context.hfRepairTriggerBps > 0
                && context.healthFactorBps < context.hfRepairTriggerBps
        ) return context;

        context.debtToken0 = hedge.getWethDebt();
        uint256 dust = hedge.donationDustToken0();
        uint256 idleHm = IERC20(token0).balanceOf(hedgeManager);
        uint256 idleRm = IERC20(token0).balanceOf(rangeManager);
        uint256 countedIdle = (idleHm > dust ? idleHm - dust : 0) + (idleRm > dust ? idleRm - dust : 0);
        context.effectiveShortToken0 = int256(context.debtToken0) - int256(countedIdle);
        (, context.token0Decimals, context.token1Decimals,,,,,) = IDnRangeManagerState(rangeManager).config();
        (uint128 price0, uint128 price1,,,,) = IDnRangeManagerState(rangeManager).priceCache();
        context.price0 = price0;
        context.price1 = price1;
        context.hedgeTargetBps = hedge.hedgeTargetBps();
        context.adjustThresholdBps = hedge.adjustHedgeBps();
        context.liquidationThresholdBps = hedge.liqThresholdBps();
        context.reserveHfTargetBps = hedge.reserveHfTargetBps();

        uint256 idleStable;
        uint16 liveLtvBps;
        try hedge.getStrategyReserveData() returns (uint256 reserve, uint16 operationalTarget, uint16 liveLtv) {
            idleStable = reserve;
            context.operationalHfTargetBps = operationalTarget;
            liveLtvBps = liveLtv;
        } catch {
            return context;
        }
        context.idleStableBase = idleStable * uint256(price1) / (10 ** context.token1Decimals);
        context.borrowLtvBps = liveLtvBps;
        context.swapSlippageBps = hedge.swapSlippageBps();
        context.criticalHedgeBps = hedge.criticalHedgeBps();
        context.cooldownSeconds = hedge.hedgeAdjustCooldown();
        context.lastAdjustmentAt = hedge.lastHedgeAdjustAt();
        if (!rateAvailable) return context;
        context.variableBorrowRateRay = rateRay;
        context.configured = context.price0 > 0 && context.price1 > 0 && context.variableBorrowRateRay > 0
            && context.hedgeTargetBps == BPS && context.liquidationThresholdBps > 0
            && context.reserveHfTargetBps > context.hfRepairTriggerBps
            && context.operationalHfTargetBps >= context.reserveHfTargetBps && context.borrowLtvBps > 0
            && context.swapSlippageBps < BPS && context.criticalHedgeBps > context.adjustThresholdBps;
    }

    struct ActionInput {
        RangeTimingInput range;
        bool sameRange;
        bool forceHedgeRecovery;
        bool hedgeEligible;
        bool hedgePending;
    }

    struct FeeRateInput {
        uint256 feeGrowth0;
        uint256 feeGrowth1;
        uint256 previousGrowth0;
        uint256 previousGrowth1;
        uint64 elapsed;
        int24 liveTick;
        uint128 price0;
        uint128 price1;
        uint8 token0Decimals;
        uint8 token1Decimals;
        uint32 epochSeconds;
        uint16 fallbackRangeDownTicks;
        uint16 fallbackRangeUpTicks;
        int24 tickSpacing;
    }

    function observedFeeRateBps(FeeRateInput memory input) external pure returns (uint16) {
        if (input.elapsed == 0) return 0;
        uint256 delta0;
        uint256 delta1;
        unchecked {
            delta0 = input.feeGrowth0 - input.previousGrowth0;
            delta1 = input.feeGrowth1 - input.previousGrowth1;
        }
        uint256 amount0 = _mulQ128(delta0, SAMPLE_LIQUIDITY);
        uint256 amount1 = _mulQ128(delta1, SAMPLE_LIQUIDITY);
        uint256 feeValue = (amount0 * uint256(input.price0)) / (10 ** input.token0Decimals)
            + (amount1 * uint256(input.price1)) / (10 ** input.token1Decimals);
        (int24 lower, int24 upper) = _alignedAsymmetricRange(
            input.liveTick, input.fallbackRangeDownTicks, input.fallbackRangeUpTicks, input.tickSpacing
        );
        (uint256 ref0, uint256 ref1) =
            RangeOperations.strategyAmountsAtTick(lower, upper, input.liveTick, SAMPLE_LIQUIDITY);
        uint256 referenceValue = (ref0 * uint256(input.price0)) / (10 ** input.token0Decimals)
            + (ref1 * uint256(input.price1)) / (10 ** input.token1Decimals);
        if (referenceValue == 0) return 0;
        uint256 annualizedToEpoch = (feeValue * BPS * input.epochSeconds) / (referenceValue * input.elapsed);
        return uint16(_min(annualizedToEpoch, MAX_FEE_RATE_BPS));
    }

    function rangeSkewWithinBounds(int24 lower, int24 upper, int24 liveTick, int24 tickSpacing, uint16 maxSkewBps)
        external
        pure
        returns (bool)
    {
        return liveTick > lower && liveTick < upper
            && _rangeSkewWithinBounds(lower, upper, liveTick, tickSpacing, maxSkewBps);
    }

    function searchCandidates(
        Context memory context,
        Position memory position,
        RiskConfig memory risk,
        SearchConfig memory config
    ) external pure returns (SearchResult memory result) {
        result.current = position.exists
            ? _evaluateCandidate(context, position, risk, config, position.lower, position.upper, false)
            : Candidate(0, 0, 0, 0, 0, 0, 0, true);
        result.best.scoreBps = type(int32).min;
        result.bestRecovery.scoreBps = type(int32).min;

        uint16[3] memory widthFactors = [uint16(7500), 10_000, 12_500];
        int16[5] memory skewFactors = [int16(-10_000), -5000, 0, 5000, 10_000];
        for (uint256 w; w < widthFactors.length; ++w) {
            uint256 width = _clamp(
                uint256(config.analyticalWidth) * widthFactors[w] / BPS,
                config.minHalfRangeTicks,
                config.maxHalfRangeTicks
            );
            for (uint256 s; s < skewFactors.length; ++s) {
                if (config.analyticOnly && (w != 1 || skewFactors[s] != 0)) continue;
                result.candidateCount++;
                int256 skew =
                    int256(width) * int256(skewFactors[s]) * int256(uint256(config.maxSkewBps)) / int256(BPS * BPS);
                int24 center = _clampInt24(int256(config.analyticalAnchor) + skew);
                (int24 lower, int24 upper) = _alignedRange(center, uint16(width), config.tickSpacing);
                Candidate memory candidate =
                    _evaluateCandidate(context, position, risk, config, lower, upper, position.inRange);
                if (candidate.admissible) {
                    result.admissibleCount++;
                    if (candidate.scoreBps > result.best.scoreBps) result.best = candidate;
                    result.bestRecovery = _betterRecovery(result.bestRecovery, candidate);
                }
            }

            (int24 recoveryLower, int24 recoveryUpper, bool recoveryFound) =
                _hedgeAlignedRange(context, position, uint16(width), config);
            if (recoveryFound) {
                result.candidateCount++;
                Candidate memory recovery =
                    _evaluateCandidate(context, position, risk, config, recoveryLower, recoveryUpper, position.inRange);
                if (recovery.admissible) {
                    result.admissibleCount++;
                    result.bestRecovery = _betterRecovery(result.bestRecovery, recovery);
                }
            }
        }
    }

    function _evaluateCandidate(
        Context memory context,
        Position memory position,
        RiskConfig memory risk,
        SearchConfig memory config,
        int24 lower,
        int24 upper,
        bool enforceMovementBounds
    ) private pure returns (Candidate memory candidate) {
        candidate.lower = lower;
        candidate.upper = upper;
        bool isCurrentRange = position.exists && lower == position.lower && upper == position.upper;
        if (
            lower >= upper || lower <= MIN_TICK || upper >= MAX_TICK
                || (
                    !isCurrentRange
                        && (
                            config.referenceTick <= lower || config.referenceTick >= upper || config.liveTick <= lower
                                || config.liveTick >= upper
                        )
                )
        ) return candidate;

        uint256 halfWidth = uint256(uint24(upper - lower)) / 2;
        if (!isCurrentRange && (halfWidth < config.minHalfRangeTicks || halfWidth > config.maxHalfRangeTicks)) {
            return candidate;
        }
        if (
            !isCurrentRange
                && !_rangeSkewWithinBounds(lower, upper, config.liveTick, config.tickSpacing, config.maxSkewBps)
        ) return candidate;

        if (enforceMovementBounds && position.exists && !_movementWithinBounds(position, config, lower, upper)) {
            return candidate;
        }

        uint24 volatility = config.forecastVolatilityTicks > 10 ? config.forecastVolatilityTicks : 10;
        (int32 scenarioScore, int32 expectedFees, int32 scenarioRisk) = RangeOperations.evaluateStrategyScenarios(
            RangeOperations.StrategyScenarioInput({
                lower: lower,
                upper: upper,
                liveTick: config.referenceTick,
                trendTicks: config.forecastTrendTicks,
                volatilityTicks: volatility,
                forecastFeeRateBps: config.forecastFeeRateBps,
                analyticalWidthTicks: config.analyticalWidth,
                tailRiskBps: risk.tailRiskBps
            })
        );
        int256 score = scenarioScore;
        uint256 transition = position.exists && (position.lower != lower || position.upper != upper)
            ? _transitionCost(position.lower, position.upper, lower, upper, config.analyticalAnchor)
                + config.transitionCostBps
            : 0;
        score -= int256(transition);

        (bool dnAdmissible, uint256 dnPenalty, uint256 hedgeDriftBps) =
            _candidatePenalty(context, position, risk, lower, upper, config.liveTick);
        if (!dnAdmissible) return candidate;
        score -= int256(dnPenalty);
        candidate.scoreBps = _clampInt32(score);
        candidate.feesBps = expectedFees;
        candidate.transitionCostBps = _clampInt32(int256(transition));
        candidate.riskPenaltyBps = _clampInt32(int256(scenarioRisk) + int256(dnPenalty));
        candidate.hedgeDriftBps = uint32(_min(hedgeDriftBps, type(uint32).max));
        candidate.admissible = true;
    }

    function _candidatePenalty(
        Context memory context,
        Position memory position,
        RiskConfig memory risk,
        int24 lower,
        int24 upper,
        int24 liveTick
    ) private pure returns (bool admissible, uint256 penaltyBps, uint256 hedgeDriftBps) {
        if (!context.configured) return (false, 0, 0);
        if (!position.exists) return (true, 0, 0);

        uint256 targetShort = _candidateTargetShort(context, position, lower, upper, liveTick);
        if (targetShort == 0) return (false, 0, 0);
        uint256 effectiveShort = context.effectiveShortToken0 < 0 ? 0 : uint256(context.effectiveShortToken0);
        Projection memory projected = _projectHedgeState(context, risk, targetShort);
        if (!projected.admissible) return (false, 0, projected.hedgeDriftBps);

        uint256 turnoverPenalty = _min(_absDiff(targetShort, effectiveShort) * BPS / targetShort / 4, 2000);
        uint256 horizonRateBps =
            context.variableBorrowRateRay * risk.strategicHorizonSeconds * BPS / (uint256(1e27) * 365 days);
        if (horizonRateBps == 0) horizonRateBps = 1;
        uint256 borrowPenalty = projected.debtBase * horizonRateBps / _max(context.collateralBase, 1);
        return (true, _min(turnoverPenalty + borrowPenalty, 3000), projected.hedgeDriftBps);
    }

    function _hedgeAlignedRange(
        Context memory context,
        Position memory position,
        uint16 width,
        SearchConfig memory config
    ) private pure returns (int24 bestLower, int24 bestUpper, bool found) {
        if (!position.exists || !context.configured) return (0, 0, false);
        int256 spacing = int256(config.tickSpacing);
        int256 low = int256(config.liveTick) - int256(uint256(width)) + spacing;
        int256 high = int256(config.liveTick) + int256(uint256(width)) - spacing;
        if (position.inRange) {
            int256 oldCenter = (int256(position.lower) + position.upper) / 2;
            uint256 oldWidth = uint256(uint24(position.upper - position.lower));
            int256 maxCenterMove = int256(oldWidth * config.maxCenterMoveBps / BPS);
            int256 minimumCenter = oldCenter - maxCenterMove;
            int256 maximumCenter = oldCenter + maxCenterMove;
            if (low < minimumCenter) low = minimumCenter;
            if (high > maximumCenter) high = maximumCenter;
        }
        if (low > high) return (0, 0, false);
        int256 minimumSearchCenter = low;
        int256 maximumSearchCenter = high;
        uint256 effectiveShort = context.effectiveShortToken0 < 0 ? 0 : uint256(context.effectiveShortToken0);
        uint256 bestDifference = type(uint256).max;

        for (uint256 iteration; iteration < 12 && low <= high; ++iteration) {
            int256 middle = (low + high) / 2;
            (int24 lower, int24 upper) = _alignedRange(_clampInt24(middle), width, config.tickSpacing);
            uint256 target;
            if (
                config.liveTick > lower && config.liveTick < upper
                    && _rangeSkewWithinBounds(lower, upper, config.liveTick, config.tickSpacing, config.maxSkewBps)
            ) {
                target = _candidateTargetShort(context, position, lower, upper, config.liveTick);
                if (target > 0 && (!position.inRange || _movementWithinBounds(position, config, lower, upper))) {
                    uint256 difference = _absDiff(target, effectiveShort);
                    if (difference < bestDifference) {
                        bestDifference = difference;
                        bestLower = lower;
                        bestUpper = upper;
                        found = true;
                    }
                }
            }
            if (target < effectiveShort) low = middle + spacing;
            else high = middle - spacing;
        }

        // The off-chain model also evaluates the two terminal bounds after the
        // bounded binary search. Keep both implementations bit-for-bit aligned.
        for (uint256 endpoint; endpoint < 2; ++endpoint) {
            int256 center = endpoint == 0 ? low : high;
            if (center < minimumSearchCenter) center = minimumSearchCenter;
            if (center > maximumSearchCenter) center = maximumSearchCenter;
            (int24 lower, int24 upper) = _alignedRange(_clampInt24(center), width, config.tickSpacing);
            if (config.liveTick <= lower || config.liveTick >= upper) continue;
            if (!_rangeSkewWithinBounds(lower, upper, config.liveTick, config.tickSpacing, config.maxSkewBps)) continue;
            if (position.inRange && !_movementWithinBounds(position, config, lower, upper)) continue;
            uint256 target = _candidateTargetShort(context, position, lower, upper, config.liveTick);
            if (target == 0) continue;
            uint256 difference = _absDiff(target, effectiveShort);
            if (difference < bestDifference) {
                bestDifference = difference;
                bestLower = lower;
                bestUpper = upper;
                found = true;
            }
        }
    }

    function _movementWithinBounds(Position memory position, SearchConfig memory config, int24 lower, int24 upper)
        private
        pure
        returns (bool)
    {
        int256 oldCenter = (int256(position.lower) + position.upper) / 2;
        int256 newCenter = (int256(lower) + upper) / 2;
        uint256 oldWidth = uint256(uint24(position.upper - position.lower));
        uint256 centerMove = _absInt(newCenter - oldCenter);
        uint256 widthMove = _absDiff(uint256(uint24(upper - lower)), oldWidth);
        return centerMove * BPS <= oldWidth * config.maxCenterMoveBps
            && widthMove * BPS <= oldWidth * config.maxWidthChangeBps;
    }

    function _rangeSkewWithinBounds(int24 lower, int24 upper, int24 liveTick, int24 tickSpacing, uint16 maxSkewBps)
        private
        pure
        returns (bool)
    {
        uint256 halfWidth = uint256(uint24(upper - lower)) / 2;
        if (halfWidth == 0) return false;
        int256 center = (int256(lower) + upper) / 2;
        uint256 centerDistance = _absInt(center - liveTick);
        uint256 alignmentTolerance = uint256(uint24(tickSpacing));
        return centerDistance * BPS <= halfWidth * maxSkewBps + alignmentTolerance * BPS;
    }

    function _betterRecovery(Candidate memory current, Candidate memory candidate)
        private
        pure
        returns (Candidate memory)
    {
        if (
            !current.admissible || candidate.hedgeDriftBps < current.hedgeDriftBps
                || (candidate.hedgeDriftBps == current.hedgeDriftBps && candidate.scoreBps > current.scoreBps)
        ) return candidate;
        return current;
    }

    function hedgeOnlyStatus(Context memory context, Position memory position, RiskConfig memory risk, int24 liveTick)
        external
        pure
        returns (uint256 driftBps, uint256 exposureBps, bool adjustmentFeasible)
    {
        (driftBps, exposureBps, adjustmentFeasible,) = _hedgeOnlyStatus(context, position, risk, liveTick);
    }

    function currentHedgeState(Context memory context, Position memory position, int24 liveTick)
        external
        pure
        returns (uint256 token0InLp, uint256 targetShort, uint256 driftBps)
    {
        if (!position.exists || position.liquidity == 0) return (0, 0, 0);
        (token0InLp,) =
            RangeOperations.strategyAmountsAtTick(position.lower, position.upper, liveTick, position.liquidity);
        targetShort = token0InLp * context.hedgeTargetBps / BPS;
        if (targetShort > 0) {
            driftBps = context.effectiveShortToken0 < 0
                ? (targetShort + uint256(-context.effectiveShortToken0)) * BPS / targetShort
                : _absDiff(uint256(context.effectiveShortToken0), targetShort) * BPS / targetShort;
        }
    }

    function hedgeControl(
        Context memory context,
        Position memory position,
        RiskConfig memory risk,
        int24 liveTick,
        uint16 minimumHedgeDeltaBps,
        uint64 previousSignalSince,
        uint8 previousDirection,
        uint32 confirmationSeconds
    ) external view returns (HedgeControl memory control) {
        uint8 direction;
        (control.driftBps, control.exposureBps, control.adjustmentFeasible, direction) =
            _hedgeOnlyStatus(context, position, risk, liveTick);
        bool exposureLargeEnough = control.exposureBps >= minimumHedgeDeltaBps;
        (control.signalSince, control.direction, control.normalConfirmed) = _nextHedgeSignal(
            previousSignalSince,
            previousDirection,
            direction,
            control.driftBps,
            exposureLargeEnough,
            control.adjustmentFeasible,
            context.adjustThresholdBps,
            confirmationSeconds
        );
        control.critical =
            control.adjustmentFeasible && exposureLargeEnough && control.driftBps >= context.criticalHedgeBps;
        bool cooldownElapsed = block.timestamp >= uint256(context.lastAdjustmentAt) + context.cooldownSeconds;
        bool normalEligible = control.adjustmentFeasible && exposureLargeEnough && control.normalConfirmed
            && control.driftBps >= context.adjustThresholdBps && cooldownElapsed
            && _hedgeOnlyRangeStable(position, liveTick, risk.hedgeOnlyMinEdgeBps);
        control.eligible = control.critical || normalEligible;
    }

    function _nextHedgeSignal(
        uint64 previousSignalSince,
        uint8 previousDirection,
        uint8 currentDirection,
        uint256 driftBps,
        bool exposureLargeEnough,
        bool adjustmentFeasible,
        uint16 adjustThresholdBps,
        uint32 confirmationSeconds
    ) private view returns (uint64 signalSince, uint8 direction, bool confirmed) {
        uint256 resetThreshold = uint256(adjustThresholdBps) * HEDGE_RESET_RATIO_BPS / BPS;
        if (!adjustmentFeasible || !exposureLargeEnough || currentDirection == 0 || driftBps < resetThreshold) {
            return (0, 0, false);
        }

        if (previousSignalSince == 0 || previousDirection != currentDirection) {
            if (driftBps < adjustThresholdBps) return (0, 0, false);
            return (uint64(block.timestamp), currentDirection, confirmationSeconds == 0);
        }

        signalSince = previousSignalSince;
        direction = previousDirection;
        confirmed =
            driftBps >= adjustThresholdBps && block.timestamp >= uint256(previousSignalSince) + confirmationSeconds;
    }

    function _hedgeOnlyStatus(Context memory context, Position memory position, RiskConfig memory risk, int24 liveTick)
        private
        pure
        returns (uint256 driftBps, uint256 exposureBps, bool adjustmentFeasible, uint8 direction)
    {
        if (!context.configured) return (0, 0, false, 0);
        if (!position.exists || position.liquidity == 0) return (0, 0, false, 0);
        (uint256 token0InLp, uint256 token1InLp) =
            RangeOperations.strategyAmountsAtTick(position.lower, position.upper, liveTick, position.liquidity);
        uint256 target = token0InLp * context.hedgeTargetBps / BPS;
        if (context.effectiveShortToken0 < 0) {
            uint256 excessToken0 = uint256(-context.effectiveShortToken0);
            uint256 negativeToken0Units = 10 ** context.token0Decimals;
            uint256 negativePortfolioBase = token0InLp * uint256(context.price0) / negativeToken0Units
                + token1InLp * uint256(context.price1) / (10 ** context.token1Decimals);
            uint256 negativeExposureToken0 = target + excessToken0;
            uint256 negativeExposureBase = negativeExposureToken0 * uint256(context.price0) / negativeToken0Units;
            exposureBps =
                negativePortfolioBase == 0 ? type(uint256).max : negativeExposureBase * BPS / negativePortfolioBase;
            driftBps = target == 0 ? type(uint256).max : negativeExposureToken0 * BPS / target;
            return (driftBps, exposureBps, false, 1);
        }
        uint256 effectiveShort = uint256(context.effectiveShortToken0);
        direction = target > effectiveShort ? 1 : target < effectiveShort ? 2 : 0;
        uint256 exposureToken0 = _absDiff(effectiveShort, target);
        uint256 token0Units = 10 ** context.token0Decimals;
        uint256 portfolioBase = token0InLp * uint256(context.price0) / token0Units
            + token1InLp * uint256(context.price1) / (10 ** context.token1Decimals);
        uint256 exposureBase = exposureToken0 * uint256(context.price0) / token0Units;
        exposureBps = portfolioBase == 0 ? type(uint256).max : exposureBase * BPS / portfolioBase;
        if (target == 0) return (effectiveShort > 0 ? type(uint256).max : 0, exposureBps, false, direction);
        Projection memory projected = _projectHedgeState(context, risk, target);
        return (projected.hedgeDriftBps, exposureBps, projected.admissible, direction);
    }

    function selectAction(ActionInput memory input)
        external
        view
        returns (IRangeStrategyEngine.Action action, IRangeStrategyEngine.ReasonCode reason)
    {
        if (input.sameRange) {
            if (input.hedgeEligible) {
                return (IRangeStrategyEngine.Action.HEDGE_ONLY, IRangeStrategyEngine.ReasonCode.HEDGE_DRIFT);
            }
            return (
                IRangeStrategyEngine.Action.NO_ACTION,
                input.hedgePending
                    ? IRangeStrategyEngine.ReasonCode.HEDGE_CONFIRMING
                    : input.range.inRange
                        ? IRangeStrategyEngine.ReasonCode.IN_RANGE_EDGE_LOW
                        : IRangeStrategyEngine.ReasonCode.OUT_OF_RANGE_EVALUATING
            );
        }

        RangeTiming memory timing = _rangeTiming(input.range, input.hedgeEligible);
        bool actionableEdge = input.range.edgeEnough && timing.exitConfirmed;
        if (!input.forceHedgeRecovery && !timing.urgent && timing.cooldownActive) {
            if (input.hedgeEligible && !timing.coalesceHedge) {
                return (IRangeStrategyEngine.Action.HEDGE_ONLY, IRangeStrategyEngine.ReasonCode.HEDGE_DRIFT);
            }
            return (
                IRangeStrategyEngine.Action.NO_ACTION,
                timing.coalesceHedge
                    ? IRangeStrategyEngine.ReasonCode.HEDGE_COALESCING
                    : input.hedgePending
                        ? IRangeStrategyEngine.ReasonCode.HEDGE_CONFIRMING
                        : IRangeStrategyEngine.ReasonCode.COOLDOWN_ACTIVE
            );
        }

        if (actionableEdge || timing.urgent || input.forceHedgeRecovery) {
            reason = input.forceHedgeRecovery
                ? IRangeStrategyEngine.ReasonCode.HEDGE_DRIFT
                : timing.forcePersistent
                    ? IRangeStrategyEngine.ReasonCode.OUT_OF_RANGE_PERSISTENT
                    : timing.forceDeep
                        ? IRangeStrategyEngine.ReasonCode.OUT_OF_RANGE_DEEP
                        : IRangeStrategyEngine.ReasonCode.EDGE_SUFFICIENT;
            return (IRangeStrategyEngine.Action.RANGE_AND_HEDGE, reason);
        }
        if (input.hedgeEligible) {
            return timing.coalesceHedge
                ? (IRangeStrategyEngine.Action.NO_ACTION, IRangeStrategyEngine.ReasonCode.HEDGE_COALESCING)
                : (IRangeStrategyEngine.Action.HEDGE_ONLY, IRangeStrategyEngine.ReasonCode.HEDGE_DRIFT);
        }
        return (
            IRangeStrategyEngine.Action.NO_ACTION,
            input.hedgePending
                ? IRangeStrategyEngine.ReasonCode.HEDGE_CONFIRMING
                : input.range.inRange
                    ? IRangeStrategyEngine.ReasonCode.IN_RANGE_EDGE_LOW
                    : IRangeStrategyEngine.ReasonCode.OUT_OF_RANGE_EVALUATING
        );
    }

    function _rangeTiming(RangeTimingInput memory input, bool hedgeEligible)
        private
        view
        returns (RangeTiming memory timing)
    {
        timing.forcePersistent =
            input.outOfRangeSince > 0 && block.timestamp >= uint256(input.outOfRangeSince) + input.maxOutOfRangeSeconds;
        uint256 outsideDepth = input.liveTick < input.lower
            ? uint256(uint24(input.lower - input.liveTick))
            : input.liveTick > input.upper ? uint256(uint24(input.liveTick - input.upper)) : 0;
        uint256 currentHalfWidth = input.upper > input.lower ? uint256(uint24(input.upper - input.lower)) / 2 : 0;
        timing.forceDeep = !input.inRange && currentHalfWidth > 0 && outsideDepth >= currentHalfWidth;
        timing.exitConfirmed = input.inRange || input.exitConfirmed;
        timing.urgent = timing.forcePersistent || timing.forceDeep;
        uint256 rangeAvailableAt = uint256(input.lastRebalanceTime) + input.rebalanceCooldownSeconds;
        timing.cooldownActive = block.timestamp < rangeAvailableAt;
        bool cooldownEndsSoon =
            timing.cooldownActive && rangeAvailableAt <= block.timestamp + input.coalesceHorizonSeconds;
        bool persistenceDueSoon = input.outOfRangeSince > 0
            && uint256(input.outOfRangeSince) + input.maxOutOfRangeSeconds <= block.timestamp + input.coalesceHorizonSeconds;
        bool rangeSignal = (input.edgeEnough && timing.exitConfirmed) || !input.inRange;
        timing.coalesceHedge =
            hedgeEligible && !input.criticalHedge && rangeSignal && (cooldownEndsSoon || persistenceDueSoon);
    }

    function nextRangeExitState(
        Position memory position,
        int24 liveTick,
        int24 tacticalTwapTick,
        int24 tickSpacing,
        uint64 currentSignalSince,
        uint32 epochSeconds
    ) external view returns (uint64 nextSignalSince, bool confirmed) {
        if (!position.exists) return (0, false);
        if (position.inRange) {
            if (currentSignalSince == 0) return (0, true);
            nextSignalSince =
                _deepInsideRange(position, liveTick, tacticalTwapTick, tickSpacing) ? 0 : currentSignalSince;
            return (nextSignalSince, true);
        }

        nextSignalSince = currentSignalSince == 0 ? uint64(block.timestamp) : currentSignalSince;
        uint256 outsideDepth = liveTick < position.lower
            ? uint256(uint24(position.lower - liveTick))
            : liveTick > position.upper ? uint256(uint24(liveTick - position.upper)) : 0;
        uint256 halfWidth = uint256(uint24(position.upper - position.lower)) / 2;
        confirmed = _exitConfirmed(
            position, liveTick, tacticalTwapTick, tickSpacing, nextSignalSince, epochSeconds, outsideDepth, halfWidth
        );
    }

    function _exitConfirmed(
        Position memory position,
        int24 liveTick,
        int24 tacticalTwapTick,
        int24 tickSpacing,
        uint64 signalSince,
        uint32 epochSeconds,
        uint256 outsideDepth,
        uint256 currentHalfWidth
    ) private view returns (bool) {
        bool twapOutsideSameSide = (liveTick <= position.lower && tacticalTwapTick <= position.lower)
            || (liveTick >= position.upper && tacticalTwapTick >= position.upper);
        bool persistedOneEpoch = signalSince > 0 && block.timestamp >= uint256(signalSince) + epochSeconds;
        return twapOutsideSameSide || persistedOneEpoch
            || outsideDepth >= _exitConfirmationDepth(currentHalfWidth, tickSpacing);
    }

    function _deepInsideRange(Position memory position, int24 liveTick, int24 tacticalTwapTick, int24 tickSpacing)
        private
        pure
        returns (bool)
    {
        uint256 depth = uint256(uint24(tickSpacing));
        int256 resetLower = int256(position.lower) + int256(depth);
        int256 resetUpper = int256(position.upper) - int256(depth);
        return resetLower < resetUpper && int256(liveTick) > resetLower && int256(liveTick) < resetUpper
            && int256(tacticalTwapTick) > resetLower && int256(tacticalTwapTick) < resetUpper;
    }

    function _exitConfirmationDepth(uint256 halfWidth, int24 tickSpacing) private pure returns (uint256) {
        uint256 minimumDepth = uint256(uint24(tickSpacing)) * EXIT_CONFIRMATION_MIN_SPACINGS;
        uint256 proportionalDepth = halfWidth * EXIT_CONFIRMATION_DEPTH_BPS / BPS;
        return minimumDepth > proportionalDepth ? minimumDepth : proportionalDepth;
    }

    function hedgeOnlyRangeStable(Position memory position, int24 liveTick, uint16 minimumEdgeBps)
        external
        pure
        returns (bool)
    {
        return _hedgeOnlyRangeStable(position, liveTick, minimumEdgeBps);
    }

    function _hedgeOnlyRangeStable(Position memory position, int24 liveTick, uint16 minimumEdgeBps)
        private
        pure
        returns (bool)
    {
        if (!position.exists || liveTick <= position.lower || liveTick >= position.upper) return false;
        uint256 width = uint256(uint24(position.upper - position.lower));
        uint256 lowerDistance = uint256(uint24(liveTick - position.lower));
        uint256 upperDistance = uint256(uint24(position.upper - liveTick));
        return _min(lowerDistance, upperDistance) * BPS >= width * minimumEdgeBps;
    }

    function _candidateTargetShort(
        Context memory context,
        Position memory position,
        int24 lower,
        int24 upper,
        int24 liveTick
    ) private pure returns (uint256) {
        uint256 candidateToken0 = RangeOperations.strategyCandidateToken0ForCurrentValue(
            position.lower, position.upper, lower, upper, liveTick, position.liquidity
        );
        return candidateToken0 * context.hedgeTargetBps / BPS;
    }

    function _projectHedgeState(Context memory context, RiskConfig memory risk, uint256 targetShort)
        private
        pure
        returns (Projection memory projected)
    {
        if (!context.configured || targetShort == 0) return projected;
        uint256 effectiveShort = context.effectiveShortToken0 < 0 ? 0 : uint256(context.effectiveShortToken0);
        projected.hedgeDriftBps = _absDiff(targetShort, effectiveShort) * BPS / targetShort;
        uint256 units = 10 ** context.token0Decimals;
        uint256 targetBase = targetShort * uint256(context.price0) / units;
        uint256 currentEffectiveBase = effectiveShort * uint256(context.price0) / units;
        uint256 stableAssetsBase = context.collateralBase + context.idleStableBase;
        if (targetBase >= currentEffectiveBase) {
            uint256 additionalBorrowBase = targetBase - currentEffectiveBase;
            uint256 reserveBorrowCapacity = context.idleStableBase * context.borrowLtvBps / BPS;
            if (additionalBorrowBase > context.availableBorrowsBase + reserveBorrowCapacity) return projected;
            projected.debtBase = context.debtBase + additionalBorrowBase;
            stableAssetsBase += additionalBorrowBase * (BPS - context.swapSlippageBps) / BPS;
        } else {
            uint256 repaymentBase = currentEffectiveBase - targetBase;
            projected.debtBase = repaymentBase < context.debtBase ? context.debtBase - repaymentBase : 0;
            // Execution loss and debt price stress are independent. The remaining debt is
            // stressed below, so charging tailRiskBps here would double-count the same shock.
            uint256 repaymentCostBps = uint256(context.swapSlippageBps) + 10;
            uint256 conservativeWithdrawal = repaymentBase * (BPS + repaymentCostBps) / BPS;
            if (conservativeWithdrawal >= stableAssetsBase) return projected;
            stableAssetsBase -= conservativeWithdrawal;
        }
        if (projected.debtBase == 0) {
            projected.collateralBase = stableAssetsBase;
        } else {
            uint256 minimumCollateral =
                _ceilDiv(projected.debtBase * context.reserveHfTargetBps, context.liquidationThresholdBps);
            if (stableAssetsBase < minimumCollateral) return projected;
            uint256 operatingTarget =
                _ceilDiv(projected.debtBase * context.operationalHfTargetBps, context.liquidationThresholdBps);
            projected.collateralBase = _min(stableAssetsBase, operatingTarget);
        }
        if (
            projected.debtBase > 0
                && projected.collateralBase * context.liquidationThresholdBps / projected.debtBase
                    < context.reserveHfTargetBps
        ) return projected;
        uint256 stressedDebt = projected.debtBase * (BPS + risk.tailRiskBps) / BPS;
        if (
            stressedDebt > 0
                && projected.collateralBase * context.liquidationThresholdBps / stressedDebt < risk.minStressHfBps
        ) return projected;
        projected.admissible = true;
    }

    function _alignedRange(int24 center, uint16 width, int24 spacing) private pure returns (int24 lower, int24 upper) {
        lower = _floorToSpacing(_boundedTick(int256(center) - int256(uint256(width))), spacing);
        upper = _ceilToSpacing(_boundedTick(int256(center) + int256(uint256(width))), spacing);
        if (lower <= MIN_TICK) lower = _ceilToSpacing(MIN_TICK + spacing, spacing);
        if (upper >= MAX_TICK) upper = _floorToSpacing(MAX_TICK - spacing, spacing);
    }

    function _alignedAsymmetricRange(int24 center, uint16 down, uint16 up, int24 spacing)
        private
        pure
        returns (int24 lower, int24 upper)
    {
        lower = _floorToSpacing(_boundedTick(int256(center) - int256(uint256(down))), spacing);
        upper = _ceilToSpacing(_boundedTick(int256(center) + int256(uint256(up))), spacing);
        if (lower <= MIN_TICK) lower = _ceilToSpacing(MIN_TICK + spacing, spacing);
        if (upper >= MAX_TICK) upper = _floorToSpacing(MAX_TICK - spacing, spacing);
    }

    function _mulQ128(uint256 x, uint128 y) private pure returns (uint256 result) {
        uint256 hi = x >> 128;
        uint256 lo = x & type(uint128).max;
        result = hi * y + ((lo * y) >> 128);
    }

    function _floorToSpacing(int24 tick, int24 spacing) private pure returns (int24) {
        int24 remainder = tick % spacing;
        if (remainder == 0) return tick;
        return tick < 0 ? tick - remainder - spacing : tick - remainder;
    }

    function _ceilToSpacing(int24 tick, int24 spacing) private pure returns (int24) {
        int24 remainder = tick % spacing;
        if (remainder == 0) return tick;
        return tick < 0 ? tick - remainder : tick - remainder + spacing;
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

    function _transitionCost(int24 oldLower, int24 oldUpper, int24 newLower, int24 newUpper, int24 anchor)
        private
        pure
        returns (uint256)
    {
        uint256 oldWidth = uint256(uint24(oldUpper - oldLower));
        uint256 newWidth = uint256(uint24(newUpper - newLower));
        int256 oldCenter = (int256(oldLower) + oldUpper) / 2;
        int256 newCenter = (int256(newLower) + newUpper) / 2;
        uint256 movement =
            _absInt(newCenter - oldCenter) + _absDiff(newWidth, oldWidth) / 2 + _absInt(newCenter - anchor) / 4;
        return _min(movement * 500 / oldWidth, 500);
    }

    function _clampInt32(int256 value) private pure returns (int32) {
        if (value > type(int32).max) return type(int32).max;
        if (value < type(int32).min) return type(int32).min;
        return int32(value);
    }

    function _absInt(int256 value) private pure returns (uint256) {
        return uint256(value < 0 ? -value : value);
    }

    function _absDiff(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return numerator == 0 ? 0 : (numerator - 1) / denominator + 1;
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
