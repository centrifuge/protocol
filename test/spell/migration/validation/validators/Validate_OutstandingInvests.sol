// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_OutstandingInvests
/// @notice Validates that no users have outstanding invest requests
/// @dev Checks ALL 4 amount fields (pending, queued, deposit, approved)
/// @dev
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

    function supportedPhases() public pure override returns (Phase) {
        return Phase.PRE;
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        string memory json = ctx.store.query(_outstandingInvestsQuery(ctx));

        uint256 totalCount = json.readUint(".data.outstandingInvests.totalCount");

        ValidationError[] memory errors = new ValidationError[](totalCount * 4);
        uint256 errorCount = 0;

        string memory basePath = ".data.outstandingInvests.items";
        for (uint256 i = 0; i < totalCount; i++) {
            OutstandingInvest memory invest = _parseInvest(json, basePath, i);

            // Skip if all amounts are zero
            if (
                invest.pendingAmount == 0 && invest.queuedAmount == 0 && invest.depositAmount == 0
                    && invest.approvedAmount == 0
            ) {
                continue;
            }

            string memory poolUser = string.concat("Pool ", _toString(invest.poolId), " / User ", invest.account);

            if (invest.pendingAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "pendingAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(invest.pendingAmount),
                    message: string.concat(_toString(invest.poolId), " has PENDING assets (in-transit Spoke to Hub)")
                });
            }

            if (invest.queuedAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "queuedAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(invest.queuedAmount),
                    message: "QUEUED assets (for after claim)"
                });
            }

            if (invest.depositAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "depositAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(invest.depositAmount),
                    message: "DEPOSITED assets on Hub"
                });
            }

            if (invest.approvedAmount > 0) {
                errors[errorCount++] = _buildError({
                    field: "approvedAmount",
                    value: poolUser,
                    expected: "0",
                    actual: _toString(invest.approvedAmount),
                    message: "APPROVED assets (awaiting claim)"
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "OutstandingInvests", errors: _trimErrors(errors, errorCount)
        });
    }

    function _parseInvest(string memory json, string memory basePath, uint256 index)
        internal
        pure
        returns (OutstandingInvest memory invest)
    {
        // Required fields for validation
        invest.poolId = json.readUint(_buildJsonPath(basePath, index, "poolId"));
        invest.account = json.readString(_buildJsonPath(basePath, index, "account"));
        invest.pendingAmount = json.readUint(_buildJsonPath(basePath, index, "pendingAmount"));
        invest.queuedAmount = json.readUint(_buildJsonPath(basePath, index, "queuedAmount"));
        invest.depositAmount = json.readUint(_buildJsonPath(basePath, index, "depositAmount"));
        invest.approvedAmount = json.readUint(_buildJsonPath(basePath, index, "approvedAmount"));
        // Note: approvedAtBlock, approvedIndex, assetId, tokenId may be null - not parsed
    }

    function _outstandingInvestsQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        string memory poolIdsJson = "[";
        for (uint256 i = 0; i < ctx.pools.length; i++) {
            poolIdsJson = string.concat(poolIdsJson, _jsonValue(PoolId.unwrap(ctx.pools[i])));
            if (i < ctx.pools.length - 1) {
                poolIdsJson = string.concat(poolIdsJson, ", ");
            }
        }
        poolIdsJson = string.concat(poolIdsJson, "]");

        return string.concat(
            "outstandingInvests(limit: 1000, where: { poolId_in: ",
            poolIdsJson,
            " }) { items { poolId tokenId assetId account pendingAmount queuedAmount depositAmount approvedAmount approvedIndex approvedAtBlock } totalCount }"
        );
    }
}
