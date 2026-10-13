// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
import "./AutonomousErrors.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
struct RevenueSendParam { uint32 dstEid; bytes32 to; uint256 amountLD; uint256 minAmountLD; bytes extraOptions; bytes composeMsg; bytes oftCmd; }
struct RevenueMessagingFee { uint256 nativeFee; uint256 lzTokenFee; }
struct RevenueMessagingReceipt { bytes32 guid; uint64 nonce; RevenueMessagingFee fee; }
struct RevenueOFTReceipt { uint256 amountSentLD; uint256 amountReceivedLD; }
struct RevenueOFTLimit { uint256 minAmountLD; uint256 maxAmountLD; }
struct RevenueOFTFeeDetail { int256 feeAmountLD; string description; }
struct RevenueTicket { uint72 ticketId; bytes passengerBytes; }
interface IRevenueStargate {
    function quoteSend(RevenueSendParam calldata, bool) external view returns (RevenueMessagingFee memory);
    function quoteOFT(RevenueSendParam calldata) external view returns (RevenueOFTLimit memory, RevenueOFTFeeDetail[] memory, RevenueOFTReceipt memory);
    function sendToken(RevenueSendParam calldata, RevenueMessagingFee calldata, address) external payable returns (RevenueMessagingReceipt memory, RevenueOFTReceipt memory, RevenueTicket memory);
}
/// @notice Atomic, fixed-destination Stargate execution in the Treasury context. No custody or caller-selected route.
library RevenueBridgeLib {
    using SafeERC20 for IERC20;
    error BridgeTransferMismatch();
    function quote(address stargate, uint32 eid, address destination, uint256 amount) external view returns (uint256 nativeFee, uint256 received) {
        RevenueSendParam memory param = _param(eid, destination, amount);
        (,, RevenueOFTReceipt memory receipt) = IRevenueStargate(stargate).quoteOFT(param);
        param.minAmountLD = receipt.amountReceivedLD;
        nativeFee = IRevenueStargate(stargate).quoteSend(param, false).nativeFee;
        received = receipt.amountReceivedLD;
    }
    function send(address stargate, address token, uint32 eid, address destination, uint256 amount, uint16 minBps)
        external returns (uint256 received, bytes32 guid, uint256 nativeFee) {
        require(destination != address(0) && eid != 0 && amount > 0 && minBps >= 9000, AutonomousCheck(0x3542e7f4));
        RevenueSendParam memory param = _param(eid, destination, amount);
        (,, RevenueOFTReceipt memory quoted) = IRevenueStargate(stargate).quoteOFT(param);
        require(quoted.amountReceivedLD * 10000 >= amount * minBps, AutonomousCheck(0x88795128));
        param.minAmountLD = quoted.amountReceivedLD;
        RevenueMessagingFee memory fee = IRevenueStargate(stargate).quoteSend(param, false);
        require(msg.value >= fee.nativeFee && fee.lzTokenFee == 0, AutonomousCheck(0x2f450712));
        IERC20 usdc = IERC20(token); uint256 beforeBalance = usdc.balanceOf(address(this));
        usdc.safeApprove(stargate, 0); usdc.safeApprove(stargate, amount);
        (RevenueMessagingReceipt memory receipt, RevenueOFTReceipt memory oft,) =
            IRevenueStargate(stargate).sendToken{value: fee.nativeFee}(param, fee, msg.sender);
        usdc.safeApprove(stargate, 0);
        uint256 afterBalance = usdc.balanceOf(address(this));
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount || oft.amountSentLD != amount
            || oft.amountReceivedLD < param.minAmountLD) revert BridgeTransferMismatch();
        return (oft.amountReceivedLD, receipt.guid, fee.nativeFee);
    }
    function _param(uint32 eid, address destination, uint256 amount) private pure returns (RevenueSendParam memory) {
        return RevenueSendParam(eid, bytes32(uint256(uint160(destination))), amount, 0, new bytes(0), new bytes(0), "");
    }
}
