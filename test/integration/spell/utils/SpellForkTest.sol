// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {BaseValidator} from "./validation/BaseValidator.sol";
import {ValidationExecutor} from "./validation/ValidationExecutor.sol";
import {testContractsFromConfig} from "./validation/TestContracts.sol";
import {InvestmentFlowExecutor, InvestmentFlowResult, VaultGraphQLData} from "./validation/InvestmentFlowExecutor.sol";

import {JsonUtils} from "../../../../script/utils/JsonUtils.s.sol";
import {Env, EnvConfig} from "../../../../script/utils/EnvConfig.s.sol";
import {GraphQLQuery} from "../../../../script/utils/GraphQLQuery.s.sol";

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {Validate_Vaults} from "../../fork/validators/Validate_Vaults.sol";
import {NonCoreReport} from "../../../../src/deployment/ActionBatchers.sol";
import {Validate_Endorsements} from "../../fork/validators/Validate_Endorsements.sol";
import {Validate_ContractWards} from "../../fork/validators/Validate_ContractWards.sol";
import {Validate_GuardianSafes} from "../../fork/validators/Validate_GuardianSafes.sol";
import {Validate_HookPoolEscrow} from "../../fork/validators/Validate_HookPoolEscrow.sol";
import {Validate_RootPermissions} from "../../fork/validators/Validate_RootPermissions.sol";
import {Validate_FileConfigurations} from "../../fork/validators/Validate_FileConfigurations.sol";
import {Validate_AdapterConfigurations} from "../../fork/validators/Validate_AdapterConfigurations.sol";

