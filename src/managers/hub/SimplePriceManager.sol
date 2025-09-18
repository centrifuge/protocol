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

import {IHub} from "../../hub/interfaces/IHub.sol";
import {IHubRegistry} from "../../hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../hub/interfaces/IShareClassManager.sol";

/// @notice Share price calculation manager for single share class pools.
contract SimplePriceManager is ISimplePriceManager, Auth {
    IHub public immutable hub;
    IHubRegistry public immutable hubRegistry;
    IShareClassManager public immutable shareClassManager;

    mapping(PoolId poolId => uint16[]) public networks;
    mapping(PoolId poolId => uint128) public globalIssuance;
    mapping(PoolId poolId => uint128) public globalNetAssetValue;
    mapping(PoolId poolId => mapping(uint16 centrifugeId => NetworkMetrics)) public metrics;
    mapping(PoolId poolId => mapping(address => bool)) public manager;

    constructor(IHub hub_, address deployer) Auth(deployer) {
        hub = hub_;
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
    function setNetworks(PoolId poolId, uint16[] calldata centrifugeIds) external onlyHubManager(poolId) {
        networks[poolId] = centrifugeIds;
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
        NetworkMetrics storage networkMetrics = metrics[poolId][centrifugeId];
        uint128 issuance = shareClassManager.issuance(scId, centrifugeId);

        globalIssuance[poolId] = globalIssuance[poolId] + issuance - networkMetrics.issuance;
        globalNetAssetValue[poolId] = globalNetAssetValue[poolId] + netAssetValue - networkMetrics.netAssetValue;

        D18 price = _navPerShare(poolId);

        networkMetrics.netAssetValue = netAssetValue;
        networkMetrics.issuance = issuance;

        uint256 networkCount = networks[poolId].length;
        bytes[] memory cs = new bytes[](networkCount + 1);
        cs[0] = abi.encodeWithSelector(hub.updateSharePrice.selector, poolId, scId, price);

        for (uint256 i; i < networkCount; i++) {
            cs[i + 1] = abi.encodeWithSelector(hub.notifySharePrice.selector, poolId, scId, networks[poolId][i]);
        }

        IMulticall(address(hub)).multicall{value: MAX_MESSAGE_COST * (cs.length)}(cs);

        emit Update(poolId, globalNetAssetValue[poolId], globalIssuance[poolId], price);
    }

    /// @inheritdoc INAVHook
    function onTransfer(
        PoolId poolId,
        ShareClassId,
        uint16 fromCentrifugeId,
        uint16 toCentrifugeId,
        uint128 sharesTransferred
    ) external auth {
        NetworkMetrics storage fromMetrics = metrics[poolId][fromCentrifugeId];
        NetworkMetrics storage toMetrics = metrics[poolId][toCentrifugeId];
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
        return globalIssuance[poolId] == 0 ? d18(1, 1) : d18(globalNetAssetValue[poolId]) / d18(globalIssuance[poolId]);
    }

    // TODO: remove when not needed anymore
    receive() external payable {
        // Accept ETH refunds from multicall
    }
}
