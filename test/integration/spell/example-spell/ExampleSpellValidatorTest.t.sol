// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Validate_PreExample, Validate_CacheExample, Validate_PostExample} from "./validators/Validate_Example.sol";

import {EnvConfig} from "../../../../script/utils/EnvConfig.s.sol";

import {BaseValidator} from "../utils/validation/BaseValidator.sol";
import {SpellRegressionTest} from "../utils/SpellRegressionTest.sol";

/// @title  ExampleSpellValidatorTest
/// @notice Copy-paste template AND end-to-end smoke test for the
///         `SpellRegressionTest` environment-regression harness. It wires every
///         hook (the default 8 structural validators, the example
///         pre/cache/post validators, and the on-by-default investment-flow
///         diff) and runs the full pre-cast -> cast -> post-cast pipeline.
///
/// @dev    `_castSpell` is intentionally a no-op here: with nothing cast, the
///         pre/post state is identical, so the structural diff and the flow diff
///         both report zero regressions. That proves the orchestration wiring
///         end-to-end without a real spell. A real spell replaces `_castSpell`
///         with its deploy + guardian relies + `cast()` (via a shared `<Spell>Cast`
///         library) and swaps the example validators for spell-specific ones.
///         See `test/integration/spell/utils/validation/README.md`.
contract ExampleSpellValidatorTest is SpellRegressionTest {
    function _networks() internal pure override returns (string[] memory networks) {
        networks = new string[](1);
        networks[0] = "ethereum";
    }

    function _executorName() internal pure override returns (string memory) {
        return "example-spell";
    }

    /// @dev No-op: a real spell deploys + relies + casts here, e.g.
    ///      `MySpellCast.deployAndCast(config);`.
    function _castSpell(
        string memory,
        /* network */
        EnvConfig memory /* config */
    )
        internal
        override
    {}

    function _preValidators() internal override returns (BaseValidator[] memory validators) {
        validators = new BaseValidator[](1);
        validators[0] = new Validate_PreExample();
    }

    function _cacheValidators() internal override returns (BaseValidator[] memory validators) {
        validators = new BaseValidator[](1);
        validators[0] = new Validate_CacheExample();
    }

    function _postValidators() internal override returns (BaseValidator[] memory validators) {
        validators = new BaseValidator[](1);
        validators[0] = new Validate_PostExample();
    }

    // Investment-flow regression is on by default. A spell that does not touch
    // vaults (e.g. an adapter rewiring) opts out:
    //
    //   function _runInvestmentFlowsDiff() internal pure override returns (bool) {
    //       return false;
    //   }
}
