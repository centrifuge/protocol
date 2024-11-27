// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    PoolId,
    AssetId,
    ShareClassId,
    PoolAmount,
    ShareClassAmount,
    AssetAmount,
    Ratio,
    EpochId
} from "src/types/Domain.sol";

// NOTE: Needs to be per (pool, shareClassId, assetId)
struct EpochRatios {
    // @dev Percentage of approved redemptions
    Ratio redeemRatio;
    // @dev Percentage of approved deposits
    Ratio depositRatio;
    // @dev Value in share class denomination per asset
    Ratio shareClassPrice;
    // @dev Value in pool denomination per asset
    Ratio assetQuote;
}

// NOTE: Needs to be per (pool, shareClassId, assetId, investorAddress)
struct UserOrder {
    // @dev Index of epoch in which last order was made
    EpochId lastEpochIdOrdered;
    // @dev Amount of pending deposit request in asset denomination
    AssetAmount pendingDepositRequest;
    // @dev Amount of pending redeem request in share class denomination
    ShareClassAmount pendingRedeemRequest;
}

interface IShareClassManager {
    /// Events
    event NewEpoch(PoolId poolId, ShareClassId shareClassId, EpochId current);
    event AllowedAsset(PoolId indexed poolId, ShareClassId indexed shareClassId, AssetId indexed assetId);
    event UpdatedDepositRequest(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        EpochId indexed epoch,
        address investor,
        AssetAmount prevAmount,
        AssetAmount updatedAmount,
        AssetId assetId
    );
    event UpdatedRedemptionRequest(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        EpochId indexed epoch,
        address investor,
        ShareClassAmount prevAmount,
        ShareClassAmount updatedAmount,
        AssetId payoutAssetId
    );
    event ApprovedDepositRequests(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        EpochId indexed epoch,
        AssetId assetId,
        Ratio approvalRatio,
        PoolAmount approvedPoolAmount,
        AssetAmount approvedAssetAmount,
        AssetAmount pending,
        Ratio assetToPool
    );
    event ApprovedRedemptionRequests(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        EpochId indexed epoch,
        AssetId assetId,
        Ratio approvalRatio,
        PoolAmount approvedPoolAmount,
        ShareClassAmount approvedShareClassAmount,
        ShareClassAmount pending,
        Ratio shareClassToPool
    );
    event IssuedShares(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        EpochId indexed epoch,
        PoolAmount nav,
        ShareClassAmount issuedShares,
        PoolAmount poolAmount
    );
    event RevokedShares(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        EpochId indexed epoch,
        PoolAmount nav,
        ShareClassAmount revokedShares,
        PoolAmount poolAmount
    );
    event ClaimedDeposit(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        EpochId indexed epoch,
        address investor,
        AssetId assetId,
        AssetAmount approvedAssetAmount,
        PoolAmount approvedPoolAmount,
        AssetAmount pendingAssetAmount,
        PoolAmount pendingPoolAmount,
        ShareClassAmount claimedShareAmount
    );
    event ClaimedRedemption(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        EpochId indexed epoch,
        address investor,
        ShareClassAmount approvedShareClassAmount,
        PoolAmount approvedPoolAmount,
        ShareClassAmount pendingShareClassAmount,
        PoolAmount pendingPoolAmount,
        AssetId assetId,
        AssetAmount claimedAssetAmount
    );
    event UpdatedNav(
        PoolId indexed poolId,
        ShareClassId indexed shareClassId,
        EpochId indexed epoch,
        PoolAmount prevAmount,
        PoolAmount newAmount
    );
    event AddedShareClass(PoolId indexed poolId, ShareClassId indexed shareClassId, string metadata);

    /// Errors
    error PoolMissing(PoolId poolId);
    error ShareClassMissing(PoolId poolId, ShareClassId shareClassId);
    error AssetNotAllowed(PoolId poolId, ShareClassId shareClassId, AssetId assetId);
    error InvestorNotAllowed(PoolId poolId, ShareClassId shareClassId, AssetId assetId, address investor);
    error ClaimDepositRequired(PoolId poolId, ShareClassId shareClassId, AssetId assetId, address investor);
    error ClaimRedemptionRequired(PoolId poolId, ShareClassId shareClassId, AssetId assetId, address investor);
    error ShareClassAddingNotAllowed(PoolId poolId);
    error EpochNotFound(PoolId poolId, ShareClassId shareClassId, EpochId epochId);

    /// Functions
    // TODO(@review): Check whether bidirectionality (deposit, redeem) is implementation specific
    /// @notice Allow an asset to used as payment for deposit request and payout for redemption requests a deposit for
    /// the given share class id.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param assetId Identifier of the asset
    function allowAsset(PoolId poolId, ShareClassId shareClassId, AssetId assetId) external;

    /// @notice Creates or updates a request to deposit (exchange) an asset amount for share class tokens.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param amount Asset token amount which is deposited
    /// @param investor Address of the entity which is depositing
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    function requestDeposit(
        PoolId poolId,
        ShareClassId shareClassId,
        AssetAmount amount,
        address investor,
        AssetId depositAssetId
    ) external;

