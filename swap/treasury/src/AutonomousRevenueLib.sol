// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import "./AutonomousErrors.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Treasury-local accounting. Linked delegatecalls never custody funds elsewhere.
/// @dev Each source owns its bounty budget; installing a new source grants no budget from existing pools.
library AutonomousRevenueLib {
    using SafeERC20 for IERC20;
    uint256 internal constant RESERVE_BPS = 500;
    struct ConversionWindow { uint64 started; uint256 spent; }
    struct State {
        mapping(address => mapping(address => ConversionWindow)) conversions;
        mapping(address => address) sourceOf;
        mapping(address => bool) sourceInstalled;
        mapping(address => bool) sourceSealed;
        mapping(address => uint8) roles;
        mapping(address=>uint64) depositDay;
        mapping(address=>uint256) depositSpent;
        mapping(address=>uint64) depositAt;
        mapping(address=>mapping(address=>uint64)) depositKeeperAt;
        mapping(address => mapping(address => uint256)) pending;
        mapping(address => uint256) accounted;
        mapping(address => uint256) reserve;
        mapping(address => uint256) revenue;
        mapping(address => uint256) remainder;
        mapping(address => uint256) bridgeRemainder;
        uint256 totalReserve;
    }
    event SourceInstalled(address indexed source, address indexed actor);
    event RevenueRecorded(address indexed source, address indexed token, uint256 amount);
    event BountyReserveCredited(address indexed source, uint256 revenue, uint256 reserved);
    event BountyReserveSpent(address indexed source, uint256 amount);
    event BountyFunded(address indexed source, uint256 amount);

    function install(State storage s, address source, address[] calldata actors) external {
        require(source != address(0) && source != address(this) && !s.sourceInstalled[source]
            && actors.length > 0, AutonomousCheck(0x16001604));
        s.sourceInstalled[source] = true;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            require(actor.code.length > 0 && s.sourceOf[actor] == address(0), AutonomousCheck(0x280035fb));
            s.sourceOf[actor] = source;
            emit SourceInstalled(source, actor);
        }
    }
    function authorize(State storage s,address actor,bool allowed,uint8 role) external {
        require(!s.sourceSealed[s.sourceOf[actor]],AutonomousCheck(0x9a247fa1));
        require(allowed && s.sourceOf[actor]!=address(0),AutonomousCheck(0x7ea92fcb));
        require(actor.code.length>0,AutonomousCheck(0x2c7a47d0));
        s.roles[actor]|=role;
    }
    event SourceSealed(address indexed source);
    function sealSource(State storage s,address source) external {
        require(s.sourceInstalled[source] && !s.sourceSealed[source],AutonomousCheck(0x16001604));
        s.sourceSealed[source]=true;emit SourceSealed(source);
    }
    function record(State storage s, address usdc, address token, uint256 amount) external {
        address source = s.sourceOf[msg.sender];
        require(source != address(0) && amount > 0, AutonomousCheck(0xdd62405b));
        _sync(s, usdc, token);
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        require(IERC20(token).balanceOf(address(this)) - beforeBalance == amount, AutonomousCheck(0xcfa42862));
        s.accounted[token] += amount;
        if (token == usdc) _credit(s, source, amount); else s.pending[source][token] += amount;
        emit RevenueRecorded(source, token, amount);
    }
    /// @dev Direct donations and Stargate receipts are attributed to the Treasury's own bridge budget.
    function sync(State storage s, address usdc, address token) external returns (uint256 amount) { return _sync(s, usdc, token); }
    function _sync(State storage s, address usdc, address token) private returns (uint256 amount) {
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
    function conversionRemaining(State storage s, address source, address token, uint256 cap, uint64 cooldown)
        external view returns (uint256 remaining, uint64 nextAt) {
        ConversionWindow storage w = s.conversions[source][token];
        nextAt = w.started + cooldown;
        remaining = block.timestamp >= nextAt ? cap : cap > w.spent ? cap - w.spent : 0;
    }
    function consumeConversion(State storage s, address source, address token, uint256 amount, uint256 cap, uint64 cooldown) external {
        ConversionWindow storage w = s.conversions[source][token];
        if (block.timestamp >= w.started + cooldown) { w.started = uint64(block.timestamp); w.spent = 0; }
        require(amount > 0 && amount <= cap - w.spent, AutonomousCheck(0xc62ba7de));
        w.spent += amount;
    }
    function converted(State storage s, address usdc, address source, address token,
        uint256 amountIn, uint256 amountOut) external {
        require(amountIn <= s.pending[source][token], AutonomousCheck(0x3f381c16));
        s.pending[source][token] -= amountIn;
        s.accounted[token] -= amountIn;
        s.accounted[usdc] += amountOut;
        _credit(s, source, amountOut);
    }
    function fund(State storage s, address usdc, address source, uint256 amount) external {
        require((source == address(this) || s.sourceInstalled[source]) && amount > 0, AutonomousCheck(0xcb003268)); _sync(s, usdc, usdc);
        uint256 beforeBalance = IERC20(usdc).balanceOf(address(this));
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
        require(IERC20(usdc).balanceOf(address(this)) - beforeBalance == amount, AutonomousCheck(0xbd973d7e));
        s.accounted[usdc] += amount; s.reserve[source] += amount; s.totalReserve += amount;
        emit BountyFunded(source, amount);
    }
    function withdraw(State storage s, address usdc, address to, uint256 amount) external {
        require(to != address(0) && amount > 0, AutonomousCheck(0x92d7cfce)); _sync(s, usdc, usdc);
        require(s.accounted[usdc] >= s.totalReserve && amount <= s.accounted[usdc] - s.totalReserve, AutonomousCheck(0xbac20538));
        s.accounted[usdc] -= amount; IERC20(usdc).safeTransfer(to, amount);
    }
    function spend(State storage s,address actor,uint256 amount) external {_spend(s,actor,amount);}
    function _spend(State storage s, address actor, uint256 amount) private {
        address source = actor == address(this) ? address(this) : s.sourceOf[actor];
        require(source != address(0) && amount > 0 && s.reserve[source] >= amount, AutonomousCheck(0x933c73ff));
        s.reserve[source] -= amount;
        s.totalReserve -= amount;
        emit BountyReserveSpent(source, amount);
    }
    struct DepositPolicy {bool enabled;uint256 amount;uint256 cap;uint64 cooldown;uint64 keeperCooldown;uint8 decimals;}
    event DepositBountyPaid(address indexed keeper,uint256 amount);
    function payDeposit(State storage s,address usdc,address keeper,address depositor,uint256 valueUsd,DepositPolicy calldata policy) external {
        require(keeper!=address(0)&&depositor!=address(0)&&keeper!=depositor,AutonomousCheck(0x77390cd7));
        require((s.roles[msg.sender]&8)!=0,AutonomousCheck(0x52c79c7b));
        require(policy.enabled,AutonomousCheck(0xb897c761));
        require(policy.amount>0,AutonomousCheck(0x2567641d));
        require(valueUsd>=(policy.amount*1e8/(10**policy.decimals))*100,AutonomousCheck(0x40b07ae4));
        require(IERC20(usdc).balanceOf(address(this))>=policy.amount,AutonomousCheck(0x18ecfaa5));
        if(policy.cooldown>0)require(block.timestamp>=uint256(s.depositAt[msg.sender])+policy.cooldown,AutonomousCheck(0x7e8fca4d));
        if(policy.keeperCooldown>0)require(block.timestamp>=uint256(s.depositKeeperAt[msg.sender][keeper])+policy.keeperCooldown,AutonomousCheck(0x127f6dec));
        uint64 day=uint64(block.timestamp/1 days);
        if(s.depositDay[msg.sender]!=day){s.depositDay[msg.sender]=day;s.depositSpent[msg.sender]=0;}
        uint256 spent=s.depositSpent[msg.sender]+policy.amount;
        if(policy.cap>0)require(spent<=policy.cap,AutonomousCheck(0xbf7d034b));
        s.depositAt[msg.sender]=uint64(block.timestamp);s.depositKeeperAt[msg.sender][keeper]=uint64(block.timestamp);s.depositSpent[msg.sender]=spent;
        _sync(s,usdc,usdc);_spend(s,msg.sender,policy.amount);
        require(policy.amount<=s.accounted[usdc],AutonomousCheck(0x34be11f1));s.accounted[usdc]-=policy.amount;
        IERC20(usdc).safeTransfer(keeper,policy.amount);emit DepositBountyPaid(keeper,policy.amount);
    }
    function debit(State storage s, address usdc, uint256 amount) external {
        require(amount <= s.accounted[usdc], AutonomousCheck(0x34be11f1));
        s.accounted[usdc] -= amount;
    }
    function protectedBalance(State storage s, address usdc) external view returns (uint256) {
        uint256 balance = IERC20(usdc).balanceOf(address(this));
        require(balance >= s.accounted[usdc], AutonomousCheck(0x05435e06));
        return s.totalReserve + ((balance - s.accounted[usdc]) * RESERVE_BPS + s.remainder[address(this)]) / 10000;
    }
    function _credit(State storage s, address source, uint256 amount) private {
        // Carry survives every inflow and every bounty payment; splitting receipts cannot evade the 5% allocation.
        uint256 numerator = amount * RESERVE_BPS + s.remainder[source];
        uint256 reserved = numerator / 10000;
        s.remainder[source] = numerator % 10000;
        if (source == address(this)) s.reserve[source] += reserved;
        else {
            // One fifth of the protected budget pays canonical Treasury bridge work; four fifths remain source-isolated.
            uint256 split = reserved + s.bridgeRemainder[source];
            uint256 bridgePart = split / 5;
            s.bridgeRemainder[source] = split % 5;
            s.reserve[address(this)] += bridgePart;
            s.reserve[source] += reserved - bridgePart;
        }
        s.totalReserve += reserved;
        s.revenue[source] += amount;
        emit BountyReserveCredited(source, amount, reserved);
    }
}
