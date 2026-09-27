'use strict';

const { ethers } = require('ethers');

const NAV_DECIMALS = 8;
const DEFAULT_PAGE_SIZE = 25;
const MAX_PAGE_SIZE = 100;
const SUPPORTED_INTERFACE_VERSION = 1;
const MAX_NAV_PRICE_AGE_SECONDS = 3600;

const REGISTRY_ABI = [
    'function deploymentChainId() view returns (uint256)',
    'function vaultCount() view returns (uint256)',
    'function getVaults(uint256 offset,uint256 limit) view returns ((address vault,address rangeManager,address dexPool,address token0,address token1,bytes32 protocolId,bytes32 strategyId,uint32 interfaceVersion,uint64 registeredAtBlock,uint64 updatedAtBlock,bool active)[])',
];

const VAULT_ABI = [
    'function userInfo(address user) view returns (uint256 shares,uint256 depositedToken0,uint256 depositedToken1,uint256 depositedValueUSD,uint256 lastDepositTime,uint256 totalFeesEarnedToken0,uint256 totalFeesEarnedToken1,uint256 firstDepositTime,uint256 lastDepositBlock)',
    'function totalShares() view returns (uint256)',
    'function getCurrentPortfolioValue() view returns (uint256)',
];
const RANGE_MANAGER_ABI = [
    'function priceCache() view returns (uint128 price0, uint128 price1, uint160 sqrtPriceX96, int24 poolTick, uint64 timestamp, bool valid)',
];

function calculateUserValue(nav, shares, totalShares) {
    const navValue = BigInt(nav);
    const userShares = BigInt(shares);
    const supply = BigInt(totalShares);
    if (userShares === 0n) return 0n;
    if (supply === 0n) throw new Error('Vault has user shares but totalShares is zero');
    return (navValue * userShares) / supply;
}

function navValuationStatus(shares, nav, cache, nowSeconds) {
    try {
        const stamp = Number(cache?.timestamp);
        if (BigInt(shares) > 0n && (BigInt(nav) <= 0n || !cache?.valid
            || BigInt(cache.price0 || 0) <= 0n || BigInt(cache.price1 || 0) <= 0n
            || !Number.isSafeInteger(stamp) || stamp <= 0 || stamp > nowSeconds
            || nowSeconds - stamp > MAX_NAV_PRICE_AGE_SECONDS)) return 'unavailable-or-stale-price-cache';
        return 'current';
    } catch { return 'unavailable-or-stale-price-cache'; }
}

function decodeRegistryId(value) {
    try {
        return ethers.decodeBytes32String(value);
    } catch {
        return String(value);
    }
}

function requireSupportedInterfaceVersion(value) {
    const version = Number(value);
    if (!Number.isInteger(version) || version !== SUPPORTED_INTERFACE_VERSION) {
        throw new Error(`Unsupported Liquid Hub vault interface version: ${String(value)}`);
    }
    return version;
}

function requireMatchingChain(registryChainId, providerChainId) {
    const registryChain = BigInt(registryChainId);
    const providerChain = BigInt(providerChainId);
    if (registryChain !== providerChain) {
        throw new Error(`Registry chain ${registryChain} does not match provider chain ${providerChain}`);
    }
    return registryChain;
}

function createPositionId(chainId, vault, user) {
    const normalizedChainId = BigInt(chainId);
    if (normalizedChainId <= 0n) throw new Error('chainId must be positive');
    return `liquidhub:${normalizedChainId}:${ethers.getAddress(vault).toLowerCase()}:${ethers.getAddress(user).toLowerCase()}`;
}

