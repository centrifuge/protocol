// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_EpochOutstandingInvests
/// @notice Validates that no pools have pending batch invest requests
/// @dev
contract Validate_EpochOutstandingInvests is BaseValidator {
    using stdJson for string;

    string constant QUERY =
        "epochOutstandingInvests(limit: 1000) { items { poolId tokenId assetId pendingAssetsAmount } totalCount }";

    function supportedPhases() public pure override returns (Phase) {
        return Phase.PRE;
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        string memory json = ctx.store.query(QUERY);

        uint256 totalCount = json.readUint(".data.epochOutstandingInvests.totalCount");

        ValidationError[] memory errors = new ValidationError[](totalCount);
        uint256 errorCount = 0;

        string memory basePath = ".data.epochOutstandingInvests.items";
        for (uint256 i = 0; i < totalCount; i++) {
            uint256 pendingAmount = json.readUint(_buildJsonPath(basePath, i, "pendingAssetsAmount"));

            if (pendingAmount > 0) {
                uint256 poolId = json.readUint(_buildJsonPath(basePath, i, "poolId"));
                errors[errorCount++] = _buildError({
                    field: "pendingAssetsAmount",
                    value: string.concat("Pool ", _toString(poolId)),
                    expected: "0",
                    actual: _toString(pendingAmount),
                    message: string.concat(_toString(poolId), " has pending assets in batch")
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "EpochOutstandingInvests", errors: _trimErrors(errors, errorCount)
        });
    }
}
