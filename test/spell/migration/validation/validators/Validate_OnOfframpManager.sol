// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../../src/core/types/ShareClassId.sol";

import {IBalanceSheet} from "../../../../../src/core/spoke/interfaces/IBalanceSheet.sol";
import {OnOfframpManager} from "../../../../../src/managers/spoke/OnOfframpManager.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_OnOfframpManager
/// @notice Validates OnOfframpManager settings (onramp, offramp, relayer) before and after migration
/// @dev PRE: Cache data and validate non-BalanceSheet managers have no state
/// @dev POST: Validates OnOfframpManager settings are migrated correctly
contract Validate_OnOfframpManager is BaseValidator {
    using stdJson for string;

    struct OnOfframpManagerData {
        address managerAddress;
        uint256 poolId;
        string tokenId;
    }

    struct AssetData {
        string id;
        address assetAddress;
    }

    function supportedPhases() public pure override returns (Phase) {
        return Phase.BOTH;
    }

    function name() public pure override returns (string memory) {
        return "OnOfframpManager";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        if (ctx.phase == Phase.PRE) {
            return _validatePre(ctx);
        } else {
            return _validatePost(ctx);
        }
    }

    /// @notice PRE-migration: Cache data and validate non-BalanceSheet managers have no state
    /// @dev The Migration Spell will not deploy a new OnOfframpManager for non-BalanceSheet managers,
    ///      but will still try to migrate, so they must have no configured state
    function _validatePre(ValidationContext memory ctx) internal returns (ValidationResult memory) {
        _cacheValidationData(ctx);

        string memory managersJson = ctx.store.get(_managersQuery(ctx));
        uint256 managerCount = managersJson.readUint(".data.onOffRampManagers.totalCount");

        if (managerCount == 0) {
            return
                ValidationResult({
                    passed: true, validatorName: "OnOfframpManager (PRE)", errors: new ValidationError[](0)
                });
        }

        OnOfframpManagerData[] memory managers = new OnOfframpManagerData[](managerCount);
        string memory basePath = ".data.onOffRampManagers.items";
        for (uint256 i = 0; i < managerCount; i++) {
            managers[i].managerAddress = managersJson.readAddress(_buildJsonPath(basePath, i, "address"));
            managers[i].poolId = managersJson.readUint(_buildJsonPath(basePath, i, "poolId"));
            managers[i].tokenId = managersJson.readString(_buildJsonPath(basePath, i, "tokenId"));
        }

        AssetData[] memory assets = _getAssets(ctx);

        ValidationError[] memory errors = new ValidationError[](managerCount * 100);
        uint256 errorCount = 0;

        for (uint256 i = 0; i < managers.length; i++) {
            errorCount = _preValidateManager(ctx, managers[i], assets, errors, errorCount);
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "OnOfframpManager (PRE)", errors: _trimErrors(errors, errorCount)
        });
    }

    /// @notice Validate that non-BalanceSheet managers have no state
    function _preValidateManager(
        ValidationContext memory ctx,
        OnOfframpManagerData memory managerData,
        AssetData[] memory assets,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal returns (uint256) {
        PoolId pid = PoolId.wrap(uint64(managerData.poolId));

        if (IBalanceSheet(address(ctx.old.inner.balanceSheet)).manager(pid, managerData.managerAddress)) {
            return errorCount;
        }

        string memory managerIdStr = string.concat("Pool ", _toString(managerData.poolId), " SC ", managerData.tokenId);
        OnOfframpManager manager = OnOfframpManager(managerData.managerAddress);

        errorCount = _preValidateNoOnrampState(manager, assets, managerIdStr, errors, errorCount);
        errorCount = _preValidateNoOfframpState(
            ctx, manager, pid, managerData.tokenId, assets, managerIdStr, errors, errorCount
        );
        errorCount =
            _preValidateNoRelayerState(ctx, manager, pid, managerData.tokenId, managerIdStr, errors, errorCount);

        return errorCount;
    }

    function _preValidateNoOnrampState(
        OnOfframpManager manager,
        AssetData[] memory assets,
        string memory managerIdStr,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i].assetAddress;
            if (manager.onramp(asset)) {
                errors[errorCount++] = _buildError({
                    field: "onramp",
                    value: string.concat(managerIdStr, " Asset ", vm.toString(asset)),
                    expected: "disabled",
                    actual: "enabled",
                    message: string.concat(
                        managerIdStr, " non-BalanceSheet manager has onramp enabled for ", vm.toString(asset)
                    )
                });
            }
        }
        return errorCount;
    }

    function _preValidateNoOfframpState(
        ValidationContext memory ctx,
        OnOfframpManager manager,
        PoolId pid,
        string memory tokenId,
        AssetData[] memory assets,
        string memory managerIdStr,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal returns (uint256) {
        address[] memory receivers = _getOfframpReceivers(ctx, pid, tokenId);
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i].assetAddress;
            for (uint256 j = 0; j < receivers.length; j++) {
                if (manager.offramp(asset, receivers[j])) {
                    errors[errorCount++] = _buildError({
                        field: "offramp",
                        value: string.concat(
                            managerIdStr, " Asset ", vm.toString(asset), " Receiver ", vm.toString(receivers[j])
                        ),
                        expected: "disabled",
                        actual: "enabled",
                        message: string.concat(
                            managerIdStr, " non-BalanceSheet manager has offramp enabled for ", vm.toString(asset)
                        )
                    });
                }
            }
        }
        return errorCount;
    }

    function _preValidateNoRelayerState(
        ValidationContext memory ctx,
        OnOfframpManager manager,
        PoolId pid,
        string memory tokenId,
        string memory managerIdStr,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal returns (uint256) {
        address[] memory relayers = _getOfframpRelayers(ctx, pid, tokenId);
        for (uint256 i = 0; i < relayers.length; i++) {
            if (manager.relayer(relayers[i])) {
                errors[errorCount++] = _buildError({
                    field: "relayer",
                    value: string.concat(managerIdStr, " Relayer ", vm.toString(relayers[i])),
                    expected: "disabled",
                    actual: "enabled",
                    message: string.concat(
                        managerIdStr, " non-BalanceSheet manager has relayer enabled for ", vm.toString(relayers[i])
                    )
                });
            }
        }
        return errorCount;
    }

    /// @notice POST-migration: Validate OnOfframpManager settings were migrated correctly
    /// @dev Compares old vs new OnOfframpManager for onramp, offramp, and relayer settings
    function _validatePost(ValidationContext memory ctx) internal returns (ValidationResult memory) {
        string memory managersJson = ctx.store.get(_managersQuery(ctx));
        uint256 managerCount = managersJson.readUint(".data.onOffRampManagers.totalCount");

        if (managerCount == 0) {
            return ValidationResult({
                passed: true, validatorName: "OnOfframpManager (POST)", errors: new ValidationError[](0)
            });
        }

        OnOfframpManagerData[] memory managers = new OnOfframpManagerData[](managerCount);
        string memory basePath = ".data.onOffRampManagers.items";
        for (uint256 i = 0; i < managerCount; i++) {
            managers[i].managerAddress = managersJson.readAddress(_buildJsonPath(basePath, i, "address"));
            managers[i].poolId = managersJson.readUint(_buildJsonPath(basePath, i, "poolId"));
            managers[i].tokenId = managersJson.readString(_buildJsonPath(basePath, i, "tokenId"));
        }

        AssetData[] memory assets = _getAssets(ctx);

        // Pre-allocate errors: enough for each manager to have errors
        ValidationError[] memory errors = new ValidationError[](managerCount * 100);
        uint256 errorCount = 0;

        for (uint256 i = 0; i < managers.length; i++) {
            errorCount = _postValidateManager(ctx, managers[i], assets, errors, errorCount);
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "OnOfframpManager (POST)", errors: _trimErrors(errors, errorCount)
        });
    }

    /// @notice Cache data needed for POST validation
    /// @dev Called during PRE phase to ensure POST can retrieve from cache
    function _cacheValidationData(ValidationContext memory ctx) internal {
        string memory managersJson = ctx.store.query(_managersQuery(ctx));
        uint256 managerCount = managersJson.readUint(".data.onOffRampManagers.totalCount");

        ctx.store.query(_assetsQuery(ctx));

        string memory basePath = ".data.onOffRampManagers.items";
        for (uint256 i = 0; i < managerCount; i++) {
            uint256 poolId = managersJson.readUint(_buildJsonPath(basePath, i, "poolId"));
            string memory tokenId = managersJson.readString(_buildJsonPath(basePath, i, "tokenId"));

            ctx.store.query(_receiversQuery(ctx, poolId, tokenId));
            ctx.store.query(_relayersQuery(ctx, poolId, tokenId));
        }
    }

    function _postValidateManager(
        ValidationContext memory ctx,
        OnOfframpManagerData memory managerData,
        AssetData[] memory assets,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal returns (uint256) {
        PoolId pid = PoolId.wrap(uint64(managerData.poolId));
        ShareClassId scid = ShareClassId.wrap(bytes16(vm.parseBytes(managerData.tokenId)));

        // Only OnOffRampManagers that are also BalanceSheet managers are migrated
        if (!IBalanceSheet(address(ctx.old.inner.balanceSheet)).manager(pid, managerData.managerAddress)) {
            return errorCount;
        }

        // The spell migrates only the first share class of a pool, so skip others
        if (scid.index() != 1) return errorCount;

        string memory managerIdStr = string.concat("Pool ", _toString(managerData.poolId), " SC ", managerData.tokenId);

        address expectedNewManager = _computeManagerAddress(ctx, pid, scid);
        bool exists;
        (errorCount, exists) = _postValidateExists(expectedNewManager, managerIdStr, errors, errorCount);

        if (!exists) return errorCount;

        OnOfframpManager newManager = OnOfframpManager(expectedNewManager);
        errorCount = _postValidateOnrampSettings(newManager, assets, managerData, managerIdStr, errors, errorCount);
        errorCount =
            _postValidateOfframpSettings(ctx, newManager, pid, managerData, assets, managerIdStr, errors, errorCount);
        errorCount = _postValidateRelayerSettings(ctx, newManager, pid, managerData, managerIdStr, errors, errorCount);

        return errorCount;
    }

    function _postValidateExists(
        address expectedNewManager,
        string memory managerIdStr,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256, bool) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(expectedNewManager)
        }

        if (codeSize == 0) {
            errors[errorCount++] = _buildError({
                field: "newManager",
                value: managerIdStr,
                expected: string.concat("Manager at ", vm.toString(expectedNewManager)),
                actual: "No contract deployed",
                message: string.concat(managerIdStr, " new OnOfframpManager not deployed")
            });
        }
        return (errorCount, codeSize != 0);
    }

    function _postValidateOnrampSettings(
        OnOfframpManager newManager,
        AssetData[] memory assets,
        OnOfframpManagerData memory managerData,
        string memory managerIdStr,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        OnOfframpManager oldManager = OnOfframpManager(managerData.managerAddress);

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i].assetAddress;
            bool oldOnramp = oldManager.onramp(asset);
            bool newOnramp = newManager.onramp(asset);

            if (oldOnramp != newOnramp) {
                errors[errorCount++] = _buildError({
                    field: "onramp",
                    value: string.concat(managerIdStr, " Asset ", vm.toString(asset)),
                    expected: oldOnramp ? "enabled" : "disabled",
                    actual: newOnramp ? "enabled" : "disabled",
                    message: string.concat(managerIdStr, " onramp mismatch for asset ", vm.toString(asset))
                });
            }
        }
        return errorCount;
    }

    function _postValidateOfframpSettings(
        ValidationContext memory ctx,
        OnOfframpManager newManager,
        PoolId pid,
        OnOfframpManagerData memory managerData,
        AssetData[] memory assets,
        string memory managerIdStr,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal returns (uint256) {
        OnOfframpManager oldManager = OnOfframpManager(managerData.managerAddress);
        address[] memory receivers = _getOfframpReceivers(ctx, pid, managerData.tokenId);
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i].assetAddress;
            for (uint256 j = 0; j < receivers.length; j++) {
                address receiver = receivers[j];
                bool oldOfframp = oldManager.offramp(asset, receiver);
                bool newOfframp = newManager.offramp(asset, receiver);

                if (oldOfframp != newOfframp) {
                    errors[errorCount++] = _buildAssetError(managerIdStr, asset, receiver, oldOfframp, newOfframp);
                }
            }
        }
        return errorCount;
    }

    function _postValidateRelayerSettings(
        ValidationContext memory ctx,
        OnOfframpManager newManager,
        PoolId pid,
        OnOfframpManagerData memory managerData,
        string memory managerIdStr,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal returns (uint256) {
        OnOfframpManager oldManager = OnOfframpManager(managerData.managerAddress);
        address[] memory relayers = _getOfframpRelayers(ctx, pid, managerData.tokenId);
        for (uint256 i = 0; i < relayers.length; i++) {
            address relayer = relayers[i];
            bool oldRelayer = oldManager.relayer(relayer);
            bool newRelayer = newManager.relayer(relayer);

            if (oldRelayer != newRelayer) {
                errors[errorCount++] = _buildError({
                    field: "relayer",
                    value: string.concat(managerIdStr, " Relayer ", vm.toString(relayer)),
                    expected: oldRelayer ? "enabled" : "disabled",
                    actual: newRelayer ? "enabled" : "disabled",
                    message: string.concat(managerIdStr, " relayer mismatch for ", vm.toString(relayer))
                });
            }
        }
        return errorCount;
    }

    function _getOfframpReceivers(ValidationContext memory ctx, PoolId poolId, string memory tokenId)
        internal
        returns (address[] memory receivers)
    {
        string memory json = ctx.store.get(_receiversQuery(ctx, PoolId.unwrap(poolId), tokenId));

        uint256 totalCount = json.readUint(".data.offRampAddresss.totalCount");

        receivers = new address[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            receivers[i] = json.readAddress(_buildJsonPath(".data.offRampAddresss.items", i, "receiverAddress"));
        }
    }

    function _getOfframpRelayers(ValidationContext memory ctx, PoolId poolId, string memory tokenId)
        internal
        returns (address[] memory relayers)
    {
        string memory json = ctx.store.get(_relayersQuery(ctx, PoolId.unwrap(poolId), tokenId));

        uint256 totalCount = json.readUint(".data.offrampRelayers.totalCount");

        relayers = new address[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            relayers[i] = json.readAddress(_buildJsonPath(".data.offrampRelayers.items", i, "address"));
        }
    }

    function _getAssets(ValidationContext memory ctx) internal returns (AssetData[] memory) {
        string memory json = ctx.store.get(_assetsQuery(ctx));

        uint256 totalCount = json.readUint(".data.assets.totalCount");
        AssetData[] memory assets = new AssetData[](totalCount);
        string memory basePath = ".data.assets.items";
        for (uint256 i = 0; i < totalCount; i++) {
            assets[i].id = json.readString(_buildJsonPath(basePath, i, "id"));
            assets[i].assetAddress = json.readAddress(_buildJsonPath(basePath, i, "address"));
        }

        return assets;
    }

    function _managersQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        return string.concat(
            "onOffRampManagers(limit: 1000, where: { centrifugeId: ",
            _jsonValue(ctx.localCentrifugeId),
            ", poolId_in: ",
            _buildPoolIdsJson(ctx.pools),
            " }) { items { address poolId tokenId } totalCount }"
        );
    }

    function _assetsQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        return string.concat(
            "assets(limit: 1000, where: { centrifugeId: ",
            _jsonValue(ctx.localCentrifugeId),
            " }) { items { id address } totalCount }"
        );
    }

    function _receiversQuery(ValidationContext memory ctx, uint256 poolId, string memory tokenId)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "offRampAddresss(limit: 1000, where: { centrifugeId: ",
            _jsonValue(ctx.localCentrifugeId),
            ", poolId: ",
            _jsonValue(poolId),
            ", tokenId: ",
            _jsonString(tokenId),
            " }) { items { receiverAddress } totalCount }"
        );
    }

    function _relayersQuery(ValidationContext memory ctx, uint256 poolId, string memory tokenId)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "offrampRelayers(limit: 1000, where: { centrifugeId: ",
            _jsonValue(ctx.localCentrifugeId),
            ", poolId: ",
            _jsonValue(poolId),
            ", tokenId: ",
            _jsonString(tokenId),
            " }) { items { address } totalCount }"
        );
    }

    function _computeManagerAddress(ValidationContext memory ctx, PoolId poolId, ShareClassId scId)
        internal
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(PoolId.unwrap(poolId), ShareClassId.unwrap(scId)));
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(ctx.latest.onOfframpManagerFactory),
                salt,
                keccak256(
                    abi.encodePacked(
                        vm.getCode("src/managers/spoke/OnOfframpManager.sol:OnOfframpManager"),
                        abi.encode(
                            poolId,
                            scId,
                            address(ctx.latest.core.contractUpdater),
                            address(ctx.latest.core.balanceSheet)
                        )
                    )
                )
            )
        );

        return address(uint160(uint256(hash)));
    }

    function _buildAssetError(
        string memory managerIdStr,
        address asset,
        address receiver,
        bool oldOfframp,
        bool newOfframp
    ) internal pure returns (ValidationError memory) {
        return _buildError({
            field: "offramp",
            value: string.concat(managerIdStr, " Asset ", vm.toString(asset), " Receiver ", vm.toString(receiver)),
            expected: oldOfframp ? "enabled" : "disabled",
            actual: newOfframp ? "enabled" : "disabled",
            message: string.concat(
                managerIdStr, " offramp mismatch for asset ", vm.toString(asset), " receiver ", vm.toString(receiver)
            )
        });
    }
}
