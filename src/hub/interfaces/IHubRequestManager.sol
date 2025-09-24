// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

interface IHubRequestManager {
    /// @notice Handles a request originating from the Hub side, similar to HubHelpers.request
    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external;

    function claimDeposit(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        returns (
            uint128 payoutShareAmount,
            uint128 paymentAssetAmount,
            uint128 cancelledAssetAmount,
            bool canClaimAgain
        );

    function claimRedeem(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external
        returns (
            uint128 payoutAssetAmount,
            uint128 paymentShareAmount,
            uint128 cancelledShareAmount,
            bool canClaimAgain
        );
}
