// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/types/D18.sol";
import {PoolId} from "src/types/PoolId.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";

interface ISingleShareClass is IShareClassManager {
    /// Events
    event File(bytes32 what, address who);

    /// Errors
    error ApprovalRequired();
    error AlreadyApproved();
    error UnrecognizedFileParam();
    error MaxApprovalRatioExceeded();

    /// @notice Emits new shares for the given identifier based on the provided NAV up to the desired epoch.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param navPerShare Total value of assets of the pool and share class per share
    /// @param endEpochId Identifier of the maximum epoch until which shares are issued
    function issueSharesUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId,
        address depositAssetId,
        D18 navPerShare,
        uint32 endEpochId
    ) external;

    /// @notice Revokes shares for an epoch span and sets the price based on amount of approved redemption shares and
    /// the
    /// provided NAV.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param payoutAssetId Identifier of the payout asset
    /// @param navPerShare Total value of assets of the pool and share class per share
    /// @param endEpochId Identifier of the maximum epoch until which shares are revoked
    /// @return payoutAssetAmount Converted amount of payout asset based on number of revoked shares
    /// @return payoutPoolAmount Converted amount of pool currency based on number of revoked shares
    function revokeSharesUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId,
        address payoutAssetId,
        D18 navPerShare,
        uint32 endEpochId
    ) external returns (uint128 payoutAssetAmount, uint128 payoutPoolAmount);

    /// @notice Collects shares for an investor after their deposit request was (partially) approved and new shares were
    /// issued until the provided epoch.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param investor Address of the recipient of the share class tokens
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    /// @param endEpochId Identifier of the maximum epoch until it is claimed claim
    /// @return payoutShareAmount Amount of shares which the investor receives
    /// @return paymentAssetAmount Amount of deposit asset which was taken as payment
    function claimDepositUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId,
        address investor,
        address depositAssetId,
        uint32 endEpochId
    ) external returns (uint128 payoutShareAmount, uint128 paymentAssetAmount);

    /// @notice Reduces the share class token count of the investor in exchange for collecting an amount of payment
    /// asset for the specified range of epochs.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param investor Address of the recipient of the payout asset
    /// @param payoutAssetId Identifier of the asset which the investor committed to as payout when requesting the
    /// redemption
    /// @param endEpochId Identifier of the maximum epoch until it is claimed claim
    /// @return payoutAssetAmount Amount of payout asset which the investor receives
    /// @return paymentShareAmount Amount of shares which the investor redeemed
    function claimRedeemUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId,
        address investor,
        address payoutAssetId,
        uint32 endEpochId
    ) external returns (uint128 payoutAssetAmount, uint128 paymentShareAmount);
}
