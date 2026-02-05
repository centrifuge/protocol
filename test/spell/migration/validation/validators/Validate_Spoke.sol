// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Spoke} from "../../../../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../../src/core/types/ShareClassId.sol";
import {IShareToken} from "../../../../../src/core/spoke/interfaces/IShareToken.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_Spoke
/// @notice Validates Spoke state before and after migration
/// @dev PRE: Caches data needed for POST validation
/// @dev POST: Validates pools are active, requestManagers are set and prices have been migrated
contract Validate_Spoke is BaseValidator {
    using stdJson for string;

    struct VaultData {
        uint256 poolId;
        string tokenId;
        string assetId;
    }

    function supportedPhases() public pure override returns (Phase) {
        return Phase.BOTH;
    }

    function name() public pure override returns (string memory) {
        return "Spoke";
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

        return ValidationResult({passed: true, validatorName: "Spoke (PRE)", errors: new ValidationError[](0)});
    }

    /// @notice POST-migration: Validate Spoke state was migrated correctly
    /// @dev Compares old vs new Spoke for pool active status, request managers, share tokens, and prices
    function _validatePost(ValidationContext memory ctx) internal returns (ValidationResult memory) {
        VaultData[] memory vaults = _getVaults(ctx);
        AssetId[] memory spokeAssetIds = _getSpokeAssetIds(ctx);

        // Pre-allocate errors: pool checks (isActive + requestManager) + vault checks + asset id checks (idToAsset + assetToId)
        ValidationError[] memory errors =
            new ValidationError[](ctx.pools.length * 2 + vaults.length * 3 + spokeAssetIds.length * 2);
        uint256 errorCount = 0;

        errorCount = _validatePools(ctx, errors, errorCount);
        errorCount = _validateVaults(ctx, vaults, errors, errorCount);
        errorCount = _validateSpokeAssetIds(ctx, spokeAssetIds, errors, errorCount);

        return ValidationResult({
            passed: errorCount == 0, validatorName: "Spoke (POST)", errors: _trimErrors(errors, errorCount)
        });
    }

    function _validatePools(ValidationContext memory ctx, ValidationError[] memory errors, uint256 errorCount)
        internal
        view
        returns (uint256)
    {
        Spoke oldSpoke = Spoke(ctx.old.inner.spoke);
        Spoke newSpoke = ctx.latest.core.spoke;

        for (uint256 i = 0; i < ctx.pools.length; i++) {
            PoolId pid = ctx.pools[i];
            string memory poolIdStr = string.concat("Pool ", _toString(PoolId.unwrap(pid)));

            bool oldIsActive = oldSpoke.isPoolActive(pid);
            if (!oldIsActive) continue;

            bool newIsActive = newSpoke.isPoolActive(pid);

            if (!newIsActive) {
                errors[errorCount++] = _buildError({
                    field: "isPoolActive",
                    value: poolIdStr,
                    expected: "Pool should be active",
                    actual: "Pool not active in new Spoke",
                    message: string.concat(poolIdStr, " not active in new Spoke")
                });
            }

            address expectedRequestManager = address(ctx.latest.asyncRequestManager);
            address actualRequestManager = address(newSpoke.requestManager(pid));

            if (actualRequestManager != expectedRequestManager) {
                errors[errorCount++] = _buildError({
                    field: "requestManager",
                    value: poolIdStr,
                    expected: string.concat("RequestManager: ", vm.toString(expectedRequestManager)),
                    actual: string.concat("RequestManager: ", vm.toString(actualRequestManager)),
                    message: string.concat(poolIdStr, " requestManager not set to asyncRequestManager")
                });
            }
        }

        return errorCount;
    }

    function _validateVaults(
        ValidationContext memory ctx,
        VaultData[] memory vaults,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        Spoke oldSpoke = Spoke(ctx.old.inner.spoke);
        Spoke newSpoke = ctx.latest.core.spoke;

        for (uint256 i = 0; i < vaults.length; i++) {
            errorCount = _validateVault(oldSpoke, newSpoke, vaults[i], errors, errorCount);
        }

        return errorCount;
    }

    function _validateSpokeAssetIds(
        ValidationContext memory ctx,
        AssetId[] memory spokeAssetIds,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        Spoke oldSpoke = Spoke(ctx.old.inner.spoke);
        Spoke newSpoke = ctx.latest.core.spoke;

        for (uint256 i = 0; i < spokeAssetIds.length; i++) {
            errorCount = _validateSpokeAssetId(oldSpoke, newSpoke, spokeAssetIds[i], errors, errorCount);
        }

        return errorCount;
    }

    /// @notice Cache data needed for POST validation
    /// @dev Called during PRE phase to ensure POST can retrieve from cache
    function _cachePostValidationData(ValidationContext memory ctx) internal {
        ctx.store.query(_vaultsQuery(ctx));
        ctx.store.query(_assetsQuery(ctx));
    }

    function _getVaults(ValidationContext memory ctx) internal returns (VaultData[] memory) {
        string memory json = ctx.store.get(_vaultsQuery(ctx));

        uint256 totalCount = json.readUint(".data.vaults.totalCount");

        VaultData[] memory vaults = new VaultData[](totalCount);
        string memory basePath = ".data.vaults.items";
        for (uint256 i = 0; i < totalCount; i++) {
            vaults[i].poolId = json.readUint(_buildJsonPath(basePath, i, "poolId"));
            vaults[i].tokenId = json.readString(_buildJsonPath(basePath, i, "tokenId"));
            vaults[i].assetId = json.readString(_buildJsonPath(basePath, i, "asset.id"));
        }

        return vaults;
    }

    function _validateVault(
        Spoke oldSpoke,
        Spoke newSpoke,
        VaultData memory vault,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        PoolId pid = PoolId.wrap(uint64(vault.poolId));
        ShareClassId scid = ShareClassId.wrap(bytes16(vm.parseBytes(vault.tokenId)));

        // The spell migrates only the first share class of a pool, so skip others
        if (!oldSpoke.isPoolActive(pid) || scid.index() != 1) return errorCount;

        string memory vaultIdStr = string.concat("Pool ", _toString(vault.poolId), " SC ", vault.tokenId);

        IShareToken oldShareToken = oldSpoke.shareToken(pid, scid);

        try newSpoke.shareToken(pid, scid) returns (IShareToken newShareToken) {
            if (address(oldShareToken) != address(newShareToken)) {
                errors[errorCount++] = _buildError({
                    field: "shareToken",
                    value: vaultIdStr,
                    expected: vm.toString(address(oldShareToken)),
                    actual: vm.toString(address(newShareToken)),
                    message: string.concat(vaultIdStr, " shareToken mismatch")
                });
                return errorCount;
            }
        } catch {
            errors[errorCount++] = _buildError({
                field: "shareToken",
                value: vaultIdStr,
                expected: vm.toString(address(oldShareToken)),
                actual: "",
                message: string.concat(vaultIdStr, " new shareToken not found")
            });

            return errorCount;
        }

        errorCount = _validateSharePrices(oldSpoke, newSpoke, vault, pid, scid, vaultIdStr, errors, errorCount);

        return errorCount;
    }

    function _validateSharePrices(
        Spoke oldSpoke,
        Spoke newSpoke,
        VaultData memory vault,
        PoolId pid,
        ShareClassId scid,
        string memory vaultIdStr,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        (uint64 oldComputedAt, uint64 oldMaxAge,) = oldSpoke.markersPricePoolPerShare(pid, scid);
        (uint64 newComputedAt, uint64 newMaxAge,) = newSpoke.markersPricePoolPerShare(pid, scid);

        if (oldComputedAt != newComputedAt || oldMaxAge != newMaxAge) {
            errors[errorCount++] = _buildError({
                field: "pricePoolPerShare",
                value: vaultIdStr,
                expected: string.concat("computedAt: ", _toString(oldComputedAt), ", maxAge: ", _toString(oldMaxAge)),
                actual: string.concat("computedAt: ", _toString(newComputedAt), ", maxAge: ", _toString(newMaxAge)),
                message: string.concat(vaultIdStr, " pricePoolPerShare mismatch")
            });
        }

        return _validateAssetPrices(oldSpoke, newSpoke, vault, pid, scid, vaultIdStr, errors, errorCount);
    }

    function _validateAssetPrices(
        Spoke oldSpoke,
        Spoke newSpoke,
        VaultData memory vault,
        PoolId pid,
        ShareClassId scid,
        string memory vaultIdStr,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        AssetId aid = AssetId.wrap(uint128(vm.parseUint(vault.assetId)));
        (uint64 oldAssetComputedAt, uint64 oldAssetMaxAge,) = oldSpoke.markersPricePoolPerAsset(pid, scid, aid);

        if (oldAssetComputedAt == 0) return errorCount;

        string memory vaultAssetStr = string.concat(vaultIdStr, " Asset ", vault.assetId);
        (uint64 newAssetComputedAt, uint64 newAssetMaxAge,) = newSpoke.markersPricePoolPerAsset(pid, scid, aid);

        if (oldAssetComputedAt != newAssetComputedAt || oldAssetMaxAge != newAssetMaxAge) {
            errors[errorCount++] = _buildError({
                field: "pricePoolPerAsset",
                value: vaultAssetStr,
                expected: string.concat(
                    "computedAt: ", _toString(oldAssetComputedAt), ", maxAge: ", _toString(oldAssetMaxAge)
                ),
                actual: string.concat(
                    "computedAt: ", _toString(newAssetComputedAt), ", maxAge: ", _toString(newAssetMaxAge)
                ),
                message: string.concat(vaultAssetStr, " pricePoolPerAsset mismatch")
            });
        }

        return errorCount;
    }

    function _getSpokeAssetIds(ValidationContext memory ctx) internal returns (AssetId[] memory assetIds) {
        string memory json = ctx.store.get(_assetsQuery(ctx));

        uint256 totalCount = json.readUint(".data.assets.totalCount");

        assetIds = new AssetId[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            assetIds[i] = AssetId.wrap(uint128(json.readUint(_buildJsonPath(".data.assets.items", i, "id"))));
        }
    }

    function _validateSpokeAssetId(
        Spoke oldSpoke,
        Spoke newSpoke,
        AssetId assetId,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        (address oldAsset, uint256 oldTokenId) = oldSpoke.idToAsset(assetId);
        (address newAsset, uint256 newTokenId) = newSpoke.idToAsset(assetId);

        if (oldAsset != newAsset || oldTokenId != newTokenId) {
            errors[errorCount++] = _buildError({
                field: "idToAsset",
                value: string.concat("AssetId ", _toString(AssetId.unwrap(assetId))),
                expected: string.concat("asset: ", vm.toString(oldAsset), ", tokenId: ", _toString(oldTokenId)),
                actual: string.concat("asset: ", vm.toString(newAsset), ", tokenId: ", _toString(newTokenId)),
                message: string.concat("AssetId ", _toString(AssetId.unwrap(assetId)), " idToAsset mismatch")
            });
        }

        AssetId oldReversedId = oldSpoke.assetToId(oldAsset, oldTokenId);
        AssetId newReversedId = newSpoke.assetToId(newAsset, newTokenId);

        if (!(oldReversedId == newReversedId)) {
            errors[errorCount++] = _buildError({
                field: "assetToId",
                value: string.concat("Asset ", vm.toString(oldAsset), " tokenId ", _toString(oldTokenId)),
                expected: string.concat("AssetId ", _toString(AssetId.unwrap(oldReversedId))),
                actual: string.concat("AssetId ", _toString(AssetId.unwrap(newReversedId))),
                message: string.concat(
                    "Asset ", vm.toString(oldAsset), " tokenId ", _toString(oldTokenId), " assetToId mismatch"
                )
            });
        }

        return errorCount;
    }

    function _vaultsQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        return string.concat(
            "vaults(limit: 1000, where: { centrifugeId: ",
            _jsonValue(ctx.localCentrifugeId),
            ", poolId_in: ",
            _buildPoolIdsJson(ctx.pools),
            " }) { items { asset { id } poolId tokenId } totalCount }"
        );
    }

    function _assetsQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        return string.concat(
            "assets(limit: 1000, where: { centrifugeId: ",
            _jsonValue(ctx.localCentrifugeId),
            " }) { items { id } totalCount }"
        );
    }
}
