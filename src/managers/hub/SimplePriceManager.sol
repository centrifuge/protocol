// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVHook} from "./interfaces/INAVManager.sol";
import {ISimplePriceManager} from "./interfaces/ISimplePriceManager.sol";

import {Auth} from "../../misc/Auth.sol";
import {D18, d18} from "../../misc/types/D18.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";
import {ICrosschainBatcher} from "../../common/interfaces/ICrosschainBatcher.sol";

import {IHub} from "../../hub/interfaces/IHub.sol";
import {IHubRegistry} from "../../hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../hub/interfaces/IShareClassManager.sol";

import {IBatchRequestManager} from "../../vaults/interfaces/IBatchRequestManager.sol";

/// @notice Share price calculation manager for single share class pools.
contract SimplePriceManager is ISimplePriceManager, Auth {
    ICrosschainBatcher public crosschainBatcher;
    IHub public immutable hub;
    IHubRegistry public immutable hubRegistry;
    IShareClassManager public immutable shareClassManager;

    mapping(PoolId poolId => Metrics) public metrics;
    mapping(PoolId poolId => mapping(uint16 centrifugeId => NetworkMetrics)) public networkMetrics;
    mapping(PoolId poolId => mapping(address => bool)) public manager;

    constructor(IHub hub_, ICrosschainBatcher crosschainBatcher_, address deployer) Auth(deployer) {
        hub = hub_;
        crosschainBatcher = crosschainBatcher_;
        hubRegistry = hub_.hubRegistry();
        shareClassManager = hub_.shareClassManager();
    }

    modifier onlyManager(PoolId poolId) {
        require(manager[poolId][msg.sender], NotAuthorized());
        _;
    }

    modifier onlyHubManager(PoolId poolId) {
        require(hubRegistry.manager(poolId, msg.sender), NotAuthorized());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISimplePriceManager
    function file(bytes32 what, address data) external auth {
        if (what == "crosschainBatcher") crosschainBatcher = ICrosschainBatcher(data);
        else revert ISimplePriceManager.FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc ISimplePriceManager
    function networks(PoolId poolId) external view returns (uint16[] memory) {
        return metrics[poolId].networks;
    }

    /// @inheritdoc ISimplePriceManager
    function setNetworks(PoolId poolId, uint16[] calldata centrifugeIds) external onlyHubManager(poolId) {
        require(shareClassManager.shareClassCount(poolId) == 1, InvalidShareClassCount());

        metrics[poolId].networks = centrifugeIds;
        emit SetNetworks(poolId, centrifugeIds);
    }

    /// @inheritdoc ISimplePriceManager
    function updateManager(PoolId poolId, address manager_, bool canManage) external onlyHubManager(poolId) {
        manager[poolId][manager_] = canManage;

        emit UpdateManager(poolId, manager_, canManage);
    }

    //----------------------------------------------------------------------------------------------
    // Updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVHook
    function onUpdate(PoolId poolId, ShareClassId scId, uint16 centrifugeId, uint128 netAssetValue) external auth {
        require(scId.index() == 1, InvalidShareClass());
        NetworkMetrics memory networkMetrics_ = networkMetrics[poolId][centrifugeId];

        // If there are pending epochs to be issued or revoked, skip updating the share price, as it will likely be off
        if (networkMetrics_.issueEpochsBehind > 0 || networkMetrics_.revokeEpochsBehind > 0) return;

        crosschainBatcher.execute(
            abi.encodeWithSelector(
                SimplePriceManager.onUpdateCallback.selector, poolId, scId, centrifugeId, netAssetValue
            )
        );
    }

    function onUpdateCallback(PoolId poolId, ShareClassId scId, uint16 centrifugeId, uint128 netAssetValue)
        external
        auth
    {
        NetworkMetrics storage networkMetrics_ = networkMetrics[poolId][centrifugeId];
        Metrics storage metrics_ = metrics[poolId];
        uint128 issuance = shareClassManager.issuance(scId, centrifugeId);

        metrics_.issuance = metrics_.issuance + issuance - networkMetrics_.issuance;
        metrics_.netAssetValue = metrics_.netAssetValue + netAssetValue - networkMetrics_.netAssetValue;

        D18 price = _navPerShare(poolId);

        networkMetrics_.netAssetValue = netAssetValue;
        networkMetrics_.issuance = issuance;

        uint256 networkCount = metrics_.networks.length;
        hub.updateSharePrice(poolId, scId, price);

        for (uint256 i; i < networkCount; i++) {
            hub.notifySharePrice(poolId, scId, metrics_.networks[i]);
        }

        emit Update(poolId, metrics_.netAssetValue, metrics_.issuance, price);
    }

    /// @inheritdoc INAVHook
    function onTransfer(
        PoolId poolId,
        ShareClassId scId,
        uint16 fromCentrifugeId,
        uint16 toCentrifugeId,
        uint128 sharesTransferred
    ) external auth {
        require(scId.index() == 1, InvalidShareClass());
        NetworkMetrics storage fromMetrics = networkMetrics[poolId][fromCentrifugeId];
        NetworkMetrics storage toMetrics = networkMetrics[poolId][toCentrifugeId];
        fromMetrics.issuance -= sharesTransferred;
        toMetrics.issuance += sharesTransferred;

        emit Transfer(poolId, fromCentrifugeId, toCentrifugeId, sharesTransferred);
    }

    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

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

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    function _navPerShare(PoolId poolId) internal view returns (D18) {
        Metrics memory metrics_ = metrics[poolId];
        return metrics_.issuance == 0 ? d18(1, 1) : d18(metrics_.netAssetValue) / d18(metrics_.issuance);
    }
}
