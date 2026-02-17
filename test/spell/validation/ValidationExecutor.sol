// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {TestContracts} from "./TestContracts.sol";
import {BaseValidator, Contracts, ValidationContext} from "./BaseValidator.sol";

import {CacheStore} from "../../../script/utils/CacheStore.sol";
import {EnvConfig, Env} from "../../../script/utils/EnvConfig.s.sol";
import {GraphQLQuery} from "../../../script/utils/GraphQLQuery.s.sol";

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

    constructor(string memory network) {
        EnvConfig memory config = Env.load(network);

        ctx = ValidationContext({
            contracts: Contracts(config.contracts, empty),
            localCentrifugeId: config.network.centrifugeId,
            indexer: new GraphQLQuery(config.network.graphQLApi()),
            cache: new CacheStore(string.concat("spell-cache/validation/", network)),
            isMainnet: config.network.isMainnet()
        });
    }

    function runPreValidation(BaseValidator[] memory validators, bool shouldRevert) external {
        ctx.contracts.latest = empty;
        _execute(validators, "PRE-SPELL", shouldRevert);
    }

    function runCacheValidation(BaseValidator[] memory validators) external {
        ctx.cache.cleanAndCreateCacheDir();
        ctx.contracts.latest = empty;
        _execute(validators, "", false);
    }

    function runPostValidation(BaseValidator[] memory validators, TestContracts memory latest) external {
        ctx.contracts.latest = latest;
        _execute(validators, "POST-SPELL", true);
    }

    function _execute(BaseValidator[] memory validators, string memory phaseName, bool shouldRevert)
        internal
        returns (bool)
    {
        ValidationResult[] memory results = new ValidationResult[](validators.length);
        uint256 totalErrors = 0;

        for (uint256 i = 0; i < validators.length; i++) {
            validators[i].validate(ctx);

            results[i].name = validators[i].name();
            results[i].errors = validators[i].errors();

            totalErrors += results[i].errors.length;
        }

        if (bytes(phaseName).length != 0) {
            _displayReport(results, totalErrors, phaseName, shouldRevert);
        }

        if (totalErrors > 0) {
            if (shouldRevert) {
                revert(string.concat(phaseName, " validation failed: ", vm.toString(totalErrors), " errors"));
            }
            return false;
        }

        return true;
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
