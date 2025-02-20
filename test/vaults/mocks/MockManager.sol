// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "test/vaults/mocks/Mock.sol";

contract MockManager is Mock {
    mapping(bytes => uint256) public received;

    function handle(bytes memory message) public {
        values_bytes["handle_message"] = message;
        received[message]++;
    }

    // Added to be ignored in coverage report
    function test() public {}
}
