// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVHook} from "./interfaces/INAVManager.sol";
import {ISimplePriceManager} from "./interfaces/ISimplePriceManager.sol";

import {D18, d18} from "../../misc/types/D18.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {IHub} from "../../core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IGateway} from "../../core/messaging/interfaces/IGateway.sol";
import {IHubRegistry} from "../../core/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../core/hub/interfaces/IShareClassManager.sol";

/// @notice Base share price calculation manager for single share class pools.
contract SimplePriceManager is ISimplePriceManager {
    IHub public immutable hub;
    IGateway public immutable gateway;
    address public immutable navUpdater;
    IHubRegistry public immutable hubRegistry;
    IShareClassManager public immutable shareClassManager;

    mapping(PoolId => Metrics) public metrics;
    mapping(PoolId => uint16[]) internal _notifiedNetworks;
    mapping(PoolId => mapping(uint16 centrifugeId => NetworkMetrics)) public networkMetrics;

    constructor(IHub hub_, address navUpdater_) {
        hub = hub_;
        gateway = hub_.gateway();
        hubRegistry = hub_.hubRegistry();
        shareClassManager = hub_.shareClassManager();
        navUpdater = navUpdater_;
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
    function onUpdate(PoolId poolId, ShareClassId scId, uint16 centrifugeId, uint128 netAssetValue) public virtual {
        require(msg.sender == navUpdater, NotAuthorized());
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
        uint128 newIssuance = shareClassManager.issuance(poolId, scId, centrifugeId);

        // When shares are transferred, the issuance in the SCM updates immediately,
        // but in this contract they are tracked separately as transferredIn/Out.
        // Here we get the diff between the current stale SPM issuance and the new SCM issuance,
        // but we need to negate the transferred amounts to avoid double-counting them in the global issuance.
        // This adjusted diff is then applied to the global issuance.
        (uint128 issuanceDelta, bool isIncrease) = _calculateIssuanceDelta(
            networkMetrics_.issuance, newIssuance, networkMetrics_.transferredIn, networkMetrics_.transferredOut
        );

        metrics_.issuance = isIncrease ? metrics_.issuance + issuanceDelta : metrics_.issuance - issuanceDelta;

        metrics_.netAssetValue = metrics_.netAssetValue + netAssetValue - networkMetrics_.netAssetValue;
        networkMetrics_.netAssetValue = netAssetValue;
        networkMetrics_.issuance = newIssuance;
        networkMetrics_.transferredIn = 0;
        networkMetrics_.transferredOut = 0;

        D18 pricePoolPerShare_ = pricePoolPerShare(poolId);
        hub.updateSharePrice(poolId, scId, pricePoolPerShare_, uint64(block.timestamp));

        uint16[] storage networks_ = _notifiedNetworks[poolId];
        for (uint256 i; i < networks_.length; i++) {
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
    ) external {
        require(msg.sender == navUpdater, NotAuthorized());
        require(scId.index() == 1, InvalidShareClass());
        NetworkMetrics storage fromMetrics = networkMetrics[poolId][fromCentrifugeId];
        NetworkMetrics storage toMetrics = networkMetrics[poolId][toCentrifugeId];
        fromMetrics.transferredOut += sharesTransferred;
        toMetrics.transferredIn += sharesTransferred;

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

    function _calculateIssuanceDelta(
        uint128 oldIssuance,
        uint128 newIssuance,
        uint128 transferredIn,
        uint128 transferredOut
    ) internal pure returns (uint128 delta, bool isIncrease) {
        // transferredIn was already added to SCM, so needs to be subtracted
        // transferredOut was already removed from SCM, so needs to be added back
        // delta = (newIssuance - oldIssuance) - transferredIn + transferredOut
        // which is the same as (newIssuance + transferredOut) - (oldIssuance + transferredIn)
        // and avoids potential underflow
        uint128 adjustedNew = newIssuance + transferredOut;
        uint128 adjustedOld = oldIssuance + transferredIn;

        if (adjustedNew >= adjustedOld) return (adjustedNew - adjustedOld, true);
        else return (adjustedOld - adjustedNew, false);
    }
}
