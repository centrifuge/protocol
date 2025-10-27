// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_EpochOutstandingInvests
/// @notice Validates that no pools have pending batch invest requests
/// @dev Queries epochOutstandingInvests from Centrifuge indexer
contract Validate_EpochOutstandingInvests is BaseValidator {
    using stdJson for string;

    struct EpochInvest {
        uint256 assetId;
        uint256 pendingAssetsAmount;
        uint256 poolId;
        string tokenId;
    }

    /// @notice Execute validation
    /// @return ValidationResult with errors for any pools with pending invests
    function validate() public override returns (ValidationResult memory) {
        // Query GraphQL API
        string memory json = _queryGraphQL(
            '{"query": "{ epochOutstandingInvests(limit: 1000) { items { poolId tokenId assetId pendingAssetsAmount } totalCount } }"}'
        );

        uint256 totalCount = json.readUint(".data.epochOutstandingInvests.totalCount");

        // Parse using stdJson helpers (see BaseValidator for why we don't use abi.decode)
        EpochInvest[] memory invests = new EpochInvest[](totalCount);
        string memory basePath = ".data.epochOutstandingInvests.items";
        for (uint256 i = 0; i < totalCount; i++) {
            invests[i].assetId = json.readUint(_buildJsonPath(basePath, i, "assetId"));
            invests[i].pendingAssetsAmount = json.readUint(_buildJsonPath(basePath, i, "pendingAssetsAmount"));
            invests[i].poolId = json.readUint(_buildJsonPath(basePath, i, "poolId"));
            invests[i].tokenId = json.readString(_buildJsonPath(basePath, i, "tokenId"));
        }

        ValidationError[] memory errors = new ValidationError[](invests.length);
        uint256 errorCount = 0;

        for (uint256 i = 0; i < invests.length; i++) {
            if (invests[i].pendingAssetsAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "pendingAssetsAmount",
                    value: string.concat("Pool ", _toString(invests[i].poolId)),
                    expected: "0",
                    actual: _toString(invests[i].pendingAssetsAmount),
                    message: string.concat(_toString(invests[i].poolId), " has pending assets in batch")
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "EpochOutstandingInvests", errors: _trimErrors(errors, errorCount)
        });
    }
}
