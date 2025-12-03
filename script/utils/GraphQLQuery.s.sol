// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GraphQLConstants} from "./GraphQLConstants.sol";

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title GraphQLQuery
/// @notice Abstract base contract for GraphQL query utilities
/// @dev Can be extended by both Script and Test contracts
/// @dev Subclasses must implement _graphQLApi() to specify endpoint
/// @dev Subclasses must provide vm() function (available in Script and Test)
/// @dev NOTE: This contract intentionally does NOT inherit from Script or Test (which inherit from CommonBase).
///      This allows it to be used by either without diamond inheritance issues
abstract contract GraphQLQuery {
    using stdJson for string;

    string constant PRODUCTION_API = GraphQLConstants.PRODUCTION_API;
    string constant TESTNET_API = GraphQLConstants.TESTNET_API;

    /// @notice Get the GraphQL API endpoint
    /// @dev Must be implemented by subclasses
    /// @return The GraphQL API URL to use
    function _graphQLApi() internal view virtual returns (string memory);

    /// @notice Get the Vm instance for cheatcodes
    /// @dev Helper to access forge-std's Vm interface
    /// @return The Vm instance at the standard cheatcode address
    function _vm() private pure returns (Vm) {
        return Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    }

    /// @notice Query Centrifuge GraphQL API via curl
    /// @dev Wraps query in {"query": "{...}"} format and checks for errors
    /// @param query GraphQL query string (without outer JSON wrapper)
    /// @return json JSON response as string
    function _queryGraphQL(string memory query) internal returns (string memory json) {
        query = string.concat('{"query": "{', query, '}"}');
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat(
            "curl -s -X POST ", "-H 'Content-Type: application/json' ", "-d '", query, "' ", _graphQLApi()
        );

        json = string(_vm().ffi(cmd));

        if (json.keyExists(".errors[0].message")) {
            revert(json.readString(".errors[0].message"));
        }
    }

    /// @notice Build JSON path for array element field
    /// @dev Helper to construct paths like ".data.items[0].fieldName"
    /// @param basePath Base path to the array (e.g., ".data.items")
    /// @param index Array index
    /// @param fieldName Field name to access
    /// @return Full JSON path
    function _buildJsonPath(string memory basePath, uint256 index, string memory fieldName)
        internal
        pure
        returns (string memory)
    {
        return string.concat(basePath, "[", _vm().toString(index), "].", fieldName);
    }

    /// @notice Convert uint256 value to JSON-escaped string
    /// @dev Wraps value in escaped quotes for JSON queries
    /// @param value The uint256 value to convert
    /// @return JSON-escaped string representation
    function _jsonValue(uint256 value) internal pure returns (string memory) {
        return string.concat("\\\"", _vm().toString(value), "\\\"");
    }
}
