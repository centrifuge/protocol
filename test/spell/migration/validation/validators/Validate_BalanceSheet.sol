// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../../src/core/types/ShareClassId.sol";
import {IBalanceSheet} from "../../../../../src/core/spoke/interfaces/IBalanceSheet.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_BalanceSheet
/// @notice Validates BalanceSheet state before and after migration
/// @dev PRE: Validates no queued assets or shares exist
/// @dev POST: Validates all pool managers were migrated correctly
contract Validate_BalanceSheet is BaseValidator {
    using stdJson for string;

    struct Vault {
        uint256 poolId;
        string tokenId;
        string assetId;
    }

    function supportedPhases() public pure override returns (Phase) {
        return Phase.BOTH;
    }

    function name() public pure override returns (string memory) {
        return "BalanceSheet";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        if (ctx.phase == Phase.PRE) {
            return _validatePre(ctx);
        } else {
            return _validatePost(ctx);
        }
    }

    /// @notice PRE-migration: Verify no queued assets or shares exist in BalanceSheet
    /// @dev Migration requires clean state with no pending operations
    /// @dev Also queries data needed for POST validation and caches it
    function _validatePre(ValidationContext memory ctx) internal returns (ValidationResult memory) {
        _cachePostValidationData(ctx);

        IBalanceSheet balanceSheet = IBalanceSheet(ctx.old.inner.balanceSheet);

        string memory json = ctx.store.query(_vaultsQuery(ctx));

        uint256 totalCount = json.readUint(".data.vaults.totalCount");

        if (totalCount == 0) {
            return
                ValidationResult({passed: true, validatorName: "BalanceSheet (PRE)", errors: new ValidationError[](0)});
        }

        Vault[] memory vaults = new Vault[](totalCount);
        string memory basePath = ".data.vaults.items";
        for (uint256 i = 0; i < totalCount; i++) {
            vaults[i].poolId = json.readUint(_buildJsonPath(basePath, i, "poolId"));
            vaults[i].tokenId = json.readString(_buildJsonPath(basePath, i, "tokenId"));
            vaults[i].assetId = json.readString(_buildJsonPath(basePath, i, "asset.id"));
        }

        // Pre-allocate max possible errors (3 per vault: deposits, withdrawals, shares)
        ValidationError[] memory errors = new ValidationError[](vaults.length * 3);
        uint256 errorCount = 0;

        for (uint256 i = 0; i < vaults.length; i++) {
            PoolId pid = PoolId.wrap(uint64(vaults[i].poolId));
            ShareClassId scid = ShareClassId.wrap(bytes16(vm.parseBytes(vaults[i].tokenId)));
            AssetId aid = AssetId.wrap(uint128(vm.parseUint(vaults[i].assetId)));

            (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(pid, scid, aid);

            if (deposits > 0) {
                errors[errorCount++] = _buildAssetError(
                    "queuedDeposits", vaults[i].poolId, vaults[i].tokenId, vaults[i].assetId, deposits
                );
            }

            if (withdrawals > 0) {
                errors[errorCount++] = _buildAssetError(
                    "queuedWithdrawals", vaults[i].poolId, vaults[i].tokenId, vaults[i].assetId, withdrawals
                );
            }
        }

        for (uint256 i = 0; i < vaults.length; i++) {
            PoolId pid = PoolId.wrap(uint64(vaults[i].poolId));
            ShareClassId scid = ShareClassId.wrap(bytes16(vm.parseBytes(vaults[i].tokenId)));

            (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(pid, scid);

            if (delta > 0) {
                errors[errorCount++] = _buildShareError(vaults[i].poolId, vaults[i].tokenId, delta, isPositive);
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "BalanceSheet (PRE)", errors: _trimErrors(errors, errorCount)
        });
    }

    /// @notice POST-migration: Verify all pool managers were migrated to new BalanceSheet
    /// @dev Ensures BalanceSheet manager permissions are correctly set for all pools
    function _validatePost(ValidationContext memory ctx) internal returns (ValidationResult memory) {
        // Pre-allocate max possible errors (assume max 10 managers per pool)
        ValidationError[] memory errors = new ValidationError[](ctx.pools.length * 10);
        uint256 errorCount = 0;

        for (uint256 i = 0; i < ctx.pools.length; i++) {
            PoolId pid = ctx.pools[i];
            address[] memory managers = _getBalanceSheetManagers(ctx, pid);

            for (uint256 j = 0; j < managers.length; j++) {
                address manager = managers[j];

                // Map old v3.0.1 manager addresses to new v3.1 addresses
                if (manager == ctx.old.inner.asyncRequestManager) {
                    manager = address(ctx.latest.asyncRequestManager);
                } else if (manager == ctx.old.inner.syncManager) {
                    manager = address(ctx.latest.syncManager);
                }

                bool isManager = ctx.latest.core.balanceSheet.manager(pid, manager);

                if (!isManager) {
                    errors[errorCount++] = _buildError({
                        field: "manager",
                        value: string.concat("Pool ", _toString(PoolId.unwrap(pid))),
                        expected: string.concat(vm.toString(manager), " should be manager"),
                        actual: "Manager not set in new BalanceSheet",
                        message: string.concat(
                            "Pool ", _toString(PoolId.unwrap(pid)), " missing manager ", vm.toString(manager)
                        )
                    });
                }
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "BalanceSheet (POST)", errors: _trimErrors(errors, errorCount)
        });
    }

    /// @notice Cache data needed for POST validation
    /// @dev Called during PRE phase to ensure POST can retrieve from cache
    function _cachePostValidationData(ValidationContext memory ctx) internal {
        for (uint256 i = 0; i < ctx.pools.length; i++) {
            ctx.store.query(_managersQuery(ctx, PoolId.unwrap(ctx.pools[i])));
        }
    }

    function _getBalanceSheetManagers(ValidationContext memory ctx, PoolId poolId)
        internal
        returns (address[] memory managers)
    {
        string memory json = ctx.store.get(_managersQuery(ctx, PoolId.unwrap(poolId)));

        uint256 totalCount = json.readUint(".data.poolManagers.totalCount");

        managers = new address[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            managers[i] = json.readAddress(_buildJsonPath(".data.poolManagers.items", i, "address"));
        }
    }

    function _vaultsQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        return string.concat(
            "vaults(limit: 1000, where: { poolId_in: ",
            _buildPoolIdsJson(ctx.pools),
            " }) { items { asset { id } poolId tokenId } totalCount }"
        );
    }

    function _managersQuery(ValidationContext memory ctx, uint256 poolId) internal pure returns (string memory) {
        return string.concat(
            "poolManagers(limit: 1000, where: { centrifugeId: ",
            _jsonValue(ctx.localCentrifugeId),
            ", poolId: ",
            _jsonValue(poolId),
            ", isBalancesheetManager: true }) { items { address } totalCount }"
        );
    }

    function _buildAssetError(
        string memory field,
        uint256 poolId,
        string memory tokenId,
        string memory assetId,
        uint128 amount
    ) internal pure returns (ValidationError memory) {
        return _buildError({
            field: field,
            value: string.concat("Pool ", _toString(poolId)),
            expected: "0",
            actual: _toString(amount),
            message: string.concat("Pool ", _toString(poolId), " SC ", tokenId, " Asset ", assetId)
        });
    }

    function _buildShareError(uint256 poolId, string memory tokenId, uint128 delta, bool isPositive)
        internal
        pure
        returns (ValidationError memory)
    {
        return _buildError({
            field: "queuedSharesDelta",
            value: string.concat("Pool ", _toString(poolId)),
            expected: "0",
            actual: _toString(delta),
            message: string.concat(
                "Pool ", _toString(poolId), " SC ", tokenId, " ", isPositive ? "+" : "-", _toString(delta)
            )
        });
    }
}
