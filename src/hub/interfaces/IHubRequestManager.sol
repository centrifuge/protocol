// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

struct EpochRedeemAmounts {
    /// @dev Amount of shares pending to be redeemed at time of epoch
    uint128 pendingShareAmount;
    /// @dev Total approved amount of redeemed share class tokens
    uint128 approvedShareAmount;
    /// @dev Total asset amount of revoked share class tokens
    uint128 payoutAssetAmount;
    /// @dev The amount of pool currency per unit of asset at time of approval
    D18 pricePoolPerAsset;
    /// @dev The amount of pool currency per unit of share at time of revocation
    D18 navPoolPerShare;
    /// @dev block timestamp when shares of epoch were revoked
    uint64 revokedAt;
}

struct EpochInvestAmounts {
    /// @dev Total pending asset amount of deposit asset at time of epoch
    uint128 pendingAssetAmount;
    /// @dev Total approved asset amount of deposit asset
    uint128 approvedAssetAmount;
    /// @dev Total approved pool amount of deposit asset
    uint128 approvedPoolAmount;
    /// @dev The amount of pool currency per unit of asset at time of approval
    D18 pricePoolPerAsset;
    /// @dev The amount of pool currency per unit of share at time of issuance
    D18 navPoolPerShare;
    /// @dev block timestamp when shares of epoch were issued
    uint64 issuedAt;
}

struct UserOrder {
    /// @dev Pending amount in deposit asset denomination
    uint128 pending;
    /// @dev Index of epoch in which last order was made
    uint32 lastUpdate;
}

struct ShareClassMetadata {
    /// @dev The name of the share class token
    string name;
    /// @dev The symbol of the share class token
    string symbol;
    /// @dev The salt of the share class token
    bytes32 salt;
}

struct ShareClassMetrics {
    /// @dev Total number of shares
    uint128 totalIssuance;
    /// @dev The latest net asset value per share class token
    D18 navPerShare;
}

struct QueuedOrder {
    /// @dev Whether the user requested a cancellation which is now queued
    bool isCancelling;
    /// @dev The queued increased request amount
    uint128 amount;
}

enum RequestType {
    /// @dev Whether the request is a deposit one
    Deposit,
    /// @dev Whether the request is a redeem one
    Redeem
}

struct EpochId {
    uint32 deposit;
    uint32 redeem;
    uint32 issue;
    uint32 revoke;
}

interface IShareClassManager {
    /// Events
    event AddShareClass(
        PoolId indexed poolId, ShareClassId indexed scId, uint32 indexed index, string name, string symbol, bytes32 salt
    );
    event UpdateMetadata(PoolId indexed poolId, ShareClassId indexed scId, string name, string symbol);
    event ApproveDeposits(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        AssetId indexed depositAssetId,
        uint32 epoch,
        uint128 approvedPoolAmount,
        uint128 approvedAssetAmount,
        uint128 pendingAssetAmount
    );
    event ApproveRedeems(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        AssetId indexed payoutAssetId,
        uint32 epoch,
        uint128 approvedShareAmount,
        uint128 pendingShareAmount
    );
    event IssueShares(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        AssetId indexed depositAssetId,
        uint32 epoch,
        D18 navPoolPerShare,
        D18 navAssetPerShare,
        uint128 issuedShareAmount
    );
    event RemoteIssueShares(
        uint16 centrifugeId, PoolId indexed poolId, ShareClassId indexed scId, uint128 issuedShareAmount
    );
    event RevokeShares(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        AssetId indexed payoutAssetId,
        uint32 epoch,
        D18 navPoolPerShare,
        D18 navAssetPerShare,
        uint128 revokedShareAmount,
        uint128 revokedAssetAmount,
        uint128 revokedPoolAmount
    );
    event RemoteRevokeShares(
        uint16 centrifugeId, PoolId indexed poolId, ShareClassId indexed scId, uint128 revokedShareAmount
    );
    event ClaimDeposit(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 epoch,
        bytes32 investor,
        AssetId indexed depositAssetId,
        uint128 paymentAssetAmount,
        uint128 pendingAssetAmount,
        uint128 claimedShareAmount,
        uint64 issuedAt
    );
    event ClaimRedeem(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 epoch,
        bytes32 investor,
        AssetId indexed payoutAssetId,
        uint128 paymentShareAmount,
        uint128 pendingShareAmount,
        uint128 claimedAssetAmount,
        uint64 revokedAt
    );
    event AddShareClass(PoolId indexed poolId, ShareClassId indexed scId, uint32 indexed index);
    event UpdateShareClass(PoolId indexed poolId, ShareClassId indexed scId, D18 navPoolPerShare);
    event UpdateDepositRequest(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        AssetId indexed depositAssetId,
        uint32 epoch,
        bytes32 investor,
        uint128 pendingUserAssetAmount,
        uint128 pendingTotalAssetAmount,
        uint128 queuedUserAssetAmount,
        bool pendingCancellation
    );
    event UpdateRedeemRequest(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        AssetId indexed payoutAssetId,
        uint32 epoch,
        bytes32 investor,
        uint128 pendingUserShareAmount,
        uint128 pendingTotalShareAmount,
        uint128 queuedUserShareAmount,
        bool pendingCancellation
    );

