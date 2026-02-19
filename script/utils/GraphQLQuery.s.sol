// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @title GraphQLQuery
/// @notice GraphQL query client for the Centrifuge indexer API
/// @dev Does not inherit Script or Test to avoid diamond inheritance issues
contract GraphQLQuery {
    using stdJson for string;

    string _graphQLApi;

    constructor(string memory api) {
        _graphQLApi = api;
    }

    /// @notice Execute a GraphQL query via curl and return the JSON response
    /// @dev Wraps query in {"query": "{...}"} format and reverts on GraphQL errors
    /// @param query GraphQL query body (without outer JSON wrapper)
    function queryGraphQL(string memory query) public returns (string memory json) {
        query = string.concat('{"query": "{', query, '}"}');
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] =
            string.concat("curl -s -X POST ", "-H 'Content-Type: application/json' ", "-d '", query, "' ", _graphQLApi);

        json = string(vm.ffi(cmd));

        if (json.keyExists(".errors[0].message")) {
            revert(json.readString(".errors[0].message"));
        }
    }
}
