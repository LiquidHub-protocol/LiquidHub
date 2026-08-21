// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

interface ILiquidHubVaultRegistryTarget {
    function rangeManager() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalShares() external view returns (uint256);
}

interface ILiquidHubRangeManagerRegistryTarget {
    function vault() external view returns (address);
    function pool() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IDexPoolRegistryTarget {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title LiquidHubVaultRegistry
 * @notice Chain-local discovery registry for Liquid Hub vault portfolio adapters.
 * @dev The registry never holds funds and has no permission on registered vaults.
 *      Adapter-facing pagination includes inactive records so indexes remain stable.
 */
contract LiquidHubVaultRegistry is Ownable2Step {
    uint256 public constant REGISTRY_VERSION = 1;
    uint256 public constant MAX_PAGE_SIZE = 100;
    uint256 private constant ABI_WORD_SIZE = 32;

    bytes32 public constant PROTOCOL_UNISWAP_V3 = bytes32("UNISWAP_V3");
    bytes32 public constant STRATEGY_EXPOSED = bytes32("EXPOSED");
    bytes32 public constant STRATEGY_DELTA_NEUTRAL = bytes32("DELTA_NEUTRAL");
    bytes32 public constant STRATEGY_STABLE = bytes32("STABLE");

    struct VaultRecord {
        address vault;
        address rangeManager;
        address dexPool;
        address token0;
        address token1;
        bytes32 protocolId;
        bytes32 strategyId;
        uint32 interfaceVersion;
        uint64 registeredAtBlock;
        uint64 updatedAtBlock;
        bool active;
    }

    error ZeroAddress();
    error InvalidContract(address target);
    error InvalidMetadata();
    error InvalidInterfaceVersion();
    error VaultAlreadyRegistered(address vault);
    error VaultNotRegistered(address vault);
    error VaultInterfaceReadFailed(address target, bytes4 selector);
    error VaultBindingMismatch(address vault);
    error VaultStatusUnchanged(address vault, bool active);
    error PageSizeTooLarge(uint256 requested, uint256 maximum);
    error BlockNumberOverflow();
    error OwnershipRenunciationDisabled();

    event VaultRegistered(
        address indexed vault,
        uint256 indexed index,
        address indexed rangeManager,
        address dexPool,
        address token0,
        address token1,
        bytes32 protocolId,
        bytes32 strategyId,
        uint32 interfaceVersion
    );
    event VaultMetadataUpdated(address indexed vault, bytes32 protocolId, bytes32 strategyId, uint32 interfaceVersion);
    event VaultStatusChanged(address indexed vault, bool active);

    uint256 public immutable deploymentChainId;
    uint256 public activeVaultCount;

    address[] private _vaultAddresses;
    mapping(address => uint256) private _indexPlusOne;
    mapping(address => VaultRecord) private _records;

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        deploymentChainId = block.chainid;
        _transferOwnership(initialOwner);
    }

    function registerVault(address vault, bytes32 protocolId, bytes32 strategyId, uint32 interfaceVersion)
        external
        onlyOwner
    {
        if (vault == address(0)) revert ZeroAddress();
        if (_indexPlusOne[vault] != 0) revert VaultAlreadyRegistered(vault);
        _validateMetadata(protocolId, strategyId, interfaceVersion);

        (address rangeManager, address dexPool, address token0, address token1) = _validatedBindings(vault);
        uint64 currentBlock = _safeBlockNumber();
        uint256 index = _vaultAddresses.length;

        _vaultAddresses.push(vault);
        _indexPlusOne[vault] = index + 1;
        _records[vault] = VaultRecord({
            vault: vault,
            rangeManager: rangeManager,
            dexPool: dexPool,
            token0: token0,
            token1: token1,
            protocolId: protocolId,
            strategyId: strategyId,
            interfaceVersion: interfaceVersion,
            registeredAtBlock: currentBlock,
            updatedAtBlock: currentBlock,
            active: true
        });
        activeVaultCount += 1;

        emit VaultRegistered(
            vault, index, rangeManager, dexPool, token0, token1, protocolId, strategyId, interfaceVersion
        );
    }

    function updateVaultMetadata(address vault, bytes32 protocolId, bytes32 strategyId, uint32 interfaceVersion)
        external
        onlyOwner
    {
        VaultRecord storage record = _registeredRecord(vault);
        _validateMetadata(protocolId, strategyId, interfaceVersion);

        record.protocolId = protocolId;
        record.strategyId = strategyId;
        record.interfaceVersion = interfaceVersion;
        record.updatedAtBlock = _safeBlockNumber();

        emit VaultMetadataUpdated(vault, protocolId, strategyId, interfaceVersion);
    }

    function setVaultActive(address vault, bool active) external onlyOwner {
        VaultRecord storage record = _registeredRecord(vault);
        if (record.active == active) revert VaultStatusUnchanged(vault, active);

        if (active) {
            (address rangeManager, address dexPool, address token0, address token1) = _validatedBindings(vault);
            if (
                rangeManager != record.rangeManager || dexPool != record.dexPool || token0 != record.token0
                    || token1 != record.token1
            ) {
                revert VaultBindingMismatch(vault);
            }
            activeVaultCount += 1;
        } else {
            activeVaultCount -= 1;
        }

        record.active = active;
        record.updatedAtBlock = _safeBlockNumber();
        emit VaultStatusChanged(vault, active);
    }

    function isRegistered(address vault) external view returns (bool) {
        return _indexPlusOne[vault] != 0;
    }

    function vaultCount() external view returns (uint256) {
        return _vaultAddresses.length;
    }

    function vaultAt(uint256 index) external view returns (address) {
        return _vaultAddresses[index];
    }

    function getVault(address vault) external view returns (VaultRecord memory) {
        if (_indexPlusOne[vault] == 0) revert VaultNotRegistered(vault);
        return _records[vault];
    }

    function getVaults(uint256 offset, uint256 limit) external view returns (VaultRecord[] memory page) {
        if (limit > MAX_PAGE_SIZE) revert PageSizeTooLarge(limit, MAX_PAGE_SIZE);

        uint256 length = _vaultAddresses.length;
        if (offset >= length || limit == 0) return new VaultRecord[](0);

        uint256 remaining = length - offset;
        uint256 pageLength = limit < remaining ? limit : remaining;
        page = new VaultRecord[](pageLength);
        for (uint256 i; i < pageLength; ++i) {
            page[i] = _records[_vaultAddresses[offset + i]];
        }
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        super.transferOwnership(newOwner);
    }

    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    function _registeredRecord(address vault) private view returns (VaultRecord storage record) {
        if (_indexPlusOne[vault] == 0) revert VaultNotRegistered(vault);
        return _records[vault];
    }

    function _validateMetadata(bytes32 protocolId, bytes32 strategyId, uint32 interfaceVersion) private pure {
        if (protocolId == bytes32(0) || strategyId == bytes32(0)) revert InvalidMetadata();
        if (interfaceVersion == 0) revert InvalidInterfaceVersion();
    }

    function _validatedBindings(address vault)
        private
        view
        returns (address rangeManager, address dexPool, address token0, address token1)
    {
        _requireContract(vault);

        rangeManager = _readAddress(vault, ILiquidHubVaultRegistryTarget.rangeManager.selector);
        token0 = _readAddress(vault, ILiquidHubVaultRegistryTarget.token0.selector);
        token1 = _readAddress(vault, ILiquidHubVaultRegistryTarget.token1.selector);
        _requireUintRead(vault, ILiquidHubVaultRegistryTarget.totalShares.selector);

        if (token0 == token1) revert VaultBindingMismatch(vault);
        _requireContract(rangeManager);
        _requireContract(token0);
        _requireContract(token1);

        dexPool = _readAddress(rangeManager, ILiquidHubRangeManagerRegistryTarget.pool.selector);
        address managerVault = _readAddress(rangeManager, ILiquidHubRangeManagerRegistryTarget.vault.selector);
        address managerToken0 = _readAddress(rangeManager, ILiquidHubRangeManagerRegistryTarget.token0.selector);
        address managerToken1 = _readAddress(rangeManager, ILiquidHubRangeManagerRegistryTarget.token1.selector);
        _requireContract(dexPool);

        address poolToken0 = _readAddress(dexPool, IDexPoolRegistryTarget.token0.selector);
        address poolToken1 = _readAddress(dexPool, IDexPoolRegistryTarget.token1.selector);

        if (
            managerVault != vault || managerToken0 != token0 || managerToken1 != token1 || poolToken0 != token0
                || poolToken1 != token1
        ) {
            revert VaultBindingMismatch(vault);
        }
    }

    function _requireContract(address target) private view {
        if (target == address(0)) revert ZeroAddress();
        if (target.code.length == 0) revert InvalidContract(target);
    }

    function _readAddress(address target, bytes4 selector) private view returns (address value) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSelector(selector));
        if (!success || data.length < ABI_WORD_SIZE) revert VaultInterfaceReadFailed(target, selector);
        value = abi.decode(data, (address));
        if (value == address(0)) revert ZeroAddress();
    }

    function _requireUintRead(address target, bytes4 selector) private view {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSelector(selector));
        if (!success || data.length < ABI_WORD_SIZE) revert VaultInterfaceReadFailed(target, selector);
    }

    function _safeBlockNumber() private view returns (uint64) {
        if (block.number > type(uint64).max) revert BlockNumberOverflow();
        return uint64(block.number);
    }
}
