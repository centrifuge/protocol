// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {TokenFactory} from "../../../../../src/core/spoke/factories/TokenFactory.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_TokenFactory
/// @notice Validates that tokenWards array was migrated correctly to new TokenFactory
/// @dev POST-only validator - verifies new TokenFactory has v3.1 equivalents of old tokenWards
/// @dev Old tokenWards contain Spoke and BalanceSheet (v3.0.1); new should have their v3.1 versions
contract Validate_TokenFactory is BaseValidator {
    function supportedPhases() public pure override returns (Phase) {
        return Phase.POST;
    }

    function name() public pure override returns (string memory) {
        return "TokenFactory";
    }

    function validate(ValidationContext memory ctx) public view override returns (ValidationResult memory) {
        TokenFactory newFactory = ctx.latest.core.tokenFactory;

        address[] memory newWards = _getTokenWards(newFactory);

        // Old tokenWards contained: Spoke (index 0), BalanceSheet (index 1)
        address[] memory expectedWards = new address[](2);
        expectedWards[0] = address(ctx.latest.core.spoke);
        expectedWards[1] = address(ctx.latest.core.balanceSheet);

        uint256 maxErrors = 1 + (expectedWards.length > newWards.length ? expectedWards.length : newWards.length);
        ValidationError[] memory errors = new ValidationError[](maxErrors);
        uint256 errorCount = 0;

        errorCount = _validateTokenWards(expectedWards, newWards, errors, errorCount);

        return ValidationResult({
            passed: errorCount == 0, validatorName: "TokenFactory (POST)", errors: _trimErrors(errors, errorCount)
        });
    }

    function _validateTokenWards(
        address[] memory expectedWards,
        address[] memory actualWards,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal pure returns (uint256) {
        if (expectedWards.length != actualWards.length) {
            errors[errorCount++] = _buildError({
                field: "tokenWards.length",
                value: "TokenFactory",
                expected: _toString(expectedWards.length),
                actual: _toString(actualWards.length),
                message: "TokenFactory tokenWards array length mismatch"
            });
        }

        uint256 minLength = expectedWards.length < actualWards.length ? expectedWards.length : actualWards.length;
        for (uint256 i = 0; i < minLength; i++) {
            if (expectedWards[i] != actualWards[i]) {
                string memory contractName = _getContractName(i);
                errors[errorCount++] = _buildError({
                    field: string.concat("tokenWards[", _toString(i), "]"),
                    value: string.concat("TokenFactory (", contractName, ")"),
                    expected: vm.toString(expectedWards[i]),
                    actual: vm.toString(actualWards[i]),
                    message: string.concat("TokenFactory tokenWards[", _toString(i), "] should be new ", contractName)
                });
            }
        }

        return errorCount;
    }

    function _getContractName(uint256 index) internal pure returns (string memory) {
        if (index == 0) return "Spoke";
        if (index == 1) return "BalanceSheet";
        return "Unknown";
    }

    function _getTokenWards(TokenFactory factory) internal view returns (address[] memory) {
        uint256 count = 0;
        while (true) {
            try factory.tokenWards(count) returns (address) {
                count++;
            } catch {
                break;
            }
        }

        address[] memory wards = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            wards[i] = factory.tokenWards(i);
        }

        return wards;
    }
}
