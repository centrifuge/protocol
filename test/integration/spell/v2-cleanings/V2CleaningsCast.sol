// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Root} from "../../../../src/admin/Root.sol";

import {EnvConfig} from "../../../../script/utils/EnvConfig.s.sol";

import {Vm} from "forge-std/Vm.sol";

import {
    V2CleaningsSpell,
    ROOT_V2,
    ROOT_V3,
    ETHEREUM_CHAIN_ID,
    BASE_CHAIN_ID,
    ARBITRUM_CHAIN_ID
} from "../../../../src/spell/V2CleaningsSpell.sol";

/// @title  V2CleaningsCast
/// @notice Shared cast preamble for the V2Cleanings spell. Consumed by BOTH the
///         focused spell test (`V2Cleanings.t.sol`) and the environment
///         regression test (`v2-cleanings/V2CleaningsValidatorTest.t.sol`) so the
///         deploy + two-guardian rely + `cast()` flow lives in one place and the
///         two tests can never drift.
library V2CleaningsCast {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Guardians holding rely rights over the V3 and V2 roots on mainnet.
    address internal constant PROTOCOL_GUARDIAN_V3_1 = 0xCEb7eD5d5B3bAD3088f6A1697738B60d829635c6;
    address internal constant GUARDIAN_V2_ETHEREUM_OR_ARBITRUM = 0x09ab10a9c3E6Eac1d18270a2322B6113F4C7f5E8;
    address internal constant GUARDIAN_V2_BASE = 0x427A1ce127b1775e4Cbd4F58ad468B9F832eA7e9;

    /// @dev The spell hardcodes ROOT_V3 to the ETH/BASE/ARB V3 root; on those
    ///      chains the env's root must match or the spell's tail-end
    ///      relyContract/deny calls would brick.
    function deployAndCast(EnvConfig memory config) internal returns (V2CleaningsSpell spell) {
        Root rootV3 = Root(config.contracts.root);

        if (block.chainid == ETHEREUM_CHAIN_ID || block.chainid == BASE_CHAIN_ID || block.chainid == ARBITRUM_CHAIN_ID)
        {
            require(address(ROOT_V3) == address(rootV3), "V2CleaningsCast: ROOT_V3 mismatch");
        }

        spell = new V2CleaningsSpell();

        vm.prank(PROTOCOL_GUARDIAN_V3_1);
        rootV3.rely(address(spell)); // Ideally through guardian.scheduleRely()

        if (address(ROOT_V2).code.length > 0) {
            vm.prank(block.chainid == BASE_CHAIN_ID ? GUARDIAN_V2_BASE : GUARDIAN_V2_ETHEREUM_OR_ARBITRUM);
            ROOT_V2.rely(address(spell)); // Ideally through guardian.scheduleRely()
        }

        spell.cast();
    }
}
