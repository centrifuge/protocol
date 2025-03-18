// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";

interface IShareClassManager {
    /// Events
    event NewEpoch(PoolId poolId, uint32 newIndex);
    event UpdatedDepositRequest(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        bytes32 investor,
        AssetId assetId,
        uint128 updatedAmountUser,
        uint128 updatedAmountTotal
    );
    event UpdatedRedeemRequest(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        bytes32 investor,
        AssetId payoutAssetId,
        uint128 updatedAmountUser,
        uint128 updatedAmountTotal
    );
    event ApprovedDeposits(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        AssetId assetId,
        uint128 approvedPoolAmount,
        uint128 approvedAssetAmount,
        uint128 pendingAssetAmount
    );
    event ApprovedRedeems(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        AssetId assetId,
        uint128 approvedShareClassAmount,
        uint128 pendingShareClassAmount
    );
    event IssuedShares(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        D18 navPerShare,
        uint128 nav,
        uint128 issuedShareAmount
    );

    event RevokedShares(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        D18 navPerShare,
        uint128 nav,
        uint128 revokedShareAmount,
        uint128 revokedAssetAmount
    );

    event ClaimedDeposit(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        bytes32 investor,
        AssetId assetId,
        uint128 approvedAssetAmount,
        uint128 pendingAssetAmount,
        uint128 claimedShareAmount
    );
    event ClaimedRedeem(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint32 indexed epoch,
        bytes32 investor,
        AssetId assetId,
        uint128 approvedShareClassAmount,
        uint128 pendingShareClassAmount,
        uint128 claimedAssetAmount
    );
    event UpdatedNav(PoolId indexed poolId, ShareClassId indexed scId, uint128 newAmount);
    event AddedShareClass(PoolId indexed poolId, ShareClassId indexed scId, uint32 indexed index);

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
    /// @param maxApproval Sum of deposit request amounts in asset amount which is desired to be approved
    /// @param paymentAssetId Identifier of the asset locked for the deposit request
    /// @param valuation Source of truth for quotas, e.g. the price of an asset amount to pool amount
    /// @return approvedAssetAmount Sum of deposit request amounts in pool amount which was approved bound to at most
    /// the total pending amount
    /// @return approvedPoolAmount Sum of deposit request amounts in pool amount which was approved
    function approveDeposits(
        PoolId poolId,
        ShareClassId scId,
        uint128 maxApproval,
        AssetId paymentAssetId,
        IERC7726 valuation
    ) external returns (uint128 approvedAssetAmount, uint128 approvedPoolAmount);

    /// @notice Approves a share class token amount of all redeem requests for the given triplet of pool id, share class
    /// id and payout asset id.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param maxApproval Sum of redeem request amounts in share class token amount which is desired to be approved
    /// @param payoutAssetId Identifier of the asset for which all requests want to exchange their share class tokens
    /// for
    /// @return approvedShareAmount Sum of redemption request amounts in share class token which was approved bound to
    /// at most the total pending amount
    /// @return pendingShareAmount Sum of redemption request amounts in share class token amount which was not approved
    function approveRedeems(PoolId poolId, ShareClassId scId, uint128 maxApproval, AssetId payoutAssetId)
        external
        returns (uint128 approvedShareAmount, uint128 pendingShareAmount);

    /// @notice Emits new shares for the given identifier based on the provided NAV per share.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param depositAssetId Identifier of the deposit asset for which shares should be issued
    /// @param navPerShare Total value of assets of the pool and share class per share
    function issueShares(PoolId poolId, ShareClassId scId, AssetId depositAssetId, D18 navPerShare) external;

    /// @notice Take back shares for the given identifier based on the provided NAV per share.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param payoutAssetId Identifier of the payout asset
    /// @param navPerShare Total value of assets of the pool and share class per share
    /// @param valuation Source of truth for quotas, e.g. the price of a share class token amount to pool amount
    /// @return payoutAssetAmount Converted amount of payout asset based on number of revoked shares
    /// @return payoutPoolAmount Converted amount of pool currency based on number of revoked shares
    function revokeShares(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation)
        external
        returns (uint128 payoutAssetAmount, uint128 payoutPoolAmount);

    /// @notice Collects shares for an investor after their deposit request was (partially) approved and new shares were
    /// issued.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param investor Centrifuge Vault address of the recipient of the claimed share class tokens
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    /// @return payoutShareAmount Amount of shares which the investor receives
    /// @return paymentAssetAmount Amount of deposit asset which was taken as payment
    function claimDeposit(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        returns (uint128 payoutShareAmount, uint128 paymentAssetAmount);

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
    function claimRedeem(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external
        returns (uint128 payoutAssetAmount, uint128 paymentShareAmount);

    /// @notice Updates the NAV of a share class of a pool and returns it per share as well as the issuance.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @return issuance Total issuance of the share class
    /// @return navPerShare Total value of assets of the pool and share class per share
    function updateShareClassNav(PoolId poolId, ShareClassId scId)
        external
        returns (uint128 issuance, D18 navPerShare);

    /// @notice Generic update function for a pool.
    ///
    /// @param poolId Identifier of the pool
    /// @param data Payload of the update
    function update(PoolId poolId, bytes calldata data) external;

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
}
