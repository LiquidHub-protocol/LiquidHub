// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ISafe {
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external returns (bool success);
}

contract SecureBotModule {
    address public immutable safe;
    address public immutable botAddress;
    address public immutable rangeManager;
    address public immutable vault;
    address public immutable pauseController;
    address public immutable treasury;
    address public owner;

    // Sécurité renforcée
    mapping(bytes4 => bool) public allowedFunctions;
    uint256 public dailyLimit;
    uint256 public dailySpent;
    uint256 public lastResetDay;
    bool public paused;

    // Audit V3 (Point 2) : endRebalance() est EXEMPTE de la limite quotidienne dans executeVaultFunction.
    // C'est un DEVERROUILLAGE (il ne deplace aucun fonds, il libere depots/retraits) : si la limite est
    // atteinte un jour de forte activite, le vault ne doit JAMAIS rester verrouille. startRebalance()
    // (qui verrouille) reste lui soumis a la limite. onlyBot/paused/onlyAllowedFunction restent actifs.
    bytes4 private constant END_REBALANCE_SELECTOR = 0x0040718e; // endRebalance()
    bytes4 private constant START_REBALANCE_SELECTOR = 0x4dce7057; // startRebalance()

    // Events
    event FunctionExecuted(bytes4 indexed selector, uint256 dailyCount);
    event FunctionAllowed(bytes4 indexed selector, bool allowed);
    event DailyLimitUpdated(uint256 newLimit);
    event Paused(bool paused);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

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
            _safe != address(0) && _botAddress != address(0) && _rangeManager != address(0)
                && _vault != address(0) && _pauseController != address(0) && _treasury != address(0),
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
        // configureSlippage, setMaxPositions, configureProtections, configureTolerance.

        // Fonctions MultiUserVault
        // processPendingDeposits (0x99dd7ead) RETIRÉ (audit V1) : fonction batch supprimée du Vault
        // (sur-mint des dépôts tardifs). Le traitement se fait via processSingleDeposit ci-dessous.
        allowedFunctions[0xac1df9bd] = true; // processSingleDeposit (traitement individuel)
        allowedFunctions[0x76919a59] = true; // processDepositPermissionless(uint256[],uint256[],address,address)
        allowedFunctions[0x4dce7057] = true; // startRebalance()
        allowedFunctions[0x0040718e] = true; // endRebalance()
        allowedFunctions[0x2a7cf2fe] = true; // addLiquidityToPosition

        // Fonctions Treasury (bridge Stargate v2 vers staking contract Phase 2)
        allowedFunctions[0xa5599124] = true; // bridgeToStakers(uint256)
        allowedFunctions[0x56a12aca] = true; // distributeToStakers(uint256) - bridge treasury same-chain
        allowedFunctions[0x1dc28748] = true; // collectAndBridge(address,uint24,uint256,uint256)
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

        bool success = ISafe(safe).execTransactionFromModule(rangeManager, 0, data, 0);
        require(success, "Execution failed");

        emit FunctionExecuted(selector, dailySpent);
    }

    // Fonctions pour MultiUserVault
    function executeVaultFunction(bytes calldata data)
        external
        onlyBot
        onlyAllowedFunction(data)
    {
        // Audit V3 (Point 2) : endRebalance() (deverrouillage, ne deplace pas de fonds) est exempte de
        // la limite quotidienne — sinon un jour de forte activite pourrait laisser le vault verrouille.
        // Toutes les autres fonctions vault (dont startRebalance) restent soumises a la limite.
        bytes4 selector = bytes4(data[:4]);
        _requireInflowsForSelector(selector);
        if (selector == START_REBALANCE_SELECTOR) _requireVaultUnlocked();
        if (selector != END_REBALANCE_SELECTOR) {
            _consumeDailyLimit();
        }

        bool success = ISafe(safe).execTransactionFromModule(vault, 0, data, 0);
        require(success, "Execution failed");

        emit FunctionExecuted(selector, dailySpent);
    }

    /// @notice Execute a Treasury function (bridge operations only, per whitelist)
    function executeTreasuryFunction(bytes calldata data)
        external
        onlyBot
        onlyAllowedFunction(data)
        withinDailyLimit
    {
        bool success = ISafe(safe).execTransactionFromModule(treasury, 0, data, 0);
        require(success, "Execution failed");

        bytes4 selector = bytes4(data[:4]);
        emit FunctionExecuted(selector, dailySpent);
    }

    /// @notice Execute a Treasury function with native ETH value (Stargate cross-chain fees)
    /// @dev The bot forwards ETH with msg.value; the module funds the Safe then calls Treasury.
    function executeTreasuryFunctionWithValue(bytes calldata data, uint256 value)
        external
        payable
        onlyBot
        onlyAllowedFunction(data)
        withinDailyLimit
    {
        require(msg.value == value, "Invalid ETH value");

        // Forward ETH to Safe so it can fund the Treasury call
        (bool sent,) = safe.call{value: value}("");
        require(sent, "ETH transfer to Safe failed");

        bool success = ISafe(safe).execTransactionFromModule(treasury, value, data, 0);
        require(success, "Execution failed");

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

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // Fonctions de lecture
    function getDailyStats() external view returns (
        uint256 limit,
        uint256 spent,
        uint256 remaining,
        uint256 resetsIn
    ) {
        uint256 currentDay = block.timestamp / 86400;
        uint256 actualSpent = (currentDay == lastResetDay) ? dailySpent : 0;

        return (
            dailyLimit,
            actualSpent,
            dailyLimit - actualSpent,
            86400 - (block.timestamp % 86400)
        );
    }

    function isFunctionAllowed(bytes4 selector) external view returns (bool) {
        return allowedFunctions[selector];
    }

    function _requireInflowsForSelector(bytes4 selector) private view {
        if (
            selector == 0xac1df9bd || // processSingleDeposit()
            selector == 0x76919a59    // processDepositPermissionless(uint256[],uint256[],address,address)
        ) {
            address controller = pauseController;
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
        return
            selector == 0x0be1c372 || // refreshPriceCache()
            selector == 0x63ccfd0b || // mintInitialPosition()
            selector == 0x38ca63bc || // burnPosition(uint256)
            selector == 0xb07391c0 || // executeSwap(address,address,uint256,uint256)
            selector == 0x6ecfe0f8 || // recordPriceSnapshot()
            selector == 0xac1df9bd || // processSingleDeposit()
            selector == 0x76919a59 || // processDepositPermissionless(uint256[],uint256[],address,address)
            selector == 0x4dce7057 || // startRebalance()
            selector == 0x0040718e || // endRebalance()
            selector == 0x2a7cf2fe || // addLiquidityToPosition()
            selector == 0xa5599124 || // bridgeToStakers(uint256)
            selector == 0x56a12aca || // distributeToStakers(uint256)
            selector == 0x1dc28748;   // collectAndBridge(address,uint24,uint256,uint256)
    }
}
