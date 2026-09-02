// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IHubRegistry} from "../../core/hub/interfaces/IHubRegistry.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";
import {IHubRequestManagerCallback} from "../../core/hub/interfaces/IHubRequestManagerCallback.sol";
import {IHubRequestManager, IHubRequestManagerNotifications} from "../../core/hub/interfaces/IHubRequestManager.sol";

/// @notice Struct containing the epoch data for issuing share class tokens
/// @param approvedPoolAmount The amount of pool currency which was approved by the Fund Manager
/// @param approvedAssetAmount The amount of assets which was approved by the Fund Manager
/// @param pendingAssetAmount The amount of assets for which issuance was pending by the Fund Manager
/// @param pricePoolPerAsset The price of one asset unit in terms of pool currency at the time of approval
/// @param pricePoolPerShare The price of 1 pool currency token in terms of share class tokens at the time of issuance
/// @param issuedAt The timestamp when shares were issued
struct EpochInvestAmounts {
    uint128 approvedPoolAmount;
    uint128 approvedAssetAmount;
    uint128 pendingAssetAmount;
    D18 pricePoolPerAsset;
    D18 pricePoolPerShare;
    uint64 issuedAt;
}

/// @notice Struct containing the epoch data for paying out assets of a share class token
/// @param approvedShareAmount The amount of share class tokens which was approved by the Fund Manager for payout
/// @param pendingShareAmount The amount of share class tokens for which payout was pending by the Fund Manager
/// @param pricePoolPerAsset The price of one asset unit in terms of pool currency at the time of approval
/// @param pricePoolPerShare The price of 1 pool currency token in terms of share class tokens at the time of revocation
/// @param payoutAssetAmount The amount of payout assets to claim by redeeming share class tokens
/// @param revokedAt The timestamp when shares were revoked
struct EpochRedeemAmounts {
    uint128 approvedShareAmount;
    uint128 pendingShareAmount;
    D18 pricePoolPerAsset;
    D18 pricePoolPerShare;
    uint128 payoutAssetAmount;
    uint64 revokedAt;
}

/// @notice Struct containing the user's deposit or redeem request data
/// @param pending The amount of assets or shares which is pending for a user
/// @param lastUpdate The epoch at which the user most recently deposited or redeemed
struct UserOrder {
    uint128 pending;
    uint32 lastUpdate;
}

/// @notice Struct containing the user's queued deposit or redeem request data
/// @param isCancelling Whether the user is cancelling their pending requests
/// @param amount The amount of assets or shares which is queued for a user
struct QueuedOrder {
    bool isCancelling;
    uint128 amount;
}

/// @notice Enum indicating the type of request, either deposit or redeem
enum RequestType {
    Deposit,
    Redeem
}

/// @notice Enum indicating the manager action encoded in a `IManagerCallFromHub.fromHub` payload
enum ManagerAction {
    Invalid,
    ApproveDeposits,
    ApproveRedeems,
    IssueShares,
    RevokeShares,
    ForceCancelDepositRequest,
    ForceCancelRedeemRequest
}

/// @notice Struct containing the epoch IDs for each action
/// @param deposit The epoch ID for deposits
/// @param issue The epoch ID for issuing shares
/// @param redeem The epoch ID for redeems
/// @param revoke The epoch ID for revoking shares
struct EpochId {
    uint32 deposit;
    uint32 issue;
    uint32 redeem;
    uint32 revoke;
}

interface IBatchRequestManager is IHubRequestManager, IHubRequestManagerNotifications, IManagerCallFromHub {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event ApproveDeposits(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        AssetId indexed assetId,
        uint32 epochId,
        uint128 approvedPoolAmount,
        uint128 approvedAssetAmount,
        uint128 pendingAssetAmount
    );

    event ApproveRedeems(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        AssetId indexed assetId,
        uint32 epochId,
        uint128 approvedShareAmount,
        uint128 pendingShareAmount
    );

    event IssueShares(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        AssetId indexed assetId,
        uint32 epochId,
        D18 pricePoolPerShare,
        D18 priceAssetPerShare,
        uint128 issuedShareAmount
    );

    event RevokeShares(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        AssetId indexed assetId,
        uint32 epochId,
        D18 pricePoolPerShare,
        D18 priceAssetPerShare,
        uint128 approvedShareAmount,
        uint128 payoutAssetAmount,
        uint128 payoutPoolAmount
    );

