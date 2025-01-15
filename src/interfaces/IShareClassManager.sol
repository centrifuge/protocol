// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/types/D18.sol";
import {IERC7726Ext} from "src/interfaces/IERC7726.sol";
import {PoolId} from "src/types/PoolId.sol";

interface IShareClassManager {
    /// Events
    event NewEpoch(PoolId poolId, uint32 newIndex);
    event UpdatedDepositRequest(
        PoolId indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        address investor,
        address assetId,
        uint256 updatedAmountUser,
        uint256 updatedAmountTotal
    );
    event UpdatedRedeemRequest(
        PoolId indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        address investor,
        address payoutAssetId,
        uint256 updatedAmountUser,
        uint256 updatedAmountTotal
    );
    event ApprovedDeposits(
        PoolId indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        address assetId,
        D18 approvalRatio,
        uint256 approvedPoolAmount,
        uint256 approvedAssetAmount,
        uint256 pendingAssetAmount,
        D18 assetToPool
    );
    event ApprovedRedeems(
        PoolId indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        address assetId,
        D18 approvalRatio,
        uint256 approvedShareClassAmount,
        uint256 pending,
        D18 assetToPool
    );
    event IssuedShares(
        PoolId indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        D18 navPerShare,
        uint256 nav,
        uint256 issuedShareAmount
    );

    event RevokedShares(
        PoolId indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        D18 navPerShare,
        uint256 nav,
        uint256 revokedShareAmount
    );

    event ClaimedDeposit(
        PoolId indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        address investor,
        address assetId,
        uint256 approvedAssetAmount,
        uint256 pendingAssetAmount,
        uint256 claimedShareAmount
    );
    event ClaimedRedeem(
        PoolId indexed poolId,
        bytes16 indexed shareClassId,
        uint32 indexed epoch,
        address investor,
        address assetId,
        uint256 approvedShareClassAmount,
        uint256 pendingShareClassAmount,
        uint256 claimedAssetAmount
    );
    event UpdatedNav(PoolId indexed poolId, bytes16 indexed shareClassId, uint256 newAmount);
    event AddedShareClass(PoolId indexed poolId, bytes16 indexed shareClassId, string metadata);

    /// Errors
    error PoolMissing();
    error ShareClassNotFound();
    error MaxShareClassNumberExceeded(uint8 numberOfShareClasses);
    error ClaimDepositRequired();
    error ClaimRedeemRequired();
    error EpochNotFound();

    /// Functions

    /// @notice Creates or updates a request to deposit (exchange) an asset amount for share class tokens.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param amount Asset token amount which is deposited
    /// @param investor Address of the entity which is depositing
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    function requestDeposit(
        PoolId poolId,
        bytes16 shareClassId,
        uint256 amount,
        address investor,
        address depositAssetId
    ) external;

    /// @notice Cancels a pending deposit request.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param investor Address of the entity which is depositing
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    function cancelDepositRequest(PoolId poolId, bytes16 shareClassId, address investor, address depositAssetId)
        external;

    /// @notice Creates or updates a request to redeem (exchange) share class tokens for some asset.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param amount Share class token amount which should be redeemed
    /// @param investor Address of the entity which is redeeming
    /// @param payoutAssetId Identifier of the asset which the investor eventually receives back for their redeemed
    /// share class tokens
    function requestRedeem(PoolId poolId, bytes16 shareClassId, uint256 amount, address investor, address payoutAssetId)
        external;

    /// @notice Cancels a pending redeem request.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param investor Address of the entity which is redeeming
    /// @param payoutAssetId Identifier of the asset which the investor eventually receives back for their redeemed
    /// share class tokens
    function cancelRedeemRequest(PoolId poolId, bytes16 shareClassId, address investor, address payoutAssetId)
        external;

    /// @notice Approves a percentage of all deposit requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param approvalRatio Percentage of approved requests
    /// @param paymentAssetId Identifier of the asset locked for the deposit request
    /// @param valuation Converter for quotas, e.g. price ratio of asset amount to pool amount
    /// @return approvedPoolAmount Sum of deposit request amounts in pool amount which was approved
    /// @return approvedAssetAmount Sum of deposit request amounts in asset amount which was not approved
    function approveDeposits(
        PoolId poolId,
        bytes16 shareClassId,
        D18 approvalRatio,
        address paymentAssetId,
        IERC7726Ext valuation
    ) external returns (uint256 approvedPoolAmount, uint256 approvedAssetAmount);

