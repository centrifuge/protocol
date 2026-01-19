// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IRecoverable} from "../../../../../src/misc/interfaces/IRecoverable.sol";

import {Spoke} from "../../../../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {HubRegistry} from "../../../../../src/core/hub/HubRegistry.sol";
import {PoolEscrowFactory} from "../../../../../src/core/spoke/factories/PoolEscrowFactory.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator} from "../BaseValidator.sol";

PoolId constant GLOBAL_POOL = PoolId.wrap(0);

interface GatewayV3Like {
    function subsidy(PoolId) external view returns (uint96 value, IRecoverable refund);
}

/// @title Validate_Subsidy
/// @notice Validates subsidy state after migration
/// @dev POST: Verifies old Gateway has 0 ETH and executor received the global subsidy
contract Validate_Subsidy is BaseValidator {
    using stdJson for string;

    string private constant POOL_ESCROW_BALANCES_KEY = "poolEscrowBalances";

    function supportedPhases() public pure override returns (Phase) {
        return Phase.BOTH;
    }

    function name() public pure override returns (string memory) {
        return "Subsidy";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        if (ctx.phase == Phase.PRE) {
            return _validatePre(ctx);
        } else {
            return _validatePost(ctx);
        }
    }

    function _validatePre(ValidationContext memory ctx) internal returns (ValidationResult memory) {
        // Only caches pool escrow balances, does not do any check
        string memory json = vm.serializeJson(POOL_ESCROW_BALANCES_KEY, "{}"); // Reset json

        PoolId[] memory pools = ctx.pools;
        for (uint256 i; i < pools.length; i++) {
            PoolId poolId = pools[i];
            address oldPoolEscrow = address(PoolEscrowFactory(ctx.old.inner.poolEscrowFactory).escrow(poolId));

            json = vm.serializeUint(POOL_ESCROW_BALANCES_KEY, _toString(PoolId.unwrap(poolId)), oldPoolEscrow.balance);
        }

        ctx.store.set(POOL_ESCROW_BALANCES_KEY, json);

        return ValidationResult({passed: true, validatorName: "Subsidy (PRE)", errors: new ValidationError[](0)});
    }

    /// @notice POST-migration: Verify old Gateway ETH balance is 0 and executor has the global subsidy
    function _validatePost(ValidationContext memory ctx) internal returns (ValidationResult memory) {
        PoolId[] memory pools = ctx.pools;
        ValidationError[] memory errors = new ValidationError[](2 + pools.length * 2);
        uint256 errorCount = 0;

        address oldGateway = ctx.old.inner.gateway;

        // Check 1: Old Gateway should have 0 ETH
        if (oldGateway.balance > 0) {
            errors[errorCount++] = _buildError({
                field: "gateway.balance",
                value: vm.toString(oldGateway),
                expected: "0",
                actual: _toString(oldGateway.balance),
                message: string.concat("Old Gateway still has ETH balance: ", _toString(oldGateway.balance), " wei")
            });
        }

        // Check 2: Old pool escrows should have 0 ETH
        for (uint256 i; i < pools.length; i++) {
            PoolId poolId = pools[i];
            address oldPoolEscrow = address(PoolEscrowFactory(ctx.old.inner.poolEscrowFactory).escrow(poolId));

            if (oldPoolEscrow.balance > 0) {
                errors[errorCount++] = _buildError({
                    field: "poolEscrow.balance",
                    value: vm.toString(oldPoolEscrow),
                    expected: "0",
                    actual: _toString(oldPoolEscrow.balance),
                    message: string.concat(
                        "Old PoolEscrow still has ETH balance: ", _toString(oldPoolEscrow.balance), " wei"
                    )
                });
            }
        }

        // Check 3: Executor should have at least the global subsidy amount
        (uint96 globalSubsidy,) = GatewayV3Like(oldGateway).subsidy(GLOBAL_POOL);

        if (ctx.executor.balance < globalSubsidy) {
            errors[errorCount++] = _buildError({
                field: "executor.balance",
                value: vm.toString(ctx.executor),
                expected: string.concat(">=", _toString(globalSubsidy)),
                actual: _toString(ctx.executor.balance),
                message: string.concat(
                    "Executor balance (",
                    _toString(ctx.executor.balance),
                    " wei) is less than global subsidy (",
                    _toString(globalSubsidy),
                    " wei)"
                )
            });
        }

        // Check 4: Manager or refundEscrow should have at least the pool subsidy amount + escrow balance amount
        string memory poolEscrowBalancesJson = ctx.store.get(POOL_ESCROW_BALANCES_KEY);
        for (uint256 i; i < pools.length; i++) {
            PoolId poolId = pools[i];
            address[] memory hubManagers = ctx.queryService.hubManagers(poolId);

            bool inHub = HubRegistry(ctx.old.inner.hubRegistry).exists(poolId);
            bool inSpoke = Spoke(ctx.old.inner.spoke).isPoolActive(poolId);

            address refund;
            if (inHub) refund = hubManagers[0];
            if (inSpoke) refund = address(ctx.latest.refundEscrowFactory.get(poolId));

            (uint96 poolSubsidy,) = GatewayV3Like(oldGateway).subsidy(poolId);
            uint256 oldPoolEscrowBalance =
                poolEscrowBalancesJson.readUint(string.concat(".", _toString(PoolId.unwrap(poolId))));
            uint256 expectedBalance = uint256(poolSubsidy) + oldPoolEscrowBalance;

            if (refund.balance < expectedBalance) {
                errors[errorCount++] = _buildError({
                    field: "managerOrRefundEscrow.balance",
                    value: vm.toString(refund),
                    expected: string.concat(">=", _toString(expectedBalance)),
                    actual: _toString(refund.balance),
                    message: string.concat(
                        "Refund balance (",
                        _toString(refund.balance),
                        " wei) is less than pool subsidy + old escrow balance (",
                        _toString(expectedBalance),
                        " wei)"
                    )
                });
            }
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "Subsidy (POST)", errors: _trimErrors(errors, errorCount)
        });
    }
}
