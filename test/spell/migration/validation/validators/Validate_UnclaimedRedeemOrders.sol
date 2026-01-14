// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_UnclaimedRedeemOrders
/// @notice Validates that no users have unclaimed redeem orders (fulfilled but not claimed)
/// @dev Checks redeemOrders with revokedAssetsAmount > 0 and claimedAt = null
/// @dev These represent maxWithdraw values in AsyncRequestManager.investments[vault][user]
contract Validate_UnclaimedRedeemOrders is BaseValidator {
    using stdJson for string;

    function supportedPhases() public pure override returns (Phase) {
        return Phase.PRE;
    }

    function name() public pure override returns (string memory) {
        return "UnclaimedRedeemOrders";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        string memory json = ctx.store.query(_unclaimedRedeemOrdersQuery(ctx));

        uint256 totalCount = json.readUint(".data.redeemOrders.totalCount");

        if (totalCount == 0) {
            return
                ValidationResult({
                    passed: true, validatorName: "UnclaimedRedeemOrders", errors: new ValidationError[](0)
                });
        }

        ValidationError[] memory errors = new ValidationError[](totalCount);
        uint256 errorCount = 0;

        string memory basePath = ".data.redeemOrders.items";
        for (uint256 i = 0; i < totalCount; i++) {
            uint256 poolId = json.readUint(_buildJsonPath(basePath, i, "poolId"));
            string memory account = json.readString(_buildJsonPath(basePath, i, "account"));
            uint256 revokedAssets = json.readUint(_buildJsonPath(basePath, i, "revokedAssetsAmount"));

            errors[errorCount++] = _buildError({
                field: "revokedAssetsAmount",
                value: string.concat("Pool ", _toString(poolId), " / User ", account),
                expected: "0 or claimed",
                actual: _toString(revokedAssets),
                message: "User has UNCLAIMED assets (maxWithdraw) on Spoke side"
            });
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "UnclaimedRedeemOrders", errors: _trimErrors(errors, errorCount)
        });
    }

    function _unclaimedRedeemOrdersQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        // Note: String values use escaped quotes \"0\"
        // Note: claimedAt uses `null` (not 0) because:
        //   - null = "never claimed" (field has no value)
        //   - 0 = "claimed at Unix timestamp 0"
        return string.concat(
            "redeemOrders(limit: 1000, where: { poolId_in: ",
            _buildPoolIdsJson(ctx.pools),
            ", revokedAssetsAmount_gt: \\\"0\\\", claimedAt: null }) ",
            "{ items { poolId tokenId assetId account revokedAssetsAmount revokedAt } totalCount }"
        );
    }
}
