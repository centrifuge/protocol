// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_CrossChainMessages
/// @notice Validates that no pending cross-chain messages exist
/// @dev
contract Validate_CrossChainMessages is BaseValidator {
    using stdJson for string;

    string constant QUERY =
        "crosschainMessages(limit: 1000) { items { id index poolId messageType status fromCentrifugeId toCentrifugeId } totalCount }";

    function supportedPhases() public pure override returns (Phase) {
        return Phase.PRE;
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        string memory json = ctx.store.query(QUERY);

        uint256 totalCount = json.readUint(".data.crosschainMessages.totalCount");

        if (totalCount == 0) {
            return
                ValidationResult({passed: true, validatorName: "CrossChainMessages", errors: new ValidationError[](0)});
        }

        uint256 itemCount = totalCount > 1000 ? 1000 : totalCount;

        string memory basePath = ".data.crosschainMessages.items";
        uint256 nonExecutedCount = 0;

        for (uint256 i = 0; i < itemCount; i++) {
            string memory status = json.readString(_buildJsonPath(basePath, i, "status"));
            if (!_stringsEqual(status, "Executed")) {
                nonExecutedCount++;
            }
        }

        if (nonExecutedCount == 0) {
            return
                ValidationResult({passed: true, validatorName: "CrossChainMessages", errors: new ValidationError[](0)});
        }

        ValidationError[] memory errors = new ValidationError[](nonExecutedCount + 1);
        uint256 errorIdx = 0;

        errors[errorIdx++] = _buildError({
            field: "totalCount",
            value: "CrossChainMessages",
            expected: "0",
            actual: _toString(nonExecutedCount),
            message: string.concat(_toString(nonExecutedCount), " pending cross-chain messages found")
        });

        // Detail each non-executed message
        for (uint256 i = 0; i < itemCount; i++) {
            string memory status = json.readString(_buildJsonPath(basePath, i, "status"));
            if (_stringsEqual(status, "Executed")) {
                continue;
            }

            string memory id = json.readString(_buildJsonPath(basePath, i, "id"));
            string memory messageType = json.readString(_buildJsonPath(basePath, i, "messageType"));
            string memory poolId = json.readString(_buildJsonPath(basePath, i, "poolId"));

            errors[errorIdx++] = _buildError({
                field: "status",
                value: string.concat("Message ", id),
                expected: "Executed",
                actual: status,
                message: string.concat(
                    "Pool ", bytes(poolId).length > 0 ? poolId : "N/A", " - Type: ", messageType, " - Status: ", status
                )
            });
        }

        return ValidationResult({passed: false, validatorName: "CrossChainMessages", errors: errors});
    }

    function _stringsEqual(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
