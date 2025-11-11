// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract GraphQLQuery is Script {
    using stdJson for string;

    string constant PRODUCTION_API = "https://api.centrifuge.io/graphql";
    string constant TESTNET_API = "https://api-v3-test.cfg.embrio.tech";

    string public graphQLApi;
    bool public isProduction;

    constructor(bool isProduction_) {
        isProduction = isProduction_;
        graphQLApi = isProduction ? PRODUCTION_API : TESTNET_API;
    }

    function _queryGraphQL(string memory query) internal returns (string memory json) {
        query = string.concat('{"query": "{', query, '}"}');
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] =
            string.concat("curl -s -X POST ", "-H 'Content-Type: application/json' ", "-d '", query, "' ", graphQLApi);

        json = string(vm.ffi(cmd));

        if (json.keyExists(".errors[0].message")) {
            revert(json.readString(".errors[0].message"));
        }
    }

    function _buildJsonPath(string memory basePath, uint256 index, string memory fieldName)
        internal
        pure
        returns (string memory)
    {
        return string.concat(basePath, "[", vm.toString(index), "].", fieldName);
    }

    function _jsonValue(uint256 value) internal pure returns (string memory) {
        return string.concat("\\\"", vm.toString(value), "\\\"");
    }
}
