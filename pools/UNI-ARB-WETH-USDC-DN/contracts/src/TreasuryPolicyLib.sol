// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {AutonomousRevenueLib, IRevenueConversionPolicy} from "./AutonomousRevenueLib.sol";
import "./AutonomousErrors.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface ITreasuryPolicyContext {
    function usdc() external view returns (address);
    function usdcDecimals() external view returns (uint8);
    function swapRouter() external view returns (address);
    function rescueSafe() external view returns (address);
    function configurationSealed() external view returns (bool);
    function keeperBountyEnabled() external view returns (bool);
    function keeperBountyAmount() external view returns (uint256);
    function keeperBountyDailyCap() external view returns (uint256);
    function strategyCheckpointBountyEnabled() external view returns (bool);
    function strategyCheckpointBountyAmount() external view returns (uint256);
    function strategyCheckpointBountyDailyCap() external view returns (uint256);
    function hedgeBountyEnabled() external view returns (bool);
    function hedgeBountyAmount() external view returns (uint256);
    function hedgeBountyDailyCap() external view returns (uint256);
    function depositBountyEnabled() external view returns (bool);
    function depositBountyAmount() external view returns (uint256);
    function depositBountyDailyCap() external view returns (uint256);
    function depositBountyCooldown() external view returns (uint64);
    function depositBountyKeeperCooldown() external view returns (uint64);
    function conversionBountyEnabled() external view returns (bool);
    function conversionBountyAmount() external view returns (uint256);
    function conversionBountyCooldown() external view returns (uint64);
    function conversionBountyMinRatio() external view returns (uint16);
    function lastConversionBountyAt() external view returns (uint64);
    function performGovernanceBountyTransfer(address keeper, uint256 amount) external;
}

interface ISourceInstallation {
    function installationSealed() external view returns (bool);
    function owner() external view returns (address);
}

interface ITreasuryCatalogue {
    function isPreparingTreasurySource(bytes32 id, address factory, address vault) external view returns (bool);
}

interface ITreasuryFactory {
    function catalogue() external view returns (address);
    function governance() external view returns (address);
    function isPreparingSource(bytes32 id, address vault) external view returns (bool);
    function sourceActors(bytes32 id)
        external
        view
        returns (address vault, address rangeManager, address engine, address module, address hedge);
    function sourceAsset(bytes32 id, uint8 index)
        external
        view
        returns (address token, address usdFeed, uint32 maxAge, bytes memory route);
    function sourceRebate(bytes32 id) external view returns (address);
    function sourceAssetLimits(bytes32 id, uint8 index)
        external
        view
        returns (uint256 maxInput, uint256 minUsdc, uint64 cooldown, uint16 slippageBps);
}

