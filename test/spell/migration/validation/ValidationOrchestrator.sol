// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {GraphQLStore} from "./GraphQLStore.sol";
import {BaseValidator} from "./BaseValidator.sol";
import {V3ContractsExt} from "./ValidationTypes.sol";
import {Validate_Spoke} from "./validators/Validate_Spoke.sol";
import {Validate_Subsidy} from "./validators/Validate_Subsidy.sol";
import {Validate_Holdings} from "./validators/Validate_Holdings.sol";
import {Validate_IsPaused} from "./validators/Validate_IsPaused.sol";
import {Validate_HubRegistry} from "./validators/Validate_HubRegistry.sol";
import {Validate_SyncManager} from "./validators/Validate_SyncManager.sol";
import {Validate_VaultRouter} from "./validators/Validate_VaultRouter.sol";
import {Validate_BalanceSheet} from "./validators/Validate_BalanceSheet.sol";
import {Validate_MultiAdapter} from "./validators/Validate_MultiAdapter.sol";
import {Validate_TokenFactory} from "./validators/Validate_TokenFactory.sol";
import {Validate_VaultRegistry} from "./validators/Validate_VaultRegistry.sol";
import {Validate_ShareTokenHook} from "./validators/Validate_ShareTokenHook.sol";
import {Validate_InvestmentFlows} from "./validators/Validate_InvestmentFlows.sol";
import {Validate_OnOfframpManager} from "./validators/Validate_OnOfframpManager.sol";
import {Validate_ShareClassManager} from "./validators/Validate_ShareClassManager.sol";
import {Validate_CrossChainMessages} from "./validators/Validate_CrossChainMessages.sol";
import {Validate_OutstandingInvests} from "./validators/Validate_OutstandingInvests.sol";
import {Validate_OutstandingRedeems} from "./validators/Validate_OutstandingRedeems.sol";
import {Validate_BatchRequestManager} from "./validators/Validate_BatchRequestManager.sol";
import {Validate_UnclaimedInvestOrders} from "./validators/Validate_UnclaimedInvestOrders.sol";
import {Validate_UnclaimedRedeemOrders} from "./validators/Validate_UnclaimedRedeemOrders.sol";
import {Validate_EpochOutstandingInvests} from "./validators/Validate_EpochOutstandingInvests.sol";
import {Validate_EpochOutstandingRedeems} from "./validators/Validate_EpochOutstandingRedeems.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";

import {FullReport} from "../../../../script/FullDeployer.s.sol";
import {MigrationQueries} from "../../../../script/spell/MigrationQueries.sol";

import {Vm} from "forge-std/Vm.sol";

import {ChainResolver} from "../ChainResolver.sol";

