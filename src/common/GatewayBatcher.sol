// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {AssetId} from "./types/AssetId.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {ShareClassId} from "./types/ShareClassId.sol";

import {Auth} from "../misc/Auth.sol";

// Gateway trust on GatewayBatcher
contract GatewayBatchCallback is Auth {
    IGateway public gateway;
    address public transient sender;

    error AlreadyBatching();
    error CallFailedWithEmptyRevert();

    constructor(IGateway gateway_, address deployer) Auth(deployer) {
        gateway = gateway_;
    }

    function file(bytes32 what, address instance) external auth {
        if (what == "gateway") gateway = IGateway(instance);
    }

    function withBatch(bytes memory data) external payable returns (uint256 cost) {
        require(sender == address(0), AlreadyBatching());

        gateway.startBatching();
        sender = msg.sender;

        (bool success, bytes memory returnData) = msg.sender.call(data);
        if (!success) {
            uint256 length = returnData.length;
            require(length != 0, CallFailedWithEmptyRevert());

            assembly ("memory-safe") {
                revert(add(32, returnData), length)
            }
        }

        sender = address(0);
        return gateway.endBatching();
    }
}
