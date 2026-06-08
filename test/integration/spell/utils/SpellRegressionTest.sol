// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {FlowRegression} from "./FlowRegression.sol";
import {BaseValidator} from "./validation/BaseValidator.sol";
import {ValidationExecutor} from "./validation/ValidationExecutor.sol";
import {InvestmentFlowResult, VaultGraphQLData} from "./validation/InvestmentFlowExecutor.sol";

import {Env, EnvConfig} from "../../../../script/utils/EnvConfig.s.sol";
import {GraphQLQuery} from "../../../../script/utils/GraphQLQuery.s.sol";

import {Validate_Vaults} from "../../fork/validators/Validate_Vaults.sol";
import {Validate_Endorsements} from "../../fork/validators/Validate_Endorsements.sol";
import {Validate_ContractWards} from "../../fork/validators/Validate_ContractWards.sol";
import {Validate_GuardianSafes} from "../../fork/validators/Validate_GuardianSafes.sol";
import {Validate_HookPoolEscrow} from "../../fork/validators/Validate_HookPoolEscrow.sol";
import {Validate_RootPermissions} from "../../fork/validators/Validate_RootPermissions.sol";
import {Validate_FileConfigurations} from "../../fork/validators/Validate_FileConfigurations.sol";
import {Validate_AdapterConfigurations} from "../../fork/validators/Validate_AdapterConfigurations.sol";

