// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

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
    function priceCache()
        external
        view
        returns (uint128 price0, uint128 price1, uint160 sqrtP, int24 tick, uint64 timestamp, bool valid);
    function getOwnerPositions() external view returns (uint256[] memory);
    function positionManager() external view returns (INonfungiblePositionManager);

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

    // endRebalance() est exempte de la limite quotidienne: ce deverrouillage ne deplace aucun fonds.
    // Mints, depots et rebalances utilisent leurs entrees atomiques; l'ancien automate module
    // start/burn/swap/mint n'est plus expose.
    bytes4 private constant END_REBALANCE_SELECTOR = 0x0040718e; // endRebalance()
    bytes4 private constant REFRESH_PRICE_SELECTOR = 0x0be1c372; // refreshPriceCache()

    // Events
    event FunctionExecuted(bytes4 indexed selector, uint256 dailyCount);
    event FunctionAllowed(bytes4 indexed selector, bool allowed);
    event DailyLimitUpdated(uint256 newLimit);
    event Paused(bool paused);
    event DirectExecutionUpdated(bool enabled);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event ModuleSweep(address indexed token, uint256 amount);

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
        allowedFunctions[0x6ecfe0f8] = true; // recordPriceSnapshot() - snapshot de prix (fallback bot si aucun keeper)
        // Setters de stratégie/risk retirés du module: configureRanges, setDynamicRangeEnabled,
        // configureSlippage, configureProtections, configureTolerance.

        // Fonctions MultiUserVault
        // processPendingDeposits (0x99dd7ead) RETIRÉ (audit V1) : fonction batch supprimée du Vault.
        // processSingleDeposit (0xac1df9bd) RETIRÉ de la whitelist : le bot traite désormais aussi le
        // mint initial standard via processDepositPermissionless(), en une transaction atomique bot-only.
        allowedFunctions[0x76919a59] = true; // processDepositPermissionless(uint256[],uint256[],address,address)
        allowedFunctions[0x0040718e] = true; // endRebalance()

        // Fonctions Treasury (bridge Stargate v2 vers staking contract Phase 2)
        allowedFunctions[0xa5599124] = true; // bridgeToStakers(uint256)
        allowedFunctions[0x56a12aca] = true; // distributeToStakers(uint256) - bridge treasury same-chain
        allowedFunctions[0x1dc28748] = true; // collectAndBridge(address,uint24,uint256,uint256)
    }

    receive() external payable {}

    /// @notice LP/free RangeManager NAV reconstructed at the Chainlink token ratio (USD, 8 decimals).
    /// @dev Read-only and unaffected by the module kill-switch. Two Newton steps start from a spot sqrt price
    ///      bounded by the mandatory RangeManager oracle-deviation guard, removing meaningful flash-slot0
    ///      influence from share minting without constraining bot or keeper execution paths.
    function getOracleLpValueUsd() external view returns (uint256 valueUsd) {
        IRangeManagerBotState rm = IRangeManagerBotState(rangeManager);
        (uint128 price0, uint128 price1, uint160 cachedSqrt,,, bool valid) = rm.priceCache();
        require(valid && price0 > 0 && price1 > 0 && cachedSqrt > 0, "E_NAV");
        (, uint8 dec0, uint8 dec1,,,,,,,) = rm.config();
        uint160 oracleSqrt = _oracleSqrtPrice(price0, price1, cachedSqrt, dec0, dec1);
        (uint256 balance0, uint256 balance1) = _balancesAtPrice(rm, oracleSqrt);
        valueUsd = Math.mulDiv(balance0, price0, 10 ** dec0) + Math.mulDiv(balance1, price1, 10 ** dec1);
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
        _requireInflowsForSelector(selector);
        if (selector != REFRESH_PRICE_SELECTOR) {
            _consumeDailyLimit();
        } else {
            _resetDailyCounterIfNeeded();
        }

        _execute(rangeManager, 0, data);

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
        return allowedFunctions[selector];
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
            || selector == 0x6ecfe0f8 // recordPriceSnapshot()
            || selector == 0x76919a59 // processDepositPermissionless(uint256[],uint256[],address,address)
            || selector == 0x0040718e // endRebalance()
            || selector == 0xa5599124 // bridgeToStakers(uint256)
            || selector == 0x56a12aca // distributeToStakers(uint256)
            || selector == 0x1dc28748; // collectAndBridge(address,uint24,uint256,uint256)
    }
}
