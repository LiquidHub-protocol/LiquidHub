// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./RangeOperations.sol";
import "./DnDepositLib.sol";

interface ISafe {
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool success);
}

interface IERC20Sweep {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IRangeManagerPostCheck {
    function token0() external view returns (address);
    function priceCache() external view returns (uint128, uint128, uint160, int24, uint64, bool);
    function config() external view returns (RangeOperations.RangeConfig memory);
    function getBotInstructions()
        external
        view
        returns (bool hasPosition, uint256 tokenId, bool shouldRebalance, string memory action, string memory reason);
}

contract SecureBotModule {
    address public immutable safe;
    address public immutable botAddress;
    address public immutable rangeManager;
    address public immutable vault;
    address public immutable pauseController;
    address public immutable hedgeManager;
    address public immutable treasury;
    address public owner;

    // Sécurité renforcée
    mapping(bytes4 => bool) public allowedFunctions;
    uint256 public dailyLimit;
    uint256 public dailySpent;
    uint256 public lastResetDay;
    bool public paused;
    bool public directExecution;
    uint8 public botCycleState;
    uint64 public botCycleUpdatedAt;

    // Audit V3 (Point 2) : endRebalance() est EXEMPTE de la limite quotidienne dans executeVaultFunction.
    // C'est un DEVERROUILLAGE (il ne deplace aucun fonds, il libere depots/retraits) : si la limite est
    // atteinte un jour de forte activite, le vault ne doit JAMAIS rester verrouille. startRebalance()
    // (qui verrouille) reste lui soumis a la limite. onlyBot/paused/onlyAllowedFunction restent actifs.
    bytes4 private constant END_REBALANCE_SELECTOR = 0x0040718e; // endRebalance()
    bytes4 private constant START_REBALANCE_SELECTOR = 0x4dce7057; // startRebalance()
    bytes4 private constant MINT_INITIAL_SELECTOR = 0x63ccfd0b; // mintInitialPosition()
    bytes4 private constant ADD_LIQUIDITY_SELECTOR = 0x2a7cf2fe; // addLiquidityToPosition()
    bytes4 private constant BURN_SELECTOR = 0x38ca63bc; // burnPosition(uint256)
    bytes4 private constant SWAP_SELECTOR = 0xb07391c0; // executeSwap(address,address,uint256,uint256)
    bytes4 private constant BORROW_MORE_SELECTOR = 0x9d0bf2e9; // borrowMore(uint256)
    uint16 private constant DN_REBAL_MAX_DRIFT_BPS = 300;
    uint16 private constant DN_REBAL_CRIT_DRIFT_BPS = 900;
    uint256 private constant DN_REBAL_DUST_FLOOR_USD = 50e8;
    uint8 private constant CYCLE_IDLE = 0;
    uint8 private constant CYCLE_LOCKED = 1;
    uint8 private constant CYCLE_REBALANCE_BURNED = 2;
    uint8 private constant CYCLE_LOCKED_MAINTENANCE = 5;
    uint32 public constant BOT_CYCLE_TIMEOUT = 1 hours;

    // Events
    event FunctionExecuted(bytes4 indexed selector, uint256 dailyCount);
    event FunctionAllowed(bytes4 indexed selector, bool allowed);
    event DailyLimitUpdated(uint256 newLimit);
    event Paused(bool paused);
    event DirectExecutionUpdated(bool enabled);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ModuleSweep(address indexed token, uint256 amount);
    event BotCycleStateUpdated(uint8 state, bytes4 indexed selector);
    event BotCycleAutoReset(uint8 previousState);

    constructor(
        address _safe,
        address _botAddress,
        address _rangeManager,
        address _vault,
        address _pauseController,
        address _hedgeManager,
        address _treasury,
        uint256 _dailyLimit
    ) {
        require(
            _safe != address(0) && _botAddress != address(0) && _rangeManager != address(0) && _vault != address(0)
                && _pauseController != address(0) && _hedgeManager != address(0) && _treasury != address(0),
            "E_ZERO"
        );
        require(_dailyLimit > 0 && _dailyLimit <= 1000, "E_LIMIT");
        safe = _safe;
        botAddress = _botAddress;
        rangeManager = _rangeManager;
        vault = _vault;
        pauseController = _pauseController;
        hedgeManager = _hedgeManager;
        treasury = _treasury;
        owner = _safe; // La Safe est owner
        dailyLimit = _dailyLimit;

        // Autoriser les fonctions essentielles au deploiement
        // Fonctions RangeManager
        // configurePriceFeeds (0x6509c2dd) RETIRÉ (audit V1) : repointage oracles = gouvernance Safe.
        // Le bot rafraîchit le cache via refreshPriceCache() (ne change aucune adresse).
        allowedFunctions[0x0be1c372] = true; // refreshPriceCache()
        // mintInitialPosition() reste nécessaire au flux bot de rebalance multi-tx. En DN, le module
        // exécute un post-check hedge on-chain après le mint ; un mint non hedgé/mal hedgé revert.
        allowedFunctions[0x63ccfd0b] = true; // mintInitialPosition()
        allowedFunctions[0x38ca63bc] = true; // burnPosition (collecte fees + retire liquidite)
        allowedFunctions[0xb07391c0] = true; // executeSwap (swaps via Uniswap V3)
        allowedFunctions[0x6ecfe0f8] = true; // recordPriceSnapshot() - snapshot de prix (fallback bot si aucun keeper)
        // Setters de stratégie/risk retirés du module: configureRanges, setDynamicRangeEnabled,
        // configureSlippage, setMaxPositions, configureProtections, configureTolerance.
        allowedFunctions[0x9be8feaa] = true; // sendTokenForHedge(address,uint256,address)

        // Fonctions MultiUserVault
        // processPendingDeposits (0x99dd7ead) RETIRÉ (audit V1) : fonction batch supprimée du Vault.
        // processSingleDeposit (0xac1df9bd) RETIRÉ en DN : le mint initial passe désormais par le bot
        // via processDepositPermissionless() pour créer le hedge AAVE atomiquement puis post-check.
        // AUDIT H-02 : le relais bot des dépôts de CROISSANCE passe par le chemin ATOMIQUE
        // processDepositPermissionless (hedge on-chain via DnDepositLib + post-check). Sélecteur à whitelister
        // sinon le fallback bot revert avant d'atteindre le Vault. Le Vault re-valide tout (paused, plafond, oracle).
        allowedFunctions[0x76919a59] = true; // processDepositPermissionless(uint256[],uint256[],address,address)
        allowedFunctions[0x4dce7057] = true; // startRebalance()
        allowedFunctions[0x0040718e] = true; // endRebalance()
        allowedFunctions[0x2a7cf2fe] = true; // addLiquidityToPosition
        // withdrawReservedCollateral (0xa5993427) RETIRÉ (audit) : fonction supprimée du Vault (réserve gérée off-chain)
        // AUDIT M-02 : decreaseLiquidityPartial(uint128) (0x41f60e3c) RETIRÉ de la whitelist — entrée publique DN
        // supprimée (trimming LP indépendant abandonné en DN strict). Plus aucune surface pour une clé bot compromise.
        // Emergency functions (EmergencyBurnPositions, EmergencyRecoverUser, sendTokenForHedgeRepay)
        // are NOT whitelisted here — they can only be called directly from the Safe

        // Fonctions AaveHedgeManager (Delta Neutral AAVE V3)
        // supplyAndBorrow(uint256,uint256) reste exposée sur le HedgeManager pour le Vault/Safe,
        // mais n'est pas une action bot/keeper récurrente : DnDepositLib l'appelle depuis le Vault pendant les
        // dépôts DN atomiques. Elle n'est donc PAS whitelistée dans le module bot.
        // AUDIT H-02 : adjustHedge() permissionless — whitelisté pour que le bot puisse le déclencher en surge
        // (sur-hedge critique). NB : le cooldown on-chain s'applique aussi au bot (pas de bypass) — garde-fou
        // anti-spam légitime. Le sur-hedge non corrigé immédiatement le sera au cycle suivant ou par un keeper.
        allowedFunctions[0x1e694f32] = true; // adjustHedge()
        // borrowMore(uint256) reste necessaire au solveur DN, mais il est borne au cycle rebalance post-burn
        // par _beforeHedgeCall() : une cle bot compromise ne peut pas augmenter la dette hors maintenance LP.
        allowedFunctions[0x9d0bf2e9] = true;
        allowedFunctions[0xebc9b94d] = true; // repayAndWithdraw(uint256,uint256)
        allowedFunctions[0x6b09de45] = true; // repayDebt(uint256)
        allowedFunctions[0x0af504cc] = true; // withdrawCollateral(uint256,address) — destination figée on-chain (audit V1)
        // closeAll (0xf6b32008) RETIRÉE (audit V1) : fonction d'URGENCE rare qui envoie TOUT
        // le hedge à un recipient → réservée à la Safe directe (jamais via le bot).
        allowedFunctions[0xacf31cb1] = true; // sweepWeth(address) — destination figée on-chain (audit V1)
        allowedFunctions[0x58ea510a] = true; // sweepUsdc(address) — destination figée on-chain (audit V1)

        // Fonctions Treasury (bridge Stargate v2 vers staking contract Phase 2)
        allowedFunctions[0xa5599124] = true; // bridgeToStakers(uint256)
        allowedFunctions[0x56a12aca] = true; // distributeToStakers(uint256) - bridge treasury same-chain
        allowedFunctions[0x1dc28748] = true; // collectAndBridge(address,uint24,uint256,uint256)
    }

    receive() external payable {}

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
    function executeRangeManagerFunction(bytes calldata data)
        external
        onlyBot
        onlyAllowedFunction(data)
        withinDailyLimit
    {
        bytes4 selector = bytes4(data[:4]);
        _requireInflowsForSelector(selector);
        _beforeRangeManagerCall(selector);

        _execute(rangeManager, 0, data);
        if (selector == MINT_INITIAL_SELECTOR || selector == ADD_LIQUIDITY_SELECTOR) _requirePostLiquidityHedgeOk();
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

    // Fonctions pour AaveHedgeManager (Delta Neutral)
    function executeHedgeFunction(bytes calldata data) external onlyBot onlyAllowedFunction(data) withinDailyLimit {
        bytes4 selector = bytes4(data[:4]);
        _beforeHedgeCall(selector);
        _execute(hedgeManager, 0, data);

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

        _execute(treasury, value, data);
        if (directExecution && address(this).balance > 0) {
            uint256 refund = address(this).balance;
            (bool ok,) = botAddress.call{value: refund}("");
            require(ok, "Refund failed");
            emit ModuleSweep(address(0), refund);
        }
        _sweepTreasuryUsdcToBot();

        bytes4 selector = bytes4(data[:4]);
        emit FunctionExecuted(selector, dailySpent);
    }

    // Fonctions d'administration (appelées par la Safe)
    function allowFunction(bytes4 selector, bool allowed) external onlyOwner {
        require(_isCoreSelector(selector), "Selector not core");
        allowedFunctions[selector] = allowed;
        emit FunctionAllowed(selector, allowed);
    }

    function setDailyLimit(uint256 newLimit) external onlyOwner {
        require(newLimit > 0 && newLimit <= 1000, "Invalid limit");
        dailyLimit = newLimit;
        emit DailyLimitUpdated(newLimit);
    }

    /// @notice Pause d'urgence du module.
    /// @dev En Phase 2, owner devient le timelock mais la Safe immutable reste guardian d'urgence.
    function setPaused(bool _paused) external {
        require(msg.sender == owner || msg.sender == safe, "Only owner");
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
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Reset manuel du cycle bot si une suite multi-tx a ete interrompue hors-chain.
    /// @dev Ne deplace aucun fonds et ne change aucune allowlist. Safe garde ce levier d'urgence en Phase 2.
    function resetBotCycle() external {
        require(msg.sender == owner || msg.sender == safe, "Only owner");
        _setCycle(CYCLE_IDLE, 0x00000000);
    }

    /// @notice Reset permissionless d'un cycle bot expire. Ne fait rien tant que le timeout n'est pas atteint.
    /// @dev Liveness uniquement: aucun fonds, aucune allowlist, aucun parametre sensible.
    function resetStaleBotCycle() external returns (bool reset) {
        uint8 previousState = botCycleState;
        _autoResetStaleCycle();
        return previousState != CYCLE_IDLE && botCycleState == CYCLE_IDLE;
    }

    function sweepNativeToBot() external onlyBot {
        uint256 amount = address(this).balance;
        require(amount > 0, "No balance");
        (bool ok,) = botAddress.call{value: amount}("");
        require(ok, "Sweep failed");
        emit ModuleSweep(address(0), amount);
    }

    function sweepTokenToBot(address token) external onlyBot {
        uint256 amount = IERC20Sweep(token).balanceOf(address(this));
        require(amount > 0, "No balance");
        require(IERC20Sweep(token).transfer(botAddress, amount), "Sweep failed");
        emit ModuleSweep(token, amount);
    }

    function _sweepTreasuryUsdcToBot() private {
        (bool ok, bytes memory ret) = treasury.staticcall(abi.encodeWithSignature("usdc()"));
        if (!ok || ret.length < 32) return;
        address token = abi.decode(ret, (address));
        uint256 amount = IERC20Sweep(token).balanceOf(address(this));
        if (amount == 0) return;
        require(IERC20Sweep(token).transfer(botAddress, amount), "Sweep failed");
        emit ModuleSweep(token, amount);
    }

    function _execute(address target, uint256 value, bytes calldata data) private {
        if (directExecution) {
            (bool success,) = target.call{value: value}(data);
            require(success, "Execution failed");
        } else {
            if (value > 0) {
                (bool sent,) = safe.call{value: value}("");
                require(sent, "ETH transfer to Safe failed");
            }
            bool success = ISafe(safe).execTransactionFromModule(target, value, data, 0);
            require(success, "Execution failed");
        }
    }

    function _beforeVaultCall(bytes4 selector) private {
        _autoResetStaleCycle();
        if (selector == START_REBALANCE_SELECTOR) {
            require(botCycleState == CYCLE_IDLE, "Bad cycle");
            _requireVaultUnlocked();
        }
    }

    function _afterVaultCall(bytes4 selector) private {
        if (selector == START_REBALANCE_SELECTOR) {
            _setCycle(CYCLE_LOCKED, selector);
        } else if (selector == END_REBALANCE_SELECTOR) {
            _setCycle(CYCLE_IDLE, selector);
        }
    }

    function _beforeRangeManagerCall(bytes4 selector) private {
        _autoResetStaleCycle();
        uint8 state = botCycleState;
        if (selector == BURN_SELECTOR) {
            require(state == CYCLE_LOCKED, "Bad cycle");
            _requireRebalanceTrigger();
        } else if (selector == SWAP_SELECTOR) {
            require(
                state == CYCLE_LOCKED || state == CYCLE_REBALANCE_BURNED || state == CYCLE_LOCKED_MAINTENANCE,
                "Bad cycle"
            );
        } else if (selector == MINT_INITIAL_SELECTOR) {
            require(
                state == CYCLE_LOCKED || state == CYCLE_LOCKED_MAINTENANCE || state == CYCLE_REBALANCE_BURNED,
                "Bad cycle"
            );
        } else if (selector == ADD_LIQUIDITY_SELECTOR) {
            require(state == CYCLE_LOCKED || state == CYCLE_LOCKED_MAINTENANCE, "Bad cycle");
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
        emit BotCycleStateUpdated(state, selector);
    }

    function _autoResetStaleCycle() private {
        if (botCycleState != CYCLE_IDLE && block.timestamp > uint256(botCycleUpdatedAt) + uint256(BOT_CYCLE_TIMEOUT)) {
            uint8 previousState = botCycleState;
            botCycleState = CYCLE_IDLE;
            botCycleUpdatedAt = uint64(block.timestamp);
            emit BotCycleAutoReset(previousState);
            emit BotCycleStateUpdated(CYCLE_IDLE, 0x00000000);
        }
    }

    function _requireRebalanceTrigger() private view {
        IRangeManagerPostCheck rm = IRangeManagerPostCheck(rangeManager);
        (bool hasPosition,, bool shouldRebalance,,) = rm.getBotInstructions();
        if (!hasPosition) revert("No rebalance");
        if (shouldRebalance) return;

        (uint128 price0,,,,, bool valid) = rm.priceCache();
        RangeOperations.RangeConfig memory cfg = rm.config();
        bool criticalDrift = valid && price0 > 0
            && DnDepositLib.dnHedgeDriftExceeds(
                rangeManager, rm.token0(), price0, cfg.token0Decimals, DN_REBAL_CRIT_DRIFT_BPS, DN_REBAL_DUST_FLOOR_USD
            );
        require(criticalDrift, "No rebalance");
    }

    function _beforeHedgeCall(bytes4 selector) private view {
        if (selector == BORROW_MORE_SELECTOR) {
            uint8 state = botCycleState;
            require(state == CYCLE_REBALANCE_BURNED || state == CYCLE_LOCKED_MAINTENANCE, "Bad cycle");
        }
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
        return (dailyLimit, actualSpent, dailyLimit - actualSpent, 86400 - (block.timestamp % 86400));
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

    function _requirePostLiquidityHedgeOk() private view {
        IRangeManagerPostCheck rm = IRangeManagerPostCheck(rangeManager);
        (uint128 price0,,,,,) = rm.priceCache();
        RangeOperations.RangeConfig memory cfg = rm.config();
        DnDepositLib.postCheckRebalanceHedge(
            rangeManager, rm.token0(), price0, cfg.token0Decimals, DN_REBAL_MAX_DRIFT_BPS, DN_REBAL_DUST_FLOOR_USD
        );
    }

    function _isCoreSelector(bytes4 selector) private pure returns (bool) {
        return selector == 0x0be1c372 // refreshPriceCache()
            || selector == 0x63ccfd0b // mintInitialPosition()
            || selector == 0x38ca63bc // burnPosition(uint256)
            || selector == 0xb07391c0 // executeSwap(address,address,uint256,uint256)
            || selector == 0x6ecfe0f8 // recordPriceSnapshot()
            || selector == 0x9be8feaa // sendTokenForHedge(address,uint256,address)
            || selector == 0x76919a59 // processDepositPermissionless(uint256[],uint256[],address,address)
            || selector == 0x4dce7057 // startRebalance()
            || selector == 0x0040718e // endRebalance()
            || selector == 0x2a7cf2fe // addLiquidityToPosition()
            || selector == 0x1e694f32 // adjustHedge()
            || selector == 0x9d0bf2e9 // borrowMore(uint256)
            || selector == 0xebc9b94d // repayAndWithdraw(uint256,uint256)
            || selector == 0x6b09de45 // repayDebt(uint256)
            || selector == 0x0af504cc // withdrawCollateral(uint256,address)
            || selector == 0xacf31cb1 // sweepWeth(address)
            || selector == 0x58ea510a // sweepUsdc(address)
            || selector == 0xa5599124 // bridgeToStakers(uint256)
            || selector == 0x56a12aca // distributeToStakers(uint256)
            || selector == 0x1dc28748; // collectAndBridge(address,uint24,uint256,uint256)
    }
}
