// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVHook} from "./interfaces/INAVManager.sol";
import {ISimplePriceManager} from "./interfaces/ISimplePriceManager.sol";

import {Auth} from "../../misc/Auth.sol";
import {D18, d18} from "../../misc/types/D18.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {IHub} from "../../core/hub/interfaces/IHub.sol";
import {IGateway} from "../../core/interfaces/IGateway.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IHubRegistry} from "../../core/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../core/hub/interfaces/IShareClassManager.sol";

/// @notice Base share price calculation manager for single share class pools.
contract SimplePriceManager is ISimplePriceManager, Auth {
    IGateway public immutable gateway;
    IHub public immutable hub;
    IHubRegistry public immutable hubRegistry;
    IShareClassManager public immutable shareClassManager;

    mapping(PoolId => Metrics) public metrics;
    mapping(PoolId => uint16[]) internal _notifiedNetworks;
    mapping(PoolId => mapping(uint16 centrifugeId => NetworkMetrics)) public networkMetrics;

    constructor(IHub hub_, address deployer) Auth(deployer) {
        hub = hub_;
        gateway = hub_.gateway();
        hubRegistry = hub_.hubRegistry();
        shareClassManager = hub_.shareClassManager();
    }

    modifier onlyHubManager(PoolId poolId) {
        require(hubRegistry.manager(poolId, msg.sender), NotAuthorized());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISimplePriceManager
    function addNotifiedNetwork(PoolId poolId, uint16 centrifugeId) external onlyHubManager(poolId) {
        require(shareClassManager.shareClassCount(poolId) == 1, InvalidShareClassCount());

        _notifiedNetworks[poolId].push(centrifugeId);
        emit UpdateNetworks(poolId, _notifiedNetworks[poolId]);
    }

    /// @inheritdoc ISimplePriceManager
    function removeNotifiedNetwork(PoolId poolId, uint16 centrifugeId) external onlyHubManager(poolId) {
        uint16[] storage networks_ = _notifiedNetworks[poolId];
        uint256 length = networks_.length;
        for (uint256 i; i < length; i++) {
            if (networks_[i] == centrifugeId) {
                networks_[i] = networks_[length - 1];
                networks_.pop();

                emit UpdateNetworks(poolId, networks_);
                return;
            }
        }
        revert NetworkNotFound();
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

        gateway.withBatch(
            abi.encodeWithSelector(
                SimplePriceManager.onUpdateCallback.selector, poolId, scId, centrifugeId, netAssetValue
            ),
            address(0)
        );
    }

    function onUpdateCallback(PoolId poolId, ShareClassId scId, uint16 centrifugeId, uint128 netAssetValue) external {
        gateway.lockCallback();

        NetworkMetrics storage networkMetrics_ = networkMetrics[poolId][centrifugeId];
        Metrics storage metrics_ = metrics[poolId];
        uint128 issuance = shareClassManager.issuance(poolId, scId, centrifugeId);

        metrics_.issuance = metrics_.issuance + issuance - networkMetrics_.issuance;
        metrics_.netAssetValue = metrics_.netAssetValue + netAssetValue - networkMetrics_.netAssetValue;

        D18 pricePoolPerShare_ = pricePoolPerShare(poolId);

        networkMetrics_.netAssetValue = netAssetValue;
        networkMetrics_.issuance = issuance;

        uint16[] storage networks_ = _notifiedNetworks[poolId];
        uint256 networkCount = networks_.length;
        hub.updateSharePrice(poolId, scId, pricePoolPerShare_, uint64(block.timestamp));

        for (uint256 i; i < networkCount; i++) {
            hub.notifySharePrice(poolId, scId, networks_[i], address(0));
        }

        emit Update(poolId, scId, metrics_.netAssetValue, metrics_.issuance, pricePoolPerShare_);
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

    /// @inheritdoc ISimplePriceManager
    function notifiedNetworks(PoolId poolId) external view returns (uint16[] memory) {
        return _notifiedNetworks[poolId];
    }

    function pricePoolPerShare(PoolId poolId) public view returns (D18) {
        Metrics memory metrics_ = metrics[poolId];
        return metrics_.issuance == 0 ? d18(1, 1) : d18(metrics_.netAssetValue) / d18(metrics_.issuance);
    }
}
