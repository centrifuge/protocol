// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "../../../../../src/misc/interfaces/IERC20.sol";

import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {PoolEscrow} from "../../../../../src/core/spoke/PoolEscrow.sol";
import {ShareClassId} from "../../../../../src/core/types/ShareClassId.sol";
import {Holding} from "../../../../../src/core/spoke/interfaces/IPoolEscrow.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_PoolEscrowHoldings
/// @notice Validates PoolEscrow holdings and balances are preserved during migration
/// @dev PRE: Caches all holding values and ERC20 balances
/// @dev POST: Compares with new PoolEscrow values (must match exactly)
contract Validate_PoolEscrowHoldings is BaseValidator {
    using stdJson for string;

    string private constant HOLDINGS_CACHE_KEY = "poolEscrowHoldings";
    string private constant BALANCES_CACHE_KEY = "poolEscrowAssetBalances";

    ValidationError[] private _errors;
    string private _holdingsJson;
    string private _balancesJson;

    function supportedPhases() public pure override returns (Phase) {
        return Phase.BOTH;
    }

    function name() public pure override returns (string memory) {
        return "PoolEscrowHoldings";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        if (ctx.phase == Phase.PRE) {
            return _validatePre(ctx);
        } else {
            return _validatePost(ctx);
        }
    }

    function _validatePre(ValidationContext memory ctx) internal returns (ValidationResult memory) {
        string memory holdingsJson = _buildHoldingsCache(ctx);
        string memory balancesJson = _buildBalancesCache(ctx);

        ctx.store.set(HOLDINGS_CACHE_KEY, holdingsJson);
        ctx.store.set(BALANCES_CACHE_KEY, balancesJson);

        return
            ValidationResult({
                passed: true, validatorName: "PoolEscrowHoldings (PRE)", errors: new ValidationError[](0)
            });
    }

    function _buildHoldingsCache(ValidationContext memory ctx) internal returns (string memory holdingsJson) {
        string memory json = ctx.store.query(_holdingEscrowsQuery(ctx));
        uint256 totalCount = json.readUint(".data.holdingEscrows.totalCount");

        holdingsJson = vm.serializeJson(HOLDINGS_CACHE_KEY, "{}");

        for (uint256 i = 0; i < totalCount; i++) {
            string memory basePath = ".data.holdingEscrows.items";

            uint64 poolIdRaw = uint64(json.readUint(_buildJsonPath(basePath, i, "poolId")));
            bytes16 scIdRaw = bytes16(vm.parseBytes(json.readString(_buildJsonPath(basePath, i, "tokenId"))));
            address asset = json.readAddress(_buildJsonPath(basePath, i, "assetAddress"));
            address escrow = json.readAddress(_buildJsonPath(basePath, i, "escrowAddress"));

            (uint128 total, uint128 reserved) = PoolEscrow(escrow).holding(ShareClassId.wrap(scIdRaw), asset, 0);

            string memory key = _buildCacheKey(poolIdRaw, scIdRaw, asset);
            holdingsJson = vm.serializeUint(HOLDINGS_CACHE_KEY, string.concat(key, "_total"), total);
            holdingsJson = vm.serializeUint(HOLDINGS_CACHE_KEY, string.concat(key, "_reserved"), reserved);
        }
    }

    function _buildBalancesCache(ValidationContext memory ctx) internal returns (string memory balancesJson) {
        string memory json = ctx.store.query(_holdingEscrowsQuery(ctx));
        uint256 totalCount = json.readUint(".data.holdingEscrows.totalCount");

        balancesJson = vm.serializeJson(BALANCES_CACHE_KEY, "{}");

        for (uint256 i = 0; i < totalCount; i++) {
            string memory basePath = ".data.holdingEscrows.items";

            uint64 poolIdRaw = uint64(json.readUint(_buildJsonPath(basePath, i, "poolId")));
            bytes16 scIdRaw = bytes16(vm.parseBytes(json.readString(_buildJsonPath(basePath, i, "tokenId"))));
            address asset = json.readAddress(_buildJsonPath(basePath, i, "assetAddress"));
            address escrow = json.readAddress(_buildJsonPath(basePath, i, "escrowAddress"));

            // Defensive: skip assets that revert on balanceOf (malicious assets)
            uint256 balance;
            try IERC20(asset).balanceOf(escrow) returns (uint256 bal) {
                balance = bal;
            } catch {
                continue; // Skip malicious assets
            }

            string memory key = _buildCacheKey(poolIdRaw, scIdRaw, asset);
            balancesJson = vm.serializeUint(BALANCES_CACHE_KEY, key, balance);
        }
    }

    function _validatePost(ValidationContext memory ctx) internal returns (ValidationResult memory) {
        _holdingsJson = ctx.store.get(HOLDINGS_CACHE_KEY);
        _balancesJson = ctx.store.get(BALANCES_CACHE_KEY);

        string memory json = ctx.store.query(_holdingEscrowsQuery(ctx));
        uint256 totalCount = json.readUint(".data.holdingEscrows.totalCount");

        for (uint256 i = 0; i < totalCount; i++) {
            _validateEntry(ctx, json, i);
        }

        ValidationError[] memory errors = new ValidationError[](_errors.length);
        for (uint256 i = 0; i < _errors.length; i++) {
            errors[i] = _errors[i];
        }

        return
            ValidationResult({passed: errors.length == 0, validatorName: "PoolEscrowHoldings (POST)", errors: errors});
    }

    function _validateEntry(ValidationContext memory ctx, string memory json, uint256 i) internal {
        string memory basePath = ".data.holdingEscrows.items";

        uint64 poolIdRaw = uint64(json.readUint(_buildJsonPath(basePath, i, "poolId")));
        bytes16 scIdRaw = bytes16(vm.parseBytes(json.readString(_buildJsonPath(basePath, i, "tokenId"))));
        address asset = json.readAddress(_buildJsonPath(basePath, i, "assetAddress"));

        address newEscrow = address(ctx.latest.core.poolEscrowFactory.escrow(PoolId.wrap(poolIdRaw)));
        (uint128 newTotal, uint128 newReserved) = PoolEscrow(newEscrow).holding(ShareClassId.wrap(scIdRaw), asset, 0);

        // Defensive: skip assets that revert on balanceOf (malicious assets)
        // If asset was skipped in PRE phase, it won't be in the cache and we skip it here too
        string memory key = _buildCacheKey(poolIdRaw, scIdRaw, asset);
        try vm.parseJsonUint(_balancesJson, string.concat(".", key)) {
        // Asset exists in cache - proceed with validation
        }
        catch {
            // Asset was skipped in PRE phase (malicious) - skip in POST too
            return;
        }

        uint256 newBalance;
        try IERC20(asset).balanceOf(newEscrow) returns (uint256 bal) {
            newBalance = bal;
        } catch {
            // Asset reverts on balanceOf - skip validation
            return;
        }

        _compareTotal(poolIdRaw, scIdRaw, asset, newTotal);
        _compareReserved(poolIdRaw, scIdRaw, asset, newReserved);
        _compareBalance(poolIdRaw, scIdRaw, asset, newBalance);
    }

    function _compareTotal(uint64 poolIdRaw, bytes16 scIdRaw, address asset, uint128 newTotal) internal {
        string memory key = _buildCacheKey(poolIdRaw, scIdRaw, asset);
        uint128 oldTotal = uint128(_holdingsJson.readUint(string.concat(".", key, "_total")));

        if (newTotal != oldTotal) {
            _errors.push(
                _buildError({
                    field: "holding.total",
                    value: _buildIdentifier(poolIdRaw, scIdRaw, asset),
                    expected: _toString(oldTotal),
                    actual: _toString(newTotal),
                    message: string.concat("Holding total mismatch")
                })
            );
        }
    }

    function _compareReserved(uint64 poolIdRaw, bytes16 scIdRaw, address asset, uint128 newReserved) internal {
        string memory key = _buildCacheKey(poolIdRaw, scIdRaw, asset);
        uint128 oldReserved = uint128(_holdingsJson.readUint(string.concat(".", key, "_reserved")));

        if (newReserved != oldReserved) {
            _errors.push(
                _buildError({
                    field: "holding.reserved",
                    value: _buildIdentifier(poolIdRaw, scIdRaw, asset),
                    expected: _toString(oldReserved),
                    actual: _toString(newReserved),
                    message: string.concat("Holding reserved mismatch")
                })
            );
        }
    }

    function _compareBalance(uint64 poolIdRaw, bytes16 scIdRaw, address asset, uint256 newBalance) internal {
        string memory key = _buildCacheKey(poolIdRaw, scIdRaw, asset);
        uint256 oldBalance = _balancesJson.readUint(string.concat(".", key));

        if (newBalance != oldBalance) {
            _errors.push(
                _buildError({
                    field: "escrow.balance",
                    value: _buildIdentifier(poolIdRaw, scIdRaw, asset),
                    expected: _toString(oldBalance),
                    actual: _toString(newBalance),
                    message: string.concat("ERC20 balance mismatch")
                })
            );
        }
    }

    function _buildIdentifier(uint64 poolIdRaw, bytes16 scIdRaw, address asset) internal pure returns (string memory) {
        return
            string.concat(
                "Pool ", vm.toString(poolIdRaw), " / SC ", vm.toString(scIdRaw), " / Asset ", vm.toString(asset)
            );
    }

    function _holdingEscrowsQuery(ValidationContext memory ctx) internal pure returns (string memory) {
        return string.concat(
            "holdingEscrows(limit: 1000, where: { centrifugeId: ",
            _jsonValue(ctx.localCentrifugeId),
            " }) { items { poolId tokenId assetAddress escrowAddress } totalCount }"
        );
    }

    function _buildCacheKey(uint64 poolId, bytes16 scId, address asset) internal pure returns (string memory) {
        return string.concat(vm.toString(poolId), "_", vm.toString(scId), "_", vm.toString(asset));
    }
}
