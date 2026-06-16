// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IAaveV3Pool - Minimal interface for AAVE V3 Pool on Arbitrum
/// @dev Only the functions needed by AaveHedgeManager
interface IAaveV3Pool {
    /// @notice Supplies an amount of underlying asset into the protocol
    /// @param asset The address of the underlying asset to supply
    /// @param amount The amount to supply
    /// @param onBehalfOf The address that will receive the aTokens
    /// @param referralCode Referral code (0 for none)
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Borrows an amount of asset with variable rate
    /// @param asset The address of the underlying asset to borrow
    /// @param amount The amount to borrow
    /// @param interestRateMode 2 = variable rate
    /// @param referralCode Referral code (0 for none)
    /// @param onBehalfOf The address that will receive the debt tokens
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;

    /// @notice Repays a borrowed amount
    /// @param asset The address of the borrowed asset
    /// @param amount The amount to repay (use type(uint256).max for full repay)
    /// @param interestRateMode 2 = variable rate
    /// @param onBehalfOf The address of the user who will get his debt reduced
    /// @return The final amount repaid
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);

    /// @notice Withdraws an amount of underlying asset from the protocol
    /// @param asset The address of the underlying asset
    /// @param amount The amount to withdraw (use type(uint256).max for full withdraw)
    /// @param to The address that will receive the underlying asset
    /// @return The final amount withdrawn
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Returns the user account data across all the reserves
    /// @param user The address of the user
    /// @return totalCollateralBase The total collateral in base currency (USD, 8 decimals)
    /// @return totalDebtBase The total debt in base currency (USD, 8 decimals)
    /// @return availableBorrowsBase The borrowing power left in base currency
    /// @return currentLiquidationThreshold The liquidation threshold of the user
    /// @return ltv The loan to value of the user
    /// @return healthFactor The current health factor (1e18 scale, < 1e18 = liquidatable)
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );

    /// @notice Allows smart contracts to access the liquidity of the pool within one transaction,
    ///         as long as the amount taken plus a fee is returned.
    /// @param receiverAddress The address of the contract receiving the funds, implementing IFlashLoanSimpleReceiver
    /// @param asset The address of the underlying asset to flash loan
    /// @param amount The amount to flash loan
    /// @param params Arbitrary bytes-encoded params to pass to the receiver
    /// @param referralCode Referral code (0 for none)
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;

    /// @notice Returns the fee on flash loans (in bps, e.g. 5 = 0.05%)
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}