/// @title  SpellForkTest
/// @notice Abstract base for spell fork tests. Inheritors run the spell on a
///         live-network fork and the base contract enforces the broader
///         live-state invariants on top of any spell-specific assertions.
///
/// @dev    Per-network flow:
///         1. Pre-cast snapshot: capture the structural validator error count
///            AND the investment-flow results, revert state.
///         2. Spell cast (child-defined).
///         3. Post-cast: run the structural validators again, assert the new
///            error count did not exceed the pre-cast baseline (regression
///            check; pre-existing live errors are tolerated).
///         4. Post-cast: run flows again, diff per-vault against step-1
///            snapshot — pre-existing failures tolerated, regressions fail.
///         5. Spell-specific assertions (child-defined).
///
/// @dev    Live mainnet currently has pre-existing errors in both suites
///         (e.g. Pharos adapter quorum mismatch and PoolEscrow accounting
///         drift surfaced by the structural validators; cross-chain sync
///         and unlinked-vault errors surfaced by the flow executor). Per
///         William's "we want the failure DIFF instead of failure" framing,
///         we tolerate these pre-existing failures and only fail the spell
///         test on NEW regressions introduced by the spell itself.
///
/// @dev    Structural-validator diff is intentionally coarse (count-only,
///         not per-error). A per-error diff was attempted but hit a
///         legacy-codegen stack-too-deep with optimizer_runs=1; the
///         count-based variant is enough to catch regressions and the full
///         per-error report is still emitted to logs for diagnostics.
abstract contract SpellForkTest is Test {
    using stdJson for string;
    using JsonUtils for *;

    // ------------------------------------------------------------------
    // Virtual hooks
    // ------------------------------------------------------------------

    /// @notice Deploy the spell, schedule any required relies, and cast it.
    function _castSpell(string memory network, EnvConfig memory config) internal virtual;

    /// @notice Spell-specific post-cast assertions (e.g. checking a sweep
    ///         transferred the expected balance).
    function _customPostAssertions(string memory network, EnvConfig memory config) internal virtual {}

    /// @notice If true (default), runs the investment flow suite pre- and
    ///         post-cast and diffs the results.
    function _runInvestmentFlowsDiff() internal pure virtual returns (bool) {
        return true;
    }

    // ------------------------------------------------------------------
    // Concrete driver
    // ------------------------------------------------------------------

    function _testCase(string memory network) internal {
        EnvConfig memory config = Env.load(network);
        vm.createSelectFork(config.network.rpcUrl());

        VaultGraphQLData[] memory vaults = _maybeQueryVaults(config);

        uint256 preValidatorErrors = _countValidatorErrorsSnapshotted(network);
        InvestmentFlowResult[] memory preFlows = _runFlowsSnapshotted(config, vaults);

        _castSpell(network, config);

        _assertValidatorErrorCountDidNotIncrease(network, preValidatorErrors);
        _assertNoFlowRegressions(preFlows, _runFlowsSnapshotted(config, vaults));
        _customPostAssertions(network, config);
    }

    function _maybeQueryVaults(EnvConfig memory config) internal returns (VaultGraphQLData[] memory) {
        if (!_runInvestmentFlowsDiff()) return new VaultGraphQLData[](0);
        GraphQLQuery indexer = new GraphQLQuery(config.network.graphQLApi());
        return _queryVaults(indexer, config.network.centrifugeId);
    }

    // ------------------------------------------------------------------
    // Validator helpers
    // ------------------------------------------------------------------

    function _buildValidators() internal returns (BaseValidator[] memory validators) {
        validators = new BaseValidator[](8);
        validators[0] = new Validate_RootPermissions();
        validators[1] = new Validate_ContractWards();
        validators[2] = new Validate_FileConfigurations();
        validators[3] = new Validate_Endorsements();
        validators[4] = new Validate_GuardianSafes();
        validators[5] = new Validate_AdapterConfigurations();
        validators[6] = new Validate_Vaults();
        validators[7] = new Validate_HookPoolEscrow();
    }

    /// @notice Run the 8 structural validators inside a state snapshot and
    ///         return the total error count without polluting surrounding
    ///         state. The per-validator report is still emitted to logs.
    function _countValidatorErrorsSnapshotted(string memory network) internal returns (uint256 count) {
        uint256 snap = vm.snapshotState();
        ValidationExecutor executor = new ValidationExecutor(network, "spell-fork-pre");
        count = executor.runValidationCountErrors(_buildValidators(), "PRE-CAST");
        vm.revertToState(snap);
    }

    /// @notice Run the 8 structural validators against post-cast live state
    ///         and assert the total error count did not exceed the pre-cast
    ///         baseline. The per-validator report is emitted to logs so the
    ///         spell author can see exactly which errors were tolerated and
    ///         which (if any) are new.
    function _assertValidatorErrorCountDidNotIncrease(string memory network, uint256 preErrors) internal {
        ValidationExecutor executor = new ValidationExecutor(network, "spell-fork-post");
        uint256 postErrors = executor.runValidationCountErrors(_buildValidators(), "POST-CAST");
        assertLe(postErrors, preErrors, "Spell introduced new structural validator errors");
    }

    // ------------------------------------------------------------------
    // Investment flow helpers
    // ------------------------------------------------------------------

    /// @notice Run InvestmentFlowExecutor inside a state snapshot so the side
    ///         effects (mints, deposits, hub registrations, manager updates)
    ///         do not bleed into the surrounding test state.
    function _runFlowsSnapshotted(EnvConfig memory config, VaultGraphQLData[] memory vaults)
        internal
        returns (InvestmentFlowResult[] memory)
    {
        if (vaults.length == 0) return new InvestmentFlowResult[](0);

        uint256 snap = vm.snapshotState();

        NonCoreReport memory report = testContractsFromConfig(config).main;
        InvestmentFlowExecutor executor = new InvestmentFlowExecutor();
        vm.deal(address(executor), 100 ether);

        InvestmentFlowResult[] memory results = executor.executeAllFlows(report, vaults, config.network.centrifugeId);

        vm.revertToState(snap);

        return results;
    }

    /// @notice Compare pre-cast and post-cast flow results vault-by-vault. A
    ///         "regression" is a vault that passed before the spell and fails
    ///         after; these hard-fail the test. Failures that pre-date the
    ///         spell are logged but tolerated.
    /// @dev    Pre and post arrays index identically because both runs were
    ///         given the same `vaults[]` (`InvestmentFlowExecutor.executeAllFlows`
    ///         writes results in input order).
    function _assertNoFlowRegressions(InvestmentFlowResult[] memory pre, InvestmentFlowResult[] memory post) internal {
        assertEq(pre.length, post.length, "Pre/post flow result length mismatch");

        uint256 depositRegressions;
        uint256 redeemRegressions;

        emit log_string("");
        emit log_string("================================================================");
        emit log_string("     INVESTMENT FLOW DIFF (pre-cast vs post-cast)");
        emit log_string("================================================================");

        for (uint256 i = 0; i < post.length; i++) {
            InvestmentFlowResult memory b = pre[i];
            InvestmentFlowResult memory a = post[i];

            if (b.depositPassed && !a.depositPassed) {
                emit log_string(string.concat("[REGRESSION deposit] ", vm.toString(a.vault), " -> ", a.depositError));
                depositRegressions++;
            } else if (!b.depositPassed && a.depositPassed) {
                emit log_string(string.concat("[IMPROVED deposit]   ", vm.toString(a.vault)));
            } else if (!b.depositPassed && !a.depositPassed) {
                emit log_string(string.concat("[PRE-EXISTING deposit] ", vm.toString(a.vault), " -> ", a.depositError));
            }

            if (b.redeemPassed && !a.redeemPassed) {
                emit log_string(string.concat("[REGRESSION redeem]  ", vm.toString(a.vault), " -> ", a.redeemError));
                redeemRegressions++;
            } else if (!b.redeemPassed && a.redeemPassed) {
                emit log_string(string.concat("[IMPROVED redeem]    ", vm.toString(a.vault)));
            } else if (!b.redeemPassed && !a.redeemPassed) {
                emit log_string(string.concat("[PRE-EXISTING redeem]  ", vm.toString(a.vault), " -> ", a.redeemError));
            }
        }

        emit log_string("================================================================");

        assertEq(depositRegressions, 0, "Spell regressed deposit flows on previously-passing vaults");
        assertEq(redeemRegressions, 0, "Spell regressed redeem flows on previously-passing vaults");
    }

    // ------------------------------------------------------------------
    // GraphQL vault query (mirrors InvestmentFlowForkTest._queryVaults)
    // ------------------------------------------------------------------

    function _queryVaults(GraphQLQuery indexer, uint16 centrifugeId)
        internal
        returns (VaultGraphQLData[] memory vaults)
    {
        string memory centrifugeIdStr = vm.toString(centrifugeId).asJsonString();

        string memory json = indexer.queryGraphQL(
            string.concat(
                "vaults(limit: 1000, where: { centrifugeId: ",
                centrifugeIdStr,
                ", status: Linked }) { totalCount items { id poolId tokenId kind assetAddress asset { decimals symbol } token { pool { managers(where: {isHubManager: true}, limit: 1) { items { address centrifugeId } } } } } }"
            )
        );

        uint256 totalCount = json.readUint(".data.vaults.totalCount");
        if (totalCount == 0) return vaults;

        require(totalCount <= 1000, "Vault count exceeds query limit; implement pagination");

        vaults = new VaultGraphQLData[](totalCount);

        for (uint256 i; i < totalCount; i++) {
            string memory base = ".data.vaults.items";
            vaults[i].vault = json.readAddress(base.asJsonPath(i, "id"));
            vaults[i].poolIdRaw = uint64(json.readUint(base.asJsonPath(i, "poolId")));
            vaults[i].tokenIdRaw = _parseBytes16(json, base.asJsonPath(i, "tokenId"));
            vaults[i].kind = json.readString(base.asJsonPath(i, "kind"));
            vaults[i].assetAddress = json.readAddress(base.asJsonPath(i, "assetAddress"));
            vaults[i].assetDecimals = uint8(json.readUint(base.asJsonPath(i, "asset.decimals")));
            vaults[i].assetSymbol = json.readString(base.asJsonPath(i, "asset.symbol"));

            string memory managersBase = string.concat(base, "[", vm.toString(i), "].token.pool.managers.items");
            try vm.parseJsonAddress(json, string.concat(managersBase, "[0].address")) returns (address mgr) {
                vaults[i].hubManager = mgr;
            } catch {}
            try vm.parseJsonUint(json, string.concat(managersBase, "[0].centrifugeId")) returns (uint256 cid) {
                vaults[i].hubCentrifugeId = uint16(cid);
            } catch {}
        }
    }

    function _parseBytes16(string memory json, string memory path) internal pure returns (bytes16 result) {
        bytes memory rawBytes = json.readBytes(path);
        require(rawBytes.length == 16, "Expected 16 bytes for tokenId");
        for (uint256 i = 0; i < 16; i++) {
            result |= bytes16(rawBytes[i]) >> (i * 8);
        }
    }
}
