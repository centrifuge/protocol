// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {ShareClassIdTest} from "../../../test/common/types/ShareClassId.t.sol";

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

interface IShareClassManager {
    /// Events
    event File(bytes32 what, address who);
    event AddShareClass(
        PoolId indexed poolId, ShareClassId indexed scId, uint32 indexed index, string name, string symbol, bytes32 salt
    );
    event UpdateMetadata(PoolId indexed poolId, ShareClassId indexed scId, string name, string symbol, bytes32 salt);
    event NewInvestEpoch(PoolId indexed poolId, AssetId indexed assetId, uint32 newIndex);
    event NewRedeemEpoch(PoolId indexed poolId, AssetId indexed assetId, uint32 newIndex);
    event ApproveDeposits(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        AssetId assetId,
        uint128 approvedPoolAmount,
        uint128 approvedAssetAmount,
        uint128 pendingAssetAmount
    );
    event ApproveRedeems(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        AssetId assetId,
        uint128 approvedShareAmount,
        uint128 pendingShareAmount
    );
    event IssueShares(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        D18 navPoolPerShare,
        D18 navAssetPerShare,
        uint128 issuedShareAmount
    );
    event RemoteIssueShares(PoolId indexed poolId, ShareClassId indexed scId, uint128 issedShareAmount);
    event RevokeShares(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        D18 navPoolPerShare,
        D18 navAssetPerShare,
        uint128 revokedShareAmount,
        uint128 paymentAssetAmount,
        uint128 paymentPoolAmount
    );
    event RemoteRevokeShares(PoolId indexed poolId, ShareClassId indexed scId, uint128 revokedAssetAmount);
    event ClaimDeposit(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        bytes32 investor,
        AssetId assetId,
        uint128 approvedAssetAmount,
        uint128 pendingAssetAmount,
        uint128 claimedShareAmount,
        uint64 issuedAt
    );
    event ClaimRedeem(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        bytes32 investor,
        AssetId assetId,
        uint128 approvedShareClassAmount,
        uint128 pendingShareClassAmount,
        uint128 claimedAssetAmount,
        uint64 revokedAt
    );
    event AddShareClass(PoolId indexed poolId, ShareClassId indexed scId, uint32 indexed index);
    event UpdateShareClass(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint128 nav,
        D18 navPoolPerShare,
        uint128 totalIssuance
    );
    event UpdateRequest(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        RequestType requestType,
        bytes32 investor,
        AssetId assetId,
        uint128 pendingUserAmount,
        uint128 pendingTotalAmount,
        uint128 queuedAmount,
        bool pendingCancellation
    );

    /// Errors
    error NotEnoughPending();
    error ApprovalRequired();
    error IssuanceRequired();
    error AlreadyIssued();
    error RevocationRequired();
    error UnrecognizedFileParam();
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

    /// @notice Approves an asset amount of all deposit requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param approvedAssetAmount Amount of assets that will be approved for deposit
    /// @param depositAssetId Identifier of the asset locked for the deposit request
    /// @param pricePoolPerAsset Amount of pool unit one gets for a unit of asset
    /// @return pendingAssetAmount Amount of assets still pending for deposit
    /// @return approvedPoolAmount  Amount of pool units approved for deposit
    function approveDeposits(
        PoolId poolId,
        ShareClassId scId,
        uint128 approvedAssetAmount,
        AssetId depositAssetId,
        D18 pricePoolPerAsset
    ) external returns (uint128 pendingAssetAmount, uint128 approvedPoolAmount);

    /// @notice Approves a share class token amount of all redeem requests for the given triplet of pool id, share class
    /// id and payout asset id.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param approvedShareAmount Amount of shares that will be approved for redemption
    /// @param payoutAssetId Identifier of the asset for which all requests want to exchange their share class tokens
    /// for
    /// @param pricePoolPerAsset Amount of pool unit one gets for a unit of asset
    /// @return pendingShareAmount Sum of redemption request amounts in share class token amount which was not approved
    function approveRedeems(
        PoolId poolId,
        ShareClassId scId,
        uint128 approvedShareAmount,
        AssetId payoutAssetId,
        D18 pricePoolPerAsset
    ) external returns (uint128 pendingShareAmount);

    /// @notice Emits new shares for the given identifier based on the provided NAV per share.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param depositAssetId Identifier of the deposit asset for which shares should be issued
    /// @param navPoolPerShare The nav per share value of the share class (in the pool currency denomination. Conversion
    /// to asset price is done onchain based on the valuation of the asset at approval)
    /// @return issuedShareAmount Amount of shares that have been issued
    function issueShares(PoolId poolId, ShareClassId scId, AssetId depositAssetId, D18 navPoolPerShare)
        external
        returns (uint128 issuedShareAmount, uint128 paymentAssetAmount, uint128 paymentPoolAmount);

    /// @notice Take back shares for the given identifier based on the provided NAV per share.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param payoutAssetId Identifier of the payout asset
    /// @param navPoolPerShare The nav per share value of the share class (in the pool currency denomination. Conversion
    /// to asset price is done onchain based on the valuation of the asset at approval)
    /// @return revokedShareAmount Amount of shares that have been revoked
    /// @return payoutAssetAmount Converted amount of payout asset based on number of revoked shares
    /// @return payoutPoolAmount Converted amount of pool currency based on number of revoked shares
    function revokeShares(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, D18 navPoolPerShare)
        external
        returns (uint128 revokedShareAmount, uint128 payoutAssetAmount, uint128 payoutPoolAmount);

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

    /// @notice Increases the share class issuance
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param amount The amount to increase the share class issuance by
    function increaseShareClassIssuance(PoolId poolId, ShareClassId scId, uint128 amount) external;

    /// @notice Decreases the share class issuance
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param amount The amount to decrease the share class issuance by
    function decreaseShareClassIssuance(PoolId poolId, ShareClassId scId, uint128 amount) external;

    /// @notice Adds a new share class to the given pool.
    ///
    /// @param poolId Identifier of the pool
    /// @param name The name of the share class
    /// @param symbol The symbol of the share class
    /// @param salt The salt used for deploying the share class tokens
    /// @param data Additional data of the new share class
    /// @return scId Identifier of the newly added share class
    function addShareClass(
        PoolId poolId,
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        bytes calldata data
    ) external returns (ShareClassId scId);


    /// @notice Updates the price pool unit per share unit of a share class
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param pricePoolPerShare The price per share of the share class (in the pool currency denomination)
    function updateShareClassPrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare) external;

    /// @notice Updates the metadata of a share class.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param name The name of the share class
    /// @param symbol The symbol of the share class
    /// @param salt The salt used for deploying the share class tokens
    /// @param metadata Encoded additional metadata of the new share class
    function updateMetadata(
        PoolId poolId,
        ShareClassId scId,
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        bytes calldata metadata
    ) external;

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

    /// @notice Exposes relevant metrics for a share class
    ///
    /// @return totalIssuance The total number of shares known to the CP side
    /// @return pricePoolPerShare The amount of pool units per unit share
    function metrics(ShareClassId scId) external view returns (uint128 totalIssuance, D18 pricePoolPerShare);

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
    function metadata(ShareClassId scId) external returns (string memory name, string memory symbol, bytes32 salt);
}
