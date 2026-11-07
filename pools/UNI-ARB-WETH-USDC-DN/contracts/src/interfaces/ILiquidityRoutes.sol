// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @notice Installation-only external identities, read from each pool's reviewed .env.
struct LiquidityRoutes {
    address curve;
    address fluid;
    address augustus;
    address executor;
    uint24 alternativeFee;
    uint64 minVeloraTvlUsd;
    address fluidToken0;
    uint32 maxExternalSwapUsd;
    uint16 maxExternalTvlBps;
    uint24 hedgeAlternativeFee;
    address executor2;
    address executor3;
    address executor4;
    address hedgeBridgeToken;
    uint24 hedgeBridgeFee0;
    uint24 hedgeBridgeFee1;
}
interface ILiquidityRange {
    function liquidityRoutes() external view returns (LiquidityRoutes memory);
    function executeDirectLiquiditySwap(bool zeroForOne, uint256 amount, uint256 minimum, uint8 route, bytes calldata data)
        external returns (uint256);
    function executeRoutedSwap(bool zeroForOne, uint256 amount, uint256 minimum, uint8 route, bytes calldata data)
        external returns (uint256);
}
interface ILiquidityAugustus {
    struct GenericData {
        address srcToken;
        address destToken;
        uint256 fromAmount;
        uint256 toAmount;
        uint256 quotedAmount;
        bytes32 metadata;
        address payable beneficiary;
    }
    function swapExactAmountIn(address executor, GenericData calldata swapData, uint256 partnerAndFee,
        bytes calldata permit, bytes calldata executorData) external payable returns (uint256, uint256, uint256);
}
