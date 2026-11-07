// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "./interfaces/ILiquidityRoutes.sol";
import "v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";

import "./RangeOperations.sol";
import "./interfaces/IRangeStrategyEngine.sol";

interface IStrategyStateInstallation {
    function installationSealed() external view returns (bool);
    function owner() external view returns (address);
    function depositorVoting() external view returns (address);
}

interface IStrategyStateRange {
    function strategyEngine() external view returns (address);
    function refreshPriceCache() external;
    function isProtocolBotCaller(address caller) external view returns (bool);
    function priceCache() external view returns (uint128, uint128, uint160, int24, uint64, bool);
}

interface IStrategyStateEngine {
    function depositorVoting() external view returns (address);
    function depositorStressParameters() external view returns (uint16, uint16);
}

interface IStrategyStateAave {
    function getConfiguration(address asset) external view returns (uint256);
    function getUserAccountData(address user)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256);
}

interface IStrategyStateToken {
    function balanceOf(address account) external view returns (uint256);
}

interface IStrategyStateHedge {
    function pool() external view returns (address);
    function usdc() external view returns (address);
    function aTokenUsdc() external view returns (address);
    function variableDebtWeth() external view returns (address);
    function rangeManager() external view returns (address);
    function stableDecimals() external view returns (uint8);
    function volatileDecimals() external view returns (uint8);
    function reserveHfTargetBps() external view returns (uint16);
    function operationalHfBufferBps() external view returns (uint16);
    function operationalHfTargetBps() external view returns (uint16);
    function hfRepairTriggerBps() external view returns (uint16);
    function liqThresholdBps() external view returns (uint16);
    function installationSealed() external view returns (bool);
}

