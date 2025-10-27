// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

// Import all validators

import {BaseValidator} from "./BaseValidator.sol";
import {Validate_CrossChainMessages} from "./validators/Validate_CrossChainMessages.sol";
import {Validate_OutstandingInvests} from "./validators/Validate_OutstandingInvests.sol";
import {Validate_OutstandingRedeems} from "./validators/Validate_OutstandingRedeems.sol";
import {Validate_EpochOutstandingInvests} from "./validators/Validate_EpochOutstandingInvests.sol";
import {Validate_EpochOutstandingRedeems} from "./validators/Validate_EpochOutstandingRedeems.sol";

import {Test} from "forge-std/Test.sol";

/// @title PreMigrationValidation
/// @notice Orchestrates all pre-migration validation checks
/// @dev Run with: forge test --match-contract PreMigrationValidation --ffi -vv
contract PreMigrationValidation is Test {
    // ============================================
    // MAIN TEST
    // ============================================

    /// @notice Execute all validation checks
    /// @dev This is the single test to run before migration
    function test_RunAllValidations() public {
        emit log_string("");
        emit log_string("================================================================");
        emit log_string("     CENTRIFUGE v3.0.1 -> v3.1 PRE-MIGRATION VALIDATION");
        emit log_string("================================================================");
        emit log_string("");

        BaseValidator[] memory validators = _initializeValidators();

        emit log_string(string.concat("Running ", vm.toString(validators.length), " validators..."));
        emit log_string("");

        BaseValidator.ValidationResult[] memory results = new BaseValidator.ValidationResult[](validators.length);
        uint256 totalErrors = 0;

        for (uint256 i = 0; i < validators.length; i++) {
            results[i] = validators[i].validate();
            totalErrors += results[i].errors.length;
        }

        _displayReport(results, totalErrors);

        if (totalErrors > 0) {
            emit log_string("");
            emit log_string("================================================================");
            emit log_string("                  MIGRATION BLOCKED");
            emit log_string("================================================================");
            revert(string.concat("Pre-migration validation failed: ", vm.toString(totalErrors), " errors found"));
        }

        emit log_string("");
        emit log_string("================================================================");
        emit log_string("            ALL VALIDATIONS PASSED");
        emit log_string("         Migration can proceed safely.");
        emit log_string("================================================================");
    }

    // ============================================
    // VALIDATOR REGISTRY
    // ============================================

    /// @notice Initialize all validators
    /// @dev Each developer adds their validator here
    /// @return Array of all validators to run
    function _initializeValidators() internal returns (BaseValidator[] memory) {
        // @dev: Add your validator to this array
        BaseValidator[] memory validators = new BaseValidator[](5);

        // GraphQL-based validators (checking indexer state)
        validators[0] = new Validate_EpochOutstandingInvests();
        validators[1] = new Validate_EpochOutstandingRedeems();
        validators[2] = new Validate_OutstandingInvests();
        validators[3] = new Validate_OutstandingRedeems();
        validators[4] = new Validate_CrossChainMessages();

        // Custom on-chain validators (add by developers as needed)
        // validators[5] = new Validate_ShareClassManager();
        // validators[6] = new Validate_BatchRequestManager();
        // validators[7] = new Validate_Gateway();
        // validators[8] = new Validate_BalanceSheet();

        return validators;
    }

    // ============================================
    // REPORTING
    // ============================================

    /// @notice Display detailed validation report
    /// @param results Array of validation results
    /// @param totalErrors Total number of errors across all validators
    function _displayReport(BaseValidator.ValidationResult[] memory results, uint256 totalErrors) internal {
        emit log_string("================================================================");
        emit log_string("                    VALIDATION RESULTS");
        emit log_string("================================================================");
        emit log_string("");

        uint256 passedCount = 0;
        uint256 failedCount = 0;

        for (uint256 i = 0; i < results.length; i++) {
            BaseValidator.ValidationResult memory result = results[i];

            if (result.passed) {
                passedCount++;
                emit log_string(string.concat("[PASS] ", result.validatorName));
            } else {
                failedCount++;
                emit log_string(string.concat("[FAIL] ", result.validatorName));
                emit log_string(string.concat("   Errors: ", vm.toString(result.errors.length)));
                emit log_string("");

                // Display each error with full context
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
