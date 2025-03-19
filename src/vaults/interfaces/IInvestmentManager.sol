// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRecoverable} from "src/common/interfaces/IRoot.sol";

import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";

/// @dev Vault requests and deposit/redeem bookkeeping per user
struct InvestmentState {
    /// @dev Shares that can be claimed using `mint()`
    uint128 maxMint;
    /// @dev Assets that can be claimed using `withdraw()`
    uint128 maxWithdraw;
    /// @dev Weighted average price of deposits, used to convert maxMint to maxDeposit
    uint256 depositPrice;
    /// @dev Weighted average price of redemptions, used to convert maxWithdraw to maxRedeem
    uint256 redeemPrice;
    /// @dev Remaining deposit request in assets
    uint128 pendingDepositRequest;
    /// @dev Remaining redeem request in shares
    uint128 pendingRedeemRequest;
    /// @dev Assets that can be claimed using `claimCancelDepositRequest()`
    uint128 claimableCancelDepositRequest;
    /// @dev Shares that can be claimed using `claimCancelRedeemRequest()`
    uint128 claimableCancelRedeemRequest;
    /// @dev Indicates whether the depositRequest was requested to be cancelled
    bool pendingCancelDepositRequest;
    /// @dev Indicates whether the redeemRequest was requested to be cancelled
    bool pendingCancelRedeemRequest;
}

interface IInvestmentManager is IRecoverable, IVaultManager {
    // --- Events ---
    event File(bytes32 indexed what, address data);
    event TriggerRedeemRequest(
        uint64 indexed poolId, bytes16 indexed trancheId, address user, address asset, uint128 shares
    );

    /// @notice Returns the investment state
    function investments(address vaultAddr, address investor)
        external
        view
        returns (
            uint128 maxMint,
            uint128 maxWithdraw,
            uint256 depositPrice,
            uint256 redeemPrice,
            uint128 pendingDepositRequest,
            uint128 pendingRedeemRequest,
            uint128 claimableCancelDepositRequest,
            uint128 claimableCancelRedeemRequest,
            bool pendingCancelDepositRequest,
            bool pendingCancelRedeemRequest
        );

    /// @notice Address of the escrow
    function escrow() external view returns (address);

    /// @notice Updates contract parameters of type address.
    /// @param what The bytes32 representation of 'gateway' or 'poolManager'.
    /// @param data The new contract address.
    function file(bytes32 what, address data) external;

    // --- Outgoing message handling ---
    /// @notice Requests assets deposit. Vaults have to request investments from Centrifuge before
    ///         shares can be minted. The deposit requests are added to the order book
    ///         on Centrifuge. Once the next epoch is executed on Centrifuge, vaults can
    ///         proceed with share payouts in case the order got fulfilled.
    /// @dev    The assets required to fulfill the deposit request have to be locked and are transferred from the
    ///         owner to the escrow, even though the share payout can only happen after epoch execution.
    ///         The receiver becomes the owner of deposit request fulfillment.
    function requestDeposit(address vaultAddr, uint256 assets, address receiver, address owner, address source)
        external
        returns (bool);

    /// @notice Requests share redemption. Vaults have to request redemptions
    ///         from Centrifuge before actual asset payouts can be done. The redemption
    ///         requests are added to the order book on Centrifuge. Once the next epoch is
    ///         executed on Centrifuge, vaults can proceed with asset payouts
    ///         in case the order got fulfilled.
    /// @dev    The shares required to fulfill the redemption request have to be locked and are transferred from the
    ///         owner to the escrow, even though the asset payout can only happen after epoch execution.
    ///         The receiver becomes the owner of redeem request fulfillment.
    function requestRedeem(address vaultAddr, uint256 shares, address receiver, address, /* owner */ address source)
        external
        returns (bool);

    /// @notice Requests the cancellation of a pending deposit request. Vaults have to request the
    ///         cancellation of outstanding requests from Centrifuge before actual assets can be unlocked and
    /// transferred
    ///         to the owner.
    ///         While users have outstanding cancellation requests no new deposit requests can be submitted.
    ///         Once the next epoch is executed on Centrifuge, vaults can proceed with asset payouts
    ///         if orders could be cancelled successfully.
    /// @dev    The cancellation request might fail in case the pending deposit order already got fulfilled on
    ///         Centrifuge.
    function cancelDepositRequest(address vaultAddr, address owner, address source) external;

    /// @notice Requests the cancellation of an pending redeem request. Vaults have to request the
    ///         cancellation of outstanding requests from Centrifuge before actual shares can be unlocked and
    ///         transferred to the owner.
    ///         While users have outstanding cancellation requests no new redeem requests can be submitted (exception:
    ///         trigger through governance).
    ///         Once the next epoch is executed on Centrifuge, vaults can proceed with share payouts
    ///         if the orders could be cancelled successfully.
    /// @dev    The cancellation request might fail in case the pending redeem order already got fulfilled on
    ///         Centrifuge.
    function cancelRedeemRequest(address vaultAddr, address owner, address source) external;

    // --- View functions ---
    /// @notice Converts the assets value to share decimals.
    function convertToShares(address vaultAddr, uint256 _assets) external view returns (uint256 shares);

    /// @notice Converts the shares value to assets decimals.
    function convertToAssets(address vaultAddr, uint256 _shares) external view returns (uint256 assets);

    /// @notice Returns the max amount of assets based on the unclaimed amount of shares after at least one successful
    ///         deposit order fulfillment on Centrifuge.
    function maxDeposit(address vaultAddr, address user) external view returns (uint256);