/// @title  SpellRegressionTest
/// @notice Abstract base for the *environment regression* layer of a spell test.
///         Scoped strictly to "did the spell break the live environment?" — the
///         focused, spell-specific correctness proof lives in the spell's own
///         `Test`-derived test, not here.
///
/// @dev    Per network (`_networks()`), the driver runs three post-cast layers —
///         structural validator diff, spell-specific pre/cache/post validators,
///         and investment-flow regression — all tolerant of pre-existing live
///         errors and failing only on regressions the spell itself introduced.
///         Architecture, author guide, and the legacy-codegen (stack-too-deep)
///         constraints behind the internals are documented in
///         `test/integration/spell/utils/validation/README.md`.
abstract contract SpellRegressionTest is FlowRegression {
    /// @dev One executor reused across the cast: it captures the structural
    ///      baseline (in its own storage) pre-cast and diffs against it post-cast,
    ///      so the baseline never crosses an ABI boundary nor touches disk.
    ValidationExecutor private _exec;
    /// @dev abi.encode(InvestmentFlowResult[]) pre-cast flow results, carried across the cast.
    bytes private _preFlowsBlob;

    // ------------------------------------------------------------------
    // Virtual hooks (children override)
    // ------------------------------------------------------------------

    /// @notice Networks to run the regression against (e.g. ["ethereum", "base"]).
    function _networks() internal view virtual returns (string[] memory);

    /// @notice Cache namespace, shared by the pre/post executors (e.g. "myspell").
    function _executorName() internal pure virtual returns (string memory);

    /// @notice Deploy the spell, schedule any required relies, and cast it.
    function _castSpell(string memory network, EnvConfig memory config) internal virtual;

    function _structuralValidators() internal virtual returns (BaseValidator[] memory validators) {
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

    function _preValidators() internal virtual returns (BaseValidator[] memory) {
        return new BaseValidator[](0);
    }

    function _cacheValidators() internal virtual returns (BaseValidator[] memory) {
        return new BaseValidator[](0);
    }

    function _postValidators() internal virtual returns (BaseValidator[] memory) {
        return new BaseValidator[](0);
    }

    function _runInvestmentFlowsDiff() internal pure virtual returns (bool) {
        return true;
    }

    // ------------------------------------------------------------------
    // Entry point
    // ------------------------------------------------------------------

    /// @notice Runs the regression suite across every network in `_networks()`.
    ///         Each network is isolated via an external self-call: a failure is
    ///         recorded and the remaining networks still run, then the test
    ///         fails at the end if any network failed.
    function test_spellRegression() external virtual {
        string[] memory networks = _networks();
        uint256 failures;

        for (uint256 i = 0; i < networks.length; i++) {
            try this.runSpellRegressionCase(networks[i]) {
                emit log_string(string.concat("[NETWORK OK]     ", networks[i]));
            } catch Error(string memory reason) {
                failures++;
                emit log_string(string.concat("[NETWORK FAILED] ", networks[i], " -> ", reason));
            } catch {
                failures++;
                emit log_string(string.concat("[NETWORK FAILED] ", networks[i]));
            }
        }

        assertEq(failures, 0, "Spell regression failed on at least one network");
    }

    /// @dev External wrapper so each network's run can be try/catch-isolated.
    ///      Not a test entry point (no `test` prefix); self-call only.
    function runSpellRegressionCase(string memory network) external {
        require(msg.sender == address(this), "SpellRegressionTest: self-call only");
        _runCase(network);
    }

    // ------------------------------------------------------------------
    // Per-network driver
    // ------------------------------------------------------------------

    function _runCase(string memory network) internal {
        EnvConfig memory config = Env.load(network);
        vm.createSelectFork(config.network.rpcUrl());

        VaultGraphQLData[] memory vaults = _maybeQueryVaults(config);

        _capturePreCast(network, config, vaults);
        _castSpell(network, config);
        _verifyPostCast(config, vaults);
    }

    function _maybeQueryVaults(EnvConfig memory config) internal returns (VaultGraphQLData[] memory) {
        if (!_runInvestmentFlowsDiff()) return new VaultGraphQLData[](0);
        return _queryVaults(new GraphQLQuery(config.network.graphQLApi()), config.network.centrifugeId);
    }

    /// @dev Capture every pre-cast artifact the post-cast verification needs:
    ///      spell-specific PRE/CACHE state, the structural baseline (in the
    ///      executor's storage), and the flow baseline. The executor is stored in
    ///      `_exec` and reused post-cast so the baseline survives without crossing
    ///      an ABI boundary or touching disk.
    function _capturePreCast(string memory network, EnvConfig memory config, VaultGraphQLData[] memory vaults)
        internal
    {
        _exec = new ValidationExecutor(network, _executorName());

        // Spell-specific PRE (soft) + CACHE (cleans dir, writes files surviving the cast).
        _exec.runPreValidation(_preValidators(), false);
        _exec.runCacheValidation(_cacheValidators());

        // Structural baseline stored in `_exec`. NOT snapshot-wrapped: the
        // validators are read-only, and a snapshot revert would also revert the
        // executor's baseline storage write (it is EVM state, unlike a file).
        _exec.captureErrorBaseline(_structuralValidators());

        if (vaults.length > 0) {
            _preFlowsBlob = abi.encode(_snapshotFlows(config, vaults));
        }
    }

    /// @dev Run the three post-cast verification layers. Reuses `_exec` so the
    ///      structural diff reads the baseline it captured pre-cast and the POST
    ///      validators read what the CACHE validators wrote. Fresh validator
    ///      instances are passed (the `executed` guard blocks reuse).
    function _verifyPostCast(EnvConfig memory config, VaultGraphQLData[] memory vaults) internal {
        // Layer 1: structural diff against the pre-cast baseline (in `_exec` storage).
        _exec.runValidationDiffPost(_structuralValidators());

        // Layer 2: spell-specific POST via the migration-aware overload (no
        // `latest`). This base is scoped to spells that deploy no new core
        // contracts, so POST validators read cache + on-chain state only; a
        // validator that reads `ctx.latest` gets the zero struct and fails loudly.
        _exec.runPostValidation(_postValidators());

        // Layer 3: investment-flow regression diff.
        if (vaults.length > 0) {
            _assertNoFlowRegressions(
                abi.decode(_preFlowsBlob, (InvestmentFlowResult[])), _snapshotFlows(config, vaults)
            );
        }
    }
}