/// @title ValidationOrchestrator
/// @notice Orchestrates pre and post-migration validation
/// @dev Single entry point for all validation operations
library ValidationOrchestrator {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event log_string(string);

    struct ValidationSuite {
        BaseValidator[] validators;
    }

    /// @notice Shared context built once and reused for PRE and POST validation
    /// @dev Only stores fields needed after construction - ChainContext is consumed during build
    struct SharedContext {
        uint16 localCentrifugeId;
        bool isMainnet;
        V3ContractsExt old;
        PoolId[] pools;
        PoolId[] hubPools;
        GraphQLStore store;
        MigrationQueries queryService;
        address executor;
    }

    /// @notice Build shared context for validation
    /// @dev Call this ONCE before runPreValidation, reuse for runPostValidation
    /// @param queryService MigrationQueries instance (shared with executor)
    /// @param chain ChainContext with resolved addresses and API endpoint
    /// @param cacheDir Cache directory for file persistence (empty string = in-memory only)
    /// For tests: cacheDir = "" (in-memory only)
    /// For production, i.e.: cacheDir = "spell-cache/validation" (file persistence)
    /// @param executor Address that executes the migration spell
    /// @return shared SharedContext to pass to runPreValidation and runPostValidation
    function buildSharedContext(
        MigrationQueries queryService,
        ChainResolver.ChainContext memory chain,
        string memory cacheDir,
        bool cleanCache,
        address executor
    ) internal returns (SharedContext memory shared) {
        emit log_string("[CONTEXT] Building shared validation context...");

        V3ContractsExt memory old = V3ContractsExt({
            inner: queryService.v3Contracts(), tokenFactory: chain.tokenFactory, routerEscrow: chain.routerEscrow
        });

        PoolId[] memory pools = queryService.pools();
        PoolId[] memory hubPools = queryService.hubPools(pools);

        shared = SharedContext({
            localCentrifugeId: chain.localCentrifugeId,
            isMainnet: chain.isMainnet,
            old: old,
            pools: pools,
            hubPools: hubPools,
            store: new GraphQLStore(chain.graphQLApi, cacheDir, cleanCache),
            queryService: queryService,
            executor: executor
        });

        emit log_string("[CONTEXT] Shared context built successfully");
    }

    /// @notice Run pre-migration validation
    /// @param shared SharedContext built by buildSharedContext()
    /// @param shouldRevert If false, displays [WARNING]; if true, reverts on errors
    /// @return true if all validations passed
    function runPreValidation(SharedContext memory shared, bool shouldRevert) internal returns (bool) {
        FullReport memory emptyReport;
        BaseValidator.ValidationContext memory ctx = BaseValidator.ValidationContext({
            phase: BaseValidator.Phase.PRE,
            old: shared.old,
            latest: emptyReport,
            pools: shared.pools,
            hubPools: shared.hubPools,
            localCentrifugeId: shared.localCentrifugeId,
            store: shared.store,
            isMainnet: shared.isMainnet,
            queryService: shared.queryService,
            executor: shared.executor
        });

        ValidationSuite memory suite = _buildPreSuite();
        return _execute(suite, ctx, "PRE-MIGRATION", shouldRevert);
    }

    /// @notice Run post-migration validation
    /// @param shared SharedContext built by buildSharedContext()
    /// @param latest The deployed v3.1 contracts
    /// @return true if all validations passed
    function runPostValidation(SharedContext memory shared, FullReport memory latest) internal returns (bool) {
        BaseValidator.ValidationContext memory ctx = BaseValidator.ValidationContext({
            phase: BaseValidator.Phase.POST,
            old: shared.old,
            latest: latest,
            pools: shared.pools,
            hubPools: shared.hubPools,
            localCentrifugeId: shared.localCentrifugeId,
            store: shared.store,
            isMainnet: shared.isMainnet,
            queryService: shared.queryService,
            executor: shared.executor
        });

        ValidationSuite memory suite = _buildPostSuite();
        return _execute(suite, ctx, "POST-MIGRATION", true); // Always revert on POST errors
    }

    // ============================================
    // Suite Builders
    // ============================================

    function _buildPreSuite() private returns (ValidationSuite memory) {
        BaseValidator[] memory validators = new BaseValidator[](19);

        validators[0] = new Validate_EpochOutstandingInvests();
        validators[1] = new Validate_EpochOutstandingRedeems();
        validators[2] = new Validate_OutstandingInvests();
        validators[3] = new Validate_OutstandingRedeems();
        validators[4] = new Validate_CrossChainMessages();
        validators[5] = new Validate_Holdings();
        validators[6] = new Validate_ShareClassManager();
        validators[7] = new Validate_BalanceSheet();
        validators[8] = new Validate_HubRegistry();
        validators[9] = new Validate_OnOfframpManager();
        validators[10] = new Validate_Spoke();
        validators[11] = new Validate_SyncManager();
        validators[12] = new Validate_VaultRegistry();
        validators[13] = new Validate_BatchRequestManager();
        validators[14] = new Validate_UnclaimedInvestOrders();
        validators[15] = new Validate_UnclaimedRedeemOrders();
        validators[16] = new Validate_VaultRouter();
        validators[17] = new Validate_Subsidy();
        validators[18] = new Validate_IsPaused();

        return ValidationSuite({validators: validators});
    }

    function _buildPostSuite() private returns (ValidationSuite memory) {
        BaseValidator[] memory validators = new BaseValidator[](13);

        validators[0] = new Validate_ShareClassManager();
        validators[1] = new Validate_BalanceSheet();
        validators[2] = new Validate_HubRegistry();
        validators[3] = new Validate_OnOfframpManager();
        validators[4] = new Validate_Spoke();
        validators[5] = new Validate_TokenFactory();
        validators[6] = new Validate_SyncManager();
        validators[7] = new Validate_VaultRegistry();
        validators[8] = new Validate_BatchRequestManager();
        validators[9] = new Validate_Subsidy();
        validators[10] = new Validate_ShareTokenHook();
        validators[11] = new Validate_MultiAdapter();
        validators[12] = new Validate_InvestmentFlows();

        return ValidationSuite({validators: validators});
    }

    // ============================================
    // Execution
    // ============================================

    function _execute(
        ValidationSuite memory suite,
        BaseValidator.ValidationContext memory ctx,
        string memory phaseName,
        bool shouldRevert
    ) private returns (bool) {
        BaseValidator.ValidationResult[] memory results = new BaseValidator.ValidationResult[](suite.validators.length);
        uint256 totalErrors = 0;

        for (uint256 i = 0; i < suite.validators.length; i++) {
            BaseValidator.Phase supported = suite.validators[i].supportedPhases();
            require(
                supported == BaseValidator.Phase.BOTH || supported == ctx.phase, "Validator does not support this phase"
            );

            results[i] = suite.validators[i].validate(ctx);
            totalErrors += results[i].errors.length;
        }

        _displayReport(results, totalErrors, phaseName, shouldRevert);

        if (totalErrors > 0) {
            if (shouldRevert) {
                revert(string.concat(phaseName, " validation failed: ", vm.toString(totalErrors), " errors"));
            }
            return false;
        }

        return true;
    }

    function _displayReport(
        BaseValidator.ValidationResult[] memory results,
        uint256 totalErrors,
        string memory phaseName,
        bool shouldRevert
    ) private {
        emit log_string("");
        emit log_string("================================================================");
        emit log_string(string.concat("     ", phaseName, " VALIDATION RESULTS"));
        emit log_string("================================================================");
        emit log_string("");

        uint256 passedCount = 0;
        uint256 failedCount = 0;

        for (uint256 i = 0; i < results.length; i++) {
            BaseValidator.ValidationResult memory result = results[i];

            if (result.passed) {
                passedCount++;
                emit log_string(string.concat("[PASS] ", result.validatorName));
            } else {
                failedCount++;
                string memory prefix = shouldRevert ? "[FAIL]" : "[WARNING]";
                emit log_string(string.concat(prefix, " ", result.validatorName));
                emit log_string(string.concat("   Errors: ", vm.toString(result.errors.length)));
                emit log_string("");

                for (uint256 j = 0; j < result.errors.length; j++) {
                    BaseValidator.ValidationError memory err = result.errors[j];
                    emit log_string(string.concat("   Error #", vm.toString(j + 1), ":"));
                    emit log_string(string.concat("   - Message:  ", err.message));
                    emit log_string(string.concat("   - Field:    ", err.field));
                    emit log_string(string.concat("   - Value:    ", err.value));
                    emit log_string(string.concat("   - Expected: ", err.expected));
                    emit log_string(string.concat("   - Actual:   ", err.actual));
                    emit log_string("");
                }
            }
        }

        emit log_string("================================================================");
        emit log_string("                         SUMMARY");
        emit log_string("================================================================");
        emit log_string(string.concat("Total Validators: ", vm.toString(results.length)));
        emit log_string(string.concat("Passed:           ", vm.toString(passedCount)));
        emit log_string(string.concat("Failed:           ", vm.toString(failedCount)));
        emit log_string(string.concat("Total Errors:     ", vm.toString(totalErrors)));
        emit log_string("================================================================");
    }
}
