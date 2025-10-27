// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_OutstandingRedeems
/// @notice Validates that no users have outstanding redeem requests
/// @dev CRITICAL: Checks ALL 4 amount fields (deposit, pending, queued, approved)
contract Validate_OutstandingRedeems is BaseValidator {
    using stdJson for string;

    struct OutstandingRedeem {
        string account;
        uint256 approvedAmount;
        uint256 approvedAtBlock;
        uint256 approvedIndex;
        uint256 assetId;
        uint256 depositAmount;
        uint256 pendingAmount;
        uint256 poolId;
        uint256 queuedAmount;
        string tokenId;
    }

    function validate() public override returns (ValidationResult memory) {
        string memory json = _queryGraphQL(
            '{"query": "{ outstandingRedeems(limit: 1000, where: { OR: [{ pendingAmount_gt: \\"0\\" }, { queuedAmount_gt: \\"0\\" }, { depositAmount_gt: \\"0\\" }, { approvedAmount_gt: \\"0\\" }] }) { items { poolId tokenId assetId account depositAmount pendingAmount queuedAmount approvedAmount approvedIndex approvedAtBlock } totalCount } }"}'
        );

        uint256 totalCount = json.readUint(".data.outstandingRedeems.totalCount");

        // Parse using stdJson helpers (see BaseValidator for why we don't use abi.decode)
        OutstandingRedeem[] memory redeems = new OutstandingRedeem[](totalCount);
        string memory basePath = ".data.outstandingRedeems.items";
        for (uint256 i = 0; i < totalCount; i++) {
            redeems[i].account = json.readString(_buildJsonPath(basePath, i, "account"));
            redeems[i].approvedAmount = json.readUint(_buildJsonPath(basePath, i, "approvedAmount"));
            redeems[i].approvedAtBlock = json.readUint(_buildJsonPath(basePath, i, "approvedAtBlock"));
            redeems[i].approvedIndex = json.readUint(_buildJsonPath(basePath, i, "approvedIndex"));
            redeems[i].assetId = json.readUint(_buildJsonPath(basePath, i, "assetId"));
            redeems[i].depositAmount = json.readUint(_buildJsonPath(basePath, i, "depositAmount"));
            redeems[i].pendingAmount = json.readUint(_buildJsonPath(basePath, i, "pendingAmount"));
            redeems[i].poolId = json.readUint(_buildJsonPath(basePath, i, "poolId"));
            redeems[i].queuedAmount = json.readUint(_buildJsonPath(basePath, i, "queuedAmount"));
            redeems[i].tokenId = json.readString(_buildJsonPath(basePath, i, "tokenId"));
        }

        ValidationError[] memory errors = new ValidationError[](redeems.length * 4);
        uint256 errorCount = 0;

        for (uint256 i = 0; i < redeems.length; i++) {
            string memory poolUser =
                string.concat("Pool ", _toString(redeems[i].poolId), " / User ", redeems[i].account);

            if (redeems[i].depositAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "depositAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(redeems[i].depositAmount),
                    message: "DEPOSITED shares on Hub"
                });
            }

            if (redeems[i].pendingAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "pendingAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(redeems[i].pendingAmount),
                    message: "PENDING shares (in-transit Spoke to Hub)"
                });
            }

            if (redeems[i].queuedAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "queuedAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(redeems[i].queuedAmount),
                    message: "QUEUED shares (for after claim)"
                });
            }

            if (redeems[i].approvedAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "approvedAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(redeems[i].approvedAmount),
                    message: "APPROVED shares (awaiting claim)"
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "OutstandingRedeems", errors: _trimErrors(errors, errorCount)
        });
    }
}
