// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

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
            uint16 rangeUpPercent,
            uint16 rangeDownPercent,
            uint32 maxPositions
        );

    function getBotInstructions()
        external
        view
        returns (bool hasPosition, uint256 tokenId, bool shouldRebalance, string memory action, string memory reason);

    function getOptimalSwapParams()
        external
        view
        returns (
            bool swapNeeded,
            bool zeroForOne,
            uint256 amountIn,
            uint256 currentBalance0,
            uint256 currentBalance1,
            uint256 targetRatio0Bps,
            int24 tickLower,
            int24 tickUpper
        );
}

contract SecureBotModule {
    address public immutable safe;
    address public immutable botAddress;
    address public immutable rangeManager;
    address public immutable vault;
    address public immutable pauseController;
    address public immutable treasury;
    address public owner;
    address public pendingOwner;

    // Sécurité renforcée
    mapping(bytes4 => bool) public allowedFunctions;
    uint256 public dailyLimit;
    uint256 public dailySpent;
    uint256 public lastResetDay;
    bool public paused;
    bool public directExecution;
    uint8 public botCycleState;
    uint64 public botCycleUpdatedAt;
    bool private cycleSwapPlanSet;
    bool private cycleSwapZeroForOne;
    uint256 private cycleSwapExpectedIn;
    uint256 private cycleSwapSpentIn;

    // Audit V3 (Point 2) : endRebalance() est EXEMPTE de la limite quotidienne dans executeVaultFunction.
    // C'est un DEVERROUILLAGE (il ne deplace aucun fonds, il libere depots/retraits) : si la limite est
    // atteinte un jour de forte activite, le vault ne doit JAMAIS rester verrouille. startRebalance()
    // (qui verrouille) reste lui soumis a la limite. La pause module bloque les flux non-maintenance,
    // pas les actions vitales de position (rebalance/swap/snapshot/deverrouillage).
    bytes4 private constant END_REBALANCE_SELECTOR = 0x0040718e; // endRebalance()
    bytes4 private constant START_REBALANCE_SELECTOR = 0x4dce7057; // startRebalance()
    bytes4 private constant MINT_INITIAL_SELECTOR = 0x63ccfd0b; // mintInitialPosition()
    bytes4 private constant BURN_SELECTOR = 0x38ca63bc; // burnPosition(uint256)
    bytes4 private constant SWAP_SELECTOR = 0xb07391c0; // executeSwap(address,address,uint256,uint256)
    bytes4 private constant ADD_LIQUIDITY_SELECTOR = 0x2a7cf2fe; // addLiquidityToPosition()
    bytes4 private constant REFRESH_PRICE_SELECTOR = 0x0be1c372; // refreshPriceCache()
    uint8 private constant CYCLE_IDLE = 0;
    uint8 private constant CYCLE_LOCKED = 1;
    uint8 private constant CYCLE_REBALANCE_BURNED = 2;
    uint8 private constant CYCLE_LOCKED_MAINTENANCE = 5;
    // Marks an interrupted bot cycle as stale for alerts and lets the bot clear it after timeout.
    // resetStaleBotCycle only resets local module state; it never moves funds or unlocks the Vault.
    uint32 public constant BOT_CYCLE_TIMEOUT = 30 minutes;

    // Events
    event FunctionExecuted(bytes4 indexed selector, uint256 dailyCount);
    event FunctionAllowed(bytes4 indexed selector, bool allowed);
    event DailyLimitUpdated(uint256 newLimit);
    event Paused(bool paused);
    event DirectExecutionUpdated(bool enabled);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event ModuleSweep(address indexed token, uint256 amount);
    event BotCycleStateUpdated(uint8 state, bytes4 indexed selector);

    constructor(
        address _safe,
        address _botAddress,
        address _rangeManager,
        address _vault,
        address _pauseController,
        address _treasury,
        uint256 _dailyLimit
    ) {
        require(
            _safe != address(0) && _botAddress != address(0) && _rangeManager != address(0) && _vault != address(0)
                && _pauseController != address(0) && _treasury != address(0),
            "E_ZERO"
        );
        require(_dailyLimit > 0 && _dailyLimit <= 1000, "E_LIMIT");
        safe = _safe;
        botAddress = _botAddress;
        rangeManager = _rangeManager;
        vault = _vault;
        pauseController = _pauseController;
        treasury = _treasury;
        owner = _safe; // La Safe est owner
        dailyLimit = _dailyLimit;

        // Autoriser les fonctions essentielles au deploiement
        // Fonctions RangeManager
        // configurePriceFeeds (0x6509c2dd) RETIRÉ (audit V1) : repointage des oracles = gouvernance Safe
        // uniquement (une clé bot compromise pourrait empoisonner les prix). Le bot rafraîchit le cache
        // via refreshPriceCache() ci-dessous, qui ne change aucune adresse.
        allowedFunctions[0x0be1c372] = true; // refreshPriceCache()
        allowedFunctions[0x63ccfd0b] = true; // mintInitialPosition
        allowedFunctions[0x38ca63bc] = true; // burnPosition (collecte fees + retire liquidite)
        allowedFunctions[0xb07391c0] = true; // executeSwap (swaps via Uniswap V3)
        allowedFunctions[0x6ecfe0f8] = true; // recordPriceSnapshot() - snapshot de prix (fallback bot si aucun keeper)
        // Setters de stratégie/risk retirés du module: configureRanges, setDynamicRangeEnabled,
        // configureSlippage, configureProtections, configureTolerance.

        // Fonctions MultiUserVault
        // processPendingDeposits (0x99dd7ead) RETIRÉ (audit V1) : fonction batch supprimée du Vault.
        // processSingleDeposit (0xac1df9bd) RETIRÉ de la whitelist : le bot traite désormais aussi le
        // mint initial standard via processDepositPermissionless(), en une transaction atomique bot-only.
        allowedFunctions[0x76919a59] = true; // processDepositPermissionless(uint256[],uint256[],address,address)
        allowedFunctions[0x4dce7057] = true; // startRebalance()
        allowedFunctions[0x0040718e] = true; // endRebalance()
        // Sélecteur RangeManager, exécuté via executeRangeManagerFunction (pas via executeVaultFunction).
        allowedFunctions[0x2a7cf2fe] = true; // addLiquidityToPosition()

        // Fonctions Treasury (bridge Stargate v2 vers staking contract Phase 2)
        allowedFunctions[0xa5599124] = true; // bridgeToStakers(uint256)
        allowedFunctions[0x56a12aca] = true; // distributeToStakers(uint256) - bridge treasury same-chain
        allowedFunctions[0x1dc28748] = true; // collectAndBridge(address,uint24,uint256,uint256)
    }

    receive() external payable {}

    modifier onlyBot() {
        require(msg.sender == botAddress, "Only bot allowed");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAllowedFunction(bytes calldata data) {
        require(data.length >= 4, "Invalid data");
        bytes4 selector = bytes4(data[:4]);
        require(allowedFunctions[selector], "Function not allowed");
        _;
    }

    modifier withinDailyLimit() {
        _consumeDailyLimit();
        _;
    }

    /// @dev Reset journalier + incrementation du compteur sous la limite. Extrait du modifier pour
    ///      que executeVaultFunction puisse l'appeler conditionnellement (exemption endRebalance).
    function _consumeDailyLimit() private {
        uint256 currentDay = block.timestamp / 86400;
        if (currentDay != lastResetDay) {
            dailySpent = 0;
            lastResetDay = currentDay;
        }
        require(dailySpent < dailyLimit, "Daily limit exceeded");
        dailySpent++;
    }

    // Fonction existante pour RangeManager
    function executeRangeManagerFunction(bytes calldata data) external onlyBot onlyAllowedFunction(data) {
        bytes4 selector = bytes4(data[:4]);
        _requireInflowsForSelector(selector);
        _beforeRangeManagerCall(selector, data);
        if (selector != REFRESH_PRICE_SELECTOR) {
            _consumeDailyLimit();
        }

        _execute(rangeManager, 0, data);
        _afterRangeManagerCall(selector);

        emit FunctionExecuted(selector, dailySpent);
    }

    // Fonctions pour MultiUserVault
    function executeVaultFunction(bytes calldata data) external onlyBot onlyAllowedFunction(data) {
        // Audit V3 (Point 2) : endRebalance() (deverrouillage, ne deplace pas de fonds) est exempte de
        // la limite quotidienne — sinon un jour de forte activite pourrait laisser le vault verrouille.
        // Toutes les autres fonctions vault (dont startRebalance) restent soumises a la limite.
        bytes4 selector = bytes4(data[:4]);
        _requireInflowsForSelector(selector);
        _beforeVaultCall(selector);
        if (selector != END_REBALANCE_SELECTOR) {
            _consumeDailyLimit();
        }

        _execute(vault, 0, data);
        _afterVaultCall(selector);

        emit FunctionExecuted(selector, dailySpent);
    }

    /// @notice Execute a Treasury function (bridge operations only, per whitelist)
    function executeTreasuryFunction(bytes calldata data) external onlyBot onlyAllowedFunction(data) withinDailyLimit {
        require(!paused, "Module paused");
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
        require(!paused, "Module paused");
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
        allowedFunctions[selector] = allowed;
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

    /// @notice Reset manuel du cycle bot si une suite multi-tx a ete interrompue hors-chain.
    /// @dev Ne deplace aucun fonds et ne change aucune allowlist. Safe garde ce levier d'urgence en Phase 2.
    function resetBotCycle() external {
        require(msg.sender == owner || msg.sender == safe, "Only owner");
        _setCycle(CYCLE_IDLE, 0x00000000);
    }

    /// @notice Let the hot bot clear an interrupted module cycle after timeout.
    /// @dev Only resets the module's internal cycle state. The Vault lock, if any, remains controlled by Vault/Safe.
    function resetStaleBotCycle() external onlyBot returns (bool reset) {
        if (botCycleState == CYCLE_IDLE) return false;
        if (block.timestamp <= uint256(botCycleUpdatedAt) + uint256(BOT_CYCLE_TIMEOUT)) return false;
        _setCycle(CYCLE_IDLE, 0x00000000);
        return true;
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

    function _beforeVaultCall(bytes4 selector) private {
        if (selector == START_REBALANCE_SELECTOR) {
            require(botCycleState == CYCLE_IDLE, "Bad cycle");
            _requireVaultUnlocked();
            _refreshRangeManagerCache();
            _requireStartRebalanceTrigger();
        }
    }

    function _afterVaultCall(bytes4 selector) private {
        if (selector == START_REBALANCE_SELECTOR) {
            _setCycle(CYCLE_LOCKED, selector);
        } else if (selector == END_REBALANCE_SELECTOR) {
            _setCycle(CYCLE_IDLE, selector);
        }
    }

    function _beforeRangeManagerCall(bytes4 selector, bytes calldata data) private {
        uint8 state = botCycleState;
        if (selector == BURN_SELECTOR) {
            require(state == CYCLE_LOCKED, "Bad cycle");
            _refreshRangeManagerCache();
            _requireRebalanceTrigger();
        } else if (selector == SWAP_SELECTOR) {
            require(
                state == CYCLE_LOCKED || state == CYCLE_REBALANCE_BURNED || state == CYCLE_LOCKED_MAINTENANCE,
                "Bad cycle"
            );
            _refreshRangeManagerCache();
            _requireCycleSwapPlan(data);
        } else if (selector == MINT_INITIAL_SELECTOR) {
            require(
                state == CYCLE_LOCKED || state == CYCLE_LOCKED_MAINTENANCE || state == CYCLE_REBALANCE_BURNED,
                "Bad cycle"
            );
            _refreshRangeManagerCache();
            _requireSwapPlanCompleteOrNone();
        } else if (selector == ADD_LIQUIDITY_SELECTOR) {
            require(state == CYCLE_LOCKED || state == CYCLE_LOCKED_MAINTENANCE, "Bad cycle");
            _refreshRangeManagerCache();
            _requireSwapPlanCompleteOrNone();
        }
    }

    function _afterRangeManagerCall(bytes4 selector) private {
        uint8 state = botCycleState;
        if (selector == BURN_SELECTOR) {
            _setCycle(CYCLE_REBALANCE_BURNED, selector);
        } else if (selector == SWAP_SELECTOR) {
            if (state != CYCLE_LOCKED_MAINTENANCE) _setCycle(CYCLE_LOCKED_MAINTENANCE, selector);
        } else if (selector == MINT_INITIAL_SELECTOR) {
            _setCycle(CYCLE_LOCKED, selector);
        } else if (selector == ADD_LIQUIDITY_SELECTOR) {
            _setCycle(CYCLE_LOCKED, selector);
        }
    }

    function _setCycle(uint8 state, bytes4 selector) private {
        botCycleState = state;
        botCycleUpdatedAt = uint64(block.timestamp);
        if (state == CYCLE_IDLE || state == CYCLE_LOCKED || state == CYCLE_REBALANCE_BURNED) {
            _clearCycleSwapPlan();
        }
        emit BotCycleStateUpdated(state, selector);
    }

    function _clearCycleSwapPlan() private {
        cycleSwapPlanSet = false;
        cycleSwapZeroForOne = false;
        cycleSwapExpectedIn = 0;
        cycleSwapSpentIn = 0;
    }

    function _refreshRangeManagerCache() private {
        _execute(rangeManager, 0, abi.encodeWithSelector(REFRESH_PRICE_SELECTOR));
    }

    function _requireCycleSwapPlan(bytes calldata data) private {
        (address tokenIn,, uint256 amountIn,) = abi.decode(data[4:], (address, address, uint256, uint256));
        IRangeManagerBotState rm = IRangeManagerBotState(rangeManager);
        bool tokenInIsToken0 = tokenIn == rm.token0();
        if (!cycleSwapPlanSet) {
            (bool swapNeeded, bool zeroForOne, uint256 expectedAmountIn,,,,,) = rm.getOptimalSwapParams();
            require(swapNeeded && expectedAmountIn > 0, "No swap plan");
            cycleSwapPlanSet = true;
            cycleSwapZeroForOne = zeroForOne;
            cycleSwapExpectedIn = expectedAmountIn;
            cycleSwapSpentIn = 0;
        }
        require(tokenInIsToken0 == cycleSwapZeroForOne, "Bad swap dir");
        uint256 tolerance = _cycleSwapTolerance(cycleSwapExpectedIn);
        require(cycleSwapSpentIn + amountIn <= cycleSwapExpectedIn + tolerance, "Swap too high");
        cycleSwapSpentIn += amountIn;
    }

    function _requireSwapPlanCompleteOrNone() private view {
        if (cycleSwapPlanSet) {
            uint256 tolerance = _cycleSwapTolerance(cycleSwapExpectedIn);
            require(cycleSwapSpentIn + tolerance >= cycleSwapExpectedIn, "Swap too low");
            return;
        }
        (bool swapNeeded,, uint256 expectedAmountIn,,,,,) = IRangeManagerBotState(rangeManager).getOptimalSwapParams();
        require(!swapNeeded || expectedAmountIn == 0, "Swap missing");
    }

    function _cycleSwapTolerance(uint256 expectedAmountIn) private view returns (uint256 tolerance) {
        (,,, uint16 toleranceBps,,,,,,) = IRangeManagerBotState(rangeManager).config();
        tolerance = (expectedAmountIn * uint256(toleranceBps)) / 10000;
        if (tolerance == 0) tolerance = 1;
    }

    function _requireRebalanceTrigger() private view {
        (bool hasPosition,, bool shouldRebalance,,) = IRangeManagerBotState(rangeManager).getBotInstructions();
        require(hasPosition && shouldRebalance, "No rebalance");
    }

    function _requireStartRebalanceTrigger() private view {
        (bool hasPosition,, bool shouldRebalance,,) = IRangeManagerBotState(rangeManager).getBotInstructions();
        require(!hasPosition || shouldRebalance, "No rebalance");
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
        return allowedFunctions[selector];
    }

    function getBotCycleStatus()
        external
        view
        returns (uint8 state, uint64 updatedAt, uint32 timeoutSeconds, bool stale)
    {
        state = botCycleState;
        updatedAt = botCycleUpdatedAt;
        timeoutSeconds = BOT_CYCLE_TIMEOUT;
        stale = state != CYCLE_IDLE && block.timestamp > uint256(updatedAt) + uint256(timeoutSeconds);
    }

    function _requireInflowsForSelector(bytes4 selector) private view {
        if (
            selector == 0x76919a59 // processDepositPermissionless(uint256[],uint256[],address,address)
        ) {
            require(!paused, "Module paused");
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

    function _requireVaultUnlocked() private view {
        (bool ok, bytes memory ret) = vault.staticcall(abi.encodeWithSelector(0xab8d23bd)); // isRebalancing()
        require(ok && ret.length >= 32 && !abi.decode(ret, (bool)), "Vault locked");
    }

    function _isCoreSelector(bytes4 selector) private pure returns (bool) {
        return selector == 0x0be1c372 // refreshPriceCache()
            || selector == 0x63ccfd0b // mintInitialPosition()
            || selector == 0x38ca63bc // burnPosition(uint256)
            || selector == 0xb07391c0 // executeSwap(address,address,uint256,uint256)
            || selector == 0x6ecfe0f8 // recordPriceSnapshot()
            || selector == 0x76919a59 // processDepositPermissionless(uint256[],uint256[],address,address)
            || selector == 0x4dce7057 // startRebalance()
            || selector == 0x0040718e // endRebalance()
            || selector == 0x2a7cf2fe // addLiquidityToPosition()
            || selector == 0xa5599124 // bridgeToStakers(uint256)
            || selector == 0x56a12aca // distributeToStakers(uint256)
            || selector == 0x1dc28748; // collectAndBridge(address,uint24,uint256,uint256)
    }
}
