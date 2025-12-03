// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {GraphQLStore} from "./GraphQLStore.sol";
import {BaseValidator} from "./BaseValidator.sol";
import {PoolMigrationOldContractsExt} from "./ValidationTypes.sol";
import {Validate_ShareClassManager} from "./validators/Validate_ShareClassManager.sol";
import {Validate_CrossChainMessages} from "./validators/Validate_CrossChainMessages.sol";
import {Validate_OutstandingInvests} from "./validators/Validate_OutstandingInvests.sol";
import {Validate_OutstandingRedeems} from "./validators/Validate_OutstandingRedeems.sol";
import {Validate_EpochOutstandingInvests} from "./validators/Validate_EpochOutstandingInvests.sol";
import {Validate_EpochOutstandingRedeems} from "./validators/Validate_EpochOutstandingRedeems.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {MessageDispatcher} from "../../../../src/core/messaging/MessageDispatcher.sol";

import {Root} from "../../../../src/admin/Root.sol";

import {FullDeployer} from "../../../../script/FullDeployer.s.sol";
import {GraphQLConstants} from "../../../../script/utils/GraphQLConstants.sol";
import {MigrationQueries} from "../../../../script/spell/MigrationQueries.sol";

import {Vm} from "forge-std/Vm.sol";

interface MessageDispatcherV3Like {
    function root() external view returns (Root root);
}

