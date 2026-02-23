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

    // forge test --match-test test_property_sum_of_shares_received_0 -vvv
    function test_property_sum_of_shares_received_0() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

        spoke_addShareClass(0, 2);

        switch_share_class(0);

        shortcut_deposit_and_claim(0, 0, 1, 1, 0);

        property_sum_of_shares_received();
    }

    // forge test --match-test test_property_authorizationBypass_2 -vvv
    // NOTE: Acknowledged
    // function test_property_authorizationBypass_2() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

    //     switch_actor(1);

    //     balanceSheet_reserve(0, 0);

    //     property_authorizationBypass();
    // }

    // forge test --match-test test_property_price_on_fulfillment_5 -vvv
    // NOTE: Acknowledged - false positive from vault switch desynchronizing investorsGlobals tracking.
    // The fuzzer-generated sequence calls hub_notifyDeposit on vault 1 (sync) which updates
    // investorsGlobals[vault1], then switch_vault(0) changes context so the property reads
    // investorsGlobals[vault0] which was never initialized. Fixed by adding vault-change guard
    // to property_price_on_fulfillment (matching property_price_on_redeem).
    // function test_property_price_on_fulfillment_5() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

    //     shortcut_deposit_queue_cancel(0, 0, 1, 1, 1, 0);

    //     spoke_deployVault(false);

    //     hub_notifyDeposit(1);

    //     switch_vault(0);

    //     property_price_on_fulfillment();
    // }

    /// === Echidna Run 2026-02-17 (30min local) === ///

    // forge test --match-test test_doomsday_zeroPrice_noPanics_6 -vvvv
    // Reproducer: echidna/reproducers/5176345492421397535.txt (October)
    function test_doomsday_zeroPrice_noPanics_6() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        doomsday_zeroPrice_noPanics();
    }

    // Removed: test_doomsday_zeroPrice_noPanics_7 — false positive from unclamped setValuation(0xdeadbeef)

    // NOTE: Acknowledged — async vault rounding dust (property scope limitation)
    // deposit(maxDeposit) leaves maxMint > 0 due to shares↔assets round-trip precision loss.
    // Protocol recommends mint(maxMint) instead. See: .claude/docs/recon/13-acknowledged-risks.md
    // Reproducer: echidna/reproducers/5155428733752326224.txt
    // function test_vault_maxDeposit_8() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 16848, false, false, true, false);
    //     shortcut_deposit_queue_cancel(0, 0, 952217297734242722496, 2, 3, 904772406170181);
    //     hub_notifyDeposit(1);
    //     vault_maxDeposit(0, 0, 0);
    // }

    // forge test --match-test test_property_authorizationBypass_9 -vvvv
    // NOTE: Acknowledged - Issue #10 (admin operational mistake)
    // Reproducer: echidna/reproducers/6835817918927048585.txt
    // function test_property_authorizationBypass_9() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

    //     switch_actor(1);

    //     balanceSheet_overridePricePoolPerAsset(0);

    //     property_authorizationBypass();
    // }

    /// === Categorized Issues === ///

    // forge test --match-test test_property_sum_of_pending_redeem_request_0 -vvv
    // NOTE: Acknowledged - property scope limitation (multi-vault scId ghost variable mismatch)
    // sumOfClaimedRedemptions[asset] is GLOBAL but userRedemptionsProcessed[scId] is PER share class.
    // Adding a new share class + vault after redemptions on the original breaks the cross-reference.
    // See: .claude/docs/recon/13-acknowledged-risks.md
    // function test_property_sum_of_pending_redeem_request_0() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

    //     shortcut_deposit_sync(414483, 1);

    //     shortcut_redeem_and_claim_clamped(710866642581474852887358001780444458098994817, 5, 0);

    //     spoke_addShareClass(0, 2);

    //     spoke_deployVault_clamped();

    //     property_sum_of_pending_redeem_request();
    // }

    // forge test --match-test test_property_authorizationBypass_1 -vvv
    // NOTE: Acknowledged - Issue #10 variant (admin operational mistake via balanceSheet_unreserve)
    // function test_property_authorizationBypass_1() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

    //     switch_actor(1);

    //     balanceSheet_unreserve(0, 0);

    //     property_authorizationBypass();
    // }

    // forge test --match-test test_doomsday_zeroPrice_noPanics_2 -vvv
    function test_doomsday_zeroPrice_noPanics_2() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 1);

        shortcut_withdraw_and_claim_clamped(3485682314928408474477641317869550809542076924060871, 1001654, 0);

        doomsday_zeroPrice_noPanics();
    }

    // forge test --match-test test_vault_maxMint_3 -vvv
    function test_vault_maxMint_3() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_mint_sync(1, 1);

        vault_maxMint(0, 0, 1000016798233);
    }

    // forge test --match-test test_vault_maxDeposit_4 -vvv
    function test_vault_maxDeposit_4() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 1);

        vault_maxDeposit(0, 0, 2);
    }
}
