// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

library JsonUtils {
    /// @notice Build JSON path for array element field (e.g. ".data.items[0].fieldName")
    function asJsonPath(string memory basePath, uint256 index, string memory fieldName)
        internal
        pure
        returns (string memory)
    {
        return string.concat(basePath, "[", vm.toString(index), "].", fieldName);
    }

    /// @notice Wrap uint256 in escaped quotes for JSON/GraphQL queries
    function asJsonString(uint256 value) internal pure returns (string memory) {
        return string.concat("\\\"", vm.toString(value), "\\\"");
    }

    /// @notice Wrap string in escaped quotes for JSON/GraphQL queries
    function asJsonString(string memory value) internal pure returns (string memory) {
        return string.concat("\\\"", value, "\\\"");
    }
}