    event ClaimDeposit(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        uint32 indexed epochId,
        bytes32 investor,
        AssetId assetId,
        uint128 paymentAssetAmount,
        uint128 pendingAssetAmount,
        uint128 payoutShareAmount,
        uint64 issuedAt
    );

    event ClaimRedeem(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        uint32 indexed epochId,
        bytes32 investor,
        AssetId assetId,
        uint128 paymentShareAmount,
        uint128 pendingShareAmount,
        uint128 payoutAssetAmount,
        uint64 revokedAt
    );

    event UpdateDepositRequest(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        AssetId indexed assetId,
        uint32 epochId,
        bytes32 investor,
        uint128 pendingAmount,
        uint128 totalPendingAmount,
        uint128 queuedAmount,
        bool isQueuedCancellation
    );

    event UpdateRedeemRequest(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        AssetId indexed assetId,
        uint32 epochId,
        bytes32 investor,
        uint128 pendingAmount,
        uint128 totalPendingAmount,
        uint128 queuedAmount,
        bool isQueuedCancellation
    );

    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 what, address addr);

    /// @notice Emitted when epoch IDs are modified via setEpochIds during migration
    event EpochIdModified(
        PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, EpochId epochIdData
    );

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when unknown request type is encountered.
    error UnknownRequestType();

    /// @notice Dispatched when value is forwarded to an action that sends no message (would strand).
    error UnexpectedValue();

    /// @notice Dispatched when `fromHub` is called by any address other than the `Envoy`.
    error NotEnvoy();

    error InsufficientPending();
    error ZeroApprovalAmount();
    error EpochNotFound();
    error EpochNotInSequence(uint32 epochId, uint32 actualEpochId);
    error NoOrderFound();
    error IssuanceRequired();
    error RevocationRequired();
    error CancellationInitializationRequired();
    error CancellationQueued();

    //----------------------------------------------------------------------------------------------
    // Incoming requests
    //----------------------------------------------------------------------------------------------

    /// @notice Submit a deposit request to invest assets into a pool's share class
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param amount The amount of assets to deposit
    /// @param investor The investor's address as bytes32
    /// @param depositAssetId The asset identifier for the deposit
    function requestDeposit(PoolId poolId, ShareClassId scId, uint128 amount, bytes32 investor, AssetId depositAssetId)
        external;

    /// @notice Cancel a pending deposit request and return the deposited assets
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param investor The investor's address as bytes32
    /// @param depositAssetId The asset identifier for the deposit
    /// @return cancelledAssetAmount The amount of assets returned to the investor
    function cancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        returns (uint128 cancelledAssetAmount);

    /// @notice Submit a redemption request to redeem shares for assets
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param amount The amount of shares to redeem
    /// @param investor The investor's address as bytes32
    /// @param payoutAssetId The asset identifier for the payout
    function requestRedeem(PoolId poolId, ShareClassId scId, uint128 amount, bytes32 investor, AssetId payoutAssetId)
        external;

    /// @notice Cancel a pending redemption request and return the shares
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param investor The investor's address as bytes32
    /// @param payoutAssetId The asset identifier for the payout
    /// @return cancelledShareAmount The amount of shares returned to the investor
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external
        returns (uint128 cancelledShareAmount);

    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

    /// @dev Entry point: `IManagerCallFromHub.fromHub`. Payload: `abi.encode(uint8 kind, bytes16 scId, ...args)`
    ///      (see `ManagerAction`). `poolId` comes from the call; `scId` is decoded from `payload`.
    ///      Only callable through the `Envoy`; policy enforcement happens at the Hub beforehand.

    //----------------------------------------------------------------------------------------------
    // Storage getters
    //----------------------------------------------------------------------------------------------

    /// @notice Hub contract called for deposit approvals, share issuance, and redeem processing
    function hub() external view returns (IHubRequestManagerCallback);

    /// @notice Registry of pools, assets, and manager permissions on the hub chain
    function hubRegistry() external view returns (IHubRegistry);

    /// @notice The Envoy, the only authorized caller of `fromHub`
    function envoy() external view returns (address);

    /// @notice Returns the epoch ID data for a given pool, share class and asset
    function epochId(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint32 deposit, uint32 issue, uint32 redeem, uint32 revoke);

    /// @notice Returns the total pending redeem amount for a given pool, share class and asset
    function pendingRedeem(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128);

    /// @notice Returns the total pending deposit amount for a given pool, share class and asset
    function pendingDeposit(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128);

    /// @notice Returns the user's redeem request order for a given pool, share class, asset and investor
    function redeemRequest(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor)
        external
        view
        returns (uint128 pending, uint32 lastUpdate);

    /// @notice Returns the user's deposit request order for a given pool, share class, asset and investor
    function depositRequest(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor)
        external
        view
        returns (uint128 pending, uint32 lastUpdate);

    /// @notice Returns the user's queued redeem request for a given pool, share class, asset and investor
    function queuedRedeemRequest(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor)
        external
        view
        returns (bool isCancelling, uint128 amount);

    /// @notice Returns the user's queued deposit request for a given pool, share class, asset and investor
    function queuedDepositRequest(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor)
        external
        view
        returns (bool isCancelling, uint128 amount);

    /// @notice Returns whether force cancel is allowed for a deposit request
    function allowForceDepositCancel(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor)
        external
        view
        returns (bool);

    /// @notice Returns whether force cancel is allowed for a redeem request
    function allowForceRedeemCancel(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor)
        external
        view
        returns (bool);

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Get the current deposit epoch identifier
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param depositAssetId The asset identifier for deposits
    /// @return The current deposit epoch ID
    function nowDepositEpoch(PoolId poolId, ShareClassId scId, AssetId depositAssetId) external view returns (uint32);

    /// @notice Get the current issue epoch identifier
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param depositAssetId The asset identifier for deposits
    /// @return The current issue epoch ID
    function nowIssueEpoch(PoolId poolId, ShareClassId scId, AssetId depositAssetId) external view returns (uint32);

    /// @notice Get the current redeem epoch identifier
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param depositAssetId The asset identifier for payouts
    /// @return The current redeem epoch ID
    function nowRedeemEpoch(PoolId poolId, ShareClassId scId, AssetId depositAssetId) external view returns (uint32);

    /// @notice Get the current revoke epoch identifier
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param depositAssetId The asset identifier for payouts
    /// @return The current revoke epoch ID
    function nowRevokeEpoch(PoolId poolId, ShareClassId scId, AssetId depositAssetId) external view returns (uint32);

    /// @notice Get the maximum number of deposit claims available for an investor
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param investor The investor's address as bytes32
    /// @param depositAssetId The asset identifier for deposits
    /// @return The maximum number of claimable deposit epochs
    function maxDepositClaims(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        view
        returns (uint32);

    /// @notice Get the maximum number of redeem claims available for an investor
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param investor The investor's address as bytes32
    /// @param payoutAssetId The asset identifier for payouts
    /// @return The maximum number of claimable redeem epochs
    function maxRedeemClaims(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external
        view
        returns (uint32);

    //----------------------------------------------------------------------------------------------
    // Epoch data access
    //----------------------------------------------------------------------------------------------

    /// @notice Get detailed investment amounts and pricing for a specific epoch
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param epochId The epoch identifier
    /// @return pendingAssetAmount Assets waiting to be approved
    /// @return approvedAssetAmount Assets approved for investment
    /// @return approvedPoolAmount Pool currency amount after asset-to-pool conversion
    /// @return pricePoolPerAsset Price of pool currency per asset unit
    /// @return pricePoolPerShare Price of pool currency per share unit
    /// @return issuedAt Timestamp when shares were issued
    function epochInvestAmounts(PoolId poolId, ShareClassId scId, AssetId assetId, uint32 epochId)
        external
        view
        returns (
            uint128 pendingAssetAmount,
            uint128 approvedAssetAmount,
            uint128 approvedPoolAmount,
            D18 pricePoolPerAsset,
            D18 pricePoolPerShare,
            uint64 issuedAt
        );

    /// @notice Get detailed redemption amounts and pricing for a specific epoch
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param epochId The epoch identifier
    /// @return approvedShareAmount Shares approved for redemption
    /// @return pendingShareAmount Shares waiting to be approved
    /// @return pricePoolPerAsset Price of pool currency per asset unit
    /// @return pricePoolPerShare Price of pool currency per share unit
    /// @return payoutAssetAmount Asset amount to be paid out
    /// @return revokedAt Timestamp when shares were revoked
    function epochRedeemAmounts(PoolId poolId, ShareClassId scId, AssetId assetId, uint32 epochId)
        external
        view
        returns (
            uint128 approvedShareAmount,
            uint128 pendingShareAmount,
            D18 pricePoolPerAsset,
            D18 pricePoolPerShare,
            uint128 payoutAssetAmount,
            uint64 revokedAt
        );
}
