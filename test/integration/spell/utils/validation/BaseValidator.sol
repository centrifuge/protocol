// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {TestContracts} from "./TestContracts.sol";

import {IAuth} from "../../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../../src/core/types/PoolId.sol";

import {CacheStore} from "../../../../../script/utils/CacheStore.sol";
import {JsonUtils} from "../../../../../script/utils/JsonUtils.s.sol";
import {GraphQLQuery} from "../../../../../script/utils/GraphQLQuery.s.sol";
import {ContractsConfig as LiveContracts} from "../../../../../script/utils/EnvConfig.s.sol";

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
    string networkName;
}

/// @title BaseValidator
/// @notice Abstract base class for pre/post migration validators
/// @dev JSON Parsing: Use stdJson helpers (readUint, readString) per field instead of
///      vm.parseJson + abi.decode, which fails silently with mixed-type structs.
abstract contract BaseValidator is Test {
    using stdJson for string;
    using JsonUtils for *;

    string public name;
    ValidationError[] _errors;

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
        string expected;
        string actual;
        string message;
    }

    function validate(ValidationContext memory ctx) public virtual;

    // ============================================
    // SHARED HELPERS
    // ============================================

    function _buildError(
        string memory field,
        string memory value,
        string memory expected,
        string memory actual,
        string memory message
    ) internal pure returns (ValidationError memory) {
        return ValidationError({field: field, value: value, expected: expected, actual: actual, message: message});
    }

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

    function _checkWard(address wardedContract, address wardHolder, string memory label) internal {
        if (wardedContract == address(0) || wardHolder == address(0)) return;
        if (wardedContract.code.length == 0) return;

        try IAuth(wardedContract).wards(wardHolder) returns (uint256 val) {
            if (val != 1) {
                _errors.push(_buildError("ward", label, "1", vm.toString(val), string.concat("Ward missing: ", label)));
            }
        } catch {
            _errors.push(_buildError("ward", label, "callable", "reverted", string.concat("wards() reverted: ", label)));
        }
    }

    /// @notice Check that wardHolder does NOT have ward on wardedContract (inverse of _checkWard).
    /// @dev    Useful for migration spells that revoke permissions (e.g. denying a stale root).
    function _checkNoWard(address wardedContract, address wardHolder, string memory label) internal {
        if (wardedContract == address(0) || wardHolder == address(0)) return;
        if (wardedContract.code.length == 0) return;

        try IAuth(wardedContract).wards(wardHolder) returns (uint256 val) {
            if (val != 0) {
                _errors.push(
                    _buildError("ward", label, "0", vm.toString(val), string.concat("Ward should be removed: ", label))
                );
            }
        } catch {
            _errors.push(_buildError("ward", label, "callable", "reverted", string.concat("wards() reverted: ", label)));
        }
    }
}
