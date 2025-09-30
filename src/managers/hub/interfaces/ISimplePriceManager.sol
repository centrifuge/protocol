// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISimplePriceManagerBase} from "./ISimplePriceManagerBase.sol";

import {PoolId} from "../../../common/types/PoolId.sol";
import {AssetId} from "../../../common/types/AssetId.sol";
import {ShareClassId} from "../../../common/types/ShareClassId.sol";

interface ISimplePriceManager is ISimplePriceManagerBase {
    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

    /// @notice Approve deposit requests for a given asset amount
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param depositAssetId The asset ID for deposits
    /// @param approvedAssetAmount Amount of assets to approve for deposit
    function approveDeposits(PoolId poolId, ShareClassId scId, AssetId depositAssetId, uint128 approvedAssetAmount)
        external;

    /// @notice Issue shares for approved deposit epochs
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param depositAssetId The asset ID for deposits
    /// @param extraGasLimit Extra gas limit for some computation that may need to happen on the remote chain
    function issueShares(PoolId poolId, ShareClassId scId, AssetId depositAssetId, uint128 extraGasLimit) external;

    /// @notice Approve redemption requests for a given share amount
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param payoutAssetId The asset ID for payouts
    /// @param approvedShareAmount Amount of shares to approve for redemption
    function approveRedeems(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, uint128 approvedShareAmount)
        external;

    /// @notice Revoke shares from approved redemption requests
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param payoutAssetId The asset ID for payouts
    /// @param extraGasLimit Extra gas limit for some computation that may need to happen on the remote chain
    function revokeShares(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, uint128 extraGasLimit) external;

    /// @notice Approve deposits and issue shares in sequence using current NAV per share
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param depositAssetId The asset ID for deposits
    /// @param approvedAssetAmount Amount of assets to approve
    /// @param extraGasLimit Extra gas limit for some computation that may need to happen on the remote chain
    function approveDepositsAndIssueShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint128 approvedAssetAmount,
        uint128 extraGasLimit
    ) external;

    /// @notice Approve redeems and revoke shares in sequence using current NAV per share
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param payoutAssetId The asset ID for payouts
    /// @param approvedShareAmount Amount of shares to approve for redemption
    /// @param extraGasLimit Extra gas limit for some computation that may need to happen on the remote chain
    function approveRedeemsAndRevokeShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint128 approvedShareAmount,
        uint128 extraGasLimit
    ) external;
}
