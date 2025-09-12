// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVHook} from "./interfaces/INAVManager.sol";
import {ISimplePriceManager} from "./interfaces/ISimplePriceManager.sol";
import {ISimplePriceManagerFactory} from "./interfaces/ISimplePriceManagerFactory.sol";

import {Auth} from "../misc/Auth.sol";
import {D18, d18} from "../misc/types/D18.sol";
import {IMulticall} from "../misc/interfaces/IMulticall.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {MAX_MESSAGE_COST} from "../common/interfaces/IGasService.sol";

import {IHub} from "../hub/interfaces/IHub.sol";
import {IHubRegistry} from "../hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../hub/interfaces/IShareClassManager.sol";

/// @notice Share price calculation manager for single share class pools.
contract SimplePriceManager is ISimplePriceManager {
    PoolId public immutable poolId;
    ShareClassId public immutable scId;

    IHub public immutable hub;
    IHubRegistry public immutable hubRegistry;
    IShareClassManager public immutable shareClassManager;

    uint16[] public networks;
    uint128 public globalIssuance;
    uint128 public globalNetAssetValue;
    mapping(uint16 centrifugeId => NetworkMetrics) public metrics;

    mapping(address => bool) public manager;
    mapping(address => bool) public caller;

    constructor(PoolId poolId_, IHub hub_) {
        poolId = poolId_;
        hub = hub_;
        hubRegistry = hub_.hubRegistry();
        shareClassManager = hub_.shareClassManager();

        require(shareClassManager.shareClassCount(poolId_) == 1, InvalidShareClassCount());

        scId = shareClassManager.previewShareClassId(poolId_, 1);
    }

    /// @dev Check if the msg.sender is a manager
    modifier onlyManager() {
        require(manager[msg.sender], NotAuthorized());
        _;
    }

    /// @dev Check if the msg.sender is a hub manager
    modifier onlyHubManager() {
        require(hubRegistry.manager(poolId, msg.sender), NotAuthorized());
        _;
    }

    /// @dev Check if the msg.sender is a allowed caller
    modifier onlyCaller() {
        require(caller[msg.sender], NotAuthorized());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISimplePriceManager
    function setNetworks(uint16[] calldata centrifugeIds) external onlyHubManager {
        networks = centrifugeIds;
    }

    /// @inheritdoc ISimplePriceManager
    function updateManager(address manager_, bool canManage) external onlyHubManager {
        require(manager_ != address(0), EmptyAddress());

        manager[manager_] = canManage;

        emit UpdateManager(manager_, canManage);
    }

    /// @inheritdoc ISimplePriceManager
    function updateCaller(address caller_, bool canCall) external onlyHubManager {
        require(caller_ != address(0), EmptyAddress());

        caller[caller_] = canCall;

        emit UpdateCaller(caller_, canCall);
    }

    //----------------------------------------------------------------------------------------------
    // Updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVHook
    function onUpdate(PoolId poolId_, ShareClassId scId_, uint16 centrifugeId, uint128 netAssetValue)
        external
        onlyCaller
    {
        require(poolId == poolId_, InvalidPoolId());
        require(scId == scId_, InvalidShareClassId());

        NetworkMetrics storage networkMetrics = metrics[centrifugeId];
        uint128 issuance = shareClassManager.issuance(scId, centrifugeId);

        globalIssuance = globalIssuance + issuance - networkMetrics.issuance;
        globalNetAssetValue = globalNetAssetValue + netAssetValue - networkMetrics.netAssetValue;

        D18 price = _navPerShare();

        networkMetrics.netAssetValue = netAssetValue;
        networkMetrics.issuance = issuance;

        uint256 networkCount = networks.length;
        bytes[] memory cs = new bytes[](networkCount + 1);
        cs[0] = abi.encodeWithSelector(hub.updateSharePrice.selector, poolId, scId, price);

        for (uint256 i; i < networkCount; i++) {
            cs[i + 1] = abi.encodeWithSelector(hub.notifySharePrice.selector, poolId, scId, networks[i]);
        }

        IMulticall(address(hub)).multicall{value: MAX_MESSAGE_COST * (cs.length)}(cs);

        emit Update(globalNetAssetValue, globalIssuance, price);
    }

    /// @inheritdoc INAVHook
    function onTransfer(
        PoolId poolId_,
        ShareClassId scId_,
        uint16 fromCentrifugeId,
        uint16 toCentrifugeId,
        uint128 sharesTransferred
    ) external onlyCaller {
        require(poolId == poolId_, InvalidPoolId());
        require(scId == scId_, InvalidShareClassId());

        NetworkMetrics storage fromMetrics = metrics[fromCentrifugeId];
        NetworkMetrics storage toMetrics = metrics[toCentrifugeId];
        fromMetrics.issuance -= sharesTransferred;
        toMetrics.issuance += sharesTransferred;

        emit Transfer(fromCentrifugeId, toCentrifugeId, sharesTransferred);
    }

    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISimplePriceManager
    function approveDepositsAndIssueShares(AssetId depositAssetId, uint128 approvedAssetAmount, uint128 extraGasLimit)
        external
        onlyManager
    {
        uint32 nowDepositEpochId = shareClassManager.nowDepositEpoch(scId, depositAssetId);
        uint32 nowIssueEpochId = shareClassManager.nowIssueEpoch(scId, depositAssetId);

        require(nowDepositEpochId == nowIssueEpochId, MismatchedEpochs());

        D18 navPoolPerShare = _navPerShare();
        hub.approveDeposits(poolId, scId, depositAssetId, nowDepositEpochId, approvedAssetAmount);
        hub.issueShares(poolId, scId, depositAssetId, nowIssueEpochId, navPoolPerShare, extraGasLimit);
    }

    /// @inheritdoc ISimplePriceManager
    function approveRedeemsAndRevokeShares(AssetId payoutAssetId, uint128 approvedShareAmount, uint128 extraGasLimit)
        external
        onlyManager
    {
        uint32 nowRedeemEpochId = shareClassManager.nowRedeemEpoch(scId, payoutAssetId);
        uint32 nowRevokeEpochId = shareClassManager.nowRevokeEpoch(scId, payoutAssetId);

        require(nowRedeemEpochId == nowRevokeEpochId, MismatchedEpochs());

        D18 navPoolPerShare = _navPerShare();
        hub.approveRedeems(poolId, scId, payoutAssetId, nowRedeemEpochId, approvedShareAmount);
        hub.revokeShares(poolId, scId, payoutAssetId, nowRevokeEpochId, navPoolPerShare, extraGasLimit);
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    function _navPerShare() internal view returns (D18) {
        return globalIssuance == 0 ? d18(1, 1) : d18(globalNetAssetValue) / d18(globalIssuance);
    }

    // TODO: remove when not needed anymore
    receive() external payable {
        // Accept ETH refunds from multicall
    }
}

contract SimplePriceManagerFactory is ISimplePriceManagerFactory {
    IHub public immutable hub;

    constructor(IHub hub_) {
        hub = hub_;
    }

    function newManager(PoolId poolId) external returns (ISimplePriceManager) {
        require(hub.shareClassManager().shareClassCount(poolId) == 1, InvalidShareClassCount());

        SimplePriceManager manager = new SimplePriceManager{salt: keccak256(abi.encode(poolId.raw()))}(poolId, hub);

        emit DeploySimplePriceManager(poolId, address(manager));
        return ISimplePriceManager(manager);
    }
}
