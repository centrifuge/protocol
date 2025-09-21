// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../../../src/misc/types/D18.sol";

import {PoolId} from "../../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../../src/common/types/ShareClassId.sol";
import {IHubGatewayHandler} from "../../../../src/common/interfaces/IGatewayHandlers.sol";
import {RequestCallbackMessageLib} from "../../../../src/common/libraries/RequestCallbackMessageLib.sol";

import {IHubRequestManager} from "../../../../src/hub/interfaces/IHubRequestManager.sol";

contract MockHubRequestManager is IHubRequestManager {
    using RequestCallbackMessageLib for *;

    uint32 private constant MOCK_EPOCH = 1;
    address public hub;

    constructor(address hub_) {
        hub = hub_;
    }

    function request(PoolId, ShareClassId, AssetId, bytes calldata) external override {}

    function requestDeposit(PoolId, ShareClassId, uint128, bytes32, AssetId) external override {}

    function cancelDepositRequest(PoolId, ShareClassId, bytes32, AssetId) external pure override returns (uint128) {
        return 0;
    }

    function requestRedeem(PoolId, ShareClassId, uint128, bytes32, AssetId) external override {}

    function cancelRedeemRequest(PoolId, ShareClassId, bytes32, AssetId) external pure override returns (uint128) {
        return 0;
    }

    function approveDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint32,
        uint128 approvedAmount,
        D18 pricePoolPerAsset
    ) external override returns (uint256) {
        // Send the ApprovedDeposits callback message like the real implementation
        return IHubGatewayHandler(hub).requestCallback(
            poolId,
            scId,
            assetId,
            RequestCallbackMessageLib.ApprovedDeposits(approvedAmount, pricePoolPerAsset.raw()).serialize(),
            0
        );
    }

    function approveRedeems(PoolId, ShareClassId, AssetId, uint32, uint128, D18) external override {}

    function issueShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint32,
        D18 navPoolPerShare,
        uint128 extraGasLimit
    ) external override returns (uint256) {
        // Calculate issued share amount (simplified for mock)
        uint128 issuedShareAmount = 10 * 1e18; // Mock value matching our test expectations

        // Send the IssuedShares callback message like the real implementation
        return IHubGatewayHandler(hub).requestCallback(
            poolId,
            scId,
            assetId,
            RequestCallbackMessageLib.IssuedShares(issuedShareAmount, navPoolPerShare.raw()).serialize(),
            extraGasLimit
        );
    }

    function revokeShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint32,
        D18 navPoolPerShare,
        uint128 extraGasLimit
    ) external override returns (uint256) {
        // Calculate revoked amounts (simplified for mock)
        uint128 revokedAssetAmount = 4 * 1e6; // Mock value matching our test expectations
        uint128 revokedShareAmount = 2 * 1e18; // Mock value matching our test expectations

        // Send the RevokedShares callback message like the real implementation
        return IHubGatewayHandler(hub).requestCallback(
            poolId,
            scId,
            assetId,
            RequestCallbackMessageLib.RevokedShares(revokedAssetAmount, revokedShareAmount, navPoolPerShare.raw())
                .serialize(),
            extraGasLimit
        );
    }

    function forceCancelDepositRequest(PoolId, ShareClassId, bytes32, AssetId)
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function forceCancelRedeemRequest(PoolId, ShareClassId, bytes32, AssetId)
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function claimDeposit(PoolId, ShareClassId, bytes32, AssetId)
        external
        pure
        override
        returns (uint128, uint128, uint128, bool)
    {
        // Return values that match the test expectations
        uint128 payoutShareAmount = 10 * 1e18; // Some share amount
        uint128 paymentAssetAmount = 20 * 1e6; // APPROVED_INVESTOR_AMOUNT
        uint128 cancelled = 80 * 1e6; // INVESTOR_AMOUNT - APPROVED_INVESTOR_AMOUNT
        bool canClaimAgain = false;
        return (payoutShareAmount, paymentAssetAmount, cancelled, canClaimAgain);
    }

    function claimRedeem(PoolId, ShareClassId, bytes32, AssetId)
        external
        pure
        override
        returns (uint128, uint128, uint128, bool)
    {
        // Return values that match the test expectations for redeem
        uint128 payoutAssetAmount = 4 * 1e6; // Some asset amount based on NAV_PER_SHARE conversion
        uint128 paymentShareAmount = 2 * 1e18; // APPROVED_SHARE_AMOUNT
        uint128 cancelled = 8 * 1e18; // SHARE_AMOUNT - APPROVED_SHARE_AMOUNT
        bool canClaimAgain = false;
        return (payoutAssetAmount, paymentShareAmount, cancelled, canClaimAgain);
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
