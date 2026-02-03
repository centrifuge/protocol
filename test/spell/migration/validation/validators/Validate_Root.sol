// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAuth} from "../../../../../src/misc/interfaces/IAuth.sol";

import {ISafe} from "../../../../../src/admin/interfaces/ISafe.sol";
import {ProtocolGuardian} from "../../../../../src/admin/ProtocolGuardian.sol";

import {BaseValidator} from "../BaseValidator.sol";
import {IntegrationConstants} from "../../../../integration/utils/IntegrationConstants.sol";

/// @title Validate_Root
/// @notice Validates that Root has the ProtocolGuardian as ward and the ProtocolGuardian's Safe has the expected owners
contract Validate_Root is BaseValidator {
    address constant PROTOCOL_GUARDIAN_V31 = 0xCEb7eD5d5B3bAD3088f6A1697738B60d829635c6;
    address constant EXPECTED_SAFE = 0x9711730060C73Ee7Fcfe1890e8A0993858a7D225;

    function supportedPhases() public pure override returns (Phase) {
        return Phase.POST;
    }

    function name() public pure override returns (string memory) {
        return "Root";
    }

    function validate(ValidationContext memory ctx) public view override returns (ValidationResult memory) {
        // Allocate max possible errors: 1 for root ward + 1 for guardian safe + 9 for safe owners
        ValidationError[] memory errors = new ValidationError[](11);
        uint256 errorCount = 0;

        // Check that Root has ProtocolGuardian as ward
        uint256 wardStatus = IAuth(address(ctx.latest.root)).wards(PROTOCOL_GUARDIAN_V31);
        if (wardStatus != 1) {
            errors[errorCount++] = _buildError({
                field: "root.wards",
                value: vm.toString(PROTOCOL_GUARDIAN_V31),
                expected: "1",
                actual: _toString(wardStatus),
                message: string.concat("Root does not have expected ward: ", vm.toString(PROTOCOL_GUARDIAN_V31))
            });
        }

        // Check That Guardian has expected safe
        ProtocolGuardian guardian = ctx.latest.protocolGuardian;

        address actualSafe = address(guardian.safe());
        if (actualSafe != EXPECTED_SAFE) {
            errors[errorCount++] = _buildError({
                field: "guardian.safe",
                value: "protocolGuardian.safe()",
                expected: vm.toString(EXPECTED_SAFE),
                actual: vm.toString(actualSafe),
                message: "Guardian safe address mismatch"
            });
        }

        // Check that Safe has all expected owners
        address[9] memory expectedOwners;
        if (ctx.localCentrifugeId == IntegrationConstants.PLUME_CENTRIFUGE_ID) {
            expectedOwners = [
                0xd55114BfE98a2ca16202Aa741BeE571765292616,
                0x080001dBE12fA46A1d7C03fa0Cbf1839E367F155,
                0x9eDec77dd2651Ce062ab17e941347018AD4eAEA9,
                0x4d47a7a89478745200Bd51c26bA87664538Df541,
                0xE9441B34f71659cCA2bfE90d98ee0e57D9CAD28F,
                0x5e7A86178252Aeae9cBDa30f9C342c71799A3EE1,
                0x701Da7A0c8ee46521955CC29D32943d47E2c02b9,
                0x044671aCf58340Ac9d7AB782D3F93D1943fE24Bf,
                0xa542A86f0fFd0A3F32C765D175935F1714437598
            ];
        } else {
            expectedOwners = [
                0xd55114BfE98a2ca16202Aa741BeE571765292616,
                0x080001dBE12fA46A1d7C03fa0Cbf1839E367F155,
                0x9eDec77dd2651Ce062ab17e941347018AD4eAEA9,
                0x4d47a7a89478745200Bd51c26bA87664538Df541,
                0xE9441B34f71659cCA2bfE90d98ee0e57D9CAD28F,
                0x5e7A86178252Aeae9cBDa30f9C342c71799A3EE1,
                0x701Da7A0c8ee46521955CC29D32943d47E2c02b9,
                0x044671aCf58340Ac9d7AB782D3F93D1943fE24Bf,
                0xb307f0b2eDdB84EF63f3F9dc99a3A1a66D68EB3a
            ];
        }

        ISafe safe = ISafe(EXPECTED_SAFE);
        for (uint256 i = 0; i < expectedOwners.length; i++) {
            if (!safe.isOwner(expectedOwners[i])) {
                errors[errorCount++] = _buildError({
                    field: "safe.isOwner",
                    value: vm.toString(expectedOwners[i]),
                    expected: "true",
                    actual: "false",
                    message: string.concat("Expected owner not found in safe: ", vm.toString(expectedOwners[i]))
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "Root (POST)", errors: _trimErrors(errors, errorCount)
        });
    }
}
