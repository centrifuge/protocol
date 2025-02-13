// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "test/mocks/Mock.sol";

contract MockManager is Mock {
    mapping(bytes => uint256) public received;

    function handle(bytes memory message) public {
        values_bytes["handle_message"] = message;
        received[message]++;
    }

    // Added to be ignored in coverage report
    function test() public {}
}
