// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMulticall} from "src/interfaces/IMulticall.sol";

contract Multicall is IMulticall {
    /// @dev Performs a generic multicall. It reverts the whole transaction if one call fails.
    function aggregate(address[] calldata targets, bytes[] calldata datas) external returns (bytes[] memory results) {
        require(targets.length == datas.length, WrongExecutionParams());

        results = new bytes[](datas.length);

        for (uint32 i; i < targets.length; i++) {
            (bool success, bytes memory result) = targets[i].call(datas[i]);
            // Forward the error happened in target.call().
            if (!success) {
                assembly {
                    // Reverting the error originated in the above call.
                    // First 32 bytes contains the size of the array, rest the error data
                    revert(add(result, 32), mload(result))
                }
            }
            results[i] = result;
        }
    }
}