    /// @notice Approves a percentage of all redemption requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param approvalRatio Percentage of approved requests
    /// @param payoutAssetId Identifier of the asset for which all requests want to exchange their share class tokens
    /// for
    /// @param valuation Converter for quotas, e.g. price ratio of share class token amount to pool amount
    /// @return approvedShareAmount Sum of redemption request amounts in pool amount which was approved
    /// @return pendingShareAmount Sum of redemption request amounts in share class token amount which was not approved
    function approveRedeems(
        PoolId poolId,
        bytes16 shareClassId,
        D18 approvalRatio,
        address payoutAssetId,
        IERC7726Ext valuation
    ) external returns (uint256 approvedShareAmount, uint256 pendingShareAmount);

    /// @notice Emits new shares for the given identifier based on the provided NAV per share.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param depositAssetId Identifier of the deposit asset for which shares should be issued
    /// @param navPerShare Total value of assets of the pool and share class per share
    function issueShares(PoolId poolId, bytes16 shareClassId, address depositAssetId, D18 navPerShare) external;

    /// @notice Take back shares for the given identifier based on the provided NAV per share.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param payoutAssetId Identifier of the payout asset
    /// @param navPerShare Total value of assets of the pool and share class per share
    /// @return payoutAssetAmount Converted amount of payout asset based on number of revoked shares
    /// @return payoutPoolAmount Converted amount of pool currency based on number of revoked shares
    function revokeShares(PoolId poolId, bytes16 shareClassId, address payoutAssetId, D18 navPerShare)
        external
        returns (uint256 payoutAssetAmount, uint256 payoutPoolAmount);

    /// @notice Collects shares for an investor after their deposit request was (partially) approved and new shares were
    /// issued.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param investor Address of the recipient address of the share class tokens
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    /// @return payoutShareAmount Amount of shares which the investor receives
    /// @return paymentAssetAmount Amount of deposit asset which was taken as payment
    function claimDeposit(PoolId poolId, bytes16 shareClassId, address investor, address depositAssetId)
        external
        returns (uint256 payoutShareAmount, uint256 paymentAssetAmount);

    /// @notice Collects an asset amount for an investor after their redeem request was (partially) approved and shares
    /// were revoked.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param investor Address of the recipient address of the asset amount
    /// @param payoutAssetId Identifier of the asset which the investor requested to receive back for their redeemed
    /// shares
    /// @return payoutAssetAmount Amount of payout amount which the investor receives
    /// @return paymentShareAmount Amount of shares which the investor redeemed
    function claimRedeem(PoolId poolId, bytes16 shareClassId, address investor, address payoutAssetId)
        external
        returns (uint256 payoutAssetAmount, uint256 paymentShareAmount);

    /// @notice Updates the NAV of a share class of a pool and returns it per share as well as the issuance.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @return navPerShare Total value of assets of the pool and share class per share
    /// @return issuance Total issuance of the share class
    function updateShareClassNav(PoolId poolId, bytes16 shareClassId)
        external
        returns (D18 navPerShare, uint256 issuance);

    /// @notice Generic update function for a pool.
    ///
    /// @param poolId Identifier of the pool
    /// @param data Payload of the update
    function update(PoolId poolId, bytes calldata data) external;

    /// @notice Adds a new share class to the given pool.
    ///
    /// @param poolId Identifier of the pool
    /// @param data Data of the new share class
    /// @return shareClassId Identifier of the newly added share class
    function addShareClass(PoolId poolId, bytes calldata data) external returns (bytes16 shareClassId);

    /// @notice Returns the current NAV of a share class of a pool per share as well as the issuance.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @return navPerShare Total value of assets of the pool and share class per share
    /// @return issuance Total issuance of the share class
    function shareClassNavPerShare(PoolId poolId, bytes16 shareClassId)
        external
        view
        returns (D18 navPerShare, uint256 issuance);
}
