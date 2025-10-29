// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title BaseValidator
/// @notice Abstract base class for all pre-migration validators
/// @dev Each validator must implement validate() function
/// @dev Run validators with: forge test --match-contract Validate_ --ffi -vv
///
/// @dev JSON Parsing Note:
/// vm.parseJson + abi.decode does NOT work reliably for structs with mixed uint256/string fields.
/// It fails silently during abi.decode with complex struct layouts.
/// SOLUTION: Use stdJson helpers (readUint, readString) to parse each field individually.
/// This works for all struct types and is the recommended approach.
abstract contract BaseValidator is Test {
    using stdJson for string;

    // Centrifuge GraphQL API endpoint
    string constant GRAPHQL_API = "https://api.centrifuge.io/graphql";

    // ============================================
    // TYPES
    // ============================================

    /// @notice Detailed validation error with full context
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

    /// @notice Execute validation checks
    /// @dev Must be implemented by each validator
    /// @return ValidationResult with pass/fail status and errors
    function validate() public virtual returns (ValidationResult memory);

    // ============================================
    // SHARED HELPERS
    // ============================================

    /// @notice Query Centrifuge GraphQL API via curl
    /// @param query GraphQL query string (JSON format)
    /// @return JSON response as string
    function _queryGraphQL(string memory query) internal returns (string memory) {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] =
            string.concat("curl -s -X POST ", "-H 'Content-Type: application/json' ", "-d '", query, "' ", GRAPHQL_API);

        bytes memory result = vm.ffi(cmd);
        return string(result);
    }

    /// @notice Build a detailed validation error
    /// @param field The field that failed validation
    /// @param value The identifier/context for the error
    /// @param expected The expected value
    /// @param actual The actual value found
    /// @param message Human-readable error message
    /// @return ValidationError struct
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
    /// @dev Wrapper around vm.toString for convenience
    function _toString(uint256 value) internal pure returns (string memory) {
        return vm.toString(value);
    }

    /// @notice Trim ValidationError array to actual error count
    /// @dev Removes empty slots from pre-allocated error arrays
    /// @param errors The pre-allocated error array
    /// @param errorCount The actual number of errors
    /// @return Trimmed array with only valid errors
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
        return string.concat(basePath, "[", vm.toString(index), "].", fieldName);
    }
}
