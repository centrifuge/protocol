// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_CrossChainMessages
/// @notice Validates that no pending cross-chain messages exist
/// @dev Queries for messages not in "Executed" status
contract Validate_CrossChainMessages is BaseValidator {
    using stdJson for string;

    struct CrosschainMessage {
        string fromCentrifugeId;
        string id;
        uint256 index;
        string messageType;
        string poolId;
        string status;
        string toCentrifugeId;
    }

    function validate() public override returns (ValidationResult memory) {
        string memory json = _queryGraphQL(
            '{"query": "{ crosschainMessages(limit: 1000, where: { status_not: Executed }) { items { id index poolId messageType status fromCentrifugeId toCentrifugeId } totalCount } }"}'
        );

        uint256 totalCount = json.readUint(".data.crosschainMessages.totalCount");

        if (totalCount == 0) {
            return
                ValidationResult({passed: true, validatorName: "CrossChainMessages", errors: new ValidationError[](0)});
        }

        // Parse using stdJson helpers (see BaseValidator for why we don't use abi.decode)
        CrosschainMessage[] memory messages = new CrosschainMessage[](totalCount);
        string memory basePath = ".data.crosschainMessages.items";
        for (uint256 i = 0; i < totalCount; i++) {
            messages[i].fromCentrifugeId = json.readString(_buildJsonPath(basePath, i, "fromCentrifugeId"));
            messages[i].id = json.readString(_buildJsonPath(basePath, i, "id"));
            messages[i].index = json.readUint(_buildJsonPath(basePath, i, "index"));
            messages[i].messageType = json.readString(_buildJsonPath(basePath, i, "messageType"));
            messages[i].poolId = json.readString(_buildJsonPath(basePath, i, "poolId"));
            messages[i].status = json.readString(_buildJsonPath(basePath, i, "status"));
            messages[i].toCentrifugeId = json.readString(_buildJsonPath(basePath, i, "toCentrifugeId"));
        }

        // Create one error summarizing all pending messages + detail errors
        ValidationError[] memory errors = new ValidationError[](messages.length + 1);

        // Summary error
        errors[0] = _buildError({
            field: "totalCount",
            value: "CrossChainMessages",
            expected: "0",
            actual: _toString(totalCount),
            message: string.concat(_toString(totalCount), " pending cross-chain messages found")
        });

        // Detail each message
        for (uint256 i = 0; i < messages.length; i++) {
            errors[i + 1] = _buildError({
                field: "status",
                value: string.concat("Message ", messages[i].id),
                expected: "Executed",
                actual: messages[i].status,
                message: string.concat(
                    "Pool ",
                    bytes(messages[i].poolId).length > 0 ? messages[i].poolId : "N/A",
                    " - Type: ",
                    messages[i].messageType,
                    " - Status: ",
                    messages[i].status
                )
            });
        }

        return ValidationResult({passed: false, validatorName: "CrossChainMessages", errors: errors});
    }
}
