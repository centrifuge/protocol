// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../../src/core/types/ShareClassId.sol";
import {VaultKind} from "../../../../../src/core/spoke/interfaces/IVault.sol";
import {IShareToken} from "../../../../../src/core/spoke/interfaces/IShareToken.sol";

import {IBaseVault} from "../../../../../src/vaults/interfaces/IBaseVault.sol";

import {FullReport} from "../../../../../script/FullDeployer.s.sol";
import {VaultGraphQLData} from "../../../../../script/spell/MigrationQueries.sol";

import {console} from "forge-std/console.sol";

import {BaseValidator} from "../BaseValidator.sol";
import {InvestmentFlowExecutor, InvestmentFlowResult} from "../InvestmentFlowExecutor.sol";

/// @title Validate_InvestmentFlows
/// @notice POST-migration validator that executes end-to-end investment flows
/// @dev Validates that all linked vaults can process deposits and redemptions
contract Validate_InvestmentFlows is BaseValidator {
    function supportedPhases() public pure override returns (Phase) {
        return Phase.POST;
    }

    function name() public pure override returns (string memory) {
        return "InvestmentFlows";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        VaultGraphQLData[] memory allVaults = ctx.queryService.linkedVaultsWithMetadata();

        console.log("");
        console.log("=== InvestmentFlows Validator (centrifugeId: %s) ===", ctx.localCentrifugeId);
        console.log("Total vaults from GraphQL: %s", allVaults.length);

        (VaultGraphQLData[] memory localVaults, VaultGraphQLData[] memory crossChainVaults) =
            _categorizeVaults(allVaults, ctx.latest, ctx.localCentrifugeId);

        console.log("Local vaults (hub == spoke): %s", localVaults.length);
        console.log("Cross-chain vaults (hub != spoke): %s", crossChainVaults.length);

        VaultGraphQLData[] memory testableVaults = _concat(localVaults, crossChainVaults);
        uint256 skipped = allVaults.length - testableVaults.length;

        if (testableVaults.length == 0) {
            console.log("WARNING: No vaults to test!");
            return ValidationResult({
                passed: true, validatorName: "InvestmentFlows [No testable vaults]", errors: new ValidationError[](0)
            });
        }

        if (!ctx.isMainnet) {
            return ValidationResult({
                passed: true,
                validatorName: string.concat(
                    "InvestmentFlows (", _toString(testableVaults.length), " vaults) [SKIPPED - testnet]"
                ),
                errors: new ValidationError[](0)
            });
        }

        InvestmentFlowExecutor executor = new InvestmentFlowExecutor();
        vm.deal(address(executor), 100 ether);

        // Assume the protocol is unpause for this post-validation
        vm.prank(address(ctx.latest.protocolGuardian));
        ctx.latest.root.unpause();

        InvestmentFlowResult[] memory results =
            executor.executeAllFlows(ctx.latest, testableVaults, ctx.localCentrifugeId);

        // Restore state for other validations
        vm.prank(address(ctx.latest.protocolGuardian));
        ctx.latest.root.pause();

        return _buildResult(results, testableVaults.length, skipped);
    }

    // ============================================
    // Vault Categorization
    // ============================================

    function _categorizeVaults(VaultGraphQLData[] memory allVaults, FullReport memory report, uint16 localCentrifugeId)
        internal
        view
        returns (VaultGraphQLData[] memory local, VaultGraphQLData[] memory crossChain)
    {
        // Allocate max-sized arrays for now, we will reduce later
        local = new VaultGraphQLData[](allVaults.length);
        crossChain = new VaultGraphQLData[](allVaults.length);

        uint256 localIdx = 0;
        uint256 crossChainIdx = 0;

        for (uint256 i = 0; i < allVaults.length; i++) {
            bool isCrossChain = allVaults[i].hubCentrifugeId != localCentrifugeId;

            if (isCrossChain) {
                if (_isValidCrossChainVault(allVaults[i], report)) {
                    crossChain[crossChainIdx++] = allVaults[i];
                }
            } else {
                if (_isValidLocalVault(allVaults[i], report)) {
                    local[localIdx++] = allVaults[i];
                }
            }
        }

        // Truncate arrays to actual size using assembly
        assembly {
            mstore(local, localIdx)
            mstore(crossChain, crossChainIdx)
        }
    }

    /// @notice Validates a cross-chain vault (hub on different chain)
    /// @dev Only checks spoke-side requirements since hub state is not accessible locally
    function _isValidCrossChainVault(VaultGraphQLData memory v, FullReport memory report) internal view returns (bool) {
        PoolId poolId = PoolId.wrap(v.poolIdRaw);

        AssetId assetId = report.core.spoke.assetToId(v.assetAddress, 0);
        if (assetId.raw() == 0) return false;

        try IBaseVault(v.vault).share() returns (address shareToken) {
            if (shareToken == address(0)) return false;
        } catch {
            return false;
        }

        // For cross-chain vaults, BalanceSheet must have AsyncRequestManager as manager
        // We can't set this up in fork tests (pool doesn't exist locally), so skip if not configured
        if (!report.core.balanceSheet.manager(poolId, address(report.asyncRequestManager))) {
            console.log("SKIP: Vault %s - BalanceSheet.manager not set for pool %s", v.vault, v.poolIdRaw);
            return false;
        }

        return true;
    }

    /// @notice Validates a local vault (hub on same chain)
    /// @dev Checks both hub and spoke requirements
    function _isValidLocalVault(VaultGraphQLData memory v, FullReport memory report) internal view returns (bool) {
        PoolId poolId = PoolId.wrap(v.poolIdRaw);
        ShareClassId scId = ShareClassId.wrap(v.tokenIdRaw);

        // Hub-side checks
        if (!report.core.hubRegistry.exists(poolId)) return false;
        if (!report.core.shareClassManager.exists(poolId, scId)) return false;

        // Spoke-side checks
        AssetId assetId = report.core.spoke.assetToId(v.assetAddress, 0);
        if (assetId.raw() == 0) return false;

        try report.core.spoke.shareToken(poolId, scId) returns (IShareToken token) {
            return address(token) != address(0);
        } catch {
            return false;
        }
    }

    /// @notice Concatenates two vault arrays
    function _concat(VaultGraphQLData[] memory a, VaultGraphQLData[] memory b)
        internal
        pure
        returns (VaultGraphQLData[] memory result)
    {
        result = new VaultGraphQLData[](a.length + b.length);

        for (uint256 i = 0; i < a.length; i++) {
            result[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            result[a.length + i] = b[i];
        }
    }

    // ============================================
    // Result Building
    // ============================================

    function _buildResult(InvestmentFlowResult[] memory results, uint256 vaultCount, uint256 skipped)
        internal
        pure
        returns (ValidationResult memory)
    {
        ValidationError[] memory errors = new ValidationError[](vaultCount * 2);
        uint256 errorCount = 0;
        uint256 passed = 0;

        for (uint256 i = 0; i < results.length; i++) {
            InvestmentFlowResult memory result = results[i];
            bool vaultPassed = result.depositPassed && result.redeemPassed;

            if (vaultPassed) {
                passed++;
            } else {
                console.log(
                    "FAILED: %s (%s, %s)",
                    result.vault,
                    _vaultKindToString(result.kind),
                    result.isCrossChain ? "CrossChain" : "Local"
                );

                if (!result.depositPassed) {
                    console.log("  Deposit: %s", result.depositError);
                    errors[errorCount++] = _buildError({
                        field: "deposit",
                        value: string.concat(
                            vm.toString(result.vault),
                            " (",
                            _vaultKindToString(result.kind),
                            result.isCrossChain ? ", CrossChain" : "",
                            ")"
                        ),
                        expected: "success",
                        actual: "failed",
                        message: bytes(result.depositError).length > 0 ? result.depositError : "Unknown error"
                    });
                }

                if (!result.redeemPassed) {
                    console.log("  Redeem: %s", result.redeemError);
                    errors[errorCount++] = _buildError({
                        field: "redeem",
                        value: string.concat(
                            vm.toString(result.vault),
                            " (",
                            _vaultKindToString(result.kind),
                            result.isCrossChain ? ", CrossChain" : "",
                            ")"
                        ),
                        expected: "success",
                        actual: "failed",
                        message: bytes(result.redeemError).length > 0 ? result.redeemError : "Unknown error"
                    });
                }
            }
        }

        // Log summary
        console.log("");
        console.log("=== Results ===");
        console.log("Passed: %s", passed);
        console.log("Skipped: %s", skipped);
        console.log("Failed: %s", results.length - passed);
        console.log("Total tested: %s", vaultCount);

        return ValidationResult({
            passed: errorCount == 0,
            validatorName: string.concat("InvestmentFlows (", _toString(vaultCount), " vaults)"),
            errors: _trimErrors(errors, errorCount)
        });
    }

    function _vaultKindToString(VaultKind kind) internal pure returns (string memory) {
        if (kind == VaultKind.Async) return "Async";
        if (kind == VaultKind.SyncDepositAsyncRedeem) return "SyncDeposit";
        return "Unknown";
    }
}
