// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {IShareClassManager} from "../../../../../src/core/hub/interfaces/IShareClassManager.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

// TODO: Validate remaining storage entries
contract Validate_ShareClassManager is BaseValidator {
    using stdJson for string;

    function supportedPhases() public pure override returns (Phase) {
        return Phase.BOTH;
    }

    function name() public pure override returns (string memory) {
        return "ShareClassManager";
    }

    function validate(ValidationContext memory ctx) public view override returns (ValidationResult memory) {
        if (ctx.phase == Phase.PRE) {
            return _validatePre(ctx);
        } else {
            return _validatePost(ctx);
        }
    }

    /// @notice PRE-migration: Verify each hub pool has exactly 1 share class
    /// @dev Migration assumes single share class per pool. Only validates pools where this chain is the hub.
    function _validatePre(ValidationContext memory ctx) internal view returns (ValidationResult memory) {
        ValidationError[] memory errors = new ValidationError[](ctx.hubPools.length);
        uint256 errorCount = 0;

        IShareClassManager scm = IShareClassManager(ctx.old.inner.shareClassManager);

        for (uint256 i = 0; i < ctx.hubPools.length; i++) {
            PoolId poolId = ctx.hubPools[i];
            uint32 count = scm.shareClassCount(poolId);

            if (count != 1) {
                errors[errorCount++] = _buildError({
                    field: "shareClassCount",
                    value: string.concat("Pool ", _toString(PoolId.unwrap(poolId))),
                    expected: "1",
                    actual: _toString(count),
                    message: count == 0
                        ? "Pool has no share classes (not initialized?)"
                        : "Pool has multiple share classes (migration assumes 1)"
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "ShareClassManager (PRE)", errors: _trimErrors(errors, errorCount)
        });
    }

    /// @notice POST-migration: Compare v3.0.1 vs v3.1 shareClassCount
    /// @dev Ensures state was preserved correctly during migration. Only validates hub pools.
    /// @dev For testnets, validation is skipped (returns success) due to potential test data inconsistencies.
    function _validatePost(ValidationContext memory ctx) internal view returns (ValidationResult memory) {
        if (!ctx.isMainnet) {
            return ValidationResult({
                passed: true,
                validatorName: "ShareClassManager (POST) [SKIPPED - testnet]",
                errors: new ValidationError[](0)
            });
        }

        ValidationError[] memory errors = new ValidationError[](ctx.hubPools.length);
        uint256 errorCount = 0;

        IShareClassManager oldScm = IShareClassManager(ctx.old.inner.shareClassManager);
        IShareClassManager newScm = ctx.latest.core.shareClassManager;

        for (uint256 i = 0; i < ctx.hubPools.length; i++) {
            PoolId poolId = ctx.hubPools[i];
            uint32 oldCount = oldScm.shareClassCount(poolId);
            uint32 newCount = newScm.shareClassCount(poolId);

            if (oldCount != newCount) {
                errors[errorCount++] = _buildError({
                    field: "shareClassCount",
                    value: string.concat("Pool ", _toString(PoolId.unwrap(poolId))),
                    expected: _toString(oldCount),
                    actual: _toString(newCount),
                    message: "Share class count mismatch after migration"
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "ShareClassManager (POST)", errors: _trimErrors(errors, errorCount)
        });
    }
}
