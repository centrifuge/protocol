// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./Mock.sol";

import {Auth} from "../../../src/misc/Auth.sol";

import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../../src/common/interfaces/IMessageHandler.sol";

import "forge-std/Test.sol";

contract MockAdapter is Auth, Mock, IAdapter {
    IMessageHandler public immutable gateway;

    uint16 centrifugeId;
    mapping(bytes => uint256) public sent;

    constructor(uint16 centrifugeId_, IMessageHandler gateway_) Auth(msg.sender) {
        centrifugeId = centrifugeId_;
        gateway = gateway_;
    }

    function execute(bytes memory _message) external {
        gateway.handle(centrifugeId, _message);
    }

    function send(uint16, bytes calldata message, uint256, address) public payable returns (bytes32 adapterData) {
        callWithValue("send", msg.value);
        values_bytes["send"] = message;
        sent[message]++;
        adapterData = bytes32("");
    }

    function estimate(uint16, bytes calldata, uint256 baseCost) public view returns (uint256 estimation) {
        estimation = values_uint256_return["estimate"] + baseCost;
    }
}
