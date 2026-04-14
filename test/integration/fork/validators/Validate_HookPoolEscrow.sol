// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {IPoolEscrow} from "../../../../src/core/spoke/interfaces/IPoolEscrow.sol";
import {IShareToken} from "../../../../src/core/spoke/interfaces/IShareToken.sol";
import {IBalanceSheet} from "../../../../src/core/spoke/interfaces/IBalanceSheet.sol";

import {IBaseVault} from "../../../../src/vaults/interfaces/IBaseVault.sol";

import {JsonUtils} from "../../../../script/utils/JsonUtils.s.sol";
import {ContractsConfig as C} from "../../../../script/utils/EnvConfig.s.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator, ValidationContext} from "../../spell/utils/validation/BaseValidator.sol";

/// @title Validate_HookPoolEscrow
/// @notice Validates that every vault's share token hook correctly recognises its pool escrow.
///         For each vault:
///           1. hook.isPoolEscrow(actualEscrow) must return true
///           2. If hook.poolEscrow() is non-zero, it must equal the actual pool escrow
contract Validate_HookPoolEscrow is BaseValidator("HookPoolEscrow") {
    using stdJson for string;
    using JsonUtils for *;

    function validate(ValidationContext memory ctx) public override {
        C memory c = ctx.contracts.live;

        string memory centrifugeIdStr = vm.toString(ctx.localCentrifugeId).asJsonString();
        string memory json = ctx.indexer
            .queryGraphQL(
                string.concat(
                    "vaults(limit: 1000, where: { centrifugeId: ", centrifugeIdStr, " }) { totalCount items { id } }"
                )
            );
        uint256 totalCount = json.readUint(".data.vaults.totalCount");

        if (totalCount == 0) return;
        require(totalCount < 1000, "Vault count exceeds query limit; implement pagination");

        for (uint256 i; i < totalCount; i++) {
            address vaultAddr = json.readAddress(".data.vaults.items".asJsonPath(i, "id"));
            _validateHookEscrow(vaultAddr, c);
        }
    }

    function _validateHookEscrow(address vaultAddr, C memory c) internal {
        string memory vaultLabel = vm.toString(vaultAddr);

        if (vaultAddr.code.length == 0) return;

        // Get share token
        address share;
        PoolId poolId;
        try IBaseVault(vaultAddr).share() returns (address s) {
            share = s;
        } catch {
            return; // Already caught by Validate_Vaults
        }
        try IBaseVault(vaultAddr).poolId() returns (PoolId p) {
            poolId = p;
        } catch {
            return;
        }

        if (share == address(0) || share.code.length == 0) return;

        // Get hook from share token
        address hook;
        try IShareToken(share).hook() returns (address h) {
            hook = h;
        } catch {
            return; // Share token without hook() — skip
        }

        if (hook == address(0) || hook.code.length == 0) return;

        // Get actual pool escrow from balanceSheet
        address actualEscrow;
        try IBalanceSheet(c.balanceSheet).escrow(poolId) returns (IPoolEscrow e) {
            actualEscrow = address(e);
        } catch {
            return; // No escrow for this pool — skip
        }

        if (actualEscrow == address(0) || actualEscrow.code.length == 0) return;

        // Check 1: hook.isPoolEscrow(actualEscrow) must return true
        (bool ok1, bytes memory data1) = hook.staticcall(abi.encodeWithSignature("isPoolEscrow(address)", actualEscrow));
        if (ok1 && data1.length >= 32) {
            bool recognised = abi.decode(data1, (bool));
            if (!recognised) {
                _errors.push(
                    _buildError(
                        "hook.isPoolEscrow",
                        vaultLabel,
                        "true",
                        "false",
                        string.concat(
                            "Hook ", vm.toString(hook), " does not recognise pool escrow ", vm.toString(actualEscrow)
                        )
                    )
                );
            }
        }

        // Check 2: If hook.poolEscrow() is non-zero, it must equal actualEscrow
        (bool ok2, bytes memory data2) = hook.staticcall(abi.encodeWithSignature("poolEscrow()"));
        if (ok2 && data2.length >= 32) {
            address immutableEscrow = abi.decode(data2, (address));
            if (immutableEscrow != address(0) && immutableEscrow != actualEscrow) {
                _errors.push(
                    _buildError(
                        "hook.poolEscrow",
                        vaultLabel,
                        vm.toString(actualEscrow),
                        vm.toString(immutableEscrow),
                        string.concat(
                            "Hook immutable poolEscrow mismatch. Hook: ",
                            vm.toString(hook),
                            " has poolEscrow=",
                            vm.toString(immutableEscrow),
                            " but balanceSheet.escrow() returns ",
                            vm.toString(actualEscrow)
                        )
                    )
                );
            }
        }
    }
}
