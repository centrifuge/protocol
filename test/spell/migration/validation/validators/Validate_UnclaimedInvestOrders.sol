// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_UnclaimedInvestOrders
/// @notice Validates that no users have unclaimed invest orders (fulfilled but not claimed)
/// @dev Checks investOrders with issuedSharesAmount > 0 and claimedAt = null
/// @dev These represent maxMint values in AsyncRequestManager.investments[vault][user]
contract Validate_UnclaimedInvestOrders is BaseValidator {
    using stdJson for string;

    function supportedPhases() public pure override returns (Phase) {
        return Phase.PRE;
    }

    function name() public pure override returns (string memory) {
        return "UnclaimedInvestOrders";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        string memory json = ctx.store.query(_unclaimedInvestOrdersQuery(ctx));

        uint256 totalCount = json.readUint(".data.investOrders.totalCount");

        if (totalCount == 0) {
            return
                ValidationResult({
                    passed: true, validatorName: "UnclaimedInvestOrders", errors: new ValidationError[](0)
                });
        }

        ValidationError[] memory errors = new ValidationError[](totalCount);
        uint256 errorCount = 0;

        string memory basePath = ".data.investOrders.items";
        for (uint256 i = 0; i < totalCount; i++) {
            uint256 poolId = json.readUint(_buildJsonPath(basePath, i, "poolId"));
            string memory account = json.readString(_buildJsonPath(basePath, i, "account"));
            uint256 issuedShares = json.readUint(_buildJsonPath(basePath, i, "issuedSharesAmount"));

            errors[errorCount++] = _buildError({
                field: "issuedSharesAmount",
                value: string.concat("Pool ", _toString(poolId), " / User ", account),
                expected: "0 or claimed",
                actual: _toString(issuedShares),
                message: "User has UNCLAIMED shares (maxMint) on Spoke side"
            });
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "UnclaimedInvestOrders", errors: _trimErrors(errors, errorCount)
        });
    }

    function _unclaimedInvestOrdersQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        // Note: String values use escaped quotes \"0\"
        // Note: claimedAt uses `null` (not 0) because:
        //   - null = "never claimed" (field has no value)
        //   - 0 = "claimed at Unix timestamp 0"
        return string.concat(
            "investOrders(limit: 1000, where: { poolId_in: ",
            _buildPoolIdsJson(ctx.pools),
            ", issuedSharesAmount_gt: \\\"0\\\", claimedAt: null }) ",
            "{ items { poolId tokenId assetId account issuedSharesAmount issuedAt } totalCount }"
        );
    }
}
