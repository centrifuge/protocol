// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../../src/core/types/AssetId.sol";
import {IHubRegistry} from "../../../../../src/core/hub/interfaces/IHubRegistry.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_HubRegistry
/// @notice Validates HubRegistry state before and after migration
/// @dev PRE: Caches data needed for POST validation
/// @dev POST: Validates all pool managers, metadata, currency, and registered assets were migrated correctly
contract Validate_HubRegistry is BaseValidator {
    using stdJson for string;

    function supportedPhases() public pure override returns (Phase) {
        return Phase.BOTH;
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        if (ctx.phase == Phase.PRE) {
            return _validatePre(ctx);
        } else {
            return _validatePost(ctx);
        }
    }

    /// @notice PRE-migration: Cache data needed for POST validation
    /// @dev No actual validation performed, just queries and caches GraphQL data
    function _validatePre(ValidationContext memory ctx) internal returns (ValidationResult memory) {
        _cachePostValidationData(ctx);

        return ValidationResult({passed: true, validatorName: "HubRegistry (PRE)", errors: new ValidationError[](0)});
    }

    /// @notice POST-migration: Validate all HubRegistry state was migrated correctly
    /// @dev Compares old vs new HubRegistry for managers, metadata, currency, and asset registrations
    function _validatePost(ValidationContext memory ctx) internal returns (ValidationResult memory) {
        IHubRegistry oldHubRegistry = IHubRegistry(ctx.old.inner.hubRegistry);
        IHubRegistry newHubRegistry = ctx.latest.core.hubRegistry;

        AssetId[] memory assetIds = _getHubAssetIds(ctx);

        // Pre-allocate max possible errors (assume max 10 managers per pool + 1 metadata + 1 currency per pool + asset errors)
        ValidationError[] memory errors = new ValidationError[](ctx.pools.length * 12 + assetIds.length);
        uint256 errorCount = 0;

        for (uint256 i = 0; i < ctx.pools.length; i++) {
            PoolId pid = ctx.pools[i];
            errorCount = _validatePool(ctx, pid, PoolId.unwrap(pid), oldHubRegistry, newHubRegistry, errors, errorCount);
        }

        for (uint256 i = 0; i < assetIds.length; i++) {
            AssetId aid = assetIds[i];

            if (!newHubRegistry.isRegistered(aid)) {
                errors[errorCount++] = _buildError({
                    field: "assetRegistration",
                    value: string.concat("Asset ", _toString(AssetId.unwrap(aid))),
                    expected: "Asset should be registered",
                    actual: "Not registered in new HubRegistry",
                    message: string.concat("Asset ", _toString(AssetId.unwrap(aid)), " not registered")
                });
            }

            uint8 oldDecimals = oldHubRegistry.decimals(aid);
            uint8 newDecimals = newHubRegistry.decimals(aid);

            if (oldDecimals != newDecimals) {
                errors[errorCount++] = _buildError({
                    field: "assetDecimals",
                    value: string.concat("Asset ", _toString(AssetId.unwrap(aid))),
                    expected: string.concat("Decimals: ", _toString(oldDecimals)),
                    actual: string.concat("Decimals: ", _toString(newDecimals)),
                    message: string.concat("Asset ", _toString(AssetId.unwrap(aid)), " decimals mismatch")
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "HubRegistry (POST)", errors: _trimErrors(errors, errorCount)
        });
    }

    /// @notice Cache data needed for POST validation
    /// @dev Called during PRE phase to ensure POST can retrieve from cache
    function _cachePostValidationData(ValidationContext memory ctx) internal {
        for (uint256 i = 0; i < ctx.pools.length; i++) {
            ctx.store.query(_managersQuery(ctx, PoolId.unwrap(ctx.pools[i])));
        }

        ctx.store.query(_assetsQuery(ctx));
    }

    function _validatePool(
        ValidationContext memory ctx,
        PoolId pid,
        uint256 poolId,
        IHubRegistry oldHubRegistry,
        IHubRegistry newHubRegistry,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal returns (uint256) {
        string memory poolIdStr = string.concat("Pool ", _toString(poolId));

        address[] memory managers = _getHubManagers(ctx, pid);
        for (uint256 j = 0; j < managers.length; j++) {
            if (!newHubRegistry.manager(pid, managers[j])) {
                errors[errorCount++] = _buildError({
                    field: "manager",
                    value: poolIdStr,
                    expected: string.concat(vm.toString(managers[j]), " should be manager"),
                    actual: "Manager not set in new HubRegistry",
                    message: string.concat(poolIdStr, " missing manager ", vm.toString(managers[j]))
                });
            }
        }

        // Validate metadata
        bytes memory oldMetadata = oldHubRegistry.metadata(pid);
        bytes memory newMetadata = newHubRegistry.metadata(pid);
        if (keccak256(oldMetadata) != keccak256(newMetadata)) {
            errors[errorCount++] = _buildError({
                field: "metadata",
                value: poolIdStr,
                expected: string.concat("Metadata: ", vm.toString(oldMetadata)),
                actual: string.concat("Metadata: ", vm.toString(newMetadata)),
                message: string.concat(poolIdStr, " metadata mismatch")
            });
        }

        // Validate currency
        AssetId oldCurrency = oldHubRegistry.currency(pid);
        AssetId newCurrency = newHubRegistry.currency(pid);
        if (AssetId.unwrap(oldCurrency) != AssetId.unwrap(newCurrency)) {
            errors[errorCount++] = _buildError({
                field: "currency",
                value: poolIdStr,
                expected: string.concat("Currency: ", _toString(AssetId.unwrap(oldCurrency))),
                actual: string.concat("Currency: ", _toString(AssetId.unwrap(newCurrency))),
                message: string.concat(poolIdStr, " currency mismatch")
            });
        }

        return errorCount;
    }

    function _getHubManagers(ValidationContext memory ctx, PoolId poolId) internal returns (address[] memory managers) {
        string memory json = ctx.store.get(_managersQuery(ctx, PoolId.unwrap(poolId)));

        uint256 totalCount = json.readUint(".data.poolManagers.totalCount");

        managers = new address[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            managers[i] = json.readAddress(_buildJsonPath(".data.poolManagers.items", i, "address"));
        }
    }

    function _getHubAssetIds(ValidationContext memory ctx) internal returns (AssetId[] memory assetIds) {
        string memory json = ctx.store.get(_assetsQuery(ctx));

        uint256 totalCount = json.readUint(".data.assetRegistrations.totalCount");

        assetIds = new AssetId[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            assetIds[i] =
                AssetId.wrap(uint128(json.readUint(_buildJsonPath(".data.assetRegistrations.items", i, "assetId"))));
        }
    }

    function _managersQuery(ValidationContext memory ctx, uint256 poolId) internal pure returns (string memory) {
        return string.concat(
            "poolManagers(limit: 1000, where: { centrifugeId: ",
            _jsonValue(ctx.localCentrifugeId),
            ", poolId: ",
            _jsonValue(poolId),
            ", isHubManager: true }) { items { address } totalCount }"
        );
    }

    function _assetsQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        return string.concat(
            "assetRegistrations(limit: 1000, where: { centrifugeId: ",
            _jsonValue(ctx.localCentrifugeId),
            " }) { items { assetId } totalCount }"
        );
    }
}
