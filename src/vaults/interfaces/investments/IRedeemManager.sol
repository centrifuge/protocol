// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";

interface IRedeemManager is IBaseInvestmentManager {
    event TriggerRedeemRequest(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address user,
        address indexed asset,
        uint256 tokenId,
        uint128 shares
    );

    /// @notice Processes owner's share redemption after the epoch has been executed on the corresponding CP instance
    /// and the redeem order
    ///         has been successfully processed (partial fulfillment possible).
    ///         Assets are transferred from the escrow to the receiver. Amount of assets is computed based of the amount
    ///         of shares and the owner's share price.
    /// @dev    The shares required to fulfill the redemption were already locked in escrow on requestRedeem and burned
    ///         on fulfillRedeemRequest.
    ///         The assets required to fulfill the redemption have already been reserved in escrow on
    ///         fulfillRedeemtRequest.
    function redeem(IBaseVault vault, uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

    /// @notice Processes owner's asset withdrawal after the epoch has been executed on the corresponding CP instance
    /// and the redeem order
    ///         has been successfully processed (partial fulfillment possible).
    ///         Assets are transferred from the escrow to the receiver. Amount of shares is computed based of the amount
    ///         of shares and the owner's share price.
    /// @dev    The shares required to fulfill the withdrawal were already locked in escrow on requestRedeem and burned
    ///         on fulfillRedeemRequest.
    ///         The assets required to fulfill the withdrawal have already been reserved in escrow on
    ///         fulfillRedeemtRequest.
    function withdraw(IBaseVault vault, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Returns the max amount of shares based on the unclaimed number of assets after at least one successful
    ///         redeem order fulfillment on the corresponding CP instance.
    function maxRedeem(IBaseVault vault, address user) external view returns (uint256 shares);

    /// @notice Returns the max amount of assets a user can claim after at least one successful redeem order fulfillment
    ///         on the corresponding CP instance.
    function maxWithdraw(IBaseVault vault, address user) external view returns (uint256 assets);
}
