// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {AssetId} from "./types/AssetId.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {ShareClassId} from "./types/ShareClassId.sol";

import {Auth} from "../misc/Auth.sol";

// Gateway trust on GatewayBatcher
contract GatewayBatcher is Auth {
    IGateway public gateway; // In case we need to migrate the gateway
    address public transient sender;

    constructor(IGateway gateway_, address deployer) Auth(deployer) {
        gateway = gateway_;
    }

    function file(bytes32 what, address instance) external auth {
        if (what == "gateway") gateway = IGateway(instance);
    }

    function withBatch(bytes memory data) external payable {
        require(sender == address(0)); // avoid reentrancy issues

        gateway.startBatching();
        sender = msg.sender;

        msg.sender.call(data);

        sender = address(0);
        gateway.endBatching();
    }
}

// ============================
// Integrators, as QueueManager, only need to:
// ============================
contract Integration {
    GatewayBatcher gatewayBatcher;

    function sync(PoolId poolId, ShareClassId scId, AssetId assetId) external {
        gatewayBatcher.withBatch(abi.encodeWithSelector(Integration._sync.selector, poolId, scId, assetId));
    }

    function _sync(PoolId poolId, ShareClassId scId, AssetId assetId) external {
        // Only the same contract can call this method
        require(gatewayBatcher.sender() == address(this));

        // Do several actions that call messages
    }
}
