// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "../../../../../src/misc/interfaces/IERC20.sol";
import {IERC6909} from "../../../../../src/misc/interfaces/IERC6909.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";
import {AssetInfo} from "../../../../../src/spell/migration_v3.1/MigrationSpell.sol";

/// @title Validate_VaultRouter
/// @notice Validates VaultRouter state before migration
/// @dev PRE: Validates no assets are associated with the router escrow
contract Validate_VaultRouter is BaseValidator {
    using stdJson for string;

    function supportedPhases() public pure override returns (Phase) {
        return Phase.PRE;
    }

    function name() public pure override returns (string memory) {
        return "VaultRouter";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        return _validatePre(ctx);
    }

    /// @notice PRE-migration: Verify no assets are locked in the VaultRouter's escrow
    /// @dev Migration requires the router escrow to be empty (no pending locked deposit requests)
    function _validatePre(ValidationContext memory ctx) internal returns (ValidationResult memory) {
        // Get all assets registered on this chain
        AssetInfo[] memory assets = ctx.queryService.assets();

        // Pre-allocate max possible errors (one per asset)
        ValidationError[] memory errors = new ValidationError[](assets.length);
        uint256 errorCount = 0;

        // Check each asset balance in the router escrow
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 balance = _getAssetBalance(assets[i].addr, assets[i].tokenId, ctx.old.routerEscrow);

            if (balance > 0) {
                errors[errorCount++] = _buildError({
                    field: "escrowBalance",
                    value: vm.toString(assets[i].addr),
                    expected: "0",
                    actual: _toString(balance),
                    message: string.concat(
                        "VaultRouter escrow has non-zero balance for asset ",
                        vm.toString(assets[i].addr),
                        " tokenId ",
                        _toString(assets[i].tokenId),
                        ": ",
                        _toString(balance)
                    )
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "VaultRouter (PRE)", errors: _trimErrors(errors, errorCount)
        });
    }

    function _getAssetBalance(address asset, uint256 tokenId, address escrow) internal view returns (uint256) {
        if (tokenId == 0) {
            try IERC20(asset).balanceOf(escrow) returns (uint256 bal) {
                return bal;
            } catch {
                return 0; // Skip malicious assets that revert
            }
        } else {
            try IERC6909(asset).balanceOf(escrow, tokenId) returns (uint256 bal) {
                return bal;
            } catch {
                return 0; // Skip malicious assets that revert
            }
        }
    }
}