    /// Errors
    error EpochNotInSequence(uint32 providedEpoch, uint32 nowEpoch);
    error NoOrderFound();
    error InsufficientPending();
    error ApprovalRequired();
    error IssuanceRequired();
    error AlreadyIssued();
    error RevocationRequired();
    error ZeroApprovalAmount();
    error InvalidMetadataSize();
    error InvalidMetadataName();
    error InvalidMetadataSymbol();
    error InvalidSalt();
    error AlreadyUsedSalt();
    error RevokeMoreThanIssued();
    error PoolMissing();
    error ShareClassNotFound();
    error EpochNotFound();
    error DecreaseMoreThanIssued();
    error CancellationQueued();
    error CancellationInitializationRequired();

    /// Functions

    /// @notice Creates or updates a request to deposit (exchange) an asset amount for share class tokens.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param amount Asset token amount which is deposited
    /// @param investor Centrifuge Vault address of the entity which is depositing
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    function requestDeposit(PoolId poolId, ShareClassId scId, uint128 amount, bytes32 investor, AssetId depositAssetId)
        external;

    /// @notice Cancels a pending deposit request.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param investor Centrifuge Vault address of the entity which is cancelling
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    /// @return cancelledAssetAmount The deposit amount which was previously pending and is now cancelled. This amount
    /// was not potentially (partially) swapped to the pool amount in case the deposit asset cannot be exchanged 1:1
    /// into the pool token
    function cancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        returns (uint128 cancelledAssetAmount);

    /// @notice Force cancels a pending deposit request.
    /// Only allowed if the user has cancelled a request at least once before. This is to protect against cancelling a
    /// request of a smart contract user that does not support the cancellation interface, and would thus be unable to
    /// claim back the cancelled assets.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param investor Centrifuge Vault address of the entity which is cancelling
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    /// @return cancelledAssetAmount The deposit amount which was previously pending and is now cancelled with force
    function forceCancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        returns (uint128 cancelledAssetAmount);

    /// @notice Creates or updates a request to redeem (exchange) share class tokens for some asset.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param amount Share class token amount which should be redeemed
    /// @param investor Centrifuge Vault address of the entity which is redeeming
    /// @param payoutAssetId Identifier of the asset which the investor eventually receives back for their redeemed
    /// share class tokens
    function requestRedeem(PoolId poolId, ShareClassId scId, uint128 amount, bytes32 investor, AssetId payoutAssetId)
        external;

    /// @notice Cancels a pending redeem request.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param investor Centrifuge Vault address of the entity which is cancelling
    /// @param payoutAssetId Identifier of the asset which the investor eventually receives back for their redeemed
    /// share class tokens
    /// @return cancelledShareAmount The redeem amount which was previously pending and is now cancelled
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external
        returns (uint128 cancelledShareAmount);

    /// @notice Force cancels a pending redeem request.
    /// Only allowed if the user has cancelled a request at least once before. This is to protect against cancelling a
    /// request of a smart contract user that does not support the cancellation interface, and would thus be unable to
    /// claim back the cancelled share class tokens.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param investor Centrifuge Vault address of the entity which is cancelling
    /// @param payoutAssetId Identifier of the asset which the investor eventually receives back for their redeemed
    /// share class tokens
    /// @return cancelledShareAmount The redeem amount which was previously pending and is now cancelled with force
    function forceCancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external
        returns (uint128 cancelledShareAmount);