/// @notice Shared state/forecast policy and guarded fixed-venue liquidity execution.
/// @dev Storage belongs to each linked caller. Routing binds the pair, venue, input and net output;
/// the RangeManager enforces authorization and the progressive module consumes canonical budgets.
interface IRoutingRange {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swapRouter() external view returns (ISwapRouter);
    function initMultiSwapTvl() external view returns (uint256);
    function protocolBotAddress() external view returns (address);
    function vault() external view returns (address);
    function priceCache() external view returns (RangeOperations.PriceCache memory);
    function config() external view returns (RangeOperations.RangeConfig memory);
    function refreshPriceCache() external;
    function getCurrentBalances() external view returns (uint256,uint256);
}
interface IRoutingProgressive { function progressiveRebalanceStatus() external view returns(uint8); }
interface IRoutingVault { function isRebalancing() external view returns(bool); }
library StrategyStateLib {
    using SafeERC20 for IERC20;
    function _liquidityCache() private view returns (RangeOperations.PriceCache memory) {
        return IRoutingRange(address(this)).priceCache();
    }
    error LiquidityRouteInvalid();
    error LiquidityPostGuard();
    event LiquidityRouteUsed(uint8 indexed route, uint256 amountIn, uint256 amountOut);
    event SwapExecuted(address indexed tokenIn,address indexed tokenOut,uint256 amountIn,uint256 amountOut);

    /// @dev Self-call boundary makes a failed/partial/LP-moving candidate roll back before the next route.
    function executeLiquidityRoute(bool z, uint256 amount, uint256 minimum, uint8 route, bytes calldata data)
        public returns (uint256 out)
    {
        IRoutingRange rm = IRoutingRange(address(this));
        LiquidityRoutes memory routes = ILiquidityRange(address(this)).liquidityRoutes();
        address input = z ? rm.token0() : rm.token1();
        address output = z ? rm.token1() : rm.token0();
        uint256 beforeIn = IERC20(input).balanceOf(address(this));
        uint256 beforeOut = IERC20(output).balanceOf(address(this));
        address target;
        bytes memory callData;
        if (route == 1 && routes.alternativeFee != 0) {
            target = address(rm.swapRouter());
            // An independent fee tier must not use the primary pool's spot-based sqrt limit.
            // The unchanged oracle minOut and post-LP guard bound execution instead.
            callData = abi.encodeCall(ISwapRouter.exactInputSingle, (ISwapRouter.ExactInputSingleParams(
                input, output, routes.alternativeFee, address(this), block.timestamp, amount, minimum, 0)));
        } else if (route == 2 && routes.curve != address(0)) {
            target = routes.curve;
            callData = abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)",
                z ? int128(0) : int128(1), z ? int128(1) : int128(0), amount, minimum);
        } else if (route == 3 && routes.fluid != address(0)) {
            target = routes.fluid;
            callData = abi.encodeWithSignature("swapIn(bool,uint256,uint256,address)",
                input == routes.fluidToken0, amount, minimum, address(this));
        } else if (route == 4 && routes.augustus != address(0)) {
            if (data.length < 12 || data.length > 32776) revert LiquidityRouteInvalid();
            uint256 deadline = uint64(bytes8(data[:8]));
            bytes calldata payload = data[8:];
            if (deadline < block.timestamp || deadline > block.timestamp + 180
                || bytes4(payload[:4]) != ILiquidityAugustus.swapExactAmountIn.selector) revert LiquidityRouteInvalid();
            (address executor, ILiquidityAugustus.GenericData memory q,,bytes memory permit,bytes memory executorData) =
                abi.decode(payload[4:],(address,ILiquidityAugustus.GenericData,uint256,bytes,bytes));
            if ((executor==address(0)||(executor!=routes.executor&&executor!=routes.executor2&&executor!=routes.executor3&&executor!=routes.executor4)) || permit.length != 0 || q.srcToken != input || q.destToken != output
                || q.fromAmount != amount || q.beneficiary != address(this) || q.quotedAmount < minimum
                || q.quotedAmount < q.toAmount) revert LiquidityRouteInvalid();
            if (q.toAmount < minimum) q.toAmount = minimum;
            target = routes.augustus;
            // No caller-selected partner payout, permit or native value. Output is measured net of router fees.
            callData = abi.encodeCall(ILiquidityAugustus.swapExactAmountIn,(executor,q,0,bytes(""),executorData));
        } else revert LiquidityRouteInvalid();
        uint256 previousAllowance = IERC20(input).allowance(address(this),target);
        IERC20(input).safeApprove(target,0);
        IERC20(input).safeApprove(target,amount);
        (bool success, bytes memory reason) = target.call(callData);
        if (!success) assembly ("memory-safe") { revert(add(reason,32),mload(reason)) }
        IERC20(input).safeApprove(target,0);
        // Preserve the constructor's existing approval to the canonical direct router only.
        if (target == address(rm.swapRouter()) && previousAllowance > 0) IERC20(input).safeApprove(target,previousAllowance);
        if (IERC20(input).balanceOf(address(this)) + amount != beforeIn) revert LiquidityRouteInvalid();
        out = IERC20(output).balanceOf(address(this)) - beforeOut;
        if (out < minimum) revert LiquidityRouteInvalid();
        rm.refreshPriceCache();
        if (!_liquidityCache().valid) revert LiquidityPostGuard();
        emit LiquidityRouteUsed(route,amount,out);
        emit SwapExecuted(input,output,amount,out);
    }



    function executeValidatedRoutedSwap(bool z, uint256 amount, uint256 minimum, uint8 route, bytes calldata data)
        external returns (uint256)
    {
        bool ordinary=_validateLiquiditySwap(z,amount,minimum,route);
        // The same-sized direct external routes always precede aggregation, including large tranches.
        if (route == 4) {
            (bool done,uint256 received)=tryDirectLiquidityRoutes(z,amount,minimum);
            if(done)return received;
            if(ordinary) {
                uint256 routeGas=gasleft()/4;if(routeGas>2000000)routeGas=2000000;
                try ILiquidityRange(address(this)).executeDirectLiquiditySwap{gas:routeGas}(z,amount,minimum,0,bytes(""))
                    returns(uint256 primaryOut){return primaryOut;}catch{}
            }
        }
        return executeLiquidityRoute(z,amount,minimum,route,data);
    }

    function _validateLiquiditySwap(bool z,uint256 amount,uint256 minimum,uint8 route) private view returns(bool ordinary) {
        IRoutingRange rm = IRoutingRange(address(this));
        RangeOperations.RangeConfig memory cfg = rm.config();
        RangeOperations.PriceCache memory pc = _liquidityCache();
        // Routed swaps have their own ordinary/external cap check immediately below.
        // Passing the ordinary cap here would reject every authorized large progressive tranche.
        RangeOperations.validateSwapAgainstOracle(z,amount,minimum,pc,cfg,0);
        LiquidityRoutes memory routes=ILiquidityRange(address(this)).liquidityRoutes();
        uint256 amountUsd=Math.mulDiv(amount,z?pc.price0:pc.price1,10**(z?cfg.token0Decimals:cfg.token1Decimals));
        (uint256 b0,uint256 b1)=rm.getCurrentBalances();
        uint256 assets=Math.mulDiv(b0,pc.price0,10**cfg.token0Decimals)+Math.mulDiv(b1,pc.price1,10**cfg.token1Decimals);
        ordinary=amountUsd<=rm.initMultiSwapTvl()*1e8;
        if(!ordinary) {
            // The ordinary cap is unchanged. A larger external-only tranche must belong to the
            // currently executing progressive module; its direction and total budgets were consumed there.
            address module=rm.protocolBotAddress();
            require(msg.sender==module && IRoutingProgressive(module).progressiveRebalanceStatus()==3
                && IRoutingVault(rm.vault()).isRebalancing(),"E91");
            require(assets>=uint256(routes.minVeloraTvlUsd)*1e8
                && amountUsd<=uint256(routes.maxExternalSwapUsd)*1e8
                && amountUsd<=Math.mulDiv(assets,routes.maxExternalTvlBps,10000),"E91");
        }
        if(route==4 && assets<uint256(routes.minVeloraTvlUsd)*1e8)revert LiquidityRouteInvalid();
    }



    /// @dev Each failed venue rolls back before the next one. No primary-LP fallback for a large tranche.
    function tryDirectLiquidityRoutes(bool z,uint256 amount,uint256 minimum) public returns(bool done,uint256 out) {
        LiquidityRoutes memory routes=ILiquidityRange(address(this)).liquidityRoutes();
        uint8[3] memory candidates=[uint8(3),uint8(2),uint8(1)];
        for(uint256 i;i<candidates.length;++i) {
            uint8 r=candidates[i];
            if((r==3&&routes.fluid==address(0))||(r==2&&routes.curve==address(0))
                ||(r==1&&routes.alternativeFee==0))continue;
            // A failed optional venue cannot consume the gas reserved for subsequent routes.
            uint256 routeGas=gasleft()/4;if(routeGas>2000000)routeGas=2000000;
            try ILiquidityRange(address(this)).executeDirectLiquiditySwap{gas:routeGas}(z,amount,minimum,r,bytes(""))
                returns(uint256 received){return(true,received);}catch{}
        }
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

    // Received local voting domain. Storage is supplied explicitly by its engine caller; no fixed slots.
    struct DepositorPolicy {
        address voting;
        uint32[12] bounds;
    }
    error InvalidConfiguration();
    event DepositorVotingInstalled(address indexed voting, bytes32 boundsHash);

    function installEngineVoting(
        DepositorPolicy storage state,
        address voting,
        address vault,
        uint8 profile,
        uint16 maxLearningInfluenceBps,
        uint32[4] memory values,
        uint32[12] memory customBounds,
        bool custom
    ) external {
        if (
            state.voting != address(0) || voting.code.length == 0
                || IStrategyStateInstallation(vault).installationSealed() || profile > 2 || custom != (profile == 2)
        ) revert InvalidConfiguration();
        uint32[12] memory bounds = custom
            ? customBounds
            : profile == 1
                ? [uint32(200), 500, 50, 14400, 43200, 7200, 1000, 2500, 500, 1500, 2500, 500]
                : [uint32(200), 500, 50, 7200, 28800, 7200, 1000, 2500, 500, 2000, 4000, 500];
        for (uint8 parameter; parameter < 4; ++parameter) {
            uint256 offset = uint256(parameter) * 3;
            uint32 minimum = bounds[offset];
            uint32 maximum = bounds[offset + 1];
            uint32 step = bounds[offset + 2];
            uint32 ceiling = parameter == 0
                ? 2000
                : parameter == 1 ? 86400 : parameter == 2 ? uint32(maxLearningInfluenceBps) : 5000;
            uint32 value = values[parameter];
            if (
                minimum == 0 || minimum > maximum || step == 0 || maximum > ceiling || (maximum - minimum) % step != 0
                    || value < minimum || value > maximum || (value - minimum) % step != 0
            ) revert InvalidConfiguration();
        }
        state.voting = voting;
        state.bounds = bounds;
        emit DepositorVotingInstalled(voting, keccak256(abi.encode(bounds)));
    }

    function engineVoteParameter(DepositorPolicy storage state, uint8 parameter, uint32 value)
        external
        view
        returns (uint32 current, uint32 minimum, uint32 maximum, uint32 step)
    {
        if (parameter > 3 || state.voting == address(0)) revert InvalidConfiguration();
        uint256 offset = uint256(parameter) * 3;
        return (value, state.bounds[offset], state.bounds[offset + 1], state.bounds[offset + 2]);
    }

    function validateEngineVote(
        DepositorPolicy storage state,
        uint8 parameter,
        uint32 value,
        uint256 expectedRevision,
        uint256 revision,
        uint32 current
    ) external view {
        if (msg.sender != state.voting || state.voting == address(0) || revision != expectedRevision || parameter > 3) revert InvalidConfiguration();
        uint256 offset = uint256(parameter) * 3;
        uint32 minimum = state.bounds[offset];
        uint32 maximum = state.bounds[offset + 1];
        if (value < minimum || value > maximum || (value - minimum) % state.bounds[offset + 2] != 0 || value == current)
        {
            revert InvalidConfiguration();
        }
    }

    struct ExpertState {
        uint16[4] trendWeights;
        uint16[3] volatilityWeights;
        uint16[3] feeWeights;
        int24[4] trendPredictions;
        uint24[3] volatilityPredictions;
        uint24[3] feePredictions;
    }

    struct ForecastInput {
        uint64 epoch;
        int24 tacticalTick;
        int24 strategicTick;
        uint16 observedFees;
        uint16 influence;
        uint256 feeGrowth0;
        uint256 feeGrowth1;
        bool configurationOnly;
        bool hybrid;
    }

    function initializeExperts(ExpertState storage experts) external {
        experts.trendWeights = [uint16(2500), 2500, 2500, 2500];
        experts.volatilityWeights = [uint16(3334), 3333, 3333];
        experts.feeWeights = [uint16(3334), 3333, 3333];
    }

    function updateForecast(MarketState storage state, ExpertState storage experts, ForecastInput memory input)
        external
        returns (bool learningUpdated)
    {
        uint64 previousTimestamp = state.checkpointTimestamp;
        int24 realized = previousTimestamp == 0
            ? int24(0)
            : _clampTick(int256(input.tacticalTick) - state.canonicalTick);
        uint24 absoluteMove = uint24(uint256(realized < 0 ? -int256(realized) : int256(realized)));
        learningUpdated = !input.configurationOnly && previousTimestamp != 0 && input.hybrid;
        if (learningUpdated) {
            experts.trendWeights =
                RangeOperations.updateTrendExpertWeights(experts.trendWeights, experts.trendPredictions, realized);
            experts.volatilityWeights = RangeOperations.updateUnsignedExpertWeights(
                experts.volatilityWeights, experts.volatilityPredictions, absoluteMove, 25
            );
            experts.feeWeights = RangeOperations.updateUnsignedExpertWeights(
                experts.feeWeights, experts.feePredictions, input.observedFees, 5
            );
        }
        uint24 fastVol =
            input.configurationOnly ? state.fastVolatilityTicks : _ewma(state.fastVolatilityTicks, absoluteMove, 5000);
        uint24 slowVol =
            input.configurationOnly ? state.slowVolatilityTicks : _ewma(state.slowVolatilityTicks, absoluteMove, 2000);
        uint24 upside = input.configurationOnly
            ? state.upsideSemivarianceTicks
            : _ewma(state.upsideSemivarianceTicks, realized > 0 ? absoluteMove : 0, 3000);
        uint24 downside = input.configurationOnly
            ? state.downsideSemivarianceTicks
            : _ewma(state.downsideSemivarianceTicks, realized < 0 ? absoluteMove : 0, 3000);
        uint16 slowFees = uint16(_ewma(state.forecastFeeRateBps, input.observedFees, 2000));
        if (!input.configurationOnly) {
            experts.trendPredictions = [
                realized,
                _clampTick(int256(input.tacticalTick) - input.strategicTick),
                _clampTick((int256(input.strategicTick) - input.tacticalTick) / 2),
                int24(0)
            ];
            experts.volatilityPredictions = [fastVol, slowVol, upside > downside ? upside : downside];
            experts.feePredictions =
                [uint24(input.observedFees), uint24(slowFees), uint24((uint256(input.observedFees) + slowFees) / 2)];
        }
        (int24 trend, uint24 vol, uint16 fees, uint16 uncertainty) = RangeOperations.combineStrategyForecasts(
            experts.trendPredictions,
            experts.volatilityPredictions,
            experts.feePredictions,
            experts.trendWeights,
            experts.volatilityWeights,
            experts.feeWeights,
            input.hybrid ? input.influence : 0
        );
        state.epoch = input.epoch;
        if (!input.configurationOnly) state.checkpointTimestamp = uint64(block.timestamp);
        state.canonicalTick = input.tacticalTick;
        state.tacticalTwapTick = input.tacticalTick;
        state.strategicTwapTick = input.strategicTick;
        state.forecastTrendTicks = trend;
        state.fastVolatilityTicks = fastVol;
        state.slowVolatilityTicks = slowVol;
        state.forecastVolatilityTicks = vol;
        state.upsideSemivarianceTicks = upside;
        state.downsideSemivarianceTicks = downside;
        state.observedFeeRateBps = input.observedFees;
        state.forecastFeeRateBps = fees;
        state.uncertaintyBps = uncertainty;
        state.feeGrowthGlobal0X128 = input.feeGrowth0;
        state.feeGrowthGlobal1X128 = input.feeGrowth1;
    }

    function _clampTick(int256 value) private pure returns (int24) {
        if (value > type(int24).max) return type(int24).max;
        if (value < type(int24).min) return type(int24).min;
        return int24(value);
    }

    function _ewma(uint256 previous, uint256 observed, uint256 alpha) private pure returns (uint24) {
        uint256 value = previous == 0 ? observed : (previous * (10000 - alpha) + observed * alpha) / 10000;
        return uint24(value > 20000 ? 20000 : value);
    }

    struct DepositorHedgePolicy {
        address voting;
        uint256 revision;
    }
    error DepositorConfigurationInvalid();
    error InvalidSwapPlan();
    event DepositorHfBufferApplied(uint16 bufferBps, uint16 targetBps, uint256 revision);
    event DepositorVotingInstalled(address indexed voting);

    function requireFactoryHedgeInstallation(address vault, address voting) external view {
        IStrategyStateInstallation installed = IStrategyStateInstallation(vault);
        if (installed.owner() != msg.sender || installed.installationSealed() || installed.depositorVoting() != voting)
        {
            revert DepositorConfigurationInvalid();
        }
    }

    function installDepositorHedgeVoting(DepositorHedgePolicy storage policy, address voting) external {
        IStrategyStateHedge context = IStrategyStateHedge(address(this));
        if (
            context.installationSealed() || policy.voting != address(0) || voting.code.length == 0
                || context.rangeManager() == address(0)
        ) revert DepositorConfigurationInvalid();
        _validateInitialHedge(context);
        address engine = IStrategyStateRange(context.rangeManager()).strategyEngine();
        if (IStrategyStateEngine(engine).depositorVoting() != voting) revert DepositorConfigurationInvalid();
        _validateHedgeTarget(context, context.operationalHfBufferBps());
        policy.voting = voting;
        policy.revision = 1;
        // The same event signature is declared by its HedgeManager.
        emit DepositorVotingInstalled(voting);
    }

    function validateDepositorHedgeSeal() external view {
        IStrategyStateHedge context = IStrategyStateHedge(address(this));
        _validateInitialHedge(context);
        _validateHedgeTarget(context, context.operationalHfBufferBps());
    }

    function applyDepositorHedgeVote(
        DepositorHedgePolicy storage policy,
        uint8 parameter,
        uint32 value,
        uint256 expectedRevision
    ) external {
        IStrategyStateHedge context = IStrategyStateHedge(address(this));
        if (
            msg.sender != policy.voting || policy.voting == address(0) || !context.installationSealed()
                || parameter != 4 || expectedRevision != policy.revision || value < 3000 || value > 9000
                || (value - 3000) % 1000 != 0 || value == context.operationalHfBufferBps()
        ) revert DepositorConfigurationInvalid();
        _validateHedgeTarget(context, value);
        ++policy.revision;
        emit DepositorHfBufferApplied(uint16(value), context.reserveHfTargetBps() + uint16(value), policy.revision);
    }

    function _validateInitialHedge(IStrategyStateHedge context) private view {
        if (
            context.reserveHfTargetBps() != 15000 || context.hfRepairTriggerBps() != 14000
                || context.operationalHfBufferBps() != 5000
        ) revert DepositorConfigurationInvalid();
    }

    function _validateHedgeTarget(IStrategyStateHedge context, uint32 buffer) private view {
        address engine = IStrategyStateRange(context.rangeManager()).strategyEngine();
        (uint16 stress, uint16 tail) = IStrategyStateEngine(engine).depositorStressParameters();
        uint256 target = uint256(context.reserveHfTargetBps()) + buffer;
        if (stress == 0 || target * 10000 < uint256(stress) * (10000 + uint256(tail))) revert DepositorConfigurationInvalid();
        uint256 config = IStrategyStateAave(context.pool()).getConfiguration(context.usdc());
        uint256 ltv = config & 0xffff;
        uint256 threshold = (config >> 16) & 0xffff;
        if (
            ltv == 0 || threshold <= ltv || threshold > 10000 || (config & (uint256(1) << 56)) == 0
                || target * ltv < threshold * 10000
        ) {
            revert DepositorConfigurationInvalid();
        }
    }

    error InvalidStrategyDecision();
    error HedgeCheck(uint8 code);

    /// @notice Consume the exact canonical hedge decision; no caller supplies debt, ticks or market data.
    /// The emergency repair selector remains independent of this engine-dependent ordinary route.
    function consumeCanonicalHedgeDecision(address rangeManager, uint16 adjustHedgeBps, address keeper)
        external
        returns (bool hfRepair)
    {
        if (rangeManager == address(0) || adjustHedgeBps == 0) revert HedgeCheck(40);
        IStrategyStateRange manager = IStrategyStateRange(rangeManager);
        manager.refreshPriceCache();
        IRangeStrategyEngine engine = IRangeStrategyEngine(manager.strategyEngine());
        if (address(engine) == address(0) || engine.hedgeManager() != address(this)) revert InvalidStrategyDecision();
        IRangeStrategyEngine.Decision memory decision = engine.previewDecision();
        if (decision.action == IRangeStrategyEngine.Action.HEDGE_ONLY) {
            IRangeStrategyEngine.Decision memory validated = engine.validateDecision(decision.decisionHash);
            if (validated.action != decision.action || validated.decisionHash != decision.decisionHash) {
                revert InvalidStrategyDecision();
            }
        }
        uint64 checkpointTimestamp = engine.currentTelemetry().checkpointTimestamp;
        bool protocolBot = manager.isProtocolBotCaller(keeper);
        if (decision.action == IRangeStrategyEngine.Action.HF_REPAIR) {
            engine.recordExecution(decision.decisionHash, decision.action, keeper);
            return true;
        }
        if (decision.action != IRangeStrategyEngine.Action.HEDGE_ONLY) revert HedgeCheck(44);
        if (protocolBot && block.timestamp < uint256(checkpointTimestamp) + 60) revert HedgeCheck(41);
        engine.recordExecution(decision.decisionHash, decision.action, keeper);
    }

    /// @notice Existing factual reserve view, shared without granting a position-changing operation.
    function hedgeStrategyReserveData() external view returns (uint256 idleStable, uint16 target, uint16 liveLtvBps) {
        IStrategyStateHedge context = IStrategyStateHedge(address(this));
        (,,,, uint256 ltv,) = IStrategyStateAave(context.pool()).getUserAccountData(address(this));
        idleStable = IStrategyStateToken(context.usdc()).balanceOf(address(this));
        target = context.operationalHfTargetBps();
        if (ltv == 0 && target > 0) ltv = uint256(context.liqThresholdBps()) * 10000 / target;
        liveLtvBps = uint16(ltv);
    }

    function hedgeData() external view returns (uint256 collateral, uint256 debt, uint256 hf, uint256 borrowable) {
        IStrategyStateHedge context = IStrategyStateHedge(address(this));
        (,, borrowable,,, hf) = IStrategyStateAave(context.pool()).getUserAccountData(address(this));
        (uint128 price0, uint128 price1,,, uint64 timestamp, bool valid) =
            IStrategyStateRange(context.rangeManager()).priceCache();
        if ((!valid && timestamp != uint64(block.timestamp)) || price0 == 0 || price1 == 0) revert InvalidSwapPlan();
        collateral = IStrategyStateToken(context.aTokenUsdc()).balanceOf(address(this)) * uint256(price1)
            / (10 ** context.stableDecimals());
        debt = IStrategyStateToken(context.variableDebtWeth()).balanceOf(address(this)) * uint256(price0)
            / (10 ** context.volatileDecimals());
    }
}
