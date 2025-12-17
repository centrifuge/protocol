// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_Holdings
/// @notice Validates that no holdings exist before migration
/// @dev PRE-only validator
contract Validate_Holdings is BaseValidator {
    using stdJson for string;

    string constant HOLDINGS_QUERY = "holdings(limit: 1000) { items { assetId poolId tokenId } totalCount }";

    struct Holding {
        string assetId;
        uint256 poolId;
        string tokenId;
    }

    function supportedPhases() public pure override returns (Phase) {
        return Phase.PRE;
    }

    function name() public pure override returns (string memory) {
        return "Holdings";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        string memory json = ctx.store.query(HOLDINGS_QUERY);

        uint256 totalCount = json.readUint(".data.holdings.totalCount");

        if (totalCount == 0) {
            return ValidationResult({passed: true, validatorName: "Holdings", errors: new ValidationError[](0)});
        }

        Holding[] memory holdings = new Holding[](totalCount);
        string memory basePath = ".data.holdings.items";
        for (uint256 i = 0; i < totalCount; i++) {
            holdings[i].assetId = json.readString(_buildJsonPath(basePath, i, "assetId"));
            holdings[i].poolId = json.readUint(_buildJsonPath(basePath, i, "poolId"));
            holdings[i].tokenId = json.readString(_buildJsonPath(basePath, i, "tokenId"));
        }

        ValidationError[] memory errors = new ValidationError[](holdings.length + 1);

        errors[0] = _buildError({
            field: "totalCount",
            value: "Holdings",
            expected: "0",
            actual: _toString(totalCount),
            message: string.concat(_toString(totalCount), " holdings found")
        });

        for (uint256 i = 0; i < holdings.length; i++) {
            errors[i + 1] = _buildError({
                field: "holding",
                value: string.concat("Holding #", _toString(i + 1)),
                expected: "none",
                actual: holdings[i].assetId,
                message: string.concat(
                    "Holding exists for Pool ",
                    _toString(holdings[i].poolId),
                    ", ShareClass ",
                    holdings[i].tokenId,
                    ", AssetId: ",
                    holdings[i].assetId
                )
            });
        }

        return ValidationResult({passed: false, validatorName: "Holdings", errors: errors});
    }
}
