// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {AssetId} from "../../../../../src/core/types/AssetId.sol";
import {IVault} from "../../../../../src/core/spoke/interfaces/IVault.sol";
import {VaultDetails, VaultRegistry} from "../../../../../src/core/spoke/VaultRegistry.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_VaultRegistry
/// @notice Validates that vault details were migrated correctly to new VaultRegistry
/// @dev BOTH-phase validator - compares old Spoke vaultDetails vs new VaultRegistry
/// @dev In v3.0.1, Spoke had vaultDetails function (now extracted to VaultRegistry in v3.1)
contract Validate_VaultRegistry is BaseValidator {
    using stdJson for string;

    function supportedPhases() public pure override returns (Phase) {
        return Phase.BOTH;
    }

    function name() public pure override returns (string memory) {
        return "VaultRegistry";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        if (ctx.phase == Phase.PRE) {
            ctx.store.query(_linkedVaultsQuery(ctx));
            return
                ValidationResult({passed: true, validatorName: "VaultRegistry (PRE)", errors: new ValidationError[](0)});
        }

        address[] memory vaultAddrs = _getLinkedVaults(ctx);

        ValidationError[] memory errors = new ValidationError[](vaultAddrs.length * 2);
        uint256 errorCount = 0;

        // Cast old Spoke to VaultRegistry interface (v3.0.1 Spoke had vaultDetails)
        VaultRegistry oldVaultRegistry = VaultRegistry(ctx.old.inner.spoke);
        VaultRegistry newVaultRegistry = ctx.latest.core.vaultRegistry;

        for (uint256 i = 0; i < vaultAddrs.length; i++) {
            IVault vault = IVault(vaultAddrs[i]);
            errorCount = _validateVaultDetails(oldVaultRegistry, newVaultRegistry, vault, errors, errorCount);
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "VaultRegistry (POST)", errors: _trimErrors(errors, errorCount)
        });
    }

    function _validateVaultDetails(
        VaultRegistry oldVaultRegistry,
        VaultRegistry newVaultRegistry,
        IVault vault,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        VaultDetails memory oldDetails;
        VaultDetails memory newDetails;

        try oldVaultRegistry.vaultDetails(vault) returns (VaultDetails memory details) {
            oldDetails = details;
        } catch {
            return errorCount;
        }

        try newVaultRegistry.vaultDetails(vault) returns (VaultDetails memory details) {
            newDetails = details;
        } catch {
            errors[errorCount++] = _buildError({
                field: "vaultDetails",
                value: vm.toString(address(vault)),
                expected: "Vault registered in new VaultRegistry",
                actual: "Vault not found",
                message: string.concat("Vault ", vm.toString(address(vault)), " not registered in new VaultRegistry")
            });
            return errorCount;
        }

        if (AssetId.unwrap(oldDetails.assetId) != AssetId.unwrap(newDetails.assetId)) {
            errors[errorCount++] = _buildError({
                field: "vaultDetails.assetId",
                value: vm.toString(address(vault)),
                expected: _toString(AssetId.unwrap(oldDetails.assetId)),
                actual: _toString(AssetId.unwrap(newDetails.assetId)),
                message: string.concat("Vault ", vm.toString(address(vault)), " assetId mismatch")
            });
        }

        if (oldDetails.asset != newDetails.asset) {
            errors[errorCount++] = _buildError({
                field: "vaultDetails.asset",
                value: vm.toString(address(vault)),
                expected: vm.toString(oldDetails.asset),
                actual: vm.toString(newDetails.asset),
                message: string.concat("Vault ", vm.toString(address(vault)), " asset address mismatch")
            });
        }

        if (oldDetails.tokenId != newDetails.tokenId) {
            errors[errorCount++] = _buildError({
                field: "vaultDetails.tokenId",
                value: vm.toString(address(vault)),
                expected: _toString(oldDetails.tokenId),
                actual: _toString(newDetails.tokenId),
                message: string.concat("Vault ", vm.toString(address(vault)), " tokenId mismatch")
            });
        }

        if (oldDetails.isLinked != newDetails.isLinked) {
            errors[errorCount++] = _buildError({
                field: "vaultDetails.isLinked",
                value: vm.toString(address(vault)),
                expected: oldDetails.isLinked ? "true" : "false",
                actual: newDetails.isLinked ? "true" : "false",
                message: string.concat("Vault ", vm.toString(address(vault)), " isLinked mismatch")
            });
        }

        return errorCount;
    }

    function _getLinkedVaults(ValidationContext memory ctx) internal returns (address[] memory vaultAddrs) {
        string memory json = ctx.store.get(_linkedVaultsQuery(ctx));

        uint256 totalCount = json.readUint(".data.vaults.totalCount");

        vaultAddrs = new address[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            vaultAddrs[i] = json.readAddress(_buildJsonPath(".data.vaults.items", i, "id"));
        }
    }

    function _linkedVaultsQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        return string.concat(
            "vaults(limit: 1000, where: { centrifugeId: ",
            _jsonValue(ctx.localCentrifugeId),
            ", status: Linked }) { items { id } totalCount }"
        );
    }
}