/// @notice Strategy-independent, fixed Treasury rules: authenticated sources, received assets,
/// protected commission accounting and bounded pool/conversion/governance bounty policy.
/// All storage stays in the single chain Treasury; this library has no owner or custody.
library TreasuryPolicyLib {
    using SafeERC20 for IERC20;
    uint256 private constant RESERVE_BPS = 500;
    error PolicyInvalid();
    error Unauthorized();
    event SourceInstalled(address indexed source, address indexed actor);
    event SourceSealed(address indexed source);
    event RevenueRecorded(address indexed source, address indexed token, uint256 amount);
    event BountyReserveCredited(address indexed source, uint256 revenue, uint256 reserved);
    event BountyReserveSpent(address indexed source, uint256 amount);
    event BountyFunded(address indexed source, uint256 amount);
    event DepositBountyPaid(address indexed keeper, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    struct Asset {
        address feed;
        address router;
        uint32 maxAge;
        uint16 slippageBps;
        uint24 fee;
        bool installed;
        uint256 maxInput;
        uint256 minUsdc;
        uint64 cooldown;
        bytes path;
    }

    struct Setting {
        uint128 amount;
        uint128 cap;
    }

    struct Daily {
        uint64 day;
        uint192 spent;
    }

    struct Payment {
        uint64 updatedAt;
        uint192 amount;
    }

    struct Rolling {
        Payment[] payments;
        uint256 cursor;
        uint256 spent;
    }

    struct Bucket {
        uint256 credit;
        uint64 updatedAt;
        uint32 version;
        uint256 refillIndex;
    }

    struct GovSettings {
        uint128 control;
        uint128 action;
        uint128 globalCap;
        uint128 addressCap;
    }

    struct Policy {
        address governance;
        address catalogue;
        address registry;
        uint256 allocationRemainder;
        mapping(address => Asset) assets;
        mapping(address => mapping(uint8 => Setting)) settings;
        mapping(address => mapping(uint8 => Daily)) spent;
        mapping(address => uint64) lastEpoch;
        Rolling conversionRolling;
        uint64 conversionLastPaid;
        GovSettings gov;
        Bucket globalBucket;
        mapping(address => Bucket) keeperBuckets;
        Rolling globalRolling;
        mapping(address => Rolling) keeperRolling;
        mapping(bytes32 => bool) consumed;
        mapping(uint64 => uint256) globalUtc;
        mapping(uint64 => mapping(uint8 => uint256)) categoryUtc;
        mapping(uint64 => mapping(address => uint256)) keeperUtc;
        uint64 lastPaid;
        uint64 lastControlWindow;
        bool controlPaid;
        uint64 configurationAt;
        uint32 version;
        uint256 keeperRefillIndex;
        mapping(uint32 => mapping(uint8 => int256)) capMinimum;
    }

    function install(AutonomousRevenueLib.State storage s, address source, address[] calldata actors) external {
        require(
            source != address(0) && source != address(this) && !s.sourceInstalled[source] && actors.length > 0,
            AutonomousCheck(0x16001604)
        );
        s.sourceInstalled[source] = true;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            require(actor.code.length > 0 && s.sourceOf[actor] == address(0), AutonomousCheck(0x280035fb));
            s.sourceOf[actor] = source;
            emit SourceInstalled(source, actor);
        }
    }

    function authorize(AutonomousRevenueLib.State storage s, address actor, bool allowed, uint8 role) external {
        require(!s.sourceSealed[s.sourceOf[actor]], AutonomousCheck(0x9a247fa1));
        require(allowed && s.sourceOf[actor] != address(0), AutonomousCheck(0x7ea92fcb));
        require(actor.code.length > 0, AutonomousCheck(0x2c7a47d0));
        s.roles[actor] |= role;
    }

    function sealSource(AutonomousRevenueLib.State storage s, address source) external {
        require(s.sourceInstalled[source] && !s.sourceSealed[source], AutonomousCheck(0x16001604));
        s.sourceSealed[source] = true;
        emit SourceSealed(source);
    }

    function record(AutonomousRevenueLib.State storage s, address usdc, address token, uint256 amount) external {
        address source = s.sourceOf[msg.sender];
        require(source != address(0) && amount > 0, AutonomousCheck(0xdd62405b));
        _sync(s, usdc, token);
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        require(IERC20(token).balanceOf(address(this)) - beforeBalance == amount, AutonomousCheck(0xcfa42862));
        s.accounted[token] += amount;
        if (token == usdc) _credit(s, source, amount);
        else s.pending[source][token] += amount;
        emit RevenueRecorded(source, token, amount);
    }

    function sync(AutonomousRevenueLib.State storage s, address usdc, address token) external returns (uint256 amount) {
        return _sync(s, usdc, token);
    }

    function _sync(AutonomousRevenueLib.State storage s, address usdc, address token) private returns (uint256 amount) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= s.accounted[token], AutonomousCheck(0x05435e06));
        amount = balance - s.accounted[token];
        s.accounted[token] = balance;
        if (amount != 0) {
            if (token == usdc) _credit(s, address(this), amount);
            else s.pending[address(this)][token] += amount;
            emit RevenueRecorded(address(this), token, amount);
        }
    }

    function converted(
        AutonomousRevenueLib.State storage s,
        address usdc,
        address source,
        address token,
        uint256 amountIn,
        uint256 amountOut
    ) external {
        require(amountIn <= s.pending[source][token], AutonomousCheck(0x3f381c16));
        s.pending[source][token] -= amountIn;
        s.accounted[token] -= amountIn;
        s.accounted[usdc] += amountOut;
        _credit(s, source, amountOut);
    }

    function fund(AutonomousRevenueLib.State storage s, address usdc, address source, uint256 amount) external {
        require((source == address(this) || s.sourceInstalled[source]) && amount > 0, AutonomousCheck(0xcb003268));
        _sync(s, usdc, usdc);
        uint256 beforeBalance = IERC20(usdc).balanceOf(address(this));
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
        require(IERC20(usdc).balanceOf(address(this)) - beforeBalance == amount, AutonomousCheck(0xbd973d7e));
        s.accounted[usdc] += amount;
        s.reserve[source] += amount;
        s.totalReserve += amount;
        emit BountyFunded(source, amount);
    }

    function withdraw(AutonomousRevenueLib.State storage s, address usdc, address to, uint256 amount) external {
        require(to != address(0) && amount > 0, AutonomousCheck(0x92d7cfce));
        _sync(s, usdc, usdc);
        require(
            s.accounted[usdc] >= s.totalReserve && amount <= s.accounted[usdc] - s.totalReserve,
            AutonomousCheck(0xbac20538)
        );
        s.accounted[usdc] -= amount;
        IERC20(usdc).safeTransfer(to, amount);
    }

    function spend(AutonomousRevenueLib.State storage s, address actor, uint256 amount) external {
        _spend(s, actor, amount);
    }

    function _spend(AutonomousRevenueLib.State storage s, address actor, uint256 amount) private {
        address source = actor == address(this) ? address(this) : s.sourceOf[actor];
        require(source != address(0) && amount > 0 && s.reserve[source] >= amount, AutonomousCheck(0x933c73ff));
        s.reserve[source] -= amount;
        s.totalReserve -= amount;
        emit BountyReserveSpent(source, amount);
    }

    function debit(AutonomousRevenueLib.State storage s, address usdc, uint256 amount) external {
        require(amount <= s.accounted[usdc], AutonomousCheck(0x34be11f1));
        s.accounted[usdc] -= amount;
    }

    function protectedBalance(AutonomousRevenueLib.State storage s, address usdc) public view returns (uint256) {
        uint256 balance = IERC20(usdc).balanceOf(address(this));
        require(balance >= s.accounted[usdc], AutonomousCheck(0x05435e06));
        uint256 unaccounted = balance - s.accounted[usdc];
        uint256 base = (unaccounted * RESERVE_BPS + s.remainder[address(this)]) / 10000;
        uint256 gov;
        if (s.policy.governance != address(0)) {
            gov = (unaccounted * 50 + s.policy.allocationRemainder) / 10000;
            uint256 ceiling = 20 * (10 ** uint256(ITreasuryPolicyContext(address(this)).usdcDecimals()));
            uint256 remaining = ceiling > s.reserve[s.policy.governance] ? ceiling - s.reserve[s.policy.governance] : 0;
            if (gov > remaining) gov = remaining;
            if (gov > unaccounted - base) gov = unaccounted - base;
        }
        return s.totalReserve + base + gov;
    }

    function creditRevenue(AutonomousRevenueLib.State storage s, address source, uint256 amount) external {
        _credit(s, source, amount);
    }

    function _credit(AutonomousRevenueLib.State storage s, address source, uint256 amount) private {
        // Carry survives every inflow and every bounty payment; splitting receipts cannot evade the 5% allocation.
        uint256 numerator = amount * RESERVE_BPS + s.remainder[source];
        uint256 reserved = numerator / 10000;
        s.remainder[source] = numerator % 10000;
        if (source == address(this)) {
            s.reserve[source] += reserved;
        } else {
            // One fifth of the protected budget pays verified local USDC conversion work; four fifths remain source-isolated.
            uint256 split = reserved + s.conversionRemainder[source];
            uint256 conversionPart = split / 5;
            s.conversionRemainder[source] = split % 5;
            s.reserve[address(this)] += conversionPart;
            s.reserve[source] += reserved - conversionPart;
        }
        s.totalReserve += reserved;
        if (s.policy.governance != address(0)) {
            uint256 numeratorGov = amount * 50 + s.policy.allocationRemainder;
            uint256 gov = numeratorGov / 10000;
            s.policy.allocationRemainder = numeratorGov % 10000;
            uint256 ceiling = 20 * (10 ** uint256(ITreasuryPolicyContext(address(this)).usdcDecimals()));
            uint256 remaining = ceiling > s.reserve[s.policy.governance] ? ceiling - s.reserve[s.policy.governance] : 0;
            if (gov > remaining) gov = remaining;
            if (gov > amount - reserved) {
                s.policy.allocationRemainder += (gov - (amount - reserved)) * 10000;
                gov = amount - reserved;
            }
            s.reserve[s.policy.governance] += gov;
            s.totalReserve += gov;
            emit GovernanceReserveCredited(amount, gov);
        }
        s.revenue[source] += amount;
        emit BountyReserveCredited(source, amount, reserved);
    }

    function distributable(AutonomousRevenueLib.State storage s, address stable) external view returns (uint256) {
        uint256 balance = IERC20(stable).balanceOf(address(this));
        uint256 reserve = protectedBalance(s, stable);
        return balance > reserve ? balance - reserve : 0;
    }

    event GovernancePolicyInstalled(address indexed governance, address indexed catalogue, address indexed registry);
    event SourceBountyConfigured(
        address indexed source,
        uint8 indexed kind,
        uint256 previousAmount,
        uint256 previousCap,
        uint256 amount,
        uint256 dailyCap,
        uint64 effectiveAt
    );
    event GovernanceBountiesConfigured(
        uint256 previousControl,
        uint256 previousAction,
        uint256 previousGlobalCap,
        uint256 previousAddressCap,
        uint256 control,
        uint256 action,
        uint256 globalCap,
        uint256 addressCap,
        uint64 effectiveAt
    );
    event GovernanceBountySkipped(address indexed keeper, bytes32 indexed actionKey, uint8 category, uint8 reason);
    event GovernanceBountyPaid(address indexed keeper, bytes32 indexed actionKey, uint8 category, uint256 amount);
    event GovernanceReserveCredited(uint256 revenue, uint256 amount);
    event KeeperBountyPaid(address indexed keeper, uint256 amount);
    event StrategyCheckpointBountyPaid(address indexed keeper, address indexed engine, uint64 epoch, uint256 amount);
    event HedgeBountyPaid(address indexed keeper, uint256 amount);
    event ConversionBountyPaid(address indexed keeper, uint256 amount);
    event AssetSealed(address indexed token);

    function installGovernancePolicy(
        AutonomousRevenueLib.State storage s,
        address governance,
        address catalogue,
        address registry
    ) external {
        ITreasuryPolicyContext c = ITreasuryPolicyContext(address(this));
        Policy storage p = s.policy;
        if (
            c.configurationSealed() || p.governance != address(0) || governance == address(this)
                || s.sourceInstalled[governance] || s.sourceOf[governance] != address(0) || governance.code.length == 0
                || catalogue.code.length == 0 || registry.code.length == 0 || block.chainid != 42161
                || c.usdcDecimals() < 2
        ) revert PolicyInvalid();
        p.governance = governance;
        p.catalogue = catalogue;
        p.registry = registry;
        uint256 u = 10 ** uint256(c.usdcDecimals());
        p.gov = GovSettings(uint128(u * 2 / 100), uint128(u * 5 / 100), uint128(u * 2), uint128(u / 2));
        p.configurationAt = uint64(block.timestamp);
        p.version = 1;
        p.globalBucket.credit = (u * 2 * 5 / 100) * 1 days;
        p.globalBucket.updatedAt = uint64(block.timestamp);
        _appendClamp(p, u / 2);
        emit GovernancePolicyInstalled(governance, catalogue, registry);
    }

    function bountyBounds(uint8 kind, uint8 decimals)
        public
        pure
        returns (
            uint256 minAmount,
            uint256 maxAmount,
            uint256 minCap,
            uint256 maxCap,
            uint256 initialAmount,
            uint256 initialCap
        )
    {
        uint256 u = 10 ** uint256(decimals);
        if (kind == 0) return (u / 2, 5 * u, 5 * u, 50 * u, 2 * u, 10 * u);
        if (kind == 1) return (u * 2 / 100, u / 4, u / 2, 5 * u, u / 10, u);
        if (kind == 2) return (u * 5 / 100, u, u, 20 * u, u / 4, 5 * u);
        if (kind == 3) return (u * 5 / 100, u, u, 12 * u, u / 4, 3 * u);
        if (kind == 4) return (u / 10, 2 * u, u / 2, 8 * u, u / 2, 2 * u);
        revert PolicyInvalid();
    }

    function sourceBounty(AutonomousRevenueLib.State storage s, address source, uint8 kind)
        external
        view
        returns (uint256 amount, uint256 cap)
    {
        return _sourceBounty(s, source, kind);
    }

    function _sourceBounty(AutonomousRevenueLib.State storage s, address source, uint8 kind)
        private
        view
        returns (uint256 amount, uint256 cap)
    {
        Setting storage st = s.policy.settings[source][kind];
        if (st.amount != 0) return (st.amount, st.cap);
        (,,,, amount, cap) = bountyBounds(kind, ITreasuryPolicyContext(address(this)).usdcDecimals());
    }

    function setSourceBounty(
        AutonomousRevenueLib.State storage s,
        address source,
        uint8 kind,
        uint256 amount,
        uint256 cap
    ) external {
        if (
            msg.sender != ITreasuryPolicyContext(address(this)).rescueSafe() || s.policy.governance == address(0)
                || (kind == 4 ? source != address(this) : !s.sourceInstalled[source])
        ) revert Unauthorized();
        (uint256 amin, uint256 amax, uint256 cmin, uint256 cmax,,) =
            bountyBounds(kind, ITreasuryPolicyContext(address(this)).usdcDecimals());
        if (amount < amin || amount > amax || cap < cmin || cap > cmax || amount > cap) revert PolicyInvalid();
        (uint256 previousAmount, uint256 previousCap) = _sourceBounty(s, source, kind);
        s.policy.settings[source][kind] = Setting(uint128(amount), uint128(cap));
        emit SourceBountyConfigured(source, kind, previousAmount, previousCap, amount, cap, uint64(block.timestamp));
    }

    function sourceSpent(AutonomousRevenueLib.State storage s, address actor, uint8 kind)
        external
        view
        returns (uint64 day, uint256 amount)
    {
        address source = s.policy.governance == address(0) ? actor : s.sourceOf[actor];
        Daily storage d = s.policy.spent[source][kind];
        return (d.day, d.spent);
    }

    function lastEpoch(AutonomousRevenueLib.State storage s, address actor) external view returns (uint64) {
        return s.policy.lastEpoch[actor];
    }

    function payPoolBounty(
        AutonomousRevenueLib.State storage s,
        address stable,
        address keeper,
        uint8 kind,
        uint64 epoch
    ) external returns (uint256 amount) {
        uint8 role = kind == 0 ? 1 : kind == 1 ? 2 : 4;
        if (kind > 3 || kind == 2) revert PolicyInvalid();
        require(keeper != address(0), AutonomousCheck(0x7245243a));
        require(s.roles[msg.sender] & role != 0, AutonomousCheck(0x52c79c7b));
        address source = s.sourceOf[msg.sender];
        uint256 cap;
        bool modern = s.policy.governance != address(0);
        if (modern) {
            _requireSealedSource(s, source);
            (amount, cap) = _sourceBounty(s, source, kind);
        } else {
            source = msg.sender;
            bool enabled;
            if (kind == 0) {
                enabled = s.legacy.keeperBountyEnabled;
                amount = s.legacy.keeperBountyAmount;
                cap = s.legacy.keeperBountyDailyCap;
            } else if (kind == 1) {
                enabled = s.legacy.strategyCheckpointBountyEnabled;
                amount = s.legacy.strategyCheckpointBountyAmount;
                cap = s.legacy.strategyCheckpointBountyDailyCap;
            } else {
                enabled = s.legacy.hedgeBountyEnabled;
                amount = s.legacy.hedgeBountyAmount;
                cap = s.legacy.hedgeBountyDailyCap;
            }
            require(enabled, AutonomousCheck(0xb897c761));
            require(amount > 0, AutonomousCheck(0x2567641d));
        }
        if (kind == 1) {
            require(epoch > s.policy.lastEpoch[msg.sender], AutonomousCheck(0xca0ab3e3));
            s.policy.lastEpoch[msg.sender] = epoch;
        }
        Daily storage d = s.policy.spent[source][kind];
        uint64 day = uint64(block.timestamp / 1 days);
        if (d.day != day) {
            d.day = day;
            d.spent = 0;
        }
        uint256 next = d.spent + amount;
        bytes4 failure = kind == 0 ? bytes4(0xa92dbde6) : kind == 1 ? bytes4(0xc5ba5b72) : bytes4(0xeca123c3);
        require((!modern && kind != 1 && cap == 0) || next <= cap, AutonomousCheck(failure));
        d.spent = uint192(next);
        _sync(s, stable, stable);
        _spend(s, msg.sender, amount);
        require(amount <= s.accounted[stable], AutonomousCheck(0x34be11f1));
        s.accounted[stable] -= amount;
        IERC20(stable).safeTransfer(keeper, amount);
        if (kind == 0) emit KeeperBountyPaid(keeper, amount);
        else if (kind == 1) emit StrategyCheckpointBountyPaid(keeper, msg.sender, epoch, amount);
        else emit HedgeBountyPaid(keeper, amount);
    }

    function _requireSealedSource(AutonomousRevenueLib.State storage s, address source) private view {
        if (!s.sourceSealed[source] || !ISourceInstallation(source).installationSealed()) revert Unauthorized();
    }

    function payConversionBounty(AutonomousRevenueLib.State storage s, address stable, address keeper, uint256 convertedUsdc)
        external
        returns (uint256 amount)
    {
        if (msg.sender != address(this)) revert Unauthorized();
        Policy storage p = s.policy;
        if (!ITreasuryPolicyContext(address(this)).configurationSealed() || !s.legacy.conversionBountyEnabled) return 0;
        if (p.governance == address(0)) return 0;
        {
            uint256 cap;
            (amount, cap) = _sourceBounty(s, address(this), 4);
            if (s.reserve[address(this)] < amount) return 0;
            if (
                block.timestamp < uint256(p.conversionLastPaid) + s.legacy.conversionBountyCooldown || convertedUsdc < amount * s.legacy.conversionBountyMinRatio
                    || !_prune(p.conversionRolling, 256) || p.conversionRolling.spent + amount > cap
            ) return 0;
            Daily storage d = p.spent[address(this)][4];
            uint64 day = uint64(block.timestamp / 1 days);
            if (d.day != day) {
                d.day = day;
                d.spent = 0;
            }
            if (d.spent + amount > cap) return 0;
            d.spent += uint192(amount);
            p.conversionLastPaid = uint64(block.timestamp);
            _push(p.conversionRolling, amount);
        }
        if (s.reserve[address(this)] < amount) return 0;
        _sync(s, stable, stable);
        _spend(s, address(this), amount);
        s.accounted[stable] -= amount;
        IERC20(stable).safeTransfer(keeper, amount);
        emit ConversionBountyPaid(keeper, amount);
    }

    function setGovernanceBounties(
        AutonomousRevenueLib.State storage s,
        uint256 control,
        uint256 action,
        uint256 globalCap,
        uint256 addressCap
    ) external {
        Policy storage p = s.policy;
        ITreasuryPolicyContext c = ITreasuryPolicyContext(address(this));
        if (msg.sender != c.rescueSafe() || p.governance == address(0)) revert Unauthorized();
        uint256 u = 10 ** uint256(c.usdcDecimals());
        if (
            control < u / 100 || control > u / 10 || action < u * 2 / 100 || action > u / 5 || globalCap < u
                || globalCap > 10 * u || addressCap < u / 10 || addressCap > u * 5 / 2 || addressCap > globalCap / 4
                || control > globalCap * 5 / 100 || action > globalCap * 5 / 100 || control > addressCap / 10
                || action > addressCap / 10
        ) revert PolicyInvalid();
        GovSettings memory previous = p.gov;
        _settleGlobal(p);
        p.keeperRefillIndex = _currentKeeperIndex(p);
        p.configurationAt = uint64(block.timestamp);
        p.gov = GovSettings(uint128(control), uint128(action), uint128(globalCap), uint128(addressCap));
        uint256 ceiling = globalCap * 5 / 100 * 1 days;
        if (p.globalBucket.credit > ceiling) p.globalBucket.credit = ceiling;
        ++p.version;
        _appendClamp(p, addressCap);
        emit GovernanceBountiesConfigured(
            previous.control,
            previous.action,
            previous.globalCap,
            previous.addressCap,
            control,
            action,
            globalCap,
            addressCap,
            uint64(block.timestamp)
        );
    }

    function _settleGlobal(Policy storage p) private {
        uint256 credit = p.globalBucket.credit + (block.timestamp - p.globalBucket.updatedAt)
            * (uint256(p.gov.globalCap) * 95 / 100);
        uint256 ceiling = uint256(p.gov.globalCap) * 5 / 100 * 1 days;
        p.globalBucket.credit = credit > ceiling ? ceiling : credit;
        p.globalBucket.updatedAt = uint64(block.timestamp);
    }

    function _currentKeeperIndex(Policy storage p) private view returns (uint256) {
        return p.keeperRefillIndex + (block.timestamp - p.configurationAt) * (uint256(p.gov.addressCap) * 90 / 100);
    }

    function _appendClamp(Policy storage p, uint256 addressCap) private {
        int256 value = int256(addressCap / 10 * 1 days) - int256(p.keeperRefillIndex);
        p.capMinimum[p.version][0] = value;
        for (uint8 level = 1; uint256(1) << level <= p.version; ++level) {
            uint32 back = p.version - uint32(uint256(1) << (level - 1));
            int256 other = p.capMinimum[back][level - 1];
            if (other < value) value = other;
            p.capMinimum[p.version][level] = value;
        }
    }

    function _minClamp(Policy storage p, uint32 from, uint32 to) private view returns (int256 value) {
        uint32 n = to - from + 1;
        uint8 level;
        while (uint256(1) << (level + 1) <= n) ++level;
        uint32 width = uint32(uint256(1) << level);
        value = p.capMinimum[to][level];
        int256 other = p.capMinimum[from + width - 1][level];
        if (other < value) value = other;
    }

    function _settleKeeper(Policy storage p, address keeper) private {
        Bucket storage b = p.keeperBuckets[keeper];
        uint256 index = _currentKeeperIndex(p);
        uint256 ceiling = uint256(p.gov.addressCap) / 10 * 1 days;
        if (b.version == 0) {
            b.credit = ceiling;
        } else {
            uint256 credit = b.credit + index - b.refillIndex;
            if (b.version < p.version) {
                int256 constrained = int256(index) + _minClamp(p, b.version + 1, p.version);
                uint256 past = constrained > 0 ? uint256(constrained) : 0;
                if (credit > past) credit = past;
            }
            b.credit = credit > ceiling ? ceiling : credit;
        }
        b.version = p.version;
        b.refillIndex = index;
        b.updatedAt = uint64(block.timestamp);
    }

    function _prune(Rolling storage r, uint256 max) private returns (bool complete) {
        uint256 n = r.payments.length;
        uint256 i = r.cursor;
        uint256 stop = i + max;
        while (i < n && i < stop && uint256(r.payments[i].updatedAt) + 1 days <= block.timestamp) {
            r.spent -= r.payments[i].amount;
            ++i;
        }
        r.cursor = i;
        return i == n || uint256(r.payments[i].updatedAt) + 1 days > block.timestamp;
    }

    function _push(Rolling storage r, uint256 amount) private {
        r.payments.push(Payment(uint64(block.timestamp), uint192(amount)));
        r.spent += amount;
    }

    function pruneGovernance(AutonomousRevenueLib.State storage s, address keeper, uint256 max) external {
        if (max == 0 || max > 256) revert PolicyInvalid();
        _prune(s.policy.globalRolling, max);
        _prune(s.policy.keeperRolling[keeper], max);
        _prune(s.policy.conversionRolling, max);
    }

    function governanceState(AutonomousRevenueLib.State storage s, address keeper)
        external
        view
        returns (
            GovSettings memory settings,
            uint256 reserve,
            uint256 globalSpent,
            uint256 keeperSpent,
            uint256 globalDay,
            uint256 keeperDay,
            uint64 lastPaid,
            uint256 keysVersion
        )
    {
        Policy storage p = s.policy;
        uint64 day = uint64(block.timestamp / 1 days);
        return (
            p.gov,
            s.reserve[p.governance],
            p.globalRolling.spent,
            p.keeperRolling[keeper].spent,
            p.globalUtc[day],
            p.keeperUtc[day][keeper],
            p.lastPaid,
            p.version
        );
    }

    function governanceKeyConsumed(AutonomousRevenueLib.State storage s, bytes32 key) external view returns (bool) {
        return s.policy.consumed[key];
    }

    function payGovernanceBounty(AutonomousRevenueLib.State storage s, uint8 category, bytes32 key, address keeper)
        external
        returns (uint256 amount)
    {
        Policy storage p = s.policy;
        if (msg.sender != p.governance || p.governance == address(0)) revert Unauthorized();
        if (category > 1 || key == bytes32(0) || keeper == address(0) || p.consumed[key]) {
            return _skip(keeper, key, category, 1);
        }
        p.consumed[key] = true; // A missed payment creates no debt or later retry claim.
        amount = category == 0 ? p.gov.control : p.gov.action;
        if (amount == 0 || s.reserve[p.governance] < amount) return _skip(keeper, key, category, 2);
        if (p.lastPaid != 0 && block.timestamp < uint256(p.lastPaid) + 30 seconds) return _skip(
            keeper, key, category, 3
        );
        uint64 window = uint64(block.timestamp / 15 minutes);
        if (category == 0 && p.controlPaid && window <= p.lastControlWindow) return _skip(keeper, key, category, 4);
        if (!_prune(p.globalRolling, 256) || !_prune(p.keeperRolling[keeper], 256)) return _skip(
            keeper, key, category, 5
        );
        uint64 day = uint64(block.timestamp / 1 days);
        if (
            p.globalRolling.spent + amount > p.gov.globalCap
                || p.keeperRolling[keeper].spent + amount > p.gov.addressCap
                || p.globalUtc[day] + amount > p.gov.globalCap || p.keeperUtc[day][keeper] + amount > p.gov.addressCap
                || p.categoryUtc[day][category] + amount > uint256(p.gov.globalCap) / 2
        ) return _skip(keeper, key, category, 6);
        _settleGlobal(p);
        _settleKeeper(p, keeper);
        uint256 cost = amount * 1 days;
        if (p.globalBucket.credit < cost || p.keeperBuckets[keeper].credit < cost) return _skip(
            keeper, key, category, 7
        );
        // Only this fixed USDC transfer can fail; the governance action and consumed key survive.
        try ITreasuryPolicyContext(address(this)).performGovernanceBountyTransfer(keeper, amount) {}
        catch {
            return _skip(keeper, key, category, 8);
        }
        s.reserve[p.governance] -= amount;
        s.totalReserve -= amount;
        s.accounted[ITreasuryPolicyContext(address(this)).usdc()] -= amount;
        p.globalBucket.credit -= cost;
        p.keeperBuckets[keeper].credit -= cost;
        _push(p.globalRolling, amount);
        _push(p.keeperRolling[keeper], amount);
        p.globalUtc[day] += amount;
        p.keeperUtc[day][keeper] += amount;
        p.categoryUtc[day][category] += amount;
        p.lastPaid = uint64(block.timestamp);
        if (category == 0) {
            p.lastControlWindow = window;
            p.controlPaid = true;
        }
        emit GovernanceBountyPaid(keeper, key, category, amount);
    }

    function _skip(address keeper, bytes32 key, uint8 category, uint8 reason) private returns (uint256) {
        emit GovernanceBountySkipped(keeper, key, category, reason);
        return 0;
    }

    function installApprovedSource(AutonomousRevenueLib.State storage s, bytes32 id, address factory) external {
        Policy storage p = s.policy;
        ITreasuryFactory f = ITreasuryFactory(factory);
        if (p.governance == address(0) || f.catalogue() != p.catalogue || f.governance() != p.governance) {
            revert Unauthorized();
        }
        (address vault, address manager, address engine, address module, address hedge) = f.sourceActors(id);
        if (
            !ITreasuryCatalogue(p.catalogue).isPreparingTreasurySource(id, factory, vault) || s.sourceInstalled[vault]
                || ISourceInstallation(vault).installationSealed()
        ) revert Unauthorized();
        address[6] memory actors = [vault, manager, engine, module, hedge, f.sourceRebate(id)];
        s.sourceInstalled[vault] = true;
        for (uint256 i; i < 6; ++i) {
            address actor = actors[i];
            if (actor == address(0)) {
                if (i == 4) continue;
                revert PolicyInvalid();
            }
            if (actor.code.length == 0 || s.sourceOf[actor] != address(0)) revert PolicyInvalid();
            s.sourceOf[actor] = vault;
            s.roles[actor] = i == 0 ? 8 : i == 1 ? 1 : i == 2 ? 2 : i == 4 ? 4 : 0;
            emit SourceInstalled(vault, actor);
        }
        for (uint8 i; i < 2; ++i) {
            _installAsset(s, id, f, i);
        }
        s.sourceSealed[vault] = true;
        emit SourceSealed(vault);
    }

    function _installAsset(AutonomousRevenueLib.State storage s, bytes32 id, ITreasuryFactory f, uint8 index) private {
        (address token, address feed, uint32 age, bytes memory path) = f.sourceAsset(id, index);
        (uint256 input, uint256 minUsdc, uint64 cooldown, uint16 slippage) = f.sourceAssetLimits(id, index);
        address stable = ITreasuryPolicyContext(address(this)).usdc();
        Asset storage a = s.policy.assets[token];
        if (
            token.code.length == 0 || feed.code.length == 0 || IERC20Metadata(token).decimals() > 18
                || AggregatorV3Interface(feed).decimals() > 18 || age < 1 hours || age > 2 days
        ) revert PolicyInvalid();
        if (token != stable) {
            if (
                input == 0 || minUsdc < 10 ** uint256(ITreasuryPolicyContext(address(this)).usdcDecimals())
                    || cooldown < 1 hours || cooldown > 30 days || slippage < 10 || slippage > 100
                    || (path.length != 43 && path.length != 66)
            ) revert PolicyInvalid();
            address first;
            address last;
            assembly ("memory-safe") {
                first := shr(96, mload(add(path, 32)))
                last := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
            }
            if (first != token || last != stable) revert PolicyInvalid();
        } else if (path.length != 0 || input != 0 || minUsdc != 0 || cooldown != 0 || slippage != 0) {
            revert PolicyInvalid();
        }
        uint24 fee;
        if (path.length != 0) {
            assembly ("memory-safe") { fee := shr(232, mload(add(path, 52))) }
            if (fee == 0) revert PolicyInvalid();
        }
        if (a.installed) {
            if (
                a.feed != feed || a.maxAge != age || keccak256(_assetPath(a, token, stable)) != keccak256(path)
                    || (token != stable
                        && (a.maxInput != input
                            || a.minUsdc != minUsdc
                            || a.cooldown != cooldown
                            || a.slippageBps != slippage))
            ) revert PolicyInvalid();
        } else {
            a.feed = feed;
            a.maxAge = age;
            a.path = path;
            a.fee = fee;
            a.maxInput = input;
            a.minUsdc = minUsdc;
            a.cooldown = cooldown;
            a.slippageBps = slippage;
            a.installed = true;
            emit AssetSealed(token);
        }
    }

    function _assetPath(Asset storage a, address token, address stable) private view returns (bytes memory) {
        if (a.path.length != 0) return a.path;
        if (token == stable) return bytes("");
        return abi.encodePacked(token, a.fee, stable);
    }

    event KeeperBountyConfigured(bool enabled, uint256 amount);
    event KeeperBountyDailyCapConfigured(uint256 cap);
    event StrategyCheckpointBountyConfigured(bool enabled, uint256 amount);
    event StrategyCheckpointBountyDailyCapConfigured(uint256 cap);
    event HedgeBountyConfigured(bool enabled, uint256 amount);
    event HedgeBountyDailyCapConfigured(uint256 cap);

    function setLegacyBounty(AutonomousRevenueLib.State storage s, uint8 kind, bool enabled, uint256 amount) external {
        require(!IRevenueConversionPolicy(address(this)).configurationSealed(), AutonomousCheck(0x9a247fa1));
        uint256 cap = kind == 0
            ? s.legacy.keeperBountyDailyCap
            : kind == 1 ? s.legacy.strategyCheckpointBountyDailyCap : s.legacy.hedgeBountyDailyCap;
        if (enabled) require(
            amount > 0 && cap >= amount, AutonomousCheck(kind == 1 ? bytes4(0xac880810) : bytes4(0x341d3670))
        );
        if (kind == 0) {
            s.legacy.keeperBountyEnabled = enabled;
            s.legacy.keeperBountyAmount = amount;
            emit KeeperBountyConfigured(enabled, amount);
        } else if (kind == 1) {
            s.legacy.strategyCheckpointBountyEnabled = enabled;
            s.legacy.strategyCheckpointBountyAmount = amount;
            emit StrategyCheckpointBountyConfigured(enabled, amount);
        } else {
            require(kind == 3);
            s.legacy.hedgeBountyEnabled = enabled;
            s.legacy.hedgeBountyAmount = amount;
            emit HedgeBountyConfigured(enabled, amount);
        }
    }

    function validateSwapFeed(
        bool isSealed,
        address existingFeed,
        address token,
        address feed,
        uint16 _swapSlippageBps,
        uint32 _maxAge,
        uint8 usdcDecimals
    ) external view {
        require(!isSealed || existingFeed == feed, AutonomousCheck(0x61ac430d));
        require(token != address(0), AutonomousCheck(0x086efea7));
        require(feed != address(0), AutonomousCheck(0x422790c9));
        require(_swapSlippageBps >= 10 && _swapSlippageBps <= 1000, AutonomousCheck(0x3b5e082d));
        require(_maxAge >= 3600 && _maxAge <= 172800, AutonomousCheck(0xd357f7c0));
        require(
            IERC20Metadata(token).decimals() <= 18 && usdcDecimals <= 18
                && AggregatorV3Interface(feed).decimals() <= 18,
            AutonomousCheck(0x8a0ba966)
        );
    }

    function validatePoolFee(bool isSealed, address token, address stable, uint24 fee) external pure {
        require(!isSealed, AutonomousCheck(0xd3f8500a));
        require(token != address(0) && token != stable, AutonomousCheck(0x086efea7));
        require(fee == 100 || fee == 500 || fee == 3000 || fee == 10000, AutonomousCheck(0x6d94368d));
    }
}
