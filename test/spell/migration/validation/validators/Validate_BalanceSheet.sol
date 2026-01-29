// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {ShareClassId, newShareClassId} from "../../../../../src/core/types/ShareClassId.sol";

import {OnOfframpManager, OnOfframpManagerFactory} from "../../../../../src/managers/spoke/OnOfframpManager.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_BalanceSheet
/// @notice Validates BalanceSheet state after migration
/// @dev POST: Validates all pool managers were migrated correctly
contract Validate_BalanceSheet is BaseValidator {
    using stdJson for string;

    function supportedPhases() public pure override returns (Phase) {
        return Phase.BOTH;
    }

    function name() public pure override returns (string memory) {
        return "BalanceSheet";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        if (ctx.phase == Phase.PRE) {
            _cachePostValidationData(ctx);
            return
                ValidationResult({passed: true, validatorName: "BalanceSheet (PRE)", errors: new ValidationError[](0)});
        } else {
            return _validatePost(ctx);
        }
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
                } else if (manager == address(ctx.queryService.onOfframpManagerV3(pid))) {
                    ShareClassId scId = newShareClassId(pid, 1);
                    manager = _computeOnOfframpManagerAddress(ctx.latest.onOfframpManagerFactory, pid, scId);
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

    function _computeOnOfframpManagerAddress(OnOfframpManagerFactory factory, PoolId poolId, ShareClassId scId)
        internal
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(PoolId.unwrap(poolId), ShareClassId.unwrap(scId)));

        bytes memory initCode = abi.encodePacked(
            type(OnOfframpManager).creationCode,
            abi.encode(poolId, scId, factory.contractUpdater(), factory.balanceSheet())
        );

        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, keccak256(initCode))))));
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
}
