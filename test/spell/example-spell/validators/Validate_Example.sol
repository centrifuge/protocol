// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator, ValidationContext} from "../../validation/BaseValidator.sol";

/// @title Validate_PreExample
/// @notice Pre-migration validator: checks that at least one pool exists in the indexer
contract Validate_PreExample is BaseValidator("PreExample") {
    using stdJson for string;

    function validate(ValidationContext memory ctx) public override {
        string memory query = "pools(limit: 1000) { items { id } totalCount }";
        string memory json = ctx.indexer.queryGraphQL(query);

        uint256 totalCount = json.readUint(".data.pools.totalCount");
        if (totalCount == 0) {
            _errors.push(
                _buildError({
                    field: "totalCount",
                    value: "pools",
                    expected: "> 0",
                    actual: "0",
                    message: "No pools found in indexer"
                })
            );
        }
    }
}

/// @title Validate_CacheExample
/// @notice Pre-migration validator: queries pools and caches the result for post-validation
contract Validate_CacheExample is BaseValidator("CacheExample") {
    function validate(ValidationContext memory ctx) public override {
        string memory query = "pools(limit: 1000) { items { id } totalCount }";
        string memory json = ctx.indexer.queryGraphQL(query);
        ctx.cache.set("pools", json);
    }
}

/// @title Validate_PostExample
/// @notice Post-migration validator: reads cached pools and verifies the list has content
contract Validate_PostExample is BaseValidator("PostExample") {
    using stdJson for string;

    function validate(ValidationContext memory ctx) public override {
        string memory json = ctx.cache.get("pools");

        uint256 totalCount = json.readUint(".data.pools.totalCount");
        if (totalCount == 0) {
            _errors.push(
                _buildError({
                    field: "totalCount",
                    value: "pools",
                    expected: "> 0",
                    actual: "0",
                    message: "Cached pools list is empty"
                })
            );
        }
    }
}
