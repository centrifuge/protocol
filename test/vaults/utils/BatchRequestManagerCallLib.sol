// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../../src/misc/types/D18.sol";

import {AssetId} from "../../../src/core/types/AssetId.sol";

import {ManagerAction} from "../../../src/vaults/interfaces/IBatchRequestManager.sol";

/// @notice Test helper encoding `BatchRequestManager.trustedCall` payloads. Mirrors the per-action
///         `abi.decode` order in `BatchRequestManager.trustedCall`. Single source of truth for the
///         wire format shared by unit, integration, recon, and script call sites.
library BatchRequestManagerCallLib {
    function approveDeposits(AssetId assetId, uint32 epoch, uint128 approvedAssetAmount, D18 price, address refund)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            uint8(ManagerAction.ApproveDeposits), assetId.raw(), epoch, approvedAssetAmount, price.raw(), refund
        );
    }

    function approveRedeems(AssetId assetId, uint32 epoch, uint128 approvedShareAmount, D18 price)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(uint8(ManagerAction.ApproveRedeems), assetId.raw(), epoch, approvedShareAmount, price.raw());
    }

    function issueShares(AssetId assetId, uint32 epoch, D18 price, uint128 extraGasLimit, address refund)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(uint8(ManagerAction.IssueShares), assetId.raw(), epoch, price.raw(), extraGasLimit, refund);
    }

    function revokeShares(AssetId assetId, uint32 epoch, D18 price, uint128 extraGasLimit, address refund)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(uint8(ManagerAction.RevokeShares), assetId.raw(), epoch, price.raw(), extraGasLimit, refund);
    }

    function forceCancelDepositRequest(bytes32 investor, AssetId assetId, address refund)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(uint8(ManagerAction.ForceCancelDepositRequest), investor, assetId.raw(), refund);
    }

    function forceCancelRedeemRequest(bytes32 investor, AssetId assetId, address refund)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(uint8(ManagerAction.ForceCancelRedeemRequest), investor, assetId.raw(), refund);
    }
}
