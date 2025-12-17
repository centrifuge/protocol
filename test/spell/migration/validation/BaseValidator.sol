// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {GraphQLStore} from "./GraphQLStore.sol";
import {V3ContractsExt} from "./ValidationTypes.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";

import {FullReport} from "../../../../script/FullDeployer.s.sol";

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title BaseValidator
/// @notice Abstract base class for all migration validators (pre and post)
/// @dev Each validator must implement validate(ValidationContext) and supportedPhases()
/// @dev Run validators with: forge test --match-contract Validate_ --ffi -vv
///
/// @dev JSON Parsing Note:
/// vm.parseJson + abi.decode does NOT work reliably for structs with mixed uint256/string fields.
/// It fails silently during abi.decode with complex struct layouts.
/// SOLUTION: Use stdJson helpers (readUint, readString) to parse each field individually.
/// This works for all struct types and is the recommended approach.
abstract contract BaseValidator is Test {
    using stdJson for string;

    constructor() {
        vm.label(address(this), string.concat("Validate_", name()));
    }

    // ============================================
    // TYPES
    // ============================================

    /// @notice Validation phase
    enum Phase {
        PRE,
        POST,
        BOTH
    }

    struct ValidationContext {
        Phase phase; // Current validation phase
        V3ContractsExt old; // v3.0.1 contracts (wrapped with test-only fields)
        FullReport latest; // v3.1 contracts (address(0) for PRE)
        PoolId[] pools; // All pools to migrate
        PoolId[] hubPools; // Pools where this chain is the hub
        uint16 localCentrifugeId; // Current chain's centrifugeId
        GraphQLStore store; // GraphQL query storage (PRE: query+store, POST: retrieve)
        bool isMainnet;
    }

    struct ValidationError {
        string field; // Field that failed (e.g., "pendingAssetsAmount")
        string value; // Identifier (e.g., "Pool 281474976710659")
        string expected; // Expected value (e.g., "0")
        string actual; // Actual value (e.g., "10000000")
        string message; // Human-readable message (e.g., "Pool has 10 USDC pending")
    }

    /// @notice Result from a validator execution
    struct ValidationResult {
        bool passed; // true if all checks passed
        string validatorName; // Name of the validator (e.g., "EpochOutstandingInvests")
        ValidationError[] errors; // Array of all errors found (empty if passed)
    }

    // ============================================
    // ABSTRACT INTERFACE
    // ============================================

    /// @notice Declare which phases this validator supports
    /// @dev Must be implemented by each validator
    /// @return Phase enum value (PRE, POST, or BOTH)
    function supportedPhases() public pure virtual returns (Phase);

    /// @notice Return the validator name for labeling and logging
    /// @return Validator name without "Validate_" prefix (e.g., "EpochOutstandingInvests")
    function name() public pure virtual returns (string memory);

    /// @notice Execute validation checks
    /// @dev Must be implemented by each validator
    /// @param ctx ValidationContext with phase, contracts, pools, and cache
    /// @return ValidationResult with pass/fail status and errors
    function validate(ValidationContext memory ctx) public virtual returns (ValidationResult memory);

    // ============================================
    // SHARED HELPERS
    // ============================================

    /// @notice Build a detailed validation error
    function _buildError(
        string memory field,
        string memory value,
        string memory expected,
        string memory actual,
        string memory message
    ) internal pure returns (ValidationError memory) {
        return ValidationError({field: field, value: value, expected: expected, actual: actual, message: message});
    }

    /// @notice Convert uint256 to string
    function _toString(uint256 value) internal pure returns (string memory) {
        return vm.toString(value);
    }

    /// @notice Convert string to JSON string
    function _jsonString(string memory value) internal pure returns (string memory) {
        return string.concat("\\\"", value, "\\\"");
    }

    /// @notice Convert uint256 to JSON string
    function _jsonValue(uint256 value) internal pure returns (string memory) {
        return _jsonString(vm.toString(value));
    }

    /// @notice Trim ValidationError array to actual error count
    function _trimErrors(ValidationError[] memory errors, uint256 errorCount)
        internal
        pure
        returns (ValidationError[] memory)
    {
        ValidationError[] memory trimmed = new ValidationError[](errorCount);
        for (uint256 i = 0; i < errorCount; i++) {
            trimmed[i] = errors[i];
        }
        return trimmed;
    }

    /// @notice Build JSON path for array element field
    /// @param basePath Base path to the array (e.g., ".data.items")
    /// @param index Array index
    /// @param fieldName Field name to access
    /// @return Full JSON path
    function _buildJsonPath(string memory basePath, uint256 index, string memory fieldName)
        internal
        pure
        returns (string memory)
    {
        return string.concat(basePath, "[", vm.toString(index), "].", fieldName);
    }

    /// @notice Build JSON array string from PoolId array for GraphQL queries
    function _buildPoolIdsJson(PoolId[] memory pools) internal pure returns (string memory) {
        string memory json = "[";
        for (uint256 i = 0; i < pools.length; i++) {
            json = string.concat(json, _jsonValue(PoolId.unwrap(pools[i])));
            if (i < pools.length - 1) {
                json = string.concat(json, ", ");
            }
        }
        return string.concat(json, "]");
    }
}
