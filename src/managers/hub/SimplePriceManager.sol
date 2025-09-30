// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVHook} from "./interfaces/INAVManager.sol";
import {SimplePriceManagerBase} from "./SimplePriceManagerBase.sol";
import {ISimplePriceManager} from "./interfaces/ISimplePriceManager.sol";

import {D18, d18} from "../../misc/types/D18.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";
import {ICrosschainBatcher} from "../../common/interfaces/ICrosschainBatcher.sol";

import {IHub} from "../../hub/interfaces/IHub.sol";

import {IBatchRequestManager} from "../../vaults/interfaces/IBatchRequestManager.sol";

/// @notice Simple price manager for single share class pools with async request management.
contract SimplePriceManager is SimplePriceManagerBase, ISimplePriceManager {
    constructor(IHub hub_, ICrosschainBatcher crosschainBatcher_, address deployer)
        SimplePriceManagerBase(hub_, crosschainBatcher_, deployer)
    {}

    //----------------------------------------------------------------------------------------------
    // Updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc SimplePriceManagerBase
    function onUpdate(PoolId poolId, ShareClassId scId, uint16 centrifugeId, uint128 netAssetValue)
        public
        override(SimplePriceManagerBase, INAVHook)
        auth
    {
        NetworkMetrics memory networkMetrics_ = networkMetrics[poolId][centrifugeId];

        // If there are pending epochs to be issued or revoked, skip updating the share price, as it will likely be off
        if (networkMetrics_.issueEpochsBehind > 0 || networkMetrics_.revokeEpochsBehind > 0) return;

        super.onUpdate(poolId, scId, centrifugeId, netAssetValue);
    }

    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISimplePriceManager
    function approveDeposits(PoolId poolId, ShareClassId scId, AssetId depositAssetId, uint128 approvedAssetAmount)
        external
        onlyManager(poolId)
    {
        require(scId.index() == 1, InvalidShareClass());
        IBatchRequestManager requestManager =
            IBatchRequestManager(address(hubRegistry.hubRequestManager(poolId, depositAssetId.centrifugeId())));
        uint32 nowDepositEpochId = requestManager.nowDepositEpoch(scId, depositAssetId);

        NetworkMetrics storage networkMetrics_ = networkMetrics[poolId][depositAssetId.centrifugeId()];

        networkMetrics_.issueEpochsBehind++;

        D18 pricePoolPerAsset = hub.pricePoolPerAsset(poolId, scId, depositAssetId);
        requestManager.approveDeposits(
            poolId, scId, depositAssetId, nowDepositEpochId, approvedAssetAmount, pricePoolPerAsset
        );
    }

    /// @inheritdoc ISimplePriceManager
    function issueShares(PoolId poolId, ShareClassId scId, AssetId depositAssetId, uint128 extraGasLimit)
        external
        onlyManager(poolId)
    {
        require(scId.index() == 1, InvalidShareClass());
        IBatchRequestManager requestManager =
            IBatchRequestManager(address(hubRegistry.hubRequestManager(poolId, depositAssetId.centrifugeId())));
        uint32 nowIssueEpochId = requestManager.nowIssueEpoch(scId, depositAssetId);

        NetworkMetrics storage networkMetrics_ = networkMetrics[poolId][depositAssetId.centrifugeId()];

        require(networkMetrics_.issueEpochsBehind > 0, MismatchedEpochs());
        networkMetrics_.issueEpochsBehind--;

        D18 navPoolPerShare = _navPerShare(poolId);
        requestManager.issueShares(poolId, scId, depositAssetId, nowIssueEpochId, navPoolPerShare, extraGasLimit);
    }

    /// @inheritdoc ISimplePriceManager
    function approveRedeems(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, uint128 approvedShareAmount)
        external
        onlyManager(poolId)
    {
        require(scId.index() == 1, InvalidShareClass());
        IBatchRequestManager requestManager =
            IBatchRequestManager(address(hubRegistry.hubRequestManager(poolId, payoutAssetId.centrifugeId())));
        uint32 nowRedeemEpochId = requestManager.nowRedeemEpoch(scId, payoutAssetId);

        NetworkMetrics storage networkMetrics_ = networkMetrics[poolId][payoutAssetId.centrifugeId()];

        networkMetrics_.revokeEpochsBehind++;

        D18 pricePoolPerAsset = hub.pricePoolPerAsset(poolId, scId, payoutAssetId);
        requestManager.approveRedeems(
            poolId, scId, payoutAssetId, nowRedeemEpochId, approvedShareAmount, pricePoolPerAsset
        );
    }

    /// @inheritdoc ISimplePriceManager
    function revokeShares(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, uint128 extraGasLimit)
        external
        onlyManager(poolId)
    {
        require(scId.index() == 1, InvalidShareClass());
        IBatchRequestManager requestManager =
            IBatchRequestManager(address(hubRegistry.hubRequestManager(poolId, payoutAssetId.centrifugeId())));
        uint32 nowRevokeEpochId = requestManager.nowRevokeEpoch(scId, payoutAssetId);

        NetworkMetrics storage networkMetrics_ = networkMetrics[poolId][payoutAssetId.centrifugeId()];

        require(networkMetrics_.revokeEpochsBehind > 0, MismatchedEpochs());
        networkMetrics_.revokeEpochsBehind--;

        D18 navPoolPerShare = _navPerShare(poolId);
        requestManager.revokeShares(poolId, scId, payoutAssetId, nowRevokeEpochId, navPoolPerShare, extraGasLimit);
    }

    /// @inheritdoc ISimplePriceManager
    function approveDepositsAndIssueShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint128 approvedAssetAmount,
        uint128 extraGasLimit
    ) external onlyManager(poolId) {
        require(scId.index() == 1, InvalidShareClass());
        IBatchRequestManager requestManager =
            IBatchRequestManager(address(hubRegistry.hubRequestManager(poolId, depositAssetId.centrifugeId())));
        uint32 nowDepositEpochId = requestManager.nowDepositEpoch(scId, depositAssetId);
        uint32 nowIssueEpochId = requestManager.nowIssueEpoch(scId, depositAssetId);

        require(nowDepositEpochId == nowIssueEpochId, MismatchedEpochs());

        D18 pricePoolPerAsset = hub.pricePoolPerAsset(poolId, scId, depositAssetId);
        D18 navPoolPerShare = _navPerShare(poolId);
        requestManager.approveDeposits(
            poolId, scId, depositAssetId, nowDepositEpochId, approvedAssetAmount, pricePoolPerAsset
        );
        requestManager.issueShares(poolId, scId, depositAssetId, nowIssueEpochId, navPoolPerShare, extraGasLimit);
    }

    /// @inheritdoc ISimplePriceManager
    function approveRedeemsAndRevokeShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint128 approvedShareAmount,
        uint128 extraGasLimit
    ) external onlyManager(poolId) {
        require(scId.index() == 1, InvalidShareClass());
        IBatchRequestManager requestManager =
            IBatchRequestManager(address(hubRegistry.hubRequestManager(poolId, payoutAssetId.centrifugeId())));
        uint32 nowRedeemEpochId = requestManager.nowRedeemEpoch(scId, payoutAssetId);
        uint32 nowRevokeEpochId = requestManager.nowRevokeEpoch(scId, payoutAssetId);

        require(nowRedeemEpochId == nowRevokeEpochId, MismatchedEpochs());

        D18 pricePoolPerAsset = hub.pricePoolPerAsset(poolId, scId, payoutAssetId);
        D18 navPoolPerShare = _navPerShare(poolId);
        requestManager.approveRedeems(
            poolId, scId, payoutAssetId, nowRedeemEpochId, approvedShareAmount, pricePoolPerAsset
        );
        requestManager.revokeShares(poolId, scId, payoutAssetId, nowRevokeEpochId, navPoolPerShare, extraGasLimit);
    }
}
