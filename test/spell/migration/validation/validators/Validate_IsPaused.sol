// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_IsPaused
/// @notice Validates that the old Root is paused before migration
/// @dev PRE: Ensures the protocol is paused to prevent state changes during migration
contract Validate_IsPaused is BaseValidator {
    function supportedPhases() public pure override returns (Phase) {
        return Phase.PRE;
    }

    function name() public pure override returns (string memory) {
        return "IsPaused";
    }

    function validate(ValidationContext memory ctx) public view override returns (ValidationResult memory) {
        ValidationError[] memory errors = new ValidationError[](1);
        uint256 errorCount = 0;

        bool isPaused = ctx.old.inner.root.paused();

        if (!isPaused) {
            errors[errorCount++] = _buildError({
                field: "root.paused",
                value: vm.toString(address(ctx.old.inner.root)),
                expected: "true",
                actual: "false",
                message: "Root must be paused before migration"
            });
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "IsPaused (PRE)", errors: _trimErrors(errors, errorCount)
        });
    }
}