    /// @notice Creates or updates a request to redeem (exchange) share class tokens for some asset.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param amount Share class token amount which should be redeemed
    /// @param investor Address of the entity which is redeeming
    /// @param payoutAssetId Identifier of the asset which the investor eventually receives back for their redeemed
    /// share class tokens
    function requestRedemption(
        PoolId poolId,
        ShareClassId shareClassId,
        ShareClassAmount amount,
        address investor,
        AssetId payoutAssetId
    ) external;

    /// @notice Approves a percentage of all deposit requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param approvalRatio Percentage of approved requests
    /// @param paymentAssetId Identifier of the asset locked for the deposit request
    /// @param paymentAssetPrice Price ratio of asset amount to pool amount
    /// @return approved Sum of deposit request amounts in pool amount which was approved
    /// @return pending Sum of deposit request amounts in asset amount which was not approved
    function approveDepositRequests(
        PoolId poolId,
        ShareClassId shareClassId,
        Ratio approvalRatio,
        AssetId paymentAssetId,
        Ratio paymentAssetPrice
    ) external returns (PoolAmount approved, AssetAmount pending);

    /// @notice Approves a percentage of all redemption requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param approvalRatio Percentage of approved requests
    /// @param payoutAssetId Identifier of the asset for which all requests want to exchange their share class tokens
    /// for
    /// @param payoutAssetPrice Price ratio of share class token amount to pool amount
    /// @return approved Sum of redemption request amounts in pool amount which was approved
    /// @return pending Sum of redemption request amounts in share class token amount which was not approved
    function approveRedemptionRequests(
        PoolId poolId,
        ShareClassId shareClassId,
        Ratio approvalRatio,
        AssetId payoutAssetId,
        Ratio payoutAssetPrice
    ) external returns (PoolAmount approved, ShareClassAmount pending);

    /// @notice Emits new shares for the given identifier based on the provided NAV.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param nav Total value of assets of the pool and share class
    function issueShares(PoolId poolId, ShareClassId shareClassId, PoolAmount nav) external;

    /// @notice Take back shares for the given identifier based on the provided NAV.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param nav Total value of assets of the pool and share class
    function revokeShares(PoolId poolId, ShareClassId shareClassId, PoolAmount nav) external;

    /// @notice Collects shares for an investor after their deposit request was (partially) approved and new shares were
    /// issued.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param investor Address of the recipient address of the share class tokens
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    /// @return payout Amount of shares which the investor receives
    function claimDeposit(PoolId poolId, ShareClassId shareClassId, address investor, AssetId depositAssetId)
        external
        returns (ShareClassAmount payout);

    /// @notice Collects an asset amount for an investor after their redeem request was (partially) approved and shares
    /// were revoked.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param investor Address of the recipient address of the asset amount
    /// @param depositAssetId Identifier of the asset which the investor requested to receive back for their redeemed
    /// shares
    /// @return payout Asset amount which the investor receives
    function claimRedemption(PoolId poolId, ShareClassId shareClassId, address investor, AssetId depositAssetId)
        external
        returns (AssetAmount payout);

    /// @notice Updates the NAV of a share class of a pool and returns it.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @return nav Total value of assets of the pool and share class post updating
    function updateShareClassNav(PoolId poolId, ShareClassId shareClassId) external returns (PoolAmount nav);

    /// @notice Updates the NAV of a pool for all share classes and returns it.
    ///
    /// @param poolId Identifier of the pool
    /// @return nav Total value of assets of the pool post updating
    function updatePoolNav(PoolId poolId) external returns (PoolAmount nav);

    /// @notice Adds a new share class to the given pool.
    ///
    /// @param poolId Identifier of the pool
    /// @param data Data of the new share class
    /// @return shareClassId Identifier of the newly added share class
    function addShareClass(PoolId poolId, bytes memory data) external returns (ShareClassId shareClassId);

    // TODO(@review): Check whether bidirectionality (deposit, redeem) is implementation specific
    /// @notice Returns whether the given asset can be used to request a deposit for the given share class id. If an
    /// asset is allowed for a deposit request, it is automatically allowed as payout asset for redemptions of the given
    /// share class id.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param assetId Identifier of the asset
    /// @return bool Whether the asset was allowed as payment for deposit and payout for redemption requests.
    function isAllowedAsset(PoolId poolId, ShareClassId shareClassId, AssetId assetId) external view returns (bool);

    /// @notice Returns the current NAV of a share class of a pool.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @return nav Total value of assets of the pool and share class
    function getShareClassNav(PoolId poolId, ShareClassId shareClassId) external view returns (PoolAmount nav);

    // TODO(@review): Check if necessary (i.e. does getShareClassNav suffice?)
    /// @notice Returns the current NAV of an entire pool
    ///
    /// @param poolId Identifier of the pool
    /// @return nav Total value of assets of the pool
    function getPoolNav(PoolId poolId) external view returns (PoolAmount nav);
}
