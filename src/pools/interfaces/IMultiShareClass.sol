// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

interface IMultiShareClass is IShareClassManager {
    /// Events
    event File(bytes32 what, address who);
    event AddedShareClass(
        PoolId indexed poolId, ShareClassId indexed scId, uint32 indexed index, string name, string symbol, bytes32 salt
    );
    event UpdatedMetadata(PoolId indexed poolId, ShareClassId indexed scId, string name, string symbol, bytes32 salt);

    /// Errors
    error ApprovalRequired();
    error AlreadyApproved();
    error UnrecognizedFileParam();
    error ZeroApprovalAmount();
    error InvalidMetadataSize();
    error InvalidMetadataName();
    error InvalidMetadataSymbol();
    error InvalidSalt();
    error AlreadyUsedSalt();
    error RevokeMoreThanIssued();

    /// @notice Emits new shares for the given identifier based on the provided NAV up to the desired epoch.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param navPerShare Total value of assets of the pool and share class per share
    /// @param endEpochId Identifier of the maximum epoch until which shares are issued
    function issueSharesUntilEpoch(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        D18 navPerShare,
        uint32 endEpochId
    ) external;

    /// @notice Revokes shares for an epoch span and sets the price based on amount of approved redemption shares and
    /// the provided NAV.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param payoutAssetId Identifier of the payout asset
    /// @param navPerShare Total value of assets of the pool and share class per share
    /// @param valuation Source of truth for quotas, e.g. the price of a share class token amount to pool amount
    /// @param endEpochId Identifier of the maximum epoch until which shares are revoked
    /// @return payoutAssetAmount Converted amount of payout asset based on number of revoked shares
    /// @return payoutPoolAmount Converted amount of pool currency based on number of revoked shares
    function revokeSharesUntilEpoch(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        D18 navPerShare,
        IERC7726 valuation,
        uint32 endEpochId
    ) external returns (uint128 payoutAssetAmount, uint128 payoutPoolAmount);

    /// @notice Collects shares for an investor after their deposit request was (partially) approved and new shares were
    /// issued until the provided epoch.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param investor Centrifuge Vault address of the recipient of the claimed share class tokens
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    /// @param endEpochId Identifier of the maximum epoch until it is claimed claim
    /// @return payoutShareAmount Amount of shares which the investor receives
    /// @return paymentAssetAmount Amount of deposit asset which was taken as payment
    function claimDepositUntilEpoch(
        PoolId poolId,
        ShareClassId scId,
        bytes32 investor,
        AssetId depositAssetId,
        uint32 endEpochId
    ) external returns (uint128 payoutShareAmount, uint128 paymentAssetAmount);

    /// @notice Reduces the share class token count of the investor in exchange for collecting an amount of payment
    /// asset for the specified range of epochs.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param investor Centrifuge Vault address of the recipient of the claimed payout asset amount
    /// @param payoutAssetId Identifier of the asset which the investor committed to as payout when requesting the
    /// redemption
    /// @param endEpochId Identifier of the maximum epoch until it is claimed claim
    /// @return payoutAssetAmount Amount of payout asset which the investor receives
    /// @return paymentShareAmount Amount of shares which the investor redeemed
    function claimRedeemUntilEpoch(
        PoolId poolId,
        ShareClassId scId,
        bytes32 investor,
        AssetId payoutAssetId,
        uint32 endEpochId
    ) external returns (uint128 payoutAssetAmount, uint128 paymentShareAmount);

    /// @notice returns The metadata of the share class.
    ///
    /// @param scId Identifier of the share class
    /// @return name The registered name of the share class token
    /// @return symbol The registered symbol of the share class token
    /// @return salt The registered salt of the share class token, used for deterministic deployments
    function metadata(ShareClassId scId) external returns (string memory name, string memory symbol, bytes32 salt);
}
