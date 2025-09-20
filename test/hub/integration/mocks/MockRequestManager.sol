// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../../../src/misc/types/D18.sol";
import {PoolId} from "../../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../../src/common/types/ShareClassId.sol";
import {IHubRequestManager} from "../../../../src/hub/interfaces/IHubRequestManager.sol";

contract MockRequestManager is IHubRequestManager {
    uint32 private constant MOCK_EPOCH = 1;

    function request(PoolId, ShareClassId, AssetId, bytes calldata) external override {}

    function requestDeposit(PoolId, ShareClassId, uint128, bytes32, AssetId) external override {}

    function cancelDepositRequest(PoolId, ShareClassId, bytes32, AssetId) external override returns (uint128) {
        return 0;
    }

    function requestRedeem(PoolId, ShareClassId, uint128, bytes32, AssetId) external override {}

    function cancelRedeemRequest(PoolId, ShareClassId, bytes32, AssetId) external override returns (uint128) {
        return 0;
    }

    function approveDeposits(PoolId, ShareClassId, AssetId, uint32, uint128, D18) external override returns (uint256) {
        return 0;
    }

    function approveRedeems(PoolId, ShareClassId, AssetId, uint32, uint128, D18) external override {}

    function issueShares(PoolId, ShareClassId, AssetId, uint32, D18, uint128) external override returns (uint256) {
        return 0;
    }

    function revokeShares(PoolId, ShareClassId, AssetId, uint32, D18, uint128) external override returns (uint256) {
        return 0;
    }

    function forceCancelDepositRequest(PoolId, ShareClassId, bytes32, AssetId) external override returns (uint256) {
        return 0;
    }

    function forceCancelRedeemRequest(PoolId, ShareClassId, bytes32, AssetId) external override returns (uint256) {
        return 0;
    }

    function claimDeposit(PoolId, ShareClassId, bytes32, AssetId)
        external
        override
        returns (uint128, uint128, uint128, bool)
    {
        return (0, 0, 0, false);
    }

    function claimRedeem(PoolId, ShareClassId, bytes32, AssetId)
        external
        override
        returns (uint128, uint128, uint128, bool)
    {
        return (0, 0, 0, false);
    }

    function nowDepositEpoch(ShareClassId, AssetId) external pure override returns (uint32) {
        return MOCK_EPOCH;
    }

    function nowIssueEpoch(ShareClassId, AssetId) external pure override returns (uint32) {
        return MOCK_EPOCH;
    }

    function nowRedeemEpoch(ShareClassId, AssetId) external pure override returns (uint32) {
        return MOCK_EPOCH;
    }

    function nowRevokeEpoch(ShareClassId, AssetId) external pure override returns (uint32) {
        return MOCK_EPOCH;
    }

    function maxDepositClaims(ShareClassId, bytes32, AssetId) external pure override returns (uint32) {
        return MOCK_EPOCH;
    }

    function maxRedeemClaims(ShareClassId, bytes32, AssetId) external pure override returns (uint32) {
        return MOCK_EPOCH;
    }
}
