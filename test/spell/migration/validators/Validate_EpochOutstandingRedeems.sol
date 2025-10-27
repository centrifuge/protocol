// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_EpochOutstandingRedeems
/// @notice Validates that no pools have pending batch redeem requests
/// @dev Queries epochOutstandingRedeems from Centrifuge indexer
contract Validate_EpochOutstandingRedeems is BaseValidator {
    using stdJson for string;

    struct EpochRedeem {
        uint256 assetId;
        uint256 pendingSharesAmount;
        uint256 poolId;
        string tokenId;
    }

    function validate() public override returns (ValidationResult memory) {
        string memory json = _queryGraphQL(
            '{"query": "{ epochOutstandingRedeems(limit: 1000) { items { poolId tokenId assetId pendingSharesAmount } totalCount } }"}'
        );

        uint256 totalCount = json.readUint(".data.epochOutstandingRedeems.totalCount");

        // Parse using stdJson helpers (see BaseValidator for why we don't use abi.decode)
        EpochRedeem[] memory redeems = new EpochRedeem[](totalCount);
        string memory basePath = ".data.epochOutstandingRedeems.items";
        for (uint256 i = 0; i < totalCount; i++) {
            redeems[i].assetId = json.readUint(_buildJsonPath(basePath, i, "assetId"));
            redeems[i].pendingSharesAmount = json.readUint(_buildJsonPath(basePath, i, "pendingSharesAmount"));
            redeems[i].poolId = json.readUint(_buildJsonPath(basePath, i, "poolId"));
            redeems[i].tokenId = json.readString(_buildJsonPath(basePath, i, "tokenId"));
        }

        ValidationError[] memory errors = new ValidationError[](redeems.length);
        uint256 errorCount = 0;

        for (uint256 i = 0; i < redeems.length; i++) {
            if (redeems[i].pendingSharesAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "pendingSharesAmount",
                    value: string.concat("Pool ", _toString(redeems[i].poolId)),
                    expected: "0",
                    actual: _toString(redeems[i].pendingSharesAmount),
                    message: string.concat(
                        _toString(redeems[i].poolId),
                        " has ",
                        _toString(redeems[i].pendingSharesAmount / 1e18),
                        " shares pending redeem in batch"
                    )
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "EpochOutstandingRedeems", errors: _trimErrors(errors, errorCount)
        });
    }
}
