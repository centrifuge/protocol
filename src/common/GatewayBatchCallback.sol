// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {AssetId} from "./types/AssetId.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {ShareClassId} from "./types/ShareClassId.sol";

import {Auth} from "../misc/Auth.sol";

import {IGatewayBatchCallback} from "./interfaces/IGatewayBatchCallback.sol";

// Gateway trust on GatewayBatcher
contract GatewayBatchCallback is Auth, IGatewayBatchCallback {
    IGateway public gateway;
    address public transient caller;

    constructor(IGateway gateway_, address deployer) Auth(deployer) {
        gateway = gateway_;
    }

    /// @inheritdoc IGatewayBatchCallback
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IGatewayBatchCallback
    function withBatch(bytes memory data) external payable returns (uint256 cost) {
        require(caller == address(0), AlreadyBatching());

        gateway.startBatching();
        caller = msg.sender;

        (bool success, bytes memory returnData) = msg.sender.call{value: msg.value}(data);
        if (!success) {
            uint256 length = returnData.length;
            require(length != 0, CallFailedWithEmptyRevert());

            assembly ("memory-safe") {
                revert(add(32, returnData), length)
            }
        }

        caller = address(0);
        return gateway.endBatching();
    }
}