    /// @notice Approves an asset amount of all deposit requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    /// @dev nowDepositEpochId MUST be called sequentially.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param depositAssetId Identifier of the asset locked for the deposit request
    /// @param nowDepositEpochId The epoch for which shares will be approved.
    /// @param approvedAssetAmount Amount of assets that will be approved for deposit
    /// @param pricePoolPerAsset Amount of pool unit one gets for a unit of asset
    /// @return pendingAssetAmount Amount of assets still pending for deposit
    /// @return approvedPoolAmount  Amount of pool units approved for deposit
    function approveDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint32 nowDepositEpochId,
        uint128 approvedAssetAmount,
        D18 pricePoolPerAsset
    ) external returns (uint128 pendingAssetAmount, uint128 approvedPoolAmount);

    /// @notice Approves a share class token amount of all redeem requests for the given triplet of pool id, share class
    /// id and payout asset id.
    /// @dev nowRedeemEpochId MUST be called sequentially.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param payoutAssetId Identifier of the asset for which all requests want to exchange their share class tokens
    /// for
    /// @param nowRedeemEpochId The epoch for which shares will be approved.
    /// @param approvedShareAmount Amount of shares that will be approved for redemption
    /// @param pricePoolPerAsset Amount of pool unit one gets for a unit of asset
    /// @return pendingShareAmount Sum of redemption request amounts in share class token amount which was not approved
    function approveRedeems(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint32 nowRedeemEpochId,
        uint128 approvedShareAmount,
        D18 pricePoolPerAsset
    ) external returns (uint128 pendingShareAmount);

    /// @notice Emits new shares for the given identifier based on the provided NAV per share.
    /// @dev nowIssueEpochId MUST be called sequentially.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param depositAssetId Identifier of the deposit asset for which shares should be issued
    /// @param nowIssueEpochId The epoch for which shares will be issued.
    /// @param navPoolPerShare The nav per share value of the share class (in the pool currency denomination. Conversion
    /// to asset price is done onchain based on the valuation of the asset at approval)
    /// @return issuedShareAmount Amount of shares that have been issued
    function issueShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint32 nowIssueEpochId,
        D18 navPoolPerShare
    ) external returns (uint128 issuedShareAmount, uint128 depositAssetAmount, uint128 depositPoolAmount);

    /// @notice Take back shares for the given identifier based on the provided NAV per share.
    /// @dev nowRevokeEpochId MUST be called sequentially.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param payoutAssetId Identifier of the payout asset
    /// @param nowRevokeEpochId The epoch for which shares will be revoked.
    /// @param navPoolPerShare The nav per share value of the share class (in the pool currency denomination. Conversion
    /// to asset price is done onchain based on the valuation of the asset at approval)
    /// @return revokedShareAmount Amount of shares that have been revoked
    /// @return payoutAssetAmount Converted amount of payout asset based on number of revoked shares
    /// @return payoutPoolAmount Converted amount of pool currency based on number of revoked shares
    function revokeShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint32 nowRevokeEpochId,
        D18 navPoolPerShare
    ) external returns (uint128 revokedShareAmount, uint128 payoutAssetAmount, uint128 payoutPoolAmount);

    /// @notice Collects shares for an investor after their deposit request was (partially) approved and new shares were
    /// issued.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param investor Centrifuge Vault address of the recipient of the claimed share class tokens
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    /// @return payoutShareAmount Amount of shares which the investor receives
    /// @return paymentAssetAmount Amount of deposit asset which was taken as payment
    /// @return cancelledAssetAmount Amount of deposit asset which was cancelled due to being queued
    /// @return canClaimAgain Whether another call to claimRedeem is needed until investor has fully claimed investments
    function claimDeposit(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        returns (
            uint128 payoutShareAmount,
            uint128 paymentAssetAmount,
            uint128 cancelledAssetAmount,
            bool canClaimAgain
        );

    /// @notice Collects an asset amount for an investor after their redeem request was (partially) approved and shares
    /// were revoked.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param investor Centrifuge Vault address of the recipient of the claimed asset amount
    /// @param payoutAssetId Identifier of the asset which the investor requested to receive back for their redeemed
    /// shares
    /// @return payoutAssetAmount Amount of payout amount which the investor receives
    /// @return paymentShareAmount Amount of shares which the investor redeemed
    /// @return cancelledShareAmount Amount of shares which were cancelled due to being queued
    /// @return canClaimAgain Whether another call to claimRedeem is needed until investor has fully claimed redemptions
    function claimRedeem(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external
        returns (
            uint128 payoutAssetAmount,
            uint128 paymentShareAmount,
            uint128 cancelledShareAmount,
            bool canClaimAgain
        );

    /// @notice Update the share class issuance
    ///
    /// @param centrifugeId Identifier of the chain
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param amount The amount to increase the share class issuance by
    /// @param isIssuance Whether it is an issuance or revocation
    function updateShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId, uint128 amount, bool isIssuance)
        external;

    /// @notice Adds a new share class to the given pool.
    ///
    /// @param poolId Identifier of the pool
    /// @param name The name of the share class
    /// @param symbol The symbol of the share class
    /// @param salt The salt used for deploying the share class tokens
    /// @return scId Identifier of the newly added share class
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        returns (ShareClassId scId);

    /// @notice Updates the price pool unit per share unit of a share class
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param pricePoolPerShare The price per share of the share class (in the pool currency denomination)
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare) external;

    /// @notice Updates the metadata of a share class.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param name The name of the share class
    /// @param symbol The symbol of the share class
    function updateMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol) external;

    /// @notice Returns the number of share classes for the given pool
    ///
    /// @param poolId Identifier of the pool in question
    /// @return count Number of share classes for the given pool
    function shareClassCount(PoolId poolId) external view returns (uint32 count);

    /// @notice Checks the existence of a share class.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    function exists(PoolId poolId, ShareClassId scId) external view returns (bool);

    /// @notice Returns the current ongoing epoch id for deposits
    ///
    /// @param scId Identifier of the share class
    /// @param depositAssetId AssetId of the payment asset
    function nowDepositEpoch(ShareClassId scId, AssetId depositAssetId) external view returns (uint32);

    /// @notice Returns the epoch for which will be issued next
    ///
    /// @param scId Identifier of the share class
    /// @param depositAssetId AssetId of the payment asset
    function nowIssueEpoch(ShareClassId scId, AssetId depositAssetId) external view returns (uint32);

    /// @notice Returns the current ongoing epoch id for deposits
    ///
    /// @param scId Identifier of the share class
    /// @param payoutAssetId AssetId of the payment asset
    function nowRedeemEpoch(ShareClassId scId, AssetId payoutAssetId) external view returns (uint32);

    /// @notice Returns the epoch for which will be revoked next
    ///
    /// @param scId Identifier of the share class
    /// @param depositAssetId AssetId of the payment asset
    function nowRevokeEpoch(ShareClassId scId, AssetId depositAssetId) external view returns (uint32);

    /// @notice Returns an upper bound for possible calls to `function claimDeposit(..)`
    ///
    /// @param scId Identifier of the share class
    /// @param investor Recipient of the share class tokens
    /// @param depositAssetId AssetId of the payment asset
    function maxDepositClaims(ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        view
        returns (uint32 maxClaims);

    /// @notice Returns an upper bound for possible calls to `function claimRedeem(..)`
    ///
    /// @param scId Identifier of the share class
    /// @param investor Recipient of the payout assets
    /// @param payoutAssetId AssetId of the payout asset
    function maxRedeemClaims(ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external
        view
        returns (uint32 maxClaims);

    /// @notice Exposes relevant metrics for a share class
    ///
    /// @return totalIssuance The total number of shares known to the Hub side
    /// @return pricePoolPerShare The amount of pool units per unit share
    function metrics(ShareClassId scId) external view returns (uint128 totalIssuance, D18 pricePoolPerShare);

    /// @notice Exposes issuance of a share class on a given network
    ///
    /// @param scId Identifier of the share class
    /// @param centrifugeId Identifier of the chain
    function issuance(ShareClassId scId, uint16 centrifugeId) external view returns (uint128);

    /// @notice Determines the next share class id for the given pool.
    ///
    /// @param poolId Identifier of the pool
    /// @return scId Identifier of the next share class
    function previewNextShareClassId(PoolId poolId) external view returns (ShareClassId scId);

    /// @notice Determines the share class id for the given pool and index.
    ///
    /// @param poolId Identifier of the pool
    /// @param index The pool-internal index of the share class id
    /// @return scId Identifier of the underlying share class
    function previewShareClassId(PoolId poolId, uint32 index) external pure returns (ShareClassId scId);

    /// @notice returns The metadata of the share class.
    ///
    /// @param scId Identifier of the share class
    /// @return name The registered name of the share class token
    /// @return symbol The registered symbol of the share class token
    /// @return salt The registered salt of the share class token, used for deterministic deployments
    function metadata(ShareClassId scId)
        external
        view
        returns (string memory name, string memory symbol, bytes32 salt);
}
