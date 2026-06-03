// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {V2CleaningsCast} from "./V2CleaningsCast.sol";
import {
    Validate_PreV2Cleanings,
    Validate_CacheV2Cleanings,
    Validate_PostV2Cleanings
} from "./validators/Validate_V2Cleanings.sol";

import {EnvConfig} from "../../../../script/utils/EnvConfig.s.sol";

import {BaseValidator} from "../utils/validation/BaseValidator.sol";
import {SpellRegressionTest} from "../utils/SpellRegressionTest.sol";

/// @title  V2CleaningsValidatorTest
/// @notice Environment regression test for the V2Cleanings spell. Uses the
///         shared `V2CleaningsCast` helper so the deploy+cast flow is identical
///         to the focused `V2CleaningsSpellTest`. Investment-flow regression is
///         enabled by default because the spell touches share-token wards.
contract V2CleaningsValidatorTest is SpellRegressionTest {
    function _networks() internal pure override returns (string[] memory networks) {
        networks = new string[](3);
        networks[0] = "ethereum";
        networks[1] = "base";
        networks[2] = "arbitrum";
    }

    function _executorName() internal pure override returns (string memory) {
        return "v2cleanings";
    }

    function _castSpell(
        string memory,
        /* network */
        EnvConfig memory config
    )
        internal
        override
    {
        V2CleaningsCast.deployAndCast(config);
    }

    function _preValidators() internal override returns (BaseValidator[] memory validators) {
        validators = new BaseValidator[](1);
        validators[0] = new Validate_PreV2Cleanings();
    }

    function _cacheValidators() internal override returns (BaseValidator[] memory validators) {
        validators = new BaseValidator[](1);
        validators[0] = new Validate_CacheV2Cleanings();
    }

    function _postValidators() internal override returns (BaseValidator[] memory validators) {
        validators = new BaseValidator[](1);
        validators[0] = new Validate_PostV2Cleanings();
    }
}
