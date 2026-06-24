// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../../src/misc/types/D18.sol";

import {AssetId} from "../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

import {ManagerAction} from "../../../src/vaults/interfaces/IBatchRequestManager.sol";

/// @notice Test helper encoding `BatchRequestManager.fromHub` payloads. Mirrors the per-action
///         `abi.decode` order in `BatchRequestManager.fromHub`. Single source of truth for the
///         wire format shared by unit, integration, recon, and script call sites.
/// @dev    Payload layout: `abi.encode(uint8 kind, bytes16 scId, ...action args)`. `scId` is folded
///         into the payload (prepend-once, after the action tag) since `fromHub` drops it from the
///         signature.
library BatchRequestManagerCallLib {
    function approveDeposits(
        ShareClassId scId,
        AssetId assetId,
        uint32 epoch,
        uint128 approvedAssetAmount,
        D18 price,
        address refund
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(ManagerAction.ApproveDeposits),
            scId.raw(),
            assetId.raw(),
            epoch,
            approvedAssetAmount,
            price.raw(),
            refund
        );
    }

    function approveRedeems(ShareClassId scId, AssetId assetId, uint32 epoch, uint128 approvedShareAmount, D18 price)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            uint8(ManagerAction.ApproveRedeems), scId.raw(), assetId.raw(), epoch, approvedShareAmount, price.raw()
        );
    }

    function issueShares(
        ShareClassId scId,
        AssetId assetId,
        uint32 epoch,
        D18 price,
        uint128 extraGasLimit,
        address refund
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(ManagerAction.IssueShares), scId.raw(), assetId.raw(), epoch, price.raw(), extraGasLimit, refund
        );
    }

    function revokeShares(
        ShareClassId scId,
        AssetId assetId,
        uint32 epoch,
        D18 price,
        uint128 extraGasLimit,
        address refund
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(ManagerAction.RevokeShares), scId.raw(), assetId.raw(), epoch, price.raw(), extraGasLimit, refund
        );
    }

    function forceCancelDepositRequest(ShareClassId scId, bytes32 investor, AssetId assetId, address refund)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(uint8(ManagerAction.ForceCancelDepositRequest), scId.raw(), investor, assetId.raw(), refund);
    }

    function forceCancelRedeemRequest(ShareClassId scId, bytes32 investor, AssetId assetId, address refund)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(uint8(ManagerAction.ForceCancelRedeemRequest), scId.raw(), investor, assetId.raw(), refund);
    }
}
