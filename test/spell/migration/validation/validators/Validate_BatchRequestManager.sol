// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../../src/core/types/ShareClassId.sol";

import {BatchRequestManager} from "../../../../../src/vaults/BatchRequestManager.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";
import {ShareClassManagerV3Like} from "../../../../../src/spell/migration_v3.1/MigrationSpell.sol";

/// @title Validate_BatchRequestManager
/// @notice Validates that epochId was migrated correctly from old ShareClassManager to new BatchRequestManager
/// @dev BOTH-phase validator - compares old SCM.epochId(scId, assetId) vs new BRM.epochId(poolId, scId, assetId)
contract Validate_BatchRequestManager is BaseValidator {
    using stdJson for string;

    struct EpochKey {
        uint64 poolId;
        bytes16 tokenId;
        uint128 assetId;
    }

    struct EpochData {
        uint32 deposit;
        uint32 issue;
        uint32 redeem;
        uint32 revoke;
    }

    function supportedPhases() public pure override returns (Phase) {
        return Phase.BOTH;
    }

    function name() public pure override returns (string memory) {
        return "BatchRequestManager";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        if (ctx.phase == Phase.PRE) {
            ctx.store.query(_epochInvestOrdersQuery(ctx));
            ctx.store.query(_epochRedeemOrdersQuery(ctx));
            return ValidationResult({
                passed: true, validatorName: "BatchRequestManager (PRE)", errors: new ValidationError[](0)
            });
        }

        EpochKey[] memory epochKeys = _getEpochKeys(ctx);

        ValidationError[] memory errors = new ValidationError[](epochKeys.length * 4);
        uint256 errorCount = 0;

        ShareClassManagerV3Like oldSCM = ShareClassManagerV3Like(ctx.old.inner.shareClassManager);
        BatchRequestManager newBRM = ctx.latest.batchRequestManager;

        for (uint256 i = 0; i < epochKeys.length; i++) {
            errorCount = _validateEpochId(oldSCM, newBRM, epochKeys[i], errors, errorCount);
        }

        return ValidationResult({
            passed: errorCount == 0,
            validatorName: "BatchRequestManager (POST)",
            errors: _trimErrors(errors, errorCount)
        });
    }

    function _validateEpochId(
        ShareClassManagerV3Like oldSCM,
        BatchRequestManager newBRM,
        EpochKey memory key,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        EpochData memory oldData = _getOldEpochData(oldSCM, key);
        EpochData memory newData = _getNewEpochData(newBRM, key);
        string memory keyStr = _keyToString(key);

        errorCount = _compareEpochData(oldData, newData, keyStr, errors, errorCount);
        return errorCount;
    }

    function _getOldEpochData(ShareClassManagerV3Like oldSCM, EpochKey memory key)
        internal
        view
        returns (EpochData memory data)
    {
        (data.deposit, data.redeem, data.issue, data.revoke) =
            oldSCM.epochId(ShareClassId.wrap(key.tokenId), AssetId.wrap(key.assetId));
    }

    function _getNewEpochData(BatchRequestManager newBRM, EpochKey memory key)
        internal
        view
        returns (EpochData memory data)
    {
        (data.deposit, data.issue, data.redeem, data.revoke) =
            newBRM.epochId(PoolId.wrap(key.poolId), ShareClassId.wrap(key.tokenId), AssetId.wrap(key.assetId));
    }

    function _compareEpochData(
        EpochData memory oldData,
        EpochData memory newData,
        string memory keyStr,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal pure returns (uint256) {
        if (oldData.deposit != newData.deposit) {
            errors[errorCount++] = _buildEpochError("deposit", oldData.deposit, newData.deposit, keyStr);
        }
        if (oldData.issue != newData.issue) {
            errors[errorCount++] = _buildEpochError("issue", oldData.issue, newData.issue, keyStr);
        }
        if (oldData.redeem != newData.redeem) {
            errors[errorCount++] = _buildEpochError("redeem", oldData.redeem, newData.redeem, keyStr);
        }
        if (oldData.revoke != newData.revoke) {
            errors[errorCount++] = _buildEpochError("revoke", oldData.revoke, newData.revoke, keyStr);
        }
        return errorCount;
    }

    function _buildEpochError(string memory fieldName, uint32 oldValue, uint32 newValue, string memory keyStr)
        internal
        pure
        returns (ValidationError memory)
    {
        return _buildError({
            field: string.concat("epochId.", fieldName),
            value: keyStr,
            expected: _toString(oldValue),
            actual: _toString(newValue),
            message: string.concat("epochId.", fieldName, " mismatch for ", keyStr)
        });
    }

    function _keyToString(EpochKey memory key) internal pure returns (string memory) {
        return string.concat("Pool ", _toString(key.poolId), " Asset ", _toString(key.assetId));
    }

    /// @dev Uses epochInvestOrders and epochRedeemOrders to find all keys with epoch data
    function _getEpochKeys(ValidationContext memory ctx) internal returns (EpochKey[] memory) {
        EpochKey[] memory investKeys = _getKeysFromInvestOrders(ctx);
        EpochKey[] memory redeemKeys = _getKeysFromRedeemOrders(ctx);
        return _mergeAndDeduplicateKeys(investKeys, redeemKeys);
    }

    function _getKeysFromInvestOrders(ValidationContext memory ctx) internal returns (EpochKey[] memory) {
        string memory json = ctx.store.get(_epochInvestOrdersQuery(ctx));
        return _parseEpochKeys(json, ".data.epochInvestOrders");
    }

    function _getKeysFromRedeemOrders(ValidationContext memory ctx) internal returns (EpochKey[] memory) {
        string memory json = ctx.store.get(_epochRedeemOrdersQuery(ctx));
        return _parseEpochKeys(json, ".data.epochRedeemOrders");
    }

    function _parseEpochKeys(string memory json, string memory basePath) internal pure returns (EpochKey[] memory) {
        string memory itemsPath = string.concat(basePath, ".items");
        uint256 totalCount = json.readUint(string.concat(basePath, ".totalCount"));

        EpochKey[] memory keys = new EpochKey[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            // poolId is derived from tokenId (first 8 bytes of ShareClassId contain poolId)
            string memory tokenIdStr = json.readString(_buildJsonPath(itemsPath, i, "tokenId"));
            bytes16 tokenId = bytes16(vm.parseBytes(tokenIdStr));

            uint64 poolId = uint64(uint128(tokenId) >> 64);

            keys[i] = EpochKey({
                poolId: poolId,
                tokenId: tokenId,
                assetId: uint128(json.readUint(_buildJsonPath(itemsPath, i, "assetId")))
            });
        }

        return keys;
    }

    function _mergeAndDeduplicateKeys(EpochKey[] memory a, EpochKey[] memory b)
        internal
        pure
        returns (EpochKey[] memory)
    {
        EpochKey[] memory merged = new EpochKey[](a.length + b.length);
        uint256 count = 0;

        for (uint256 i = 0; i < a.length; i++) {
            if (!_containsKey(merged, count, a[i])) {
                merged[count++] = a[i];
            }
        }

        for (uint256 i = 0; i < b.length; i++) {
            if (!_containsKey(merged, count, b[i])) {
                merged[count++] = b[i];
            }
        }

        EpochKey[] memory result = new EpochKey[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = merged[i];
        }

        return result;
    }

    function _containsKey(EpochKey[] memory keys, uint256 length, EpochKey memory key) internal pure returns (bool) {
        for (uint256 i = 0; i < length; i++) {
            if (keys[i].poolId == key.poolId && keys[i].tokenId == key.tokenId && keys[i].assetId == key.assetId) {
                return true;
            }
        }
        return false;
    }

    function _epochInvestOrdersQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        string memory poolIdsJson = _buildPoolIdsJson(ctx.hubPools);

        return string.concat(
            "epochInvestOrders(limit: 1000, where: { poolId_in: ",
            poolIdsJson,
            " }) { items { tokenId assetId } totalCount }"
        );
    }

    function _epochRedeemOrdersQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        string memory poolIdsJson = _buildPoolIdsJson(ctx.hubPools);

        return string.concat(
            "epochRedeemOrders(limit: 1000, where: { poolId_in: ",
            poolIdsJson,
            " }) { items { tokenId assetId } totalCount }"
        );
    }
}
