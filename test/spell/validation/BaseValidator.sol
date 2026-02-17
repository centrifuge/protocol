// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {TestContracts} from "./TestContracts.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";

import {CacheStore} from "../../../script/utils/CacheStore.sol";
import {JsonUtils} from "../../../script/utils/JsonUtils.s.sol";
import {GraphQLQuery} from "../../../script/utils/GraphQLQuery.s.sol";
import {ContractsConfig as LiveContracts} from "../../../script/utils/EnvConfig.s.sol";

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

struct Contracts {
    /// @notice Always from the indexer, will represent the previous deployed version
    LiveContracts live;

    /// @notice Represents the modified version. Pre validators don't have latest version.
    TestContracts latest;
}

struct ValidationContext {
    Contracts contracts;
    uint16 localCentrifugeId;
    GraphQLQuery indexer;
    CacheStore cache;
    bool isMainnet;
}

/// @title BaseValidator
/// @notice Abstract base class for pre/post migration validators
/// @dev Each validator must implement validate(ValidationContext)
/// @dev JSON Parsing: Use stdJson helpers (readUint, readString) per field instead of
///      vm.parseJson + abi.decode, which fails silently with mixed-type structs.
abstract contract BaseValidator is Test {
    using stdJson for string;
    using JsonUtils for *;

    string public name;
    ValidationError[] _errors; // Array of all errors found (empty if passed)

    constructor(string memory name_) {
        name = name_;
        vm.label(address(this), string.concat("Validate_", name_));
    }

    function errors() external view returns (ValidationError[] memory) {
        return _errors;
    }

    // ============================================
    // TYPES
    // ============================================

    struct ValidationError {
        string field; // Field that failed (e.g., "pendingAssetsAmount")
        string value; // Identifier (e.g., "Pool 281474976710659")
        string expected; // Expected value (e.g., "0")
        string actual; // Actual value (e.g., "10000000")
        string message; // Human-readable message (e.g., "Pool has 10 USDC pending")
    }

    // ============================================
    // ABSTRACT INTERFACE
    // ============================================

    /// @notice Execute validation checks
    /// @param ctx Validation context with contracts, indexer, and cache
    function validate(ValidationContext memory ctx) public virtual;

    // ============================================
    // SHARED HELPERS
    // ============================================

    /// @notice Build a validation error
    function _buildError(
        string memory field,
        string memory value,
        string memory expected,
        string memory actual,
        string memory message
    ) internal pure returns (ValidationError memory) {
        return ValidationError({field: field, value: value, expected: expected, actual: actual, message: message});
    }

    /// @notice Build JSON array string from PoolId array for GraphQL queries
    function _buildPoolIdsJson(PoolId[] memory pools) internal pure returns (string memory) {
        string memory json = "[";
        for (uint256 i = 0; i < pools.length; i++) {
            json = string.concat(json, vm.toString(PoolId.unwrap(pools[i])));
            if (i < pools.length - 1) {
                json = string.concat(json, ", ");
            }
        }
        return string.concat(json, "]");
    }
}
