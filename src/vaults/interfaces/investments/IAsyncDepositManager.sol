// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";

interface IAsyncDepositManager is IDepositManager, IVaultManager {
    /// @notice Requests assets deposit. Vaults have to request investments from Centrifuge before
    ///         shares can be minted. The deposit requests are added to the order book
    ///         on the corresponding CP instance. Once the next epoch is executed on the corresponding CP instance,
    /// vaults can
    ///         proceed with share payouts in case the order got fulfilled.
    /// @dev    The assets required to fulfill the deposit request have to be locked and are transferred from the
    ///         owner to the escrow, even though the share payout can only happen after epoch execution.
    ///         The receiver becomes the owner of deposit request fulfillment.
    /// @param  source Deprecated
    function requestDeposit(IBaseVault vault, uint256 assets, address receiver, address owner, address source)
        external
        returns (bool);

    /// @notice Requests the cancellation of a pending deposit request. Vaults have to request the
    ///         cancellation of outstanding requests from Centrifuge before actual assets can be unlocked and
    /// transferred
    ///         to the owner.
    ///         While users have outstanding cancellation requests no new deposit requests can be submitted.
    ///         Once the next epoch is executed on the corresponding CP instance, vaults can proceed with asset payouts
    ///         if orders could be cancelled successfully.
    /// @dev    The cancellation request might fail in case the pending deposit order already got fulfilled on
    ///         Centrifuge.
    /// @param  source Deprecated
    function cancelDepositRequest(IBaseVault vault, address owner, address source) external;

    /// @notice Processes owner's deposit request cancellation after the epoch has been executed on the corresponding CP
    /// instance and the
    ///         deposit order cancellation has been successfully processed (partial fulfillment possible).
    ///         Assets are transferred from the escrow to the receiver.
    /// @dev    The assets required to fulfill the claim have already been reserved for the owner in escrow on
    ///         fulfillCancelDepositRequest.
    function claimCancelDepositRequest(IBaseVault vault, address receiver, address owner)
        external
        returns (uint256 assets);

    /// @notice Indicates whether a user has pending deposit requests and returns the total deposit request asset
    /// request value.
    function pendingDepositRequest(IBaseVault vault, address user) external view returns (uint256 assets);

    /// @notice Indicates whether a user has pending deposit request cancellations.
    function pendingCancelDepositRequest(IBaseVault vault, address user) external view returns (bool isPending);

    /// @notice Indicates whether a user has claimable deposit request cancellation and returns the total claim
    ///         value in assets.
    function claimableCancelDepositRequest(IBaseVault vault, address user) external view returns (uint256 assets);
}