async function readPosition(provider, user, record, chainId, blockTag, blockTimestamp) {
    const interfaceVersion = requireSupportedInterfaceVersion(record.interfaceVersion);
    const vault = new ethers.Contract(record.vault, VAULT_ABI, provider);
    const userInfo = await vault.userInfo(user, { blockTag });
    const shares = BigInt(userInfo.shares);
    if (shares === 0n) return null;

    const [totalShares, nav, cache] = await Promise.all([
        vault.totalShares({ blockTag }),
        vault.getCurrentPortfolioValue({ blockTag }),
        new ethers.Contract(record.rangeManager, RANGE_MANAGER_ABI, provider).priceCache({ blockTag }),
    ]);
    const valuationStatus = navValuationStatus(shares, nav, cache, blockTimestamp);
    const valueUsdRaw = valuationStatus === 'current' ? calculateUserValue(nav, shares, totalShares) : null;
    return {
        id: createPositionId(chainId, record.vault, user),
        chainId: BigInt(chainId),
        protocol: 'Liquid Hub',
        protocolId: decodeRegistryId(record.protocolId),
        strategy: decodeRegistryId(record.strategyId),
        interfaceVersion,
        vault: record.vault,
        active: Boolean(record.active),
        rangeManager: record.rangeManager,
        dexPool: record.dexPool,
        token0: record.token0,
        token1: record.token1,
        shares,
        totalShares: BigInt(totalShares),
        valuationStatus,
        priceCacheTimestamp: Number(cache.timestamp),
        valueUsdRaw,
        valueUsdDecimals: NAV_DECIMALS,
        valueUsd: valueUsdRaw === null ? null : ethers.formatUnits(valueUsdRaw, NAV_DECIMALS),
    };
}

async function getLiquidHubPositions({ provider, user, registryAddress, pageSize = DEFAULT_PAGE_SIZE }) {
    if (!provider) throw new Error('provider is required');
    const normalizedUser = ethers.getAddress(user);
    const normalizedRegistry = ethers.getAddress(registryAddress);
    if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > MAX_PAGE_SIZE) {
        throw new Error(`pageSize must be between 1 and ${MAX_PAGE_SIZE}`);
    }

    // Discovery and valuation share one snapshot even when the chain advances between calls.
    const blockTag = await provider.getBlockNumber();
    if (!Number.isSafeInteger(blockTag) || blockTag < 0) throw new Error('Invalid snapshot block number');
    const registry = new ethers.Contract(normalizedRegistry, REGISTRY_ABI, provider);
    const [chainId, countRaw, network, block] = await Promise.all([
        registry.deploymentChainId({ blockTag }),
        registry.vaultCount({ blockTag }),
        provider.getNetwork(),
        provider.getBlock(blockTag),
    ]);
    const blockTimestamp = Number(block?.timestamp);
    if (!Number.isSafeInteger(blockTimestamp) || blockTimestamp <= 0) throw new Error('Snapshot block timestamp unavailable');
    const verifiedChainId = requireMatchingChain(chainId, network.chainId);
    const count = Number(countRaw);
    if (!Number.isSafeInteger(count)) throw new Error('Registry vault count is too large');

    const positions = [];
    const failures = [];
    for (let offset = 0; offset < count; offset += pageSize) {
        const records = await registry.getVaults(offset, Math.min(pageSize, count - offset), { blockTag });
        // Deactivation stops new discovery for investment; it must not hide
        // shares already owned by this user or their withdrawal route.
        const positionRecords = records;
        const settled = await Promise.allSettled(
            positionRecords.map((record) => readPosition(provider, normalizedUser, record, verifiedChainId, blockTag, blockTimestamp)),
        );
        settled.forEach((result, index) => {
            if (result.status === 'fulfilled') {
                if (result.value) positions.push(result.value);
                return;
            }
            failures.push({
                vault: positionRecords[index].vault,
                reason: result.reason instanceof Error ? result.reason.message : String(result.reason),
            });
        });
    }

    return { chainId: verifiedChainId, blockNumber: blockTag, positions, failures };
}

module.exports = {
    NAV_DECIMALS,
    REGISTRY_ABI,
    SUPPORTED_INTERFACE_VERSION,
    VAULT_ABI,
    calculateUserValue,
    createPositionId,
    decodeRegistryId,
    getLiquidHubPositions,
    requireMatchingChain,
    requireSupportedInterfaceVersion,
};
