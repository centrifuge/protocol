// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "test/common/mocks/Mock.sol";

import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";

contract MockManager is Mock, IMessageHandler {
    mapping(bytes => uint256) public received;

    function handle(uint16, bytes memory message) public {
        values_bytes["handle_message"] = message;
        received[message]++;
    }

    // Added to be ignored in coverage report
    function test() public {}
}
