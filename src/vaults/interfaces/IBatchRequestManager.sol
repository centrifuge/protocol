// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

import {IHubRequestManager, IHubRequestManagerNotifications} from "../../hub/interfaces/IHubRequestManager.sol";

/// @notice Struct containing the epoch data for issuing share class tokens
/// @param approvedPoolAmount The amount of pool currency which was approved by the Fund Manager
/// @param approvedAssetAmount The amount of assets which was approved by the Fund Manager
/// @param pendingAssetAmount The amount of assets for which issuance was pending by the Fund Manager
/// @param pricePoolPerAsset The price of 1 pool currency token in terms of asset tokens at the time of approval
/// @param navPoolPerShare The price of 1 pool currency token in terms of share class tokens at the time of issuance
/// @param issuedAt The timestamp when shares were issued
struct EpochInvestAmounts {
    uint128 approvedPoolAmount;
    uint128 approvedAssetAmount;
    uint128 pendingAssetAmount;
    D18 pricePoolPerAsset;
    D18 navPoolPerShare;
    uint64 issuedAt;
}

/// @notice Struct containing the epoch data for paying out assets of a share class token
/// @param approvedShareAmount The amount of share class tokens which was approved by the Fund Manager for payout
/// @param pendingShareAmount The amount of share class tokens for which payout was pending by the Fund Manager
/// @param pricePoolPerAsset The price of 1 pool currency token in terms of asset tokens at the time of approval
/// @param navPoolPerShare The price of 1 pool currency token in terms of share class tokens at the time of revocation
/// @param payoutAssetAmount The amount of payout assets to claim by redeeming share class tokens
/// @param revokedAt The timestamp when shares were revoked
struct EpochRedeemAmounts {
    uint128 approvedShareAmount;
    uint128 pendingShareAmount;
    D18 pricePoolPerAsset;
    D18 navPoolPerShare;
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
        D18 navPoolPerShare,
        D18 priceAssetPerShare,
        uint128 issuedShareAmount
    );

    event RevokeShares(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        AssetId indexed assetId,
        uint32 epochId,
        D18 navPoolPerShare,
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

    /// @notice Dispatched when there is not enough gas for payment methods
    error NotEnoughGas();

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

    function requestDeposit(PoolId poolId, ShareClassId scId, uint128 amount, bytes32 investor, AssetId depositAssetId)
        external;

    function cancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        returns (uint128 cancelledAssetAmount);

    function requestRedeem(PoolId poolId, ShareClassId scId, uint128 amount, bytes32 investor, AssetId payoutAssetId)
        external;

    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external
        returns (uint128 cancelledShareAmount);

    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

    function approveDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint32 nowDepositEpochId,
        uint128 approvedAssetAmount,
        D18 pricePoolPerAsset,
        address refund
    ) external payable;

    function approveRedeems(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint32 nowRedeemEpochId,
        uint128 approvedShareAmount,
        D18 pricePoolPerAsset
    ) external;

    function issueShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint32 nowIssueEpochId,
        D18 navPoolPerShare,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    function revokeShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint32 nowRevokeEpochId,
        D18 navPoolPerShare,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    function forceCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        bytes32 investor,
        AssetId depositAssetId,
        address refund
    ) external payable;

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

    function nowDepositEpoch(ShareClassId scId, AssetId depositAssetId) external view returns (uint32);

    function nowIssueEpoch(ShareClassId scId, AssetId depositAssetId) external view returns (uint32);

    function nowRedeemEpoch(ShareClassId scId, AssetId depositAssetId) external view returns (uint32);

    function nowRevokeEpoch(ShareClassId scId, AssetId depositAssetId) external view returns (uint32);

    function maxDepositClaims(ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        view
        returns (uint32);

    function maxRedeemClaims(ShareClassId scId, bytes32 investor, AssetId payoutAssetId) external view returns (uint32);

    //----------------------------------------------------------------------------------------------
    // Epoch data access
    //----------------------------------------------------------------------------------------------

    function epochInvestAmounts(ShareClassId scId, AssetId assetId, uint32 epochId)
        external
        view
        returns (
            uint128 pendingAssetAmount,
            uint128 approvedAssetAmount,
            uint128 approvedPoolAmount,
            D18 pricePoolPerAsset,
            D18 navPoolPerShare,
            uint64 issuedAt
        );

    function epochRedeemAmounts(ShareClassId scId, AssetId assetId, uint32 epochId)
        external
        view
        returns (
            uint128 approvedShareAmount,
            uint128 pendingShareAmount,
            D18 pricePoolPerAsset,
            D18 navPoolPerShare,
            uint128 payoutAssetAmount,
            uint64 revokedAt
        );
}
