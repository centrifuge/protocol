// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVHook} from "./interfaces/INAVManager.sol";
import {ISimplePriceManager} from "./interfaces/ISimplePriceManager.sol";

import {D18, d18} from "../../misc/types/D18.sol";
import {IMulticall} from "../../misc/interfaces/IMulticall.sol";
import {Auth} from "../../misc/Auth.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";
import {MAX_MESSAGE_COST} from "../../common/interfaces/IGasService.sol";
import {IGateway} from "../../common/interfaces/IGateway.sol";

import {IHub} from "../../hub/interfaces/IHub.sol";
import {IHubRegistry} from "../../hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../hub/interfaces/IShareClassManager.sol";

/// @notice Share price calculation manager for single share class pools.
contract SimplePriceManager is ISimplePriceManager, Auth {
    IGateway public gateway;
    IHub public immutable hub;
    IHubRegistry public immutable hubRegistry;
    IShareClassManager public immutable shareClassManager;

    mapping(PoolId poolId => Metrics) public metrics;
    mapping(PoolId poolId => mapping(uint16 centrifugeId => NetworkMetrics)) public networkMetrics;
    mapping(PoolId poolId => mapping(address => bool)) public manager;

    constructor(IHub hub_, address deployer) Auth(deployer) {
        hub = hub_;
        gateway = hub_.gateway();
        hubRegistry = hub_.hubRegistry();
        shareClassManager = hub_.shareClassManager();

        // TODO: where to check share class count?
        // require(shareClassManager.shareClassCount(poolId) == 1, InvalidShareClassCount());
        // scId = shareClassManager.previewShareClassId(poolId, 1);
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
        if (what == "gateway") gateway = IGateway(data);
        else revert ISimplePriceManager.FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc ISimplePriceManager
    function networks(PoolId poolId) external view returns (uint16[] memory) {
        return metrics[poolId].networks;
    }

    /// @inheritdoc ISimplePriceManager
    function setNetworks(PoolId poolId, uint16[] calldata centrifugeIds) external onlyHubManager(poolId) {
        metrics[poolId].networks = centrifugeIds;
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
        NetworkMetrics storage networkMetrics_ = networkMetrics[poolId][centrifugeId];
        uint128 issuance = shareClassManager.issuance(scId, centrifugeId);

        metrics[poolId].issuance = metrics[poolId].issuance + issuance - networkMetrics_.issuance;
        metrics[poolId].netAssetValue = metrics[poolId].netAssetValue + netAssetValue - networkMetrics_.netAssetValue;

        D18 price = _navPerShare(poolId);

        networkMetrics_.netAssetValue = netAssetValue;
        networkMetrics_.issuance = issuance;

        uint256 networkCount = metrics[poolId].networks.length;
        gateway.startBatching();
        hub.updateSharePrice(poolId, scId, price);

        for (uint256 i; i < networkCount; i++) {
            hub.notifySharePrice(poolId, scId, metrics[poolId].networks[i]);
        }

        emit Update(poolId, metrics[poolId].netAssetValue, metrics[poolId].issuance, price);
    }

    /// @inheritdoc INAVHook
    function onTransfer(
        PoolId poolId,
        ShareClassId,
        uint16 fromCentrifugeId,
        uint16 toCentrifugeId,
        uint128 sharesTransferred
    ) external auth {
        NetworkMetrics storage fromMetrics = networkMetrics[poolId][fromCentrifugeId];
        NetworkMetrics storage toMetrics = networkMetrics[poolId][toCentrifugeId];
        fromMetrics.issuance -= sharesTransferred;
        toMetrics.issuance += sharesTransferred;

        emit Transfer(poolId, fromCentrifugeId, toCentrifugeId, sharesTransferred);
    }

    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISimplePriceManager
    function approveDepositsAndIssueShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint128 approvedAssetAmount,
        uint128 extraGasLimit
    ) external onlyManager(poolId) {
        uint32 nowDepositEpochId = shareClassManager.nowDepositEpoch(scId, depositAssetId);
        uint32 nowIssueEpochId = shareClassManager.nowIssueEpoch(scId, depositAssetId);

        require(nowDepositEpochId == nowIssueEpochId, MismatchedEpochs());

        D18 navPoolPerShare = _navPerShare(poolId);
        hub.approveDeposits(poolId, scId, depositAssetId, nowDepositEpochId, approvedAssetAmount);
        hub.issueShares(poolId, scId, depositAssetId, nowIssueEpochId, navPoolPerShare, extraGasLimit);
    }

    /// @inheritdoc ISimplePriceManager
    function approveRedeemsAndRevokeShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint128 approvedShareAmount,
        uint128 extraGasLimit
    ) external onlyManager(poolId) {
        uint32 nowRedeemEpochId = shareClassManager.nowRedeemEpoch(scId, payoutAssetId);
        uint32 nowRevokeEpochId = shareClassManager.nowRevokeEpoch(scId, payoutAssetId);

        require(nowRedeemEpochId == nowRevokeEpochId, MismatchedEpochs());

        D18 navPoolPerShare = _navPerShare(poolId);
        hub.approveRedeems(poolId, scId, payoutAssetId, nowRedeemEpochId, approvedShareAmount);
        hub.revokeShares(poolId, scId, payoutAssetId, nowRevokeEpochId, navPoolPerShare, extraGasLimit);
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    function _navPerShare(PoolId poolId) internal view returns (D18) {
        return metrics[poolId].issuance == 0
            ? d18(1, 1)
            : d18(metrics[poolId].netAssetValue) / d18(metrics[poolId].issuance);
    }

    // TODO: remove when not needed anymore
    receive() external payable {
        // Accept ETH refunds from multicall
    }
}
