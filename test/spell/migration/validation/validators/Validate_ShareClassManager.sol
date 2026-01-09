// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {D18} from "../../../../../src/misc/types/D18.sol";

import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {ShareClassId, newShareClassId} from "../../../../../src/core/types/ShareClassId.sol";
import {IShareClassManager} from "../../../../../src/core/hub/interfaces/IShareClassManager.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";
import {ShareClassManagerV3Like} from "../../../../../src/spell/migration_v3.1/MigrationSpell.sol";

/// @title Validate_ShareClassManager
/// @notice Validates ShareClassManager storage migration from v3.0.1 to v3.1
/// @dev Validates the following storage fields:
///      - shareClassCount: PRE == 1, POST old == new
///      - salts: POST new == bytes32(abi.encodePacked(bytes8(poolId), bytes24(oldSalt)))
///      - totalIssuance: POST old metrics.totalIssuance == new totalIssuance
///      - pricePoolPerShare: POST old metrics.navPerShare == new pricePoolPerShare
///      - metadata: POST old == new (name, symbol)
/// @dev Note: Both v3.0.1 and v3.1 use 1-based scId indexing: scId = (poolId << 64) + 1
contract Validate_ShareClassManager is BaseValidator {
    using stdJson for string;

    /// @dev Context for validating a single pool's share class
    struct PoolValidationContext {
        PoolId poolId;
        ShareClassId scId;
        string poolIdStr;
        string scIdStr;
        ShareClassManagerV3Like oldScm;
        IShareClassManager newScm;
    }

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

            if (count > 1) {
                errors[errorCount++] = _buildError({
                    field: "shareClassCount",
                    value: string.concat("Pool ", _toString(PoolId.unwrap(poolId))),
                    expected: "1",
                    actual: _toString(count),
                    message: "Pool has multiple share classes (migration assumes 1)"
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "ShareClassManager (PRE)", errors: _trimErrors(errors, errorCount)
        });
    }

    function _validatePost(ValidationContext memory ctx) internal view returns (ValidationResult memory) {
        if (!ctx.isMainnet) {
            return ValidationResult({
                passed: true,
                validatorName: "ShareClassManager (POST) [SKIPPED - testnet]",
                errors: new ValidationError[](0)
            });
        }

        ValidationError[] memory errors = new ValidationError[](ctx.hubPools.length * 6);
        uint256 errorCount = 0;

        ShareClassManagerV3Like oldScm = ShareClassManagerV3Like(ctx.old.inner.shareClassManager);
        IShareClassManager newScm = ctx.latest.core.shareClassManager;

        for (uint256 i = 0; i < ctx.hubPools.length; i++) {
            PoolValidationContext memory pctx = _buildPoolContext(ctx.hubPools[i], oldScm, newScm);

            errorCount = _validateShareClassCount(pctx, errors, errorCount);
            errorCount = _validateSalts(pctx, errors, errorCount);
            errorCount = _validateTotalIssuance(pctx, errors, errorCount);
            errorCount = _validatePricePoolPerShare(pctx, errors, errorCount);
            errorCount = _validateMetadata(pctx, errors, errorCount);
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "ShareClassManager (POST)", errors: _trimErrors(errors, errorCount)
        });
    }

    // ============================================
    // Pool Context Builder
    // ============================================

    function _buildPoolContext(PoolId poolId, ShareClassManagerV3Like oldScm, IShareClassManager newScm)
        internal
        pure
        returns (PoolValidationContext memory pctx)
    {
        string memory poolIdStr = string.concat("Pool ", _toString(PoolId.unwrap(poolId)));

        ShareClassId scId = newShareClassId(poolId, 1);
        string memory scIdStr = string.concat(poolIdStr, " / SC ", _toString(uint128(ShareClassId.unwrap(scId))));

        pctx = PoolValidationContext({
            poolId: poolId, scId: scId, poolIdStr: poolIdStr, scIdStr: scIdStr, oldScm: oldScm, newScm: newScm
        });
    }

    // ============================================
    // Individual Validation Helpers
    // ============================================

    function _validateShareClassCount(
        PoolValidationContext memory pctx,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        uint32 oldCount = IShareClassManager(address(pctx.oldScm)).shareClassCount(pctx.poolId);
        uint32 newCount = pctx.newScm.shareClassCount(pctx.poolId);

        if (oldCount != newCount) {
            errors[errorCount++] = _buildError({
                field: "shareClassCount",
                value: pctx.poolIdStr,
                expected: _toString(oldCount),
                actual: _toString(newCount),
                message: "Share class count mismatch after migration"
            });
        }
        return errorCount;
    }

    function _validateSalts(PoolValidationContext memory pctx, ValidationError[] memory errors, uint256 errorCount)
        internal
        view
        returns (uint256)
    {
        (,, bytes32 oldSalt) = pctx.oldScm.metadata(pctx.scId);
        (,, bytes32 newSalt) = pctx.newScm.metadata(pctx.poolId, pctx.scId);

        // Migration formula: bytes32(abi.encodePacked(bytes8(poolId.raw()), bytes24(scSalt)))
        // Takes first 8 bytes from poolId, last 24 bytes from old salt
        bytes32 expectedSalt = bytes32(abi.encodePacked(bytes8(PoolId.unwrap(pctx.poolId)), bytes24(oldSalt)));

        if (newSalt != expectedSalt) {
            errors[errorCount++] = _buildError({
                field: "salts",
                value: pctx.scIdStr,
                expected: _toString(uint256(expectedSalt)),
                actual: _toString(uint256(newSalt)),
                message: "Salt mismatch - expected bytes32(abi.encodePacked(bytes8(poolId), bytes24(oldSalt)))"
            });
        }
        return errorCount;
    }

    function _validateTotalIssuance(
        PoolValidationContext memory pctx,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        (uint128 oldTotalIssuance,) = pctx.oldScm.metrics(pctx.scId);
        uint128 newTotalIssuance = pctx.newScm.totalIssuance(pctx.poolId, pctx.scId);

        if (oldTotalIssuance != newTotalIssuance) {
            errors[errorCount++] = _buildError({
                field: "totalIssuance",
                value: pctx.scIdStr,
                expected: _toString(oldTotalIssuance),
                actual: _toString(newTotalIssuance),
                message: "Total issuance mismatch after migration"
            });
        }
        return errorCount;
    }

    function _validatePricePoolPerShare(
        PoolValidationContext memory pctx,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        (, D18 oldNavPerShare) = pctx.oldScm.metrics(pctx.scId);
        (D18 newPrice,) = pctx.newScm.pricePoolPerShare(pctx.poolId, pctx.scId);

        if (D18.unwrap(oldNavPerShare) != D18.unwrap(newPrice)) {
            errors[errorCount++] = _buildError({
                field: "pricePoolPerShare",
                value: pctx.scIdStr,
                expected: _toString(D18.unwrap(oldNavPerShare)),
                actual: _toString(D18.unwrap(newPrice)),
                message: "Price per share mismatch after migration"
            });
        }
        return errorCount;
    }

    function _validateMetadata(PoolValidationContext memory pctx, ValidationError[] memory errors, uint256 errorCount)
        internal
        view
        returns (uint256)
    {
        (string memory oldName, string memory oldSymbol,) = pctx.oldScm.metadata(pctx.scId);
        (string memory newName, string memory newSymbol,) = pctx.newScm.metadata(pctx.poolId, pctx.scId);

        if (keccak256(bytes(oldName)) != keccak256(bytes(newName))) {
            errors[errorCount++] = _buildError({
                field: "metadata.name",
                value: pctx.scIdStr,
                expected: oldName,
                actual: newName,
                message: "Share class name mismatch after migration"
            });
        }

        if (keccak256(bytes(oldSymbol)) != keccak256(bytes(newSymbol))) {
            errors[errorCount++] = _buildError({
                field: "metadata.symbol",
                value: pctx.scIdStr,
                expected: oldSymbol,
                actual: newSymbol,
                message: "Share class symbol mismatch after migration"
            });
        }
        return errorCount;
    }
}
