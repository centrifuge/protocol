// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVHook} from "./interfaces/INAVManager.sol";
import {ISimplePriceManagerBase} from "./interfaces/ISimplePriceManagerBase.sol";

import {Auth} from "../../misc/Auth.sol";
import {D18, d18} from "../../misc/types/D18.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";
import {ICrosschainBatcher} from "../../common/interfaces/ICrosschainBatcher.sol";

import {IHub} from "../../hub/interfaces/IHub.sol";
import {IHubRegistry} from "../../hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../hub/interfaces/IShareClassManager.sol";

/// @notice Base share price calculation manager for single share class pools.
contract SimplePriceManagerBase is ISimplePriceManagerBase, Auth {
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

    /// @inheritdoc ISimplePriceManagerBase
    function file(bytes32 what, address data) external auth {
        if (what == "crosschainBatcher") crosschainBatcher = ICrosschainBatcher(data);
        else revert ISimplePriceManagerBase.FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc ISimplePriceManagerBase
    function networks(PoolId poolId) external view returns (uint16[] memory) {
        return metrics[poolId].networks;
    }

    /// @inheritdoc ISimplePriceManagerBase
    function addNetwork(PoolId poolId, uint16 centrifugeId) external onlyHubManager(poolId) {
        require(shareClassManager.shareClassCount(poolId) == 1, InvalidShareClassCount());

        metrics[poolId].networks.push(centrifugeId);
        emit UpdateNetworks(poolId, metrics[poolId].networks);
    }

    /// @inheritdoc ISimplePriceManagerBase
    function removeNetwork(PoolId poolId, uint16 centrifugeId) external onlyHubManager(poolId) {
        uint16[] storage networks_ = metrics[poolId].networks;
        uint256 length = networks_.length;
        for (uint256 i; i < length; i++) {
            if (networks_[i] == centrifugeId) {
                NetworkMetrics storage networkMetrics_ = networkMetrics[poolId][centrifugeId];
                Metrics storage metrics_ = metrics[poolId];

                metrics_.netAssetValue -= networkMetrics_.netAssetValue;
                metrics_.issuance -= networkMetrics_.issuance;

                delete networkMetrics[poolId][centrifugeId];

                networks_[i] = networks_[length - 1];
                networks_.pop();

                emit UpdateNetworks(poolId, networks_);
                return;
            }
        }
        revert NetworkNotFound();
    }

    /// @inheritdoc ISimplePriceManagerBase
    function updateManager(PoolId poolId, address manager_, bool canManage) external onlyHubManager(poolId) {
        manager[poolId][manager_] = canManage;

        emit UpdateManager(poolId, manager_, canManage);
    }

    //----------------------------------------------------------------------------------------------
    // Updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVHook
    function onUpdate(PoolId poolId, ShareClassId scId, uint16 centrifugeId, uint128 netAssetValue)
        public
        virtual
        auth
    {
        require(scId.index() == 1, InvalidShareClass());

        crosschainBatcher.execute(
            abi.encodeWithSelector(
                SimplePriceManagerBase.onUpdateCallback.selector, poolId, scId, centrifugeId, netAssetValue
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

        emit Update(poolId, scId, metrics_.netAssetValue, metrics_.issuance, price);
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

        emit Transfer(poolId, scId, fromCentrifugeId, toCentrifugeId, sharesTransferred);
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    function _navPerShare(PoolId poolId) internal view returns (D18) {
        Metrics memory metrics_ = metrics[poolId];
        return metrics_.issuance == 0 ? d18(1, 1) : d18(metrics_.netAssetValue) / d18(metrics_.issuance);
    }
}
