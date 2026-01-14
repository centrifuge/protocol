// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Spoke} from "../../../../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../../src/core/types/ShareClassId.sol";

import {SyncManager, ISyncDepositValuation} from "../../../../../src/vaults/SyncManager.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_SyncManager
/// @notice Validates that valuation and maxReserve were migrated correctly to new SyncManager
/// @dev BOTH-phase validator - compares old vs new SyncManager storage
contract Validate_SyncManager is BaseValidator {
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
        return "SyncManager";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        if (ctx.phase == Phase.PRE) {
            ctx.store.query(_vaultsQuery(ctx));
            return
                ValidationResult({passed: true, validatorName: "SyncManager (PRE)", errors: new ValidationError[](0)});
        }

        VaultData[] memory vaults = _getVaults(ctx);

        ValidationError[] memory errors = new ValidationError[](ctx.pools.length + vaults.length);
        uint256 errorCount = 0;

        SyncManager oldSyncMgr = SyncManager(ctx.old.inner.syncManager);
        SyncManager newSyncMgr = ctx.latest.syncManager;
        Spoke oldSpoke = Spoke(ctx.old.inner.spoke);

        for (uint256 i = 0; i < ctx.pools.length; i++) {
            PoolId poolId = ctx.pools[i];
            ShareClassId scId = ShareClassId.wrap(bytes16(uint128(PoolId.unwrap(poolId)) << 64 | 1));

            errorCount = _validateValuation(oldSyncMgr, newSyncMgr, poolId, scId, errors, errorCount);
        }

        for (uint256 i = 0; i < vaults.length; i++) {
            errorCount = _validateMaxReserveForVault(oldSyncMgr, newSyncMgr, oldSpoke, vaults[i], errors, errorCount);
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "SyncManager (POST)", errors: _trimErrors(errors, errorCount)
        });
    }

    function _validateValuation(
        SyncManager oldSyncMgr,
        SyncManager newSyncMgr,
        PoolId poolId,
        ShareClassId scId,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        ISyncDepositValuation oldVal = oldSyncMgr.valuation(poolId, scId);
        ISyncDepositValuation newVal = newSyncMgr.valuation(poolId, scId);

        if (address(oldVal) != address(newVal)) {
            errors[errorCount++] = _buildError({
                field: "valuation",
                value: string.concat("Pool ", _toString(PoolId.unwrap(poolId))),
                expected: vm.toString(address(oldVal)),
                actual: vm.toString(address(newVal)),
                message: string.concat("SyncManager valuation mismatch for Pool ", _toString(PoolId.unwrap(poolId)))
            });
        }

        return errorCount;
    }

    function _validateMaxReserveForVault(
        SyncManager oldSyncMgr,
        SyncManager newSyncMgr,
        Spoke oldSpoke,
        VaultData memory vault,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        PoolId poolId = PoolId.wrap(uint64(vault.poolId));
        ShareClassId scId = ShareClassId.wrap(bytes16(vm.parseBytes(vault.tokenId)));

        if (scId.index() != 0) return errorCount;

        AssetId assetId = AssetId.wrap(uint128(vm.parseUint(vault.assetId)));
        (address asset, uint256 tokenId) = oldSpoke.idToAsset(assetId);

        if (asset == address(0)) return errorCount;

        return _validateMaxReserve(oldSyncMgr, newSyncMgr, poolId, scId, asset, tokenId, errors, errorCount);
    }

    function _validateMaxReserve(
        SyncManager oldSyncMgr,
        SyncManager newSyncMgr,
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        uint128 oldMaxReserve = oldSyncMgr.maxReserve(poolId, scId, asset, tokenId);
        uint128 newMaxReserve = newSyncMgr.maxReserve(poolId, scId, asset, tokenId);

        if (oldMaxReserve != newMaxReserve) {
            errors[errorCount++] = _buildError({
                field: "maxReserve",
                value: string.concat(
                    "Pool ",
                    _toString(PoolId.unwrap(poolId)),
                    " Asset ",
                    vm.toString(asset),
                    " TokenId ",
                    _toString(tokenId)
                ),
                expected: _toString(oldMaxReserve),
                actual: _toString(newMaxReserve),
                message: string.concat("SyncManager maxReserve mismatch for Pool ", _toString(PoolId.unwrap(poolId)))
            });
        }

        return errorCount;
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

    function _vaultsQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        return string.concat(
            "vaults(limit: 1000, where: { centrifugeId: ",
            _jsonValue(ctx.localCentrifugeId),
            ", poolId_in: ",
            _buildPoolIdsJson(ctx.pools),
            " }) { items { asset { id } poolId tokenId } totalCount }"
        );
    }
}
