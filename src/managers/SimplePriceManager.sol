// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "src/misc/types/D18.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IHub} from "src/hub/interfaces/IHub.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";

import {INAVHook} from "src/managers/NAVManager.sol";

struct NetworkMetrics {
    D18 netAssetValue;
    uint128 issuance;
}

/// @notice Share price calculation manager for single share class pools.
contract SimplePriceManager is INAVHook {
    error InvalidShareClassCount();

    PoolId public immutable poolId;
    ShareClassId public immutable scId;

    IHub public immutable hub;
    IShareClassManager public immutable shareClassManager;

    uint128 public globalIssuance;
    D18 public globalNetAssetValue;
    mapping(uint16 centrifugeId => NetworkMetrics) public metrics;


    constructor(PoolId poolId_, ShareClassId scId_, IHub hub_) {
        poolId = poolId_;
        scId = scId_;

        hub = hub_;
        shareClassManager = hub_.shareClassManager();

        require(shareClassManager.shareClassCount(poolId_) == 1, InvalidShareClassCount());
    }

    //----------------------------------------------------------------------------------------------
    // Price updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVHook
    function onUpdate(PoolId poolId_, ShareClassId scId_, uint16 centrifugeId, D18 netAssetValue_) external {
        require(poolId == poolId_);
        require(scId == scId_);
        // TODO: check msg.sender

        NetworkMetrics storage networkMetrics = metrics[centrifugeId];
        uint128 issuance = shareClassManager.issuance(scId, centrifugeId);

        globalIssuance = globalIssuance + issuance - networkMetrics.issuance;
        globalNetAssetValue = globalNetAssetValue + netAssetValue_ - networkMetrics.netAssetValue;
        
        D18 price = globalIssuance == 0 ? d18(1, 1) : globalNetAssetValue / d18(globalIssuance);

        networkMetrics.netAssetValue = netAssetValue_;
        networkMetrics.issuance = issuance;

        hub.updateSharePrice(poolId, scId, price);
    }
}
