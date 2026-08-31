// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import "./RangeOperations.sol";
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";

interface ISafe {
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool success);
}

interface IERC20Sweep {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IRangeManagerBotState {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function priceCache() external view returns (RangeOperations.PriceCache memory);
    function getOwnerPositions() external view returns (uint256[] memory);
    function getCurrentBalances() external view returns (uint256 balance0, uint256 balance1);
    function getOptimalSwapParams() external view returns (RangeOperations.OptimalSwapParams memory);
    function initMultiSwapTvl() external view returns (uint256);
    function positionManager() external view returns (INonfungiblePositionManager);
    function refreshPriceCache() external;
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);

    function config() external view returns (RangeOperations.RangeConfig memory);
}

interface IProgressiveRangeManager {
    function progressiveRebalance(
        uint8 step,
        bytes32 expectedDecisionHash,
        int24 tickLower,
        int24 tickUpper,
        uint256 amountIn,
        uint256 minAmountOut,
        address keeper
    ) external returns (int24 lower, int24 upper);
}

interface IProgressiveVault {
    function endRebalance() external;
    function isRebalancing() external view returns (bool);
}

contract SecureBotModule {
    address public immutable safe;
    address public immutable botAddress;
    address public immutable rangeManager;
    address public immutable strategyEngine;
    address public immutable vault;
    address public immutable pauseController;
    address public immutable treasury;
    address public owner;
    address public pendingOwner;

    // Sécurité renforcée
    mapping(bytes4 => bool) private _allowedFunctions;
    uint256 public dailyLimit;
    uint256 public dailySpent;
    uint256 public lastResetDay;
    bool public paused;
    bool public directExecution;

    // 0 idle, 1 starting, 2 active, 3 executing. The transient states also block callback reentrancy.
    uint8 public progressiveRebalanceStatus;
    int24 public progressiveTickLower;
    int24 public progressiveTickUpper;
    bytes32 public progressiveDecisionHash;
    uint256 public progressiveSwapBudgetUsdE8;

    // endRebalance() est exempte de la limite quotidienne: ce deverrouillage ne deplace aucun fonds.
    // Mints, depots et rebalances utilisent leurs entrees atomiques; l'ancien automate module
    // start/burn/swap/mint n'est plus expose.
    bytes4 private constant END_REBALANCE_SELECTOR = 0x0040718e; // endRebalance()
    bytes4 private constant REFRESH_PRICE_SELECTOR = 0x0be1c372; // refreshPriceCache()
    bytes4 private constant CHECKPOINT_SELECTOR = bytes4(keccak256("checkpointMarketState()"));
    bytes4 private constant REBALANCE_SELECTOR =
        bytes4(keccak256("rebalance(bytes32,uint256[],uint256[],address,address)"));

    // Events
    event FunctionExecuted(bytes4 indexed selector, uint256 dailyCount);
    event FunctionAllowed(bytes4 indexed selector, bool allowed);
    event DailyLimitUpdated(uint256 newLimit);
    event Paused(bool paused);
    event DirectExecutionUpdated(bool enabled);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event ModuleSweep(address indexed token, uint256 amount);
    event ProgressiveRebalanceStarted(bytes32 indexed decisionHash, int24 tickLower, int24 tickUpper, address keeper);
    event ProgressiveRebalanceChunk(uint256 amountIn, uint256 amountOut, address keeper);
    event ProgressiveRebalanceFinalized(bytes32 indexed decisionHash, address keeper);
    event ProgressiveRebalanceCancelled(bytes32 indexed decisionHash, address safe);

    constructor(
        address _safe,
        address _botAddress,
        address _rangeManager,
        address _strategyEngine,
        address _vault,
        address _pauseController,
        address _treasury,
        uint256 _dailyLimit
    ) {
        require(
            _safe != address(0) && _botAddress != address(0) && _rangeManager != address(0)
                && _strategyEngine != address(0) && _strategyEngine.code.length > 0 && _vault != address(0)
                && _pauseController != address(0) && _treasury != address(0),
            "E_ZERO"
        );
        require(_dailyLimit > 0 && _dailyLimit <= 1000, "E_LIMIT");
        safe = _safe;
        botAddress = _botAddress;
        rangeManager = _rangeManager;
        strategyEngine = _strategyEngine;
        vault = _vault;
        pauseController = _pauseController;
        treasury = _treasury;
        owner = _safe; // La Safe est owner
        dailyLimit = _dailyLimit;

        // Autoriser les fonctions essentielles au deploiement
        // Fonctions RangeManager
        // configurePriceFeeds (0x6509c2dd) RETIRÉ (audit V1) : repointage des oracles = gouvernance uniquement
        // (Safe Phase 1 / Timelock Phase 2). Une clé bot compromise ne peut pas empoisonner les prix.
        // Le bot rafraîchit le cache
        // via refreshPriceCache() ci-dessous, qui ne change aucune adresse.
        _allowedFunctions[0x0be1c372] = true; // refreshPriceCache()
        _allowedFunctions[CHECKPOINT_SELECTOR] = true;
        _allowedFunctions[REBALANCE_SELECTOR] = true;
        // Les setters de strategie/risk du moteur et du RangeManager restent reserves a la gouvernance.

        // Fonctions MultiUserVault
        // processPendingDeposits (0x99dd7ead) RETIRÉ (audit V1) : fonction batch supprimée du Vault.
        // processSingleDeposit (0xac1df9bd) RETIRÉ de la whitelist : le bot traite désormais aussi le
        // mint initial standard via processDepositPermissionless(), en une transaction atomique bot-only.
        _allowedFunctions[0x76919a59] = true; // processDepositPermissionless(uint256[],uint256[],address,address)
        _allowedFunctions[0x0040718e] = true; // endRebalance()

        // Fonctions Treasury (bridge Stargate v2 vers staking contract Phase 2)
        _allowedFunctions[0xa5599124] = true; // bridgeToStakers(uint256)
        _allowedFunctions[0x56a12aca] = true; // distributeToStakers(uint256) - bridge treasury same-chain
    }

    receive() external payable {}

    /// @notice Permissionless high-TVL path. It remains callable if the hot-bot relay is paused because
    ///         every decision, price, direction and amount is revalidated by RangeManager on-chain.
    function beginProgressiveRebalance(bytes32 expectedDecisionHash) external {
        require(progressiveRebalanceStatus == 0, "Progressive active");
        progressiveRebalanceStatus = 1;
        IRangeManagerBotState(rangeManager).refreshPriceCache();
        progressiveSwapBudgetUsdE8 = _requireProgressivePlan();
        (int24 lower, int24 upper) =
            IProgressiveRangeManager(rangeManager).progressiveRebalance(0, expectedDecisionHash, 0, 0, 0, 0, msg.sender);
        progressiveTickLower = lower;
        progressiveTickUpper = upper;
        progressiveDecisionHash = expectedDecisionHash;
        progressiveRebalanceStatus = 2;
        emit ProgressiveRebalanceStarted(expectedDecisionHash, lower, upper, msg.sender);
    }

    function _requireProgressivePlan() private view returns (uint256 budgetUsdE8) {
        IRangeManagerBotState rm = IRangeManagerBotState(rangeManager);
        RangeOperations.OptimalSwapParams memory plan = rm.getOptimalSwapParams();
        RangeOperations.PriceCache memory cache = rm.priceCache();
        RangeOperations.RangeConfig memory cfg = rm.config();
        require(cache.valid && cache.price0 > 0 && cache.price1 > 0, "Invalid price");
        uint256 price = plan.zeroForOne ? cache.price0 : cache.price1;
        uint256 decimals = plan.zeroForOne ? cfg.token0Decimals : cfg.token1Decimals;
        uint256 amountUsd = Math.mulDiv(plan.amountIn, price, 10 ** decimals);
        require(plan.swapNeeded && amountUsd > rm.initMultiSwapTvl() * 1e8, "Use atomic");
        budgetUsdE8 = Math.mulDiv(plan.currentBalance0, cache.price0, 10 ** cfg.token0Decimals)
            + Math.mulDiv(plan.currentBalance1, cache.price1, 10 ** cfg.token1Decimals);
        require(budgetUsdE8 > 0, "Invalid budget");
    }

    function continueProgressiveRebalance(uint256 amountIn, uint256 minAmountOut) external {
        require(progressiveRebalanceStatus == 2 && IProgressiveVault(vault).isRebalancing(), "No progressive");
        progressiveRebalanceStatus = 3;
        IRangeManagerBotState(rangeManager).refreshPriceCache();
        RangeOperations.OptimalSwapParams memory plan = _progressiveSwapParams();
        require(plan.swapNeeded && amountIn > 0 && amountIn <= plan.amountIn, "Invalid chunk");
        _consumeProgressiveSwapBudget(plan.zeroForOne, amountIn);
        IRangeManagerBotState rm = IRangeManagerBotState(rangeManager);
        address tokenIn = plan.zeroForOne ? rm.token0() : rm.token1();
        address tokenOut = plan.zeroForOne ? rm.token1() : rm.token0();
        uint256 amountOut = rm.executeSwap(tokenIn, tokenOut, amountIn, minAmountOut);
        progressiveRebalanceStatus = 2;
        emit ProgressiveRebalanceChunk(amountIn, amountOut, msg.sender);
    }

    function getProgressiveSwapParams() external view returns (RangeOperations.OptimalSwapParams memory) {
        require(progressiveRebalanceStatus == 2, "No progressive");
        return _progressiveSwapParams();
    }

    function _progressiveSwapParams() private view returns (RangeOperations.OptimalSwapParams memory) {
        IRangeManagerBotState rm = IRangeManagerBotState(rangeManager);
        RangeOperations.PriceCache memory cache = rm.priceCache();
        require(cache.valid, "Invalid price");
        (uint256 balance0, uint256 balance1) = rm.getCurrentBalances();
        return RangeOperations.calculateOptimalSwapParams(
            balance0, balance1, cache, rm.config(), progressiveTickLower, progressiveTickUpper
        );
    }

    function finalizeProgressiveRebalance(uint256 amountIn, uint256 minAmountOut) external {
        require(progressiveRebalanceStatus == 2 && IProgressiveVault(vault).isRebalancing(), "No progressive");
        progressiveRebalanceStatus = 3;
        if (amountIn > 0) {
            IRangeManagerBotState(rangeManager).refreshPriceCache();
            RangeOperations.OptimalSwapParams memory plan = _progressiveSwapParams();
            require(plan.swapNeeded && amountIn <= plan.amountIn, "Invalid chunk");
            _consumeProgressiveSwapBudget(plan.zeroForOne, amountIn);
        }
        bytes32 decisionHash = progressiveDecisionHash;
        IProgressiveRangeManager(rangeManager).progressiveRebalance(
            2, bytes32(0), progressiveTickLower, progressiveTickUpper, amountIn, minAmountOut, msg.sender
        );
        delete progressiveTickLower;
        delete progressiveTickUpper;
        delete progressiveDecisionHash;
        delete progressiveSwapBudgetUsdE8;
        progressiveRebalanceStatus = 0;
        emit ProgressiveRebalanceFinalized(decisionHash, msg.sender);
    }

    function _consumeProgressiveSwapBudget(bool zeroForOne, uint256 amountIn) private {
        IRangeManagerBotState rm = IRangeManagerBotState(rangeManager);
        RangeOperations.PriceCache memory cache = rm.priceCache();
        RangeOperations.RangeConfig memory cfg = rm.config();
        uint256 amountUsdE8 = Math.mulDiv(
            amountIn,
            zeroForOne ? cache.price0 : cache.price1,
            10 ** (zeroForOne ? cfg.token0Decimals : cfg.token1Decimals)
        );
        require(amountUsdE8 > 0 && amountUsdE8 <= progressiveSwapBudgetUsdE8, "Cycle budget");
        progressiveSwapBudgetUsdE8 -= amountUsdE8;
    }

    /// @notice Emergency-only release. It never swaps or transfers principal; funds stay idle in RangeManager.
    function cancelProgressiveRebalance() external {
        require(msg.sender == safe && progressiveRebalanceStatus != 0, "Only Safe");
        bytes32 decisionHash = progressiveDecisionHash;
        progressiveRebalanceStatus = 3;
        if (IProgressiveVault(vault).isRebalancing()) IProgressiveVault(vault).endRebalance();
        delete progressiveTickLower;
        delete progressiveTickUpper;
        delete progressiveDecisionHash;
        delete progressiveSwapBudgetUsdE8;
        progressiveRebalanceStatus = 0;
        emit ProgressiveRebalanceCancelled(decisionHash, msg.sender);
    }

    /// @notice LP/free RangeManager NAV reconstructed at the Chainlink token ratio (USD, 8 decimals).
    /// @dev Read-only and unaffected by the module kill-switch. Two Newton steps start from a spot sqrt price
    ///      bounded by the mandatory RangeManager oracle-deviation guard, removing meaningful flash-slot0
    ///      influence from share minting without constraining bot or keeper execution paths.
    function getOracleLpValueUsd() external view returns (uint256 valueUsd) {
        IRangeManagerBotState rm = IRangeManagerBotState(rangeManager);
        RangeOperations.PriceCache memory cache = rm.priceCache();
        require(cache.valid && cache.price0 > 0 && cache.price1 > 0 && cache.poolSqrtPriceX96 > 0, "E_NAV");
        RangeOperations.RangeConfig memory cfg = rm.config();
        uint160 oracleSqrt =
            _oracleSqrtPrice(cache.price0, cache.price1, cache.poolSqrtPriceX96, cfg.token0Decimals, cfg.token1Decimals);
        (uint256 balance0, uint256 balance1) = _balancesAtPrice(rm, oracleSqrt);
        valueUsd = Math.mulDiv(balance0, cache.price0, 10 ** cfg.token0Decimals)
            + Math.mulDiv(balance1, cache.price1, 10 ** cfg.token1Decimals);
    }

    function _oracleSqrtPrice(uint128 price0, uint128 price1, uint160 seed, uint8 dec0, uint8 dec1)
        private
        pure
        returns (uint160)
    {
        uint256 ratioX192 =
            Math.mulDiv(uint256(price0) * (10 ** dec1), uint256(1) << 192, uint256(price1) * (10 ** dec0));
        uint256 guess = seed;
        guess = (guess + ratioX192 / guess) >> 1;
        guess = (guess + ratioX192 / guess) >> 1;
        require(guess > 0 && guess <= type(uint160).max, "E_RATIO");
        return uint160(guess);
    }

    function _balancesAtPrice(IRangeManagerBotState rm, uint160 sqrtPriceX96)
        private
        view
        returns (uint256 balance0, uint256 balance1)
    {
        balance0 = IERC20Sweep(rm.token0()).balanceOf(rangeManager);
        balance1 = IERC20Sweep(rm.token1()).balanceOf(rangeManager);
        uint256[] memory positions = rm.getOwnerPositions();
        require(positions.length <= 1, "E_POS");
        if (positions.length == 0) return (balance0, balance1);

        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,, uint128 owed0, uint128 owed1) =
            rm.positionManager().positions(positions[0]);
        (uint256 amount0, uint256 amount1) = _liquidityAmounts(liquidity, tickLower, tickUpper, sqrtPriceX96);
        return (balance0 + amount0 + owed0, balance1 + amount1 + owed1);
    }

    function _liquidityAmounts(uint128 liquidity, int24 tickLower, int24 tickUpper, uint160 sqrtPriceX96)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) return (0, 0);
        uint160 sqrtA = RangeOperations.sqrtRatioAtTickExt(tickLower);
        uint160 sqrtB = RangeOperations.sqrtRatioAtTickExt(tickUpper);
        uint256 numerator = uint256(liquidity) << 96;
        if (sqrtPriceX96 <= sqrtA) {
            amount0 = numerator / sqrtA - numerator / sqrtB;
        } else if (sqrtPriceX96 >= sqrtB) {
            amount1 = Math.mulDiv(liquidity, sqrtB - sqrtA, uint256(1) << 96);
        } else {
            amount0 = numerator / sqrtPriceX96 - numerator / sqrtB;
            amount1 = Math.mulDiv(liquidity, sqrtPriceX96 - sqrtA, uint256(1) << 96);
        }
    }

    modifier onlyBot() {
        require(msg.sender == botAddress, "Only bot allowed");
        require(!paused, "Module paused");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAllowedFunction(bytes calldata data) {
        require(data.length >= 4, "Invalid data");
        bytes4 selector = bytes4(data[:4]);
        require(_allowedFunctions[selector], "Function not allowed");
        _;
    }

    modifier withinDailyLimit() {
        _consumeDailyLimit();
        _;
    }

    /// @dev Reset journalier + incrementation du compteur sous la limite. Extrait du modifier pour
    ///      que executeVaultFunction puisse l'appeler conditionnellement (exemption endRebalance).
    function _consumeDailyLimit() private {
        _resetDailyCounterIfNeeded();
        require(dailySpent < dailyLimit, "Daily limit exceeded");
        dailySpent++;
    }

    function _resetDailyCounterIfNeeded() private {
        uint256 currentDay = block.timestamp / 86400;
        if (currentDay != lastResetDay) {
            dailySpent = 0;
            lastResetDay = currentDay;
        }
    }

    // Fonction existante pour RangeManager
    function executeRangeManagerFunction(bytes calldata data) external onlyBot onlyAllowedFunction(data) {
        bytes4 selector = bytes4(data[:4]);
        require(selector == REFRESH_PRICE_SELECTOR || selector == REBALANCE_SELECTOR, "Wrong target");
        _requireInflowsForSelector(selector);
        if (selector != REFRESH_PRICE_SELECTOR) {
            _consumeDailyLimit();
        } else {
            _resetDailyCounterIfNeeded();
        }

        _execute(rangeManager, 0, data);

        emit FunctionExecuted(selector, dailySpent);
    }

    function executeStrategyEngineFunction(bytes calldata data) external onlyBot onlyAllowedFunction(data) {
        bytes4 selector = bytes4(data[:4]);
        require(selector == CHECKPOINT_SELECTOR, "Wrong target");
        _consumeDailyLimit();
        _execute(strategyEngine, 0, data);
        emit FunctionExecuted(selector, dailySpent);
    }

    // Fonctions pour MultiUserVault
    function executeVaultFunction(bytes calldata data) external onlyBot onlyAllowedFunction(data) {
        // Audit V3 (Point 2) : endRebalance() (deverrouillage, ne deplace pas de fonds) est exempte de
        // la limite quotidienne — sinon un jour de forte activite pourrait laisser le vault verrouille.
        // Toutes les autres fonctions vault (dont startRebalance) restent soumises a la limite.
        bytes4 selector = bytes4(data[:4]);
        _requireInflowsForSelector(selector);
        if (selector != END_REBALANCE_SELECTOR) {
            _consumeDailyLimit();
        } else {
            _resetDailyCounterIfNeeded();
        }

        _execute(vault, 0, data);

        emit FunctionExecuted(selector, dailySpent);
    }

    /// @notice Execute a Treasury function (bridge operations only, per whitelist)
    function executeTreasuryFunction(bytes calldata data) external onlyBot onlyAllowedFunction(data) withinDailyLimit {
        _execute(treasury, 0, data);

        bytes4 selector = bytes4(data[:4]);
        emit FunctionExecuted(selector, dailySpent);
    }

    /// @notice Execute a Treasury function with native ETH value (Stargate cross-chain fees)
    /// @dev Phase 1: forwards ETH to Safe, then Safe calls Treasury. Phase 2: module calls Treasury directly.
    function executeTreasuryFunctionWithValue(bytes calldata data, uint256 value)
        external
        payable
        onlyBot
        onlyAllowedFunction(data)
        withinDailyLimit
    {
        require(msg.value == value, "Invalid ETH value");

        uint256 nativeBefore = address(this).balance - msg.value;
        (address refundToken, uint256 tokenBefore) = _treasuryUsdcBalance();
        _execute(treasury, value, data);
        if (directExecution && address(this).balance > nativeBefore) {
            uint256 refund = address(this).balance - nativeBefore;
            (bool ok,) = botAddress.call{value: refund}("");
            require(ok, "Refund failed");
            emit ModuleSweep(address(0), refund);
        }
        _sweepTreasuryUsdcToBot(refundToken, tokenBefore);

        bytes4 selector = bytes4(data[:4]);
        emit FunctionExecuted(selector, dailySpent);
    }

    // Fonctions d'administration (Phase 1: Safe owner, Phase 2: Timelock owner)
    function allowFunction(bytes4 selector, bool allowed) external onlyOwner {
        require(_isCoreSelector(selector), "Selector not core");
        _allowedFunctions[selector] = allowed;
        emit FunctionAllowed(selector, allowed);
    }

    function setDailyLimit(uint256 newLimit) external onlyOwner {
        require(newLimit > 0 && newLimit <= 1000, "Invalid limit");
        uint256 currentDay = block.timestamp / 86400;
        uint256 actualSpent = (currentDay == lastResetDay) ? dailySpent : 0;
        require(newLimit >= actualSpent, "Below spent");
        dailyLimit = newLimit;
        emit DailyLimitUpdated(newLimit);
    }

    /// @notice Pause d'urgence du module.
    /// @dev En Phase 2, owner devient le timelock mais la Safe immutable reste guardian d'urgence.
    function setPaused(bool _paused) external {
        require(msg.sender == owner || msg.sender == safe, "Only owner");
        if (msg.sender == safe && msg.sender != owner) require(_paused, "Safe pause only");
        paused = _paused;
        emit Paused(_paused);
    }

    /// @notice Phase 2 switch. false = Gnosis Safe module execution; true = direct module execution.
    function setDirectExecution(bool enabled) external onlyOwner {
        directExecution = enabled;
        emit DirectExecutionUpdated(enabled);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Only pending owner");
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    function sweepNativeToSafe() external {
        require(msg.sender == owner || msg.sender == safe, "Only owner");
        uint256 amount = address(this).balance;
        require(amount > 0, "No balance");
        (bool ok,) = safe.call{value: amount}("");
        require(ok, "Sweep failed");
        emit ModuleSweep(address(0), amount);
    }

    function sweepTokenToSafe(address token) external {
        require(msg.sender == owner || msg.sender == safe, "Only owner");
        uint256 amount = IERC20Sweep(token).balanceOf(address(this));
        require(amount > 0, "No balance");
        _safeTransfer(token, safe, amount);
        emit ModuleSweep(token, amount);
    }

    function _treasuryUsdcBalance() private view returns (address token, uint256 balance) {
        (bool ok, bytes memory ret) = treasury.staticcall(abi.encodeWithSignature("usdc()"));
        if (!ok || ret.length < 32) return (address(0), 0);
        token = abi.decode(ret, (address));
        balance = IERC20Sweep(token).balanceOf(address(this));
    }

    function _sweepTreasuryUsdcToBot(address token, uint256 balanceBefore) private {
        if (token == address(0)) return;
        uint256 balance = IERC20Sweep(token).balanceOf(address(this));
        uint256 amount = balance > balanceBefore ? balance - balanceBefore : 0;
        if (amount == 0) return;
        _safeTransfer(token, botAddress, amount);
        emit ModuleSweep(token, amount);
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20Sweep.transfer.selector, to, amount));
        require(ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool)))), "Sweep failed");
    }

    function _execute(address target, uint256 value, bytes memory data) private {
        if (directExecution) {
            (bool success, bytes memory reason) = target.call{value: value}(data);
            if (!success) _revertWithReason(reason);
        } else {
            if (value > 0) {
                (bool sent,) = safe.call{value: value}("");
                require(sent, "ETH transfer to Safe failed");
            }
            bool success = ISafe(safe).execTransactionFromModule(target, value, data, 0);
            require(success, "Execution failed");
        }
    }

    function _revertWithReason(bytes memory reason) private pure {
        if (reason.length > 0) {
            assembly {
                revert(add(32, reason), mload(reason))
            }
        }
        revert("Execution failed");
    }

    // Fonctions de lecture
    function getDailyStats()
        external
        view
        returns (uint256 limit, uint256 spent, uint256 remaining, uint256 resetsIn)
    {
        uint256 currentDay = block.timestamp / 86400;
        uint256 actualSpent = (currentDay == lastResetDay) ? dailySpent : 0;

        // UI/monitoring countdown only; this timestamp modulo is not randomness.
        uint256 remainingToday = dailyLimit > actualSpent ? dailyLimit - actualSpent : 0;
        return (dailyLimit, actualSpent, remainingToday, 86400 - (block.timestamp % 86400));
    }

    function isFunctionAllowed(bytes4 selector) external view returns (bool) {
        return _allowedFunctions[selector];
    }

    function _requireInflowsForSelector(bytes4 selector) private view {
        if (
            selector == 0x76919a59 // processDepositPermissionless(uint256[],uint256[],address,address)
        ) {
            address controller = pauseController;
            // Yul shl order is shl(shift, value): left-align requireInflowsActive().
            assembly ("memory-safe") {
                mstore(0x00, shl(224, 0x5ea9e82a)) // requireInflowsActive()
                if iszero(staticcall(gas(), controller, 0x00, 0x04, 0x00, 0x00)) {
                    returndatacopy(0x00, 0x00, returndatasize())
                    revert(0x00, returndatasize())
                }
            }
        }
    }

    function _isCoreSelector(bytes4 selector) private pure returns (bool) {
        return selector == 0x0be1c372 // refreshPriceCache()
            || selector == CHECKPOINT_SELECTOR || selector == REBALANCE_SELECTOR || selector == 0x76919a59 // processDepositPermissionless(uint256[],uint256[],address,address)
            || selector == 0x0040718e // endRebalance()
            || selector == 0xa5599124 // bridgeToStakers(uint256)
            || selector == 0x56a12aca; // distributeToStakers(uint256)
    }
}
