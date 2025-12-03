// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_OutstandingRedeems
/// @notice Validates that no users have outstanding redeem requests
/// @dev Checks ALL 4 amount fields (deposit, pending, queued, approved)
/// @dev
contract Validate_OutstandingRedeems is BaseValidator {
    using stdJson for string;

    string constant QUERY =
        "outstandingRedeems(limit: 1000) { items { poolId tokenId assetId account depositAmount pendingAmount queuedAmount approvedAmount approvedIndex approvedAtBlock } totalCount }";

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

    function supportedPhases() public pure override returns (Phase) {
        return Phase.PRE;
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        string memory json = ctx.store.query(QUERY);

        uint256 totalCount = json.readUint(".data.outstandingRedeems.totalCount");

        ValidationError[] memory errors = new ValidationError[](totalCount * 4);
        uint256 errorCount = 0;

        string memory basePath = ".data.outstandingRedeems.items";
        for (uint256 i = 0; i < totalCount; i++) {
            OutstandingRedeem memory redeem = _parseRedeem(json, basePath, i);

            // Skip if all amounts are zero
            if (
                redeem.depositAmount == 0 && redeem.pendingAmount == 0 && redeem.queuedAmount == 0
                    && redeem.approvedAmount == 0
            ) {
                continue;
            }

            string memory poolUser = string.concat("Pool ", _toString(redeem.poolId), " / User ", redeem.account);

            if (redeem.depositAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "depositAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(redeem.depositAmount),
                    message: "DEPOSITED shares on Hub"
                });
            }

            if (redeem.pendingAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "pendingAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(redeem.pendingAmount),
                    message: "PENDING shares (in-transit Spoke to Hub)"
                });
            }

            if (redeem.queuedAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "queuedAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(redeem.queuedAmount),
                    message: "QUEUED shares (for after claim)"
                });
            }

            if (redeem.approvedAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "approvedAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(redeem.approvedAmount),
                    message: "APPROVED shares (awaiting claim)"
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "OutstandingRedeems", errors: _trimErrors(errors, errorCount)
        });
    }

    function _parseRedeem(string memory json, string memory basePath, uint256 index)
        internal
        pure
        returns (OutstandingRedeem memory redeem)
    {
        // Required fields for validation
        redeem.poolId = json.readUint(_buildJsonPath(basePath, index, "poolId"));
        redeem.account = json.readString(_buildJsonPath(basePath, index, "account"));
        redeem.depositAmount = json.readUint(_buildJsonPath(basePath, index, "depositAmount"));
        redeem.pendingAmount = json.readUint(_buildJsonPath(basePath, index, "pendingAmount"));
        redeem.queuedAmount = json.readUint(_buildJsonPath(basePath, index, "queuedAmount"));
        redeem.approvedAmount = json.readUint(_buildJsonPath(basePath, index, "approvedAmount"));
        // Note: approvedAtBlock, approvedIndex, assetId, tokenId may be null - not parsed
    }
}
