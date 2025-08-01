// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IBaseVault} from "./IBaseVault.sol";
import {IBaseRequestManager} from "./IBaseRequestManager.sol";

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

import {IUpdateContract} from "../../spoke/interfaces/IUpdateContract.sol";

interface IDepositManager {
    /// @notice Processes owner's asset deposit after the epoch has been executed on the corresponding CP instance and
    /// the deposit order
    ///         has been successfully processed (partial fulfillment possible).
    ///         Shares are transferred from the escrow to the receiver. Amount of shares is computed based of the amount
    ///         of assets and the owner's share price.
    /// @dev    The assets required to fulfill the deposit are already locked in escrow upon calling requestDeposit.
    ///         The shares required to fulfill the deposit have already been minted and transferred to the escrow on
    ///         fulfillDepositRequest.
    ///         Receiver has to pass all the share token restrictions in order to receive the shares.
    function deposit(IBaseVault vault, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Processes owner's share mint after the epoch has been executed on the corresponding CP instance and the
    /// deposit order has
    ///         been successfully processed (partial fulfillment possible).
    ///         Shares are transferred from the escrow to the receiver. Amount of assets is computed based of the amount
    ///         of shares and the owner's share price.
    /// @dev    The assets required to fulfill the mint are already locked in escrow upon calling requestDeposit.
    ///         The shares required to fulfill the mint have already been minted and transferred to the escrow on
    ///         fulfillDepositRequest.
    ///         Receiver has to pass all the share token restrictions in order to receive the shares.
    function mint(IBaseVault vault, uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

    /// @notice Returns the max amount of assets based on the unclaimed amount of shares after at least one successful
    ///         deposit order fulfillment on the corresponding CP instance.
    function maxDeposit(IBaseVault vault, address user) external view returns (uint256);

    /// @notice Returns the max amount of shares a user can claim after at least one successful deposit order
    ///         fulfillment on the corresponding CP instance.
    function maxMint(IBaseVault vault, address user) external view returns (uint256 shares);
}

interface ISyncDepositManager is IDepositManager {
    function previewDeposit(IBaseVault vault, address sender, uint256 assets) external view returns (uint256);
    function previewMint(IBaseVault vault, address sender, uint256 shares) external view returns (uint256);
}

interface IAsyncDepositManager is IDepositManager, IBaseRequestManager {
    /// @notice Requests assets deposit. Vaults have to request investments from Centrifuge before
    ///         shares can be minted. The deposit requests are added to the order book
    ///         on the corresponding CP instance. Once the next epoch is executed on the corresponding CP instance,
    ///         vaults can proceed with share payouts in case the order got fulfilled.
    /// @dev    The assets required to fulfill the deposit request have to be locked and are transferred from the
    ///         owner to the escrow, even though the share payout can only happen after epoch execution.
    ///         The receiver becomes the owner of deposit request fulfillment.
    /// @param  source Deprecated
    function requestDeposit(IBaseVault vault, uint256 assets, address receiver, address owner, address source)
        external
        returns (bool);

    /// @notice Requests the cancellation of a pending deposit request. Vaults have to request the
    ///         cancellation of outstanding requests from Centrifuge before actual assets can be unlocked and
    ///         transferred to the owner.
    ///         While users have outstanding cancellation requests no new deposit requests can be submitted.
    ///         Once the next epoch is executed on the corresponding CP instance, vaults can proceed with asset payouts
    ///         if orders could be cancelled successfully.
    /// @dev    The cancellation request might fail in case the pending deposit order already got fulfilled on
    ///         Centrifuge.
    /// @param  source Deprecated
    function cancelDepositRequest(IBaseVault vault, address owner, address source) external;

    /// @notice Processes owner's deposit request cancellation after the epoch has been executed on the corresponding CP
    ///         instance and the deposit order cancellation has been successfully processed (partial fulfillment
    ///         possible).
    ///         Assets are transferred from the escrow to the receiver.
    /// @dev    The assets required to fulfill the claim have already been reserved for the owner in escrow on
    ///         fulfillDepositRequest with non-zero cancelled asset amount value.
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

interface IRedeemManager {
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

interface IAsyncRedeemManager is IRedeemManager, IBaseRequestManager {
    /// @notice Requests share redemption. Vaults have to request redemptions
    ///         from Centrifuge before actual asset payouts can be done. The redemption
    ///         requests are added to the order book on the corresponding CP instance. Once the next epoch is
    ///         executed on the corresponding CP instance, vaults can proceed with asset payouts
    ///         in case the order got fulfilled.
    /// @dev    The shares required to fulfill the redemption request have to be locked and are transferred from the
    ///         owner to the escrow, even though the asset payout can only happen after epoch execution.
    ///         The receiver becomes the owner of redeem request fulfillment.
    /// @param  source Deprecated
    /// @param  transfer Set `false` for legacy vaults which already execute the transfer in the vault implementation
    function requestRedeem(
        IBaseVault vault,
        uint256 shares,
        address receiver,
        address owner,
        address source,
        bool transfer
    ) external returns (bool);

    /// @notice Requests the cancellation of an pending redeem request. Vaults have to request the
    ///         cancellation of outstanding requests from Centrifuge before actual shares can be unlocked and
    ///         transferred to the owner.
    ///         While users have outstanding cancellation requests no new redeem requests can be submitted (exception:
    ///         trigger through governance).
    ///         Once the next epoch is executed on the corresponding CP instance, vaults can proceed with share payouts
    ///         if the orders could be cancelled successfully.
    /// @dev    The cancellation request might fail in case the pending redeem order already got fulfilled on
    ///         Centrifuge.
    function cancelRedeemRequest(IBaseVault vault, address owner, address source) external;

    /// @notice Processes owner's redeem request cancellation after the epoch has been executed on the corresponding CP
    ///         instance and the redeem order cancellation has been successfully processed (partial fulfillment
    ///         possible).
    ///         Shares are transferred from the escrow to the receiver.
    /// @dev    The shares required to fulfill the claim have already been reserved for the owner in escrow on
    ///         fulfillRedeemRequest with non-zero cancelled share amount value.
    ///         Receiver has to pass all the share token restrictions in order to receive the shares.
    function claimCancelRedeemRequest(IBaseVault vault, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Indicates whether a user has pending redeem requests and returns the total share request value.
    function pendingRedeemRequest(IBaseVault vault, address user) external view returns (uint256 shares);

    /// @notice Indicates whether a user has pending redeem request cancellations.
    function pendingCancelRedeemRequest(IBaseVault vault, address user) external view returns (bool isPending);

    /// @notice Indicates whether a user has claimable redeem request cancellation and returns the total claim
    ///         value in shares.
    function claimableCancelRedeemRequest(IBaseVault vault, address user) external view returns (uint256 shares);
}

/// @dev Solely used locally as protection against stack-too-deep
struct Prices {
    /// @dev Price of 1 asset unit per share unit
    D18 assetPerShare;
    /// @dev Price of 1 pool unit per asset unit
    D18 poolPerAsset;
    /// @dev Price of 1 pool unit per share unit
    D18 poolPerShare;
}

interface ISyncDepositValuation {
    /// @notice Returns the pool price per share for a given pool and share class, asset, and asset id.
    // The provided price is defined as POOL_UNIT/SHARE_UNIT.
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @return price The pool price per share
    function pricePoolPerShare(PoolId poolId, ShareClassId scId) external view returns (D18 price);
}

interface ISyncManager is ISyncDepositManager, ISyncDepositValuation, IUpdateContract {
    event SetValuation(PoolId indexed poolId, ShareClassId indexed scId, address valuation);
    event SetMaxReserve(
        PoolId indexed poolId, ShareClassId indexed scId, address asset, uint256 tokenId, uint128 maxReserve
    );
    event File(bytes32 indexed what, address data);

    error ExceedsMaxDeposit();
    error FileUnrecognizedParam();
    error ExceedsMaxMint();
    error ShareTokenDoesNotExist();
    error SecondaryManagerDoesNotExist();

    /// @notice Updates contract parameters of type address.
    /// @param what The bytes32 representation of 'gateway' or 'spoke'.
    /// @param data The new contract address.
    function file(bytes32 what, address data) external;

    /// @notice Converts the assets value to share decimals.
    function convertToShares(IBaseVault vault, uint256 _assets) external view returns (uint256 shares);

    /// @notice Converts the shares value to assets decimals.
    function convertToAssets(IBaseVault vault, uint256 _shares) external view returns (uint256 assets);

    /// @notice Sets the valuation for a specific pool and share class.
    ///
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param valuation The address of the valuation contract
    function setValuation(PoolId poolId, ShareClassId scId, address valuation) external;

    /// @notice Sets the max reserve for a specific pool, share class and asset.
    ///
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param asset The address of the asset
    /// @param tokenId The asset token id, i.e. 0 for ERC20, or the token id for ERC6909
    /// @param maxReserve The amount of maximum reserve
    function setMaxReserve(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 maxReserve)
        external;
}

/// @dev Vault requests and deposit/redeem bookkeeping per user
struct AsyncInvestmentState {
    /// @dev Shares that can be claimed using `mint()`
    uint128 maxMint;
    /// @dev Assets that can be claimed using `withdraw()`
    uint128 maxWithdraw;
    /// @dev Weighted average price of deposits, used to convert maxMint to maxDeposit
    /// @dev Represents priceAssetPerShare, i.e. ASSET_UNIT/SHARE_UNIT
    D18 depositPrice;
    /// @dev Weighted average price of redemptions, used to convert maxWithdraw to maxRedeem
    /// @dev Represents priceAssetPerShare, i.e. ASSET_UNIT/SHARE_UNIT
    D18 redeemPrice;
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

interface IAsyncRequestManager is IAsyncDepositManager, IAsyncRedeemManager {
    error ExceedsMaxDeposit();
    error AssetMismatch();
    error ZeroAmountNotAllowed();
    error TransferNotAllowed();
    error CancellationIsPending();
    error NoPendingRequest();
    error ShareTokenAmountIsZero();
    error FailedRedeemRequest();
    error ExceedsDepositLimits();
    error ShareTokenTransferFailed();
    error ExceedsMaxRedeem();
    error ExceedsRedeemLimits();
    error VaultNotLinked();

    /// @notice Returns the investment state
    function investments(IBaseVault vaultAddr, address investor)
        external
        view
        returns (
            uint128 maxMint,
            uint128 maxWithdraw,
            D18 depositPrice,
            D18 redeemPrice,
            uint128 pendingDepositRequest,
            uint128 pendingRedeemRequest,
            uint128 claimableCancelDepositRequest,
            uint128 claimableCancelRedeemRequest,
            bool pendingCancelDepositRequest,
            bool pendingCancelRedeemRequest
        );

    /// @notice Signal from the Hub that an asynchronous investment order has been approved
    ///
    /// @dev This message needs to trigger making the asset amounts available to the pool-share-class.
    function approvedDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        D18 pricePoolPerAsset
    ) external;

    /// @notice Signal from the Hub that an asynchronous investment order has been finalized. Shares have been issued.
    ///
    /// @dev This message needs to trigger minting the new amount of shares.
    function issuedShares(PoolId poolId, ShareClassId scId, uint128 shareAmount, D18 pricePoolPerShare) external;

    /// @notice Signal from the Hub that an asynchronous redeem order has been finalized.
    ///
    /// @dev This messages needs to trigger reserving the asset amount for claims of redemptions by users.
    function revokedShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        uint128 shareAmount,
        D18 pricePoolPerShare
    ) external;

    // --- Deposits ---
    /// @notice Fulfills pending deposit requests after successful epoch execution on Hub.
    ///         The amount of shares that can be claimed by the user is minted and moved to the escrow contract.
    ///         The maxMint and claimableCancelDepositRequest bookkeeping values are updated.
    ///         The request fulfillment can be partial.
    /// @dev    The shares in the escrow are reserved for the user and are transferred to the user on deposit
    ///         and mint calls.
    /// @dev    The cancelled and fulfilled amounts are both non-zero iff the cancellation was queued.
    ///         Otherwise, either of the two must always be zero.
    function fulfillDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        address user,
        AssetId assetId,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledAssetAmount
    ) external;

    // --- Redeems ---
    /// @notice Fulfills pending redeem requests after successful epoch execution on Hub.
    ///         The amount of redeemed shares is burned. The amount of assets that can be claimed by the user in
    ///         return is locked in the escrow contract.
    ///         The maxWithdraw and claimableCancelRedeemRequest bookkeeping values are updated.
    ///         The request fulfillment can be partial.
    /// @dev    The assets in the escrow are reserved for the user and are transferred to the user on redeem
    ///         and withdraw calls.
    /// @dev    The cancelled and fulfilled amounts are both non-zero iff the cancellation was queued.
    ///         Otherwise, either of the two must always be zero.
    function fulfillRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        address user,
        AssetId assetId,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledShareAmount
    ) external;
}
