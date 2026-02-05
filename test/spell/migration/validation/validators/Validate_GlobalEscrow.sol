// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "../../../../../src/misc/interfaces/IERC20.sol";
import {IERC7575Share, IERC165} from "../../../../../src/misc/interfaces/IERC7575.sol";

import {console} from "forge-std/console.sol";

import {BaseValidator} from "../BaseValidator.sol";
import {AssetInfo} from "../../../../../src/spell/migration_v3.1/MigrationSpell.sol";

/// @title Validate_GlobalEscrow
/// @notice Validates that GlobalEscrow has zero balance for all ERC20 assets (excludes share tokens)
/// @dev POST: Asserts migration swept all ERC20 funds from GlobalEscrow. Share tokens are skipped
///      (users must claim via old contracts) and logged as warnings.
contract Validate_GlobalEscrow is BaseValidator {
    function supportedPhases() public pure override returns (Phase) {
        return Phase.POST;
    }

    function name() public pure override returns (string memory) {
        return "GlobalEscrow";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        address globalEscrow = ctx.old.globalEscrow;
        AssetInfo[] memory assets = ctx.queryService.assets();

        if (assets.length == 0) {
            return
                ValidationResult({passed: true, validatorName: "GlobalEscrow (POST)", errors: new ValidationError[](0)});
        }

        ValidationError[] memory errors = new ValidationError[](assets.length);
        uint256 errorCount = 0;

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i].addr;
            uint256 tokenId = assets[i].tokenId;

            if (tokenId != 0) continue;

            uint256 balance;
            try IERC20(asset).balanceOf(globalEscrow) returns (uint256 bal) {
                balance = bal;
            } catch {
                continue; // Skip assets that revert on balanceOf
            }

            if (balance == 0) continue;

            bool isShare = false;
            try IERC165(asset).supportsInterface(type(IERC7575Share).interfaceId) returns (bool result) {
                isShare = result;
            } catch {}

            if (isShare) {
                // Share tokens are expected to remain in GlobalEscrow since they should be processed pre-migration, just warn
                console.log(
                    "[WARN] GlobalEscrow has share token balance (expected - users must claim via old contracts):"
                );
                console.log("       Asset:", asset);
                console.log("       Balance:", balance);
                continue;
            }

            // ERC20 tokens should have been swept during migration
            errors[errorCount++] = _buildError({
                field: "globalEscrow.balance",
                value: vm.toString(asset),
                expected: "0",
                actual: _toString(balance),
                message: string.concat(
                    "GlobalEscrow has non-zero ERC20 balance for asset ", vm.toString(asset), ": ", _toString(balance)
                )
            });
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "GlobalEscrow (POST)", errors: _trimErrors(errors, errorCount)
        });
    }
}
