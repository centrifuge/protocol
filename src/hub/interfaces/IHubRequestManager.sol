// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC165} from "../../misc/interfaces/IERC165.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

interface IHubRequestManager is IERC165 {
    /// @notice Handles a request originating from the Hub side, similar to HubHelpers.request
    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external;
}

interface IHubRequestManagerNotifications is IERC165 {
    /// @notice Notify a deposit for an investor address located in the chain where the asset belongs
    function notifyDeposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        bytes32 investor,
        uint32 maxClaims
    ) external payable returns (uint256 cost);

    /// @notice Notify a redemption for an investor address located in the chain where the asset belongs
    function notifyRedeem(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, bytes32 investor, uint32 maxClaims)
        external
        payable
        returns (uint256 cost);

    /// @notice Claims a cancelled deposit request
    /// @dev Only works for immediate cancellations. Queued cancellations use notifyDeposit
    function notifyCancelDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor)
        external
        payable
        returns (uint256 cost);

    /// @notice Claims a cancelled redeem request
    /// @dev Only works for immediate cancellations. Queued cancellations use notifyRedeem
    function notifyCancelRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor)
        external
        payable
        returns (uint256 cost);
}
