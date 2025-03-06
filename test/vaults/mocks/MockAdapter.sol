// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Auth} from "src/misc/Auth.sol";

import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";

import "test/common/mocks/Mock.sol";

contract MockAdapter is Auth, Mock, IAdapter {
    IMessageHandler public immutable gateway;

    mapping(bytes => uint256) public sent;

    constructor(address gateway_) Auth(msg.sender) {
        gateway = IMessageHandler(gateway_);
    }

    function execute(bytes memory _message) external {
        gateway.handle(1, _message);
    }

    function send(uint32, bytes calldata message) public {
        values_bytes["send"] = message;
        sent[message]++;
    }

    function estimate(uint32, bytes calldata, uint256 baseCost) public view returns (uint256 estimation) {
        estimation = values_uint256_return["estimate"] + baseCost;
    }

    function pay(uint32, bytes calldata, address) external payable {
        callWithValue("pay", msg.value);
    }
    // Added to be ignored in coverage report

    function test() public {}
}
