// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Mock} from "./Mock.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {MultiAdapter} from "../../../src/core/messaging/MultiAdapter.sol";
import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../../src/core/messaging/interfaces/IMessageHandler.sol";

import "forge-std/Test.sol";

contract MockAdapter is Mock, IAdapter {
    IMessageHandler public immutable gateway;

    uint16 centrifugeId;
    mapping(bytes => uint256) public sent;

    constructor(uint16 centrifugeId_, IMessageHandler gateway_) {
        centrifugeId = centrifugeId_;
        gateway = gateway_;
    }

    function execute(bytes memory _message) external {
        MultiAdapter multiAdapter = MultiAdapter(address(gateway));
        PoolId poolId = multiAdapter.messageProperties().messagePoolId(_message);
        uint16 sessionId = multiAdapter.activeSessionId(centrifugeId, poolId);
        gateway.handle(centrifugeId, abi.encodePacked(sessionId, _message));
    }

    function send(uint16, bytes calldata message, uint256, address) public payable returns (bytes32 adapterData) {
        callWithValue("send", msg.value);
        // Strip the 2-byte session ID prefix that MultiAdapter prepends to outgoing messages
        values_bytes["send"] = message[2:];
        sent[message]++;
        adapterData = bytes32("");
    }

    function estimate(uint16, bytes calldata, uint256 baseCost) public view returns (uint256 estimation) {
        estimation = values_uint256_return["estimate"] + baseCost;
    }

    function wire(bytes memory) external pure {
        revert("MockAdapter: wire not supported");
    }
}
