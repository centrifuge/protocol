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

    /// === Echidna Run 2026-02-23 (local) === ///

    // forge test --match-test test_vault_maxMint_10 -vvv
    // Reproducer: echidna/reproducers/8135390276025078258.txt
    // Sync vault: deploy → updatePrice → updateMember → deposit(1) → maxMint
    function test_vault_maxMint_10() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        spoke_updatePricePoolPerShare(1, 1);

        spoke_updateMember(1527537386);

        vault_deposit(1);

        vault_maxMint(0, 0, 0);
    }

    // forge test --match-test test_vault_maxDeposit_11 -vvv
    // Reproducer: echidna/reproducers/2368209461496406051.txt
    // Sync vault: deploy → mint_sync(1,1) → maxDeposit — same conversion cap as test_vault_maxDeposit_4
    function test_vault_maxDeposit_11() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_mint_sync(1, 1);

        vault_maxDeposit(0, 0, 0);
    }

    // forge test --match-test test_vault_maxDeposit_12 -vvvv
    // Reproducer: echidna/reproducers/9143144158582049584.txt
    // Async vault: deploy → deposit_queue_cancel → hub_notifyDeposit → maxDeposit
    function test_vault_maxDeposit_12() public {
        shortcut_deployNewTokenPoolAndShare(
            58, 3725620682615936983603445291889200717745835437975087272030550155022530317057, false, true, true, false
        );

        balanceSheet_submitQueuedShares(2986799447496935121812250855886100387);

        switch_actor(270);

        shortcut_deposit_queue_cancel(
            4662387785827488946,
            238,
            1577203754821733349138040342627210308022144620756482427698354874963446062794,
            326587208,
            53058427172526584712949480,
            124879742162045852864037660195030038286
        );

        switch_share_class(7);

        hub_setPriceNonZero_clamped(7752043034099767843566551880075692922312402738550953727126425389436347475576);

        vault_cancelDepositRequest();

        hub_notifyDeposit(9648631);

        vault_maxDeposit(72301513, 1624510, 48);
    }

    // NOTE: Stale — syncManager_setValuation handler is commented out in current codebase
    // Reproducer: echidna/reproducers/315514015980947277.txt
    // function test_doomsday_zeroPrice_noPanics_13() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);
    //     syncManager_setValuation(false);
    //     doomsday_zeroPrice_noPanics();
    // }

    // NOTE: Stale — erc7540_5 is now internal, exposed via vault_5 with address clamping
    // Reproducer: echidna/reproducers/6989870935168821446.txt
    // function test_erc7540_5_14() public {
    //     erc7540_5(address(0x13aa49bAc059d709dd0a18D6bb63290076a702D7));
    // }

    // NOTE: vault_maxMint complex multi-actor (80+ calls) — too long for CryticToFoundry
    // Likely same conversion cap issue as test_vault_maxMint_10
    // Reproducer: echidna/reproducers/4242091224602848012.txt

    // NOTE: vault_maxDeposit complex multi-actor (100+ calls) — too long for CryticToFoundry
    // Likely same conversion cap or async rounding issue
    // Reproducer: echidna/reproducers/4772574167540358405.txt
}
