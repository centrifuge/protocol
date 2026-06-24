// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {TargetFunctions} from "./TargetFunctions.sol";

import {Test} from "forge-std/Test.sol";

import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

// forge test --match-contract CryticToFoundry -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    // forge test --match-test test_crytic -vvv
    function test_crytic() public {}

    /// === Potential Issues === ///

    /// === Echidna Run 2026-06-22 === ///

    // NOTE: Acknowledged - Issue #10 (Authorization Bypass via Admin Mistake).
    // Same pattern as test_property_authorizationBypass_0; this variant exercises
    // balanceSheet_submitQueuedShares (another isManager(poolId)-gated function).
    // Requires deliberate admin misconfiguration (skipping updateBalanceSheetManager).
    // See .claude/docs/recon/13-acknowledged-risks.md#issue-10
    // Reproducer: echidna/reproducers/6467440627941903344.txt
    // forge test --match-test test_property_authorizationBypass_submitQueuedShares -vvvv
    // function test_property_authorizationBypass_submitQueuedShares() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 0, false, false, false, false);
    //     switch_actor(1);
    //     balanceSheet_submitQueuedShares(0);
    //     property_authorizationBypass();
    // }
}
