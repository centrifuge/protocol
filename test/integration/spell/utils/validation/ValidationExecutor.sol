// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {TestContracts} from "./TestContracts.sol";
import {BaseValidator, Contracts, ValidationContext} from "./BaseValidator.sol";

import {CacheStore} from "../../../../../script/utils/CacheStore.sol";
import {EnvConfig, Env} from "../../../../../script/utils/EnvConfig.s.sol";
import {GraphQLQuery} from "../../../../../script/utils/GraphQLQuery.s.sol";

import {Script} from "forge-std/Script.sol";

/// @notice Result from a single validator execution
struct ValidationResult {
    string name;
    BaseValidator.ValidationError[] errors;
}

contract ValidationExecutor is Script {
    event log_string(string);

    ValidationContext ctx;
    TestContracts empty;
    mapping(BaseValidator => bool) executed;

    /// @dev Serialized baseline error-identity keys, captured pre-cast and read
    ///      post-cast from this SAME executor instance. Kept in storage as a
    ///      compact string so it survives the cast without crossing an ABI
    ///      boundary (see README, "Legacy-codegen constraints").
    string private _baselineKeys;

    constructor(string memory network, string memory executorName) {
        EnvConfig memory config = Env.load(network);

        ctx = ValidationContext({
            contracts: Contracts(config.contracts, empty),
            localCentrifugeId: config.network.centrifugeId,
            indexer: new GraphQLQuery(config.network.graphQLApi()),
            cache: new CacheStore(string.concat("spell-cache/validation/", executorName, "/", network)),
            isMainnet: config.network.isMainnet(),
            networkName: network
        });
    }

    function runPreValidation(BaseValidator[] memory validators, bool shouldRevert) external {
        ctx.contracts.latest = empty;
        _execute(validators, "PRE", shouldRevert);
    }

    function runCacheValidation(BaseValidator[] memory validators) external {
        ctx.cache.cleanAndCreateCacheDir();
        ctx.contracts.latest = empty;
        _execute(validators, "", false);
    }

    function runPostValidation(BaseValidator[] memory validators, TestContracts memory latest) external {
        ctx.contracts.latest = latest;
        _execute(validators, "POST", true);
    }

    /// @notice Migration-aware POST: no `latest`. Use for spells that deploy no
    ///         new core contracts (e.g. an ops/migration spell). `ctx.contracts.latest`
    ///         is left empty so a validator that erroneously reads it gets the
    ///         zero struct and fails loudly, rather than silently aliasing `live`.
    function runPostValidation(BaseValidator[] memory validators) external {
        ctx.contracts.latest = empty;
        _execute(validators, "POST", true);
    }

    /// @notice Run validators against current (pre-cast) state and store a
    ///         baseline of error-identity keys in this executor's storage, so the
    ///         post-cast diff can tolerate errors that pre-date the spell.
    /// @dev    The matching `runValidationDiffPost` must be called on this SAME
    ///         executor instance. The full per-validator report is still emitted.
    function captureErrorBaseline(BaseValidator[] memory validators) external {
        ctx.contracts.latest = empty;
        ValidationResult[] memory results = _run(validators);
        _baselineKeys = _serializeKeys(results);
        _displayReport(results, _countErrors(results), "PRE-CAST BASELINE", false);
    }

    /// @notice Run validators against current (post-cast) state and revert ONLY
    ///         if an error is present now whose identity key was NOT in the
    ///         baseline captured by `captureErrorBaseline` on this same executor.
    ///         Errors are classified PRE-EXISTING / REGRESSION / IMPROVED.
    /// @dev    Error identity is `keccak256(name | field | value)` — `actual` is
    ///         deliberately excluded because it legitimately drifts (e.g. balances)
    ///         and would mask a tolerated pre-existing error as a fresh regression.
    function runValidationDiffPost(BaseValidator[] memory validators) external {
        ctx.contracts.latest = empty;
        ValidationResult[] memory results = _run(validators);

        uint256 regressions = _displayDiffReport(results, _baselineKeys);

        if (regressions > 0) {
            revert(
                string.concat(
                    "Spell introduced ", vm.toString(regressions), " new structural validator error(s) (REGRESSION)"
                )
            );
        }
    }

    function _run(BaseValidator[] memory validators) internal returns (ValidationResult[] memory results) {
        results = new ValidationResult[](validators.length);

        for (uint256 i = 0; i < validators.length; i++) {
            require(
                !executed[validators[i]], string.concat("The validator ", validators[i].name(), " was already executed")
            );
            executed[validators[i]] = true;

            validators[i].validate(ctx);

            results[i].name = validators[i].name();
            results[i].errors = validators[i].errors();
        }
    }

    function _execute(BaseValidator[] memory validators, string memory phaseName, bool shouldRevert) internal {
        ValidationResult[] memory results = _run(validators);
        uint256 totalErrors = _countErrors(results);

        if (bytes(phaseName).length != 0) {
            _displayReport(results, totalErrors, phaseName, shouldRevert);
        }

        if (shouldRevert && totalErrors > 0) {
            revert(string.concat(phaseName, " validation failed: ", vm.toString(totalErrors), " errors"));
        }
    }

    function _countErrors(ValidationResult[] memory results) private pure returns (uint256 total) {
        for (uint256 i = 0; i < results.length; i++) {
            total += results[i].errors.length;
        }
    }

    /// @dev `vm.toString(bytes32)` is "0x" + 64 hex chars (66); plus the "\n"
    ///      record separator that makes 67 the fixed stride per baseline key.
    uint256 private constant _KEY_STRIDE = 67;

    /// @dev Error identity excludes `actual` (drifts) and `expected`/`message`
    ///      (presentation). Two errors are "the same" iff same validator name,
    ///      field and value.
    function _errorKey(string memory name, BaseValidator.ValidationError memory err) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(name, "|", err.field, "|", err.value));
    }

    /// @dev Serialize every error's identity key as a newline-separated list of
    ///      fixed-width hex strings — the on-disk baseline format.
    function _serializeKeys(ValidationResult[] memory results) private pure returns (string memory out) {
        for (uint256 i = 0; i < results.length; i++) {
            for (uint256 j = 0; j < results[i].errors.length; j++) {
                out = string.concat(out, vm.toString(_errorKey(results[i].name, results[i].errors[j])), "\n");
            }
        }
    }

    /// @dev Substring search; needle is a fixed-width hex key, and the newline
    ///      separators make accidental cross-record matches impossible.
    function _contains(bytes memory haystack, bytes memory needle) private pure returns (bool) {
        if (needle.length == 0) return true;
        if (haystack.length < needle.length) return false;
        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    /// @dev Classify every post-cast error against the cached baseline keys and
    ///      log it. Returns the count of REGRESSION errors (present now, absent
    ///      from the baseline). IMPROVED is derived: every baseline error is
    ///      either still present (PRE-EXISTING) or resolved (IMPROVED).
    function _displayDiffReport(ValidationResult[] memory results, string memory baseline)
        private
        returns (uint256 regressions)
    {
        emit log_string("");
        emit log_string("================================================================");
        emit log_string("     STRUCTURAL VALIDATOR DIFF (pre-cast vs post-cast)");
        emit log_string("================================================================");

        bytes memory baselineBytes = bytes(baseline);
        uint256 preExisting;

        for (uint256 i = 0; i < results.length; i++) {
            for (uint256 j = 0; j < results[i].errors.length; j++) {
                BaseValidator.ValidationError memory err = results[i].errors[j];
                string memory keyHex = vm.toString(_errorKey(results[i].name, err));

                if (_contains(baselineBytes, bytes(keyHex))) {
                    preExisting++;
                    emit log_string(string.concat(
                            "[PRE-EXISTING] ", results[i].name, ": ", err.field, " / ", err.value
                        ));
                } else {
                    regressions++;
                    emit log_string(string.concat(
                            "[REGRESSION]   ", results[i].name, ": ", err.field, " / ", err.value, " -> ", err.message
                        ));
                }
            }
        }

        uint256 baselineCount = baselineBytes.length / _KEY_STRIDE;
        uint256 improved = baselineCount > preExisting ? baselineCount - preExisting : 0;

        emit log_string("----------------------------------------------------------------");
        emit log_string(string.concat("Pre-existing (tolerated): ", vm.toString(preExisting)));
        emit log_string(string.concat("Improved (resolved):      ", vm.toString(improved)));
        emit log_string(string.concat("Regressions (NEW):        ", vm.toString(regressions)));
        emit log_string("================================================================");
    }

    function _displayReport(
        ValidationResult[] memory results,
        uint256 totalErrors,
        string memory phaseName,
        bool shouldRevert
    ) private {
        emit log_string("");
        emit log_string("================================================================");
        emit log_string(string.concat("     ", phaseName, " VALIDATION RESULTS"));
        emit log_string("================================================================");
        emit log_string("");

        uint256 passedCount = 0;
        uint256 failedCount = 0;

        for (uint256 i = 0; i < results.length; i++) {
            ValidationResult memory result = results[i];

            if (result.errors.length == 0) {
                passedCount++;
                emit log_string(string.concat("[PASS] ", result.name));
            } else {
                failedCount++;
                string memory prefix = shouldRevert ? "[FAIL]" : "[WARNING]";
                emit log_string(string.concat(prefix, " ", result.name));
                emit log_string(string.concat("   Errors: ", vm.toString(result.errors.length)));
                emit log_string("");

                for (uint256 j = 0; j < result.errors.length; j++) {
                    BaseValidator.ValidationError memory err = result.errors[j];
                    emit log_string(string.concat("   Error #", vm.toString(j + 1), ":"));
                    emit log_string(string.concat("   - Message:  ", err.message));
                    emit log_string(string.concat("   - Field:    ", err.field));
                    emit log_string(string.concat("   - Value:    ", err.value));
                    emit log_string(string.concat("   - Expected: ", err.expected));
                    emit log_string(string.concat("   - Actual:   ", err.actual));
                    emit log_string("");
                }
            }
        }

        emit log_string("================================================================");
        emit log_string("                         SUMMARY");
        emit log_string("================================================================");
        emit log_string(string.concat("Total Validators: ", vm.toString(results.length)));
        emit log_string(string.concat("Passed:           ", vm.toString(passedCount)));
        emit log_string(string.concat("Failed:           ", vm.toString(failedCount)));
        emit log_string(string.concat("Total Errors:     ", vm.toString(totalErrors)));
        emit log_string("================================================================");
    }
}