/// @title ValidationOrchestrator
/// @notice Orchestrates pre and post-migration validation
/// @dev Single entry point for all validation operations
library ValidationOrchestrator {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address constant PRODUCTION_MESSAGE_DISPATCHER_V3 = 0x21AF0C29611CFAaFf9271C8a3F84F2bC31d59132;
    address constant TESTNET_MESSAGE_DISPATCHER_V3 = 0x332bE89CAB9FF501F5EBe3f6DC9487bfF50Bd0BF;

    event log_string(string);

    struct ValidationSuite {
        BaseValidator[] validators;
    }

    /// @notice Chain context resolved from isMainnet flag
    struct ChainContext {
        address rootWard;
        uint16 localCentrifugeId;
        Root rootV3;
        string graphQLApi;
        bool isMainnet;
    }

    /// @notice Shared context built once and reused for PRE and POST validation
    /// @dev Only stores fields needed after construction - ChainContext is consumed during build
    struct SharedContext {
        uint16 localCentrifugeId;
        bool isMainnet;
        PoolMigrationOldContractsExt old;
        PoolId[] pools;
        PoolId[] hubPools;
        GraphQLStore store;
        MigrationQueries queryService;
    }

    /// @notice Resolve chain context from isMainnet flag
    /// @dev Centralizes address resolution logic for v3.0.1 contracts
    /// @param isMainnet Whether this is production (mainnet) or testnet
    /// @return ctx ChainContext with resolved addresses and API endpoint
    function resolveChainContext(bool isMainnet) internal view returns (ChainContext memory ctx) {
        address rootWard = isMainnet ? PRODUCTION_MESSAGE_DISPATCHER_V3 : TESTNET_MESSAGE_DISPATCHER_V3;
        uint16 localCentrifugeId = MessageDispatcher(rootWard).localCentrifugeId();
        Root rootV3 = MessageDispatcherV3Like(rootWard).root();
        string memory graphQLApi = isMainnet ? GraphQLConstants.PRODUCTION_API : GraphQLConstants.TESTNET_API;

        ctx = ChainContext({
            rootWard: rootWard,
            localCentrifugeId: localCentrifugeId,
            rootV3: rootV3,
            graphQLApi: graphQLApi,
            isMainnet: isMainnet
        });
    }

    /// @notice Build shared context for validation
    /// @dev Call this ONCE before runPreValidation, reuse for runPostValidation
    /// @param queryService MigrationQueries instance (shared with executor)
    /// @param pools All pools to migrate
    /// @param chain ChainContext with resolved addresses and API endpoint
    /// @param cacheDir Cache directory for file persistence (empty string = in-memory only)
    /// @return shared SharedContext to pass to runPreValidation and runPostValidation
    function buildSharedContext(
        MigrationQueries queryService,
        PoolId[] memory pools,
        ChainContext memory chain,
        string memory cacheDir
    ) internal returns (SharedContext memory shared) {
        emit log_string("[CONTEXT] Building shared validation context...");

        PoolMigrationOldContractsExt memory old = PoolMigrationOldContractsExt({
            inner: queryService.poolMigrationOldContracts(),
            root: address(chain.rootV3),
            messageDispatcher: chain.rootWard
        });

        PoolId[] memory hubPools = queryService.hubPools(pools);

        // For tests: cacheDir = "" (in-memory only)
        // For production: cacheDir = "spell-cache/validation" (file persistence)
        bool cleanCache = true; // PRE phase always cleans

        shared = SharedContext({
            localCentrifugeId: chain.localCentrifugeId,
            isMainnet: chain.isMainnet,
            old: old,
            pools: pools,
            hubPools: hubPools,
            store: new GraphQLStore(chain.graphQLApi, cacheDir, cleanCache),
            queryService: queryService
        });

        emit log_string("[CONTEXT] Shared context built successfully");
    }

    /// @notice Run pre-migration validation
    /// @param shared SharedContext built by buildSharedContext()
    /// @param shouldRevert If false, displays [WARNING]; if true, reverts on errors
    /// @return true if all validations passed
    function runPreValidation(SharedContext memory shared, bool shouldRevert) internal returns (bool) {
        BaseValidator.ValidationContext memory ctx = BaseValidator.ValidationContext({
            phase: BaseValidator.Phase.PRE,
            old: shared.old,
            deployer: FullDeployer(address(0)),
            pools: shared.pools,
            hubPools: shared.hubPools,
            localCentrifugeId: shared.localCentrifugeId,
            store: shared.store,
            isMainnet: shared.isMainnet
        });

        ValidationSuite memory suite = _buildPreSuite();
        return _execute(suite, ctx, "PRE-MIGRATION", shouldRevert);
    }

    /// @notice Run post-migration validation
    /// @param shared SharedContext built by buildSharedContext()
    /// @param deployer The deployed v3.1 contracts
    /// @return true if all validations passed
    function runPostValidation(SharedContext memory shared, FullDeployer deployer) internal returns (bool) {
        BaseValidator.ValidationContext memory ctx = BaseValidator.ValidationContext({
            phase: BaseValidator.Phase.POST,
            old: shared.old,
            deployer: deployer,
            pools: shared.pools,
            hubPools: shared.hubPools,
            localCentrifugeId: shared.localCentrifugeId,
            store: shared.store,
            isMainnet: shared.isMainnet
        });

        ValidationSuite memory suite = _buildPostSuite();
        return _execute(suite, ctx, "POST-MIGRATION", true); // Always revert on POST errors
    }

    // ============================================
    // Suite Builders
    // ============================================

    function _buildPreSuite() private returns (ValidationSuite memory) {
        BaseValidator[] memory validators = new BaseValidator[](6);

        // GraphQL-based pre-migration validators (use ctx.store.query())
        validators[0] = new Validate_EpochOutstandingInvests();
        validators[1] = new Validate_EpochOutstandingRedeems();
        validators[2] = new Validate_OutstandingInvests();
        validators[3] = new Validate_OutstandingRedeems();
        validators[4] = new Validate_CrossChainMessages();

        // On-chain validators (BOTH phase)
        validators[5] = new Validate_ShareClassManager();

        return ValidationSuite({validators: validators});
    }

    function _buildPostSuite() private returns (ValidationSuite memory) {
        BaseValidator[] memory validators = new BaseValidator[](1);

        // On-chain validators (BOTH phase) - compares old vs new ShareClassManager
        validators[0] = new Validate_ShareClassManager();

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
