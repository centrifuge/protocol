// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IHubRequestManager, IHubRequestManagerNotifications} from "../../core/hub/interfaces/IHubRequestManager.sol";

/// @notice Struct containing the epoch data for issuing share class tokens
/// @param approvedPoolAmount The amount of pool currency which was approved by the Fund Manager
/// @param approvedAssetAmount The amount of assets which was approved by the Fund Manager
/// @param pendingAssetAmount The amount of assets for which issuance was pending by the Fund Manager
/// @param pricePoolPerAsset The price of 1 pool currency token in terms of asset tokens at the time of approval
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
/// @param pricePoolPerAsset The price of 1 pool currency token in terms of asset tokens at the time of approval
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

interface IBatchRequestManager is IHubRequestManager, IHubRequestManagerNotifications {
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

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when unknown request type is encountered.
    error UnknownRequestType();

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

    /// @notice Approve pending deposit requests for an epoch
    /// @dev This function approves a specific amount of assets from the current deposit epoch
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param depositAssetId The asset identifier for deposits
    /// @param nowDepositEpochId The current deposit epoch identifier
    /// @param approvedAssetAmount The amount of assets approved for this epoch
    /// @param pricePoolPerAsset The price of pool currency per asset unit
    /// @param refund Address to receive unused gas refund
    function approveDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint32 nowDepositEpochId,
        uint128 approvedAssetAmount,
        D18 pricePoolPerAsset,
        address refund
    ) external payable;

    /// @notice Approve pending redemption requests for an epoch
    /// @dev This function approves a specific amount of shares from the current redeem epoch
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param payoutAssetId The asset identifier for payouts
    /// @param nowRedeemEpochId The current redeem epoch identifier
    /// @param approvedShareAmount The amount of shares approved for redemption
    /// @param pricePoolPerAsset The price of pool currency per asset unit
    function approveRedeems(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint32 nowRedeemEpochId,
        uint128 approvedShareAmount,
        D18 pricePoolPerAsset
    ) external payable;

    /// @notice Issue shares to investors based on approved deposits
    /// @dev This function mints shares for the approved deposit epoch using the provided share price
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param depositAssetId The asset identifier for deposits
    /// @param nowIssueEpochId The current issue epoch identifier
    /// @param pricePoolPerShare The price of pool currency per share unit
    /// @param extraGasLimit Additional gas limit for cross-chain operations
    /// @param refund Address to receive unused gas refund
    function issueShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint32 nowIssueEpochId,
        D18 pricePoolPerShare,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Revoke shares and prepare asset payouts for redemptions
    /// @dev This function burns shares for the approved redeem epoch and calculates asset payouts
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param payoutAssetId The asset identifier for payouts
    /// @param nowRevokeEpochId The current revoke epoch identifier
    /// @param pricePoolPerShare The price of pool currency per share unit
    /// @param extraGasLimit Additional gas limit for cross-chain operations
    /// @param refund Address to receive unused gas refund
    function revokeShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint32 nowRevokeEpochId,
        D18 pricePoolPerShare,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Force cancel a user's deposit request (manager action)
    /// @dev This allows the manager to cancel a deposit request on behalf of a user
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param investor The investor's address as bytes32
    /// @param depositAssetId The asset identifier for the deposit
    /// @param refund Address to receive unused gas refund
    function forceCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        bytes32 investor,
        AssetId depositAssetId,
        address refund
    ) external payable;

    /// @notice Force cancel a user's redemption request (manager action)
    /// @dev This allows the manager to cancel a redemption request on behalf of a user
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param investor The investor's address as bytes32
    /// @param payoutAssetId The asset identifier for the payout
    /// @param refund Address to receive unused gas refund
    function forceCancelRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        bytes32 investor,
        AssetId payoutAssetId,
        address refund
    ) external payable;

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
