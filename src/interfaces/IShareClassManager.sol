// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IShareClassManager {
    /// Events
    event NewEpoch(uint64 poolId, uint32 newIndex);
    event AllowedAsset(uint64 indexed poolId, bytes16 indexed shareClassId, address indexed assetId);
    event UpdatedDepositRequest(
        uint64 indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        address investor,
        uint256 prevAmount,
        uint256 updatedAmount,
        address assetId
    );
    event UpdatedRedemptionRequest(
        uint64 indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        address investor,
        uint256 prevAmount,
        uint256 updatedAmount,
        address payoutAssetId
    );
    event ApprovedDeposits(
        uint64 indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        address assetId,
        uint128 approvalRatio,
        uint256 approvedPoolAmount,
        uint256 approvedAssetAmount,
        uint256 pendingAssetAmount,
        uint128 assetToPool
    );
    event ApprovedRedemptions(
        uint64 indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        address assetId,
        uint128 approvalRatio,
        uint256 approvedPoolAmount,
        uint256 approvedShareClassAmount,
        uint256 pending,
        uint128 shareClassToPool
    );
    event IssuedShares(
        uint64 indexed poolId, bytes16 indexed shareClassId, uint32 indexed epoch, uint256 nav, uint256 issuedShares
    );
    // uint256 poolAmount

    event RevokedShares(
        uint64 indexed poolId, bytes16 indexed shareClassId, uint32 indexed epoch, uint256 nav, uint256 revokedShares
    );
    // uint256 poolAmount

    event ClaimedDeposit(
        uint64 indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        address investor,
        address assetId,
        uint256 approvedAssetAmount,
        uint256 pendingAssetAmount,
        uint256 claimedShareAmount
    );
    event ClaimedRedemption(
        uint64 indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        address investor,
        uint256 approvedShareClassAmount,
        uint256 approvedPoolAmount,
        uint256 pendingShareClassAmount,
        uint256 pendingPoolAmount,
        address assetId,
        uint256 claimedAssetAmount
    );
    event UpdatedNav(
        uint64 indexed poolId, bytes16 indexed shareClassId, uint32 indexed epoch, uint256 prevAmount, uint256 newAmount
    );
    event AddedShareClass(uint64 indexed poolId, bytes16 indexed shareClassId, string metadata);

    /// Errors
    error PoolMissing(uint64 poolId);
    error ShareClassMismatch(uint64 poolId, bytes16 shareClassId);
    error MaxShareClassNumberExceeded(uint64 poolId, uint64 numberOfShareClasses);
    error AssetNotAllowed(uint64 poolId, bytes16 shareClassId, address assetId);
    error InvestorNotAllowed(uint64 poolId, bytes16 shareClassId, address assetId, address investor);
    error ClaimDepositRequired(uint64 poolId, bytes16 shareClassId, address assetId, address investor);
    error ClaimRedemptionRequired(uint64 poolId, bytes16 shareClassId, address assetId, address investor);
    error EpochNotFound(uint64 poolId, uint32 epochId);

    /// Functions
    // TODO(@review): Check whether bidirectionality (deposit, redeem) is implementation specific
    /// @notice Allow an asset to used as payment for deposit request and payout for redemption requests a deposit for
    /// the given share class id.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param assetId Identifier of the asset
    function allowAsset(uint64 poolId, bytes16 shareClassId, address assetId) external;

    /// @notice Creates or updates a request to deposit (exchange) an asset amount for share class tokens.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param amount Asset token amount which is deposited
    /// @param investor Address of the entity which is depositing
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    function requestDeposit(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 amount,
        address investor,
        address depositAssetId
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
        uint64 poolId,
        bytes16 shareClassId,
        uint256 amount,
        address investor,
        address payoutAssetId
    ) external;

    /// @notice Approves a percentage of all deposit requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param approvalRatio Percentage of approved requests
    /// @param paymentAssetId Identifier of the asset locked for the deposit request
    /// @param paymentAssetPrice Price ratio of asset amount to pool amount
    /// @return approvedPoolAmount Sum of deposit request amounts in pool amount which was approved
    /// @return approvedAssetAmount Sum of deposit request amounts in asset amount which was not approved
    function approveDeposits(
        uint64 poolId,
        bytes16 shareClassId,
        uint128 approvalRatio,
        address paymentAssetId,
        uint128 paymentAssetPrice
    ) external returns (uint256 approvedPoolAmount, uint256 approvedAssetAmount);

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
    function approveRedemptions(
        uint64 poolId,
        bytes16 shareClassId,
        uint128 approvalRatio,
        address payoutAssetId,
        uint128 payoutAssetPrice
    ) external returns (uint256 approved, uint256 pending);

    /// @notice Emits new shares for the given identifier based on the provided NAV.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param nav Total value of assets of the pool and share class
    function issueShares(uint64 poolId, bytes16 shareClassId, uint256 nav) external;

    /// @notice Take back shares for the given identifier based on the provided NAV.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param nav Total value of assets of the pool and share class
    function revokeShares(uint64 poolId, bytes16 shareClassId, uint256 nav) external;

    /// @notice Collects shares for an investor after their deposit request was (partially) approved and new shares were
    /// issued.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param investor Address of the recipient address of the share class tokens
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    /// @return payout Amount of shares which the investor receives
    function claimDeposit(uint64 poolId, bytes16 shareClassId, address investor, address depositAssetId)
        external
        returns (uint256 payout);

    /// @notice Collects an asset amount for an investor after their redeem request was (partially) approved and shares
    /// were revoked.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param investor Address of the recipient address of the asset amount
    /// @param depositAssetId Identifier of the asset which the investor requested to receive back for their redeemed
    /// shares
    /// @return payout Asset amount which the investor receives
    function claimRedemption(uint64 poolId, bytes16 shareClassId, address investor, address depositAssetId)
        external
        returns (uint256 payout);

    /// @notice Updates the NAV of a share class of a pool and returns it.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param navCorrection Manual correction of the NAV
    /// @return nav Total value of assets of the pool and share class post updating
    function updateShareClassNav(uint64 poolId, bytes16 shareClassId, int256 navCorrection)
        external
        returns (uint256 nav);

    /// @notice Adds a new share class to the given pool.
    ///
    /// @param poolId Identifier of the pool
    /// @param data Data of the new share class
    /// @return shareClassId Identifier of the newly added share class
    function addShareClass(uint64 poolId, bytes memory data) external returns (bytes16 shareClassId);

    // TODO(@review): Check whether bidirectionality (deposit, redeem) is implementation specific
    /// @notice Returns whether the given asset can be used to request a deposit for the given share class id. If an
    /// asset is allowed for a deposit request, it is automatically allowed as payout asset for redemptions of the given
    /// share class id.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param assetId Identifier of the asset
    /// @return bool Whether the asset was allowed as payment for deposit and payout for redemption requests.
    function isAllowedAsset(uint64 poolId, bytes16 shareClassId, address assetId) external view returns (bool);

    /// @notice Returns the current NAV of a share class of a pool.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @return nav Total value of assets of the pool and share class
    function getShareClassNav(uint64 poolId, bytes16 shareClassId) external view returns (uint256 nav);
}
