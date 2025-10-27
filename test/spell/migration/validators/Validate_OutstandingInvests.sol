// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_OutstandingInvests
/// @notice Validates that no users have outstanding invest requests
/// @dev Checks ALL 4 amount fields (pending, queued, deposit, approved)
contract Validate_OutstandingInvests is BaseValidator {
    using stdJson for string;

    struct OutstandingInvest {
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
            '{"query": "{ outstandingInvests(limit: 1000, where: { OR: [{ pendingAmount_gt: \\"0\\" }, { queuedAmount_gt: \\"0\\" }, { depositAmount_gt: \\"0\\" }, { approvedAmount_gt: \\"0\\" }] }) { items { poolId tokenId assetId account pendingAmount queuedAmount depositAmount approvedAmount approvedIndex approvedAtBlock } totalCount } }"}'
        );

        uint256 totalCount = json.readUint(".data.outstandingInvests.totalCount");

        // Parse using stdJson helpers (see BaseValidator for why we don't use abi.decode)
        OutstandingInvest[] memory invests = new OutstandingInvest[](totalCount);
        string memory basePath = ".data.outstandingInvests.items";
        for (uint256 i = 0; i < totalCount; i++) {
            invests[i].account = json.readString(_buildJsonPath(basePath, i, "account"));
            invests[i].approvedAmount = json.readUint(_buildJsonPath(basePath, i, "approvedAmount"));
            invests[i].approvedAtBlock = json.readUint(_buildJsonPath(basePath, i, "approvedAtBlock"));
            invests[i].approvedIndex = json.readUint(_buildJsonPath(basePath, i, "approvedIndex"));
            invests[i].assetId = json.readUint(_buildJsonPath(basePath, i, "assetId"));
            invests[i].depositAmount = json.readUint(_buildJsonPath(basePath, i, "depositAmount"));
            invests[i].pendingAmount = json.readUint(_buildJsonPath(basePath, i, "pendingAmount"));
            invests[i].poolId = json.readUint(_buildJsonPath(basePath, i, "poolId"));
            invests[i].queuedAmount = json.readUint(_buildJsonPath(basePath, i, "queuedAmount"));
            invests[i].tokenId = json.readString(_buildJsonPath(basePath, i, "tokenId"));
        }

        ValidationError[] memory errors = new ValidationError[](invests.length * 4);
        uint256 errorCount = 0;

        for (uint256 i = 0; i < invests.length; i++) {
            string memory poolUser =
                string.concat("Pool ", _toString(invests[i].poolId), " / User ", invests[i].account);

            if (invests[i].pendingAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "pendingAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(invests[i].pendingAmount),
                    message: string.concat(
                        _toString(invests[i].poolId), " has PENDING assets (in-transit Spoke to Hub)"
                    )
                });
            }

            if (invests[i].queuedAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "queuedAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(invests[i].queuedAmount),
                    message: "QUEUED assets (for after claim)"
                });
            }

            if (invests[i].depositAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "depositAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(invests[i].depositAmount),
                    message: "DEPOSITED assets on Hub"
                });
            }

            if (invests[i].approvedAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "approvedAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(invests[i].approvedAmount),
                    message: "APPROVED assets (awaiting claim)"
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "OutstandingInvests", errors: _trimErrors(errors, errorCount)
        });
    }
}