    /// @notice Returns the max amount of shares a user can claim after at least one successful deposit order
    ///         fulfillment on Centrifuge.
    function maxMint(address vaultAddr, address user) external view returns (uint256 shares);

    /// @notice Returns the max amount of assets a user can claim after at least one successful redeem order fulfillment
    ///         on Centrifuge.
    function maxWithdraw(address vaultAddr, address user) external view returns (uint256 assets);

    /// @notice Returns the max amount of shares based on the unclaimed number of assets after at least one successful
    ///         redeem order fulfillment on Centrifuge.
    function maxRedeem(address vaultAddr, address user) external view returns (uint256 shares);

    /// @notice Indicates whether a user has pending deposit requests and returns the total deposit request asset
    /// request value.
    function pendingDepositRequest(address vaultAddr, address user) external view returns (uint256 assets);

    /// @notice Indicates whether a user has pending redeem requests and returns the total share request value.
    function pendingRedeemRequest(address vaultAddr, address user) external view returns (uint256 shares);

    /// @notice Indicates whether a user has pending deposit request cancellations.
    function pendingCancelDepositRequest(address vaultAddr, address user) external view returns (bool isPending);

    /// @notice Indicates whether a user has pending redeem request cancellations.
    function pendingCancelRedeemRequest(address vaultAddr, address user) external view returns (bool isPending);

    /// @notice Indicates whether a user has claimable deposit request cancellation and returns the total claim
    ///         value in assets.
    function claimableCancelDepositRequest(address vaultAddr, address user) external view returns (uint256 assets);

    /// @notice Indicates whether a user has claimable redeem request cancellation and returns the total claim
    ///         value in shares.
    function claimableCancelRedeemRequest(address vaultAddr, address user) external view returns (uint256 shares);

    /// @notice Returns the timestamp of the last share price update for a vaultAddr.
    function priceLastUpdated(address vaultAddr) external view returns (uint64 lastUpdated);

    // --- Vault claim functions ---
    /// @notice Processes owner's asset deposit after the epoch has been executed on Centrifuge and the deposit order
    ///         has been successfully processed (partial fulfillment possible).
    ///         Shares are transferred from the escrow to the receiver. Amount of shares is computed based of the amount
    ///         of assets and the owner's share price.
    /// @dev    The assets required to fulfill the deposit are already locked in escrow upon calling requestDeposit.
    ///         The shares required to fulfill the deposit have already been minted and transferred to the escrow on
    ///         fulfillDepositRequest.
    ///         Receiver has to pass all the share token restrictions in order to receive the shares.
    function deposit(address vaultAddr, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Processes owner's share mint after the epoch has been executed on Centrifuge and the deposit order has
    ///         been successfully processed (partial fulfillment possible).
    ///         Shares are transferred from the escrow to the receiver. Amount of assets is computed based of the amount
    ///         of shares and the owner's share price.
    /// @dev    The assets required to fulfill the mint are already locked in escrow upon calling requestDeposit.
    ///         The shares required to fulfill the mint have already been minted and transferred to the escrow on
    ///         fulfillDepositRequest.
    ///         Receiver has to pass all the share token restrictions in order to receive the shares.
    function mint(address vaultAddr, uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

    /// @notice Processes owner's share redemption after the epoch has been executed on Centrifuge and the redeem order
    ///         has been successfully processed (partial fulfillment possible).
    ///         Assets are transferred from the escrow to the receiver. Amount of assets is computed based of the amount
    ///         of shares and the owner's share price.
    /// @dev    The shares required to fulfill the redemption were already locked in escrow on requestRedeem and burned
    ///         on fulfillRedeemRequest.
    ///         The assets required to fulfill the redemption have already been reserved in escrow on
    ///         fulfillRedeemtRequest.
    function redeem(address vaultAddr, uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

    /// @notice Processes owner's asset withdrawal after the epoch has been executed on Centrifuge and the redeem order
    ///         has been successfully processed (partial fulfillment possible).
    ///         Assets are transferred from the escrow to the receiver. Amount of shares is computed based of the amount
    ///         of shares and the owner's share price.
    /// @dev    The shares required to fulfill the withdrawal were already locked in escrow on requestRedeem and burned
    ///         on fulfillRedeemRequest.
    ///         The assets required to fulfill the withdrawal have already been reserved in escrow on
    ///         fulfillRedeemtRequest.
    function withdraw(address vaultAddr, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Processes owner's deposit request cancellation after the epoch has been executed on Centrifuge and the
    ///         deposit order cancellation has been successfully processed (partial fulfillment possible).
    ///         Assets are transferred from the escrow to the receiver.
    /// @dev    The assets required to fulfill the claim have already been reserved for the owner in escrow on
    ///         fulfillCancelDepositRequest.
    function claimCancelDepositRequest(address vaultAddr, address receiver, address owner)
        external
        returns (uint256 assets);

    /// @notice Processes owner's redeem request cancellation after the epoch has been executed on Centrifuge and the
    ///         redeem order cancellation has been successfully processed (partial fulfillment possible).
    ///         Shares are transferred from the escrow to the receiver.
    /// @dev    The shares required to fulfill the claim have already been reserved for the owner in escrow on
    ///         fulfillCancelRedeemRequest.
    ///         Receiver has to pass all the share token restrictions in order to receive the shares.
    function claimCancelRedeemRequest(address vaultAddr, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Returns the address of the vault for a given pool, tranche and asset
    function vaultByAddress(uint64 poolId, bytes16 trancheId, address asset)
        external
        view
        returns (address vaultAddr);
}
