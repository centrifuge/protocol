// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVHook} from "./NAVManager.sol";

import {Auth} from "../misc/Auth.sol";
import {D18, d18} from "../misc/types/D18.sol";
import {IMulticall} from "../misc/interfaces/IMulticall.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {MAX_MESSAGE_COST} from "../common/interfaces/IGasService.sol";

import {IHub} from "../hub/interfaces/IHub.sol";
import {IShareClassManager} from "../hub/interfaces/IShareClassManager.sol";

struct NetworkMetrics {
    D18 netAssetValue;
    uint128 issuance;
}

/// @notice Share price calculation manager for single share class pools.
contract SimplePriceManager is Auth, INAVHook {
    error InvalidShareClassCount();

    PoolId public immutable poolId;
    ShareClassId public immutable scId;

    IHub public immutable hub;
    IShareClassManager public immutable shareClassManager;

    uint16[] public networks;
    uint128 public globalIssuance;
    D18 public globalNetAssetValue;
    mapping(uint16 centrifugeId => NetworkMetrics) public metrics;

    constructor(PoolId poolId_, ShareClassId scId_, IHub hub_, address deployer) Auth(deployer) {
        poolId = poolId_;
        scId = scId_;

        hub = hub_;
        shareClassManager = hub_.shareClassManager();

        require(shareClassManager.shareClassCount(poolId_) == 1, InvalidShareClassCount());
    }

    //----------------------------------------------------------------------------------------------
    // Network management
    //----------------------------------------------------------------------------------------------

    /// @dev Ensure the number of network updates can fit in a single block
    function setNetworks(uint16[] calldata centrifugeIds) external auth {
        networks = centrifugeIds;
    }

    //----------------------------------------------------------------------------------------------
    // Price updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVHook
    function onUpdate(PoolId poolId_, ShareClassId scId_, uint16 centrifugeId, D18 netAssetValue) external {
        require(poolId == poolId_);
        require(scId == scId_);
        // TODO: check msg.sender

        NetworkMetrics storage networkMetrics = metrics[centrifugeId];
        uint128 issuance = shareClassManager.issuance(scId, centrifugeId);

        globalIssuance = globalIssuance + issuance - networkMetrics.issuance;
        globalNetAssetValue = globalNetAssetValue + netAssetValue - networkMetrics.netAssetValue;

        D18 price = globalIssuance == 0 ? d18(1, 1) : globalNetAssetValue / d18(globalIssuance);

        networkMetrics.netAssetValue = netAssetValue;
        networkMetrics.issuance = issuance;

        uint256 networkCount = networks.length;
        bytes[] memory cs = new bytes[](networkCount + 1);
        cs[0] = abi.encodeWithSelector(hub.updateSharePrice.selector, poolId, scId, price);

        for (uint256 i; i < networkCount; i++) {
            cs[i + 1] = abi.encodeWithSelector(hub.notifySharePrice.selector, poolId, scId, centrifugeId);
        }

        IMulticall(address(hub)).multicall{value: MAX_MESSAGE_COST * (cs.length)}(cs);
    }
}
