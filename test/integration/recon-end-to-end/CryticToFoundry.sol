// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {MockERC20} from "@recon/MockERC20.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {AccountId, AccountType} from "src/hub/interfaces/IHub.sol";
import {PoolEscrow} from "src/spoke/Escrow.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {CryticSanity} from "./CryticSanity.sol";

// forge test --match-contract CryticToFoundry --match-path test/integration/recon-end-to-end/CryticToFoundry.sol -vv
contract CryticToFoundry is CryticSanity {
    function setUp() override public {
        setup();
    }

    /// === Potential Issues === ///
    // forge test --match-test test_asyncVault_maxRedeem_8 -vvv 
    // NOTE: shows that user maintains an extra 1 wei in maxRedeem after a redemption
    // this is only a precondition, optimization property will determine what the max difference amount can be 
    function test_asyncVault_maxRedeem_8() public {

        shortcut_deployNewTokenPoolAndShare(16,29654276389875203551777999997167602027943,true,false,true);

        shortcut_deposit_and_claim(0,1,143,1,0);

        shortcut_redeem_and_claim_clamped(44055836141804467353088311715299154505223682107,1,60194726908356682833407755266714281307);

        asyncVault_maxRedeem(0,0,0);

    }

    // forge test --match-test test_property_totalAssets_solvency_13 -vvv 
    // NOTE: indicates a discrepancy between the totalAssets and actualAssets, root cause TBD
    // NOTE: this is only a precondition, optimize_totalAssets_solvency is used to determine the maximum possible difference between totalAssets and actualAssets
    function test_property_totalAssets_solvency_13() public {

        shortcut_deployNewTokenPoolAndShare(6,1,true,false,true);

        shortcut_deposit_and_claim(0,1,16,1,0);

        shortcut_request_deposit(1126650826843,1,0,0);

        property_totalAssets_solvency();

    }

    // forge test --match-test test_optimize_totalAssets_solvency_0 -vvv 
    // NOTE: optimization test for the above, achieves a max difference of 340282366920938463463374607431768211452
    // probably need to clean up this repro because it seems like shrinking didn't work
    // function test_optimize_totalAssets_solvency_0() public {

    //     // Max value: 340282366920938463463374607431768211452;

    //     vm.roll(block.number + 22699);
    //     vm.warp(block.timestamp + 166184);
    //     shortcut_deposit_and_cancel(2105723079186344767,695,26012068170781306951180452649320697174728931058792834910336741884350144630897,1524785991,13196291235116277773595871680055955912065833494957093333304083642154464648095);

    //     vm.roll(block.number + 55640);
    //     vm.warp(block.timestamp + 2647);
    //     property_escrow_share_balance();

    //     vm.roll(block.number + 33357);
    //     vm.warp(block.timestamp + 404997);
    //     vault_withdraw(46248472530333771835509579570158122583740335379706396429291089094393356581377,115792089237316195423570985008687907853269984665640564039457584007913129639935);

    //     vm.roll(block.number + 286);
    //     vm.warp(block.timestamp + 463587);
    //     asyncVault_9_mint(0x7bb886E6fCe69554E427e4DCC5CD8EAf5A3C9dd0);

    //     vm.roll(block.number + 40376);
    //     vm.warp(block.timestamp + 440097);
    //     hub_approveRedeems(4294967295,153727342273849683920146908601078066217);

    //     vm.roll(block.number + 1349);
    //     vm.warp(block.timestamp + 411553);
    //     switch_share_token(1524785993);

    //     vm.roll(block.number + 1123);
    //     vm.warp(block.timestamp + 435);
    //     add_new_asset(33);

    //     vm.roll(block.number + 34272);
    //     vm.warp(block.timestamp + 146);
    //     doomsday_redeem(1457524644);

    //     vm.roll(block.number + 620);
    //     vm.warp(block.timestamp + 289607);
    //     property_sum_of_balances();

    //     vm.roll(block.number + 3922);
    //     vm.warp(block.timestamp + 332369);
    //     shortcut_deposit_cancel_claim(513,872495699263271649264605665497717157,4369999,152922428216360986173068129692004835250,4369999);

    //     vm.roll(block.number + 561);
    //     vm.warp(block.timestamp + 73040);
    //     hub_notifyPool(37562);

    //     vm.roll(block.number + 22909);
    //     vm.warp(block.timestamp + 342);
    //     property_escrow_balance();

    //     vm.roll(block.number + 11942);
    //     vm.warp(block.timestamp + 305);
    //     property_accounting_and_holdings_soundness();

    //     vm.roll(block.number + 981);
    //     vm.warp(block.timestamp + 225906);
    //     token_transfer(0x00000000000000000000000000000000FFFFfFFF,23043005865450709157593441307337850662549715024538113461058023079301907090750);

    //     vm.roll(block.number + 30042);
    //     vm.warp(block.timestamp + 45142);
    //     hub_triggerIssueShares_clamped(292860634175216377044974284442252023582);

    //     vm.roll(block.number + 54155);
    //     vm.warp(block.timestamp + 520126);
    //     doomsday_withdraw(1524785992);

    //     vm.roll(block.number + 739);
    //     vm.warp(block.timestamp + 797);
    //     property_price_on_redeem();

    //     vm.roll(block.number + 829);
    //     vm.warp(block.timestamp + 157);
    //     property_accounting_and_holdings_soundness();

    //     vm.roll(block.number + 58783);
    //     vm.warp(block.timestamp + 548);
    //     vault_cancelRedeemRequest();

    //     vm.roll(block.number + 866);
    //     vm.warp(block.timestamp + 277232);
    //     toggle_GainAccount(1729781393);

    //     vm.roll(block.number + 711);
    //     vm.warp(block.timestamp + 800);
    //     property_sum_of_assets_received_on_claim_cancel_deposit_request();

    //     vm.roll(block.number + 951);
    //     vm.warp(block.timestamp + 143);
    //     vault_withdraw(4370000,4370001);

    //     vm.roll(block.number + 42650);
    //     vm.warp(block.timestamp + 351848);
    //     shortcut_deployNewTokenPoolAndShare(101,8265840767236642207266184662003188253997744328901981078219120830022826733465,true,true,false);

    //     vm.roll(block.number + 312);
    //     vm.warp(block.timestamp + 800);
    //     property_cancelled_soundness();

    //     vm.roll(block.number + 2512);
    //     vm.warp(block.timestamp + 420078);
    //     vault_requestDeposit_clamped(33830692711947617775971208311954888792545382842435610690950187154008816806922,1524785991);

    //     vm.roll(block.number + 1255);
    //     vm.warp(block.timestamp + 244);
    //     hub_multicall_clamped();

    //     vm.roll(block.number + 42247);
    //     vm.warp(block.timestamp + 343258);
    //     hub_approveRedeems_clamped(3975750824,1524785993);

    //     vm.roll(block.number + 689);
    //     vm.warp(block.timestamp + 424);
    //     hub_setQueue(14402,false);

    //     vm.roll(block.number + 778);
    //     vm.warp(block.timestamp + 478);
    //     doomsday_mint(31519228843119876520980925320601367686226872728170293384824396078454651103599);

    //     vm.roll(block.number + 2734);
    //     vm.warp(block.timestamp + 187);
    //     restrictedTransfers_freeze();

    //     vm.roll(block.number + 285);
    //     vm.warp(block.timestamp + 61);
    //     hub_triggerSubmitQueuedAssets(12461614315941195453357724755302660017);

    //     vm.roll(block.number + 3);
    //     vm.warp(block.timestamp + 30);
    //     spoke_registerAsset(0xE8F1B392844009F24effeA587932Ee06c049b434,16060024066238306762108704779051709181052769654158773406672896171390510505927);

    //     vm.roll(block.number + 30178);
    //     vm.warp(block.timestamp + 522178);
    //     asyncVault_5(0x886D6d1eB8D415b00052828CD6d5B321f072073d);

    //     vm.roll(block.number + 20954);
    //     vm.warp(block.timestamp + 490331);
    //     vault_cancelRedeemRequest();

    //     vm.roll(block.number + 29708);
    //     vm.warp(block.timestamp + 473);
    //     hub_triggerSubmitQueuedAssets(340282366920938463463374607431768211455);

    //     vm.roll(block.number + 7043);
    //     vm.warp(block.timestamp + 12300);
    //     property_sum_of_assets_received_on_claim_cancel_deposit_request();

    //     vm.roll(block.number + 26135);
    //     vm.warp(block.timestamp + 33375);
    //     toggle_MaxClaims(2212471255);

    //     vm.roll(block.number + 46422);
    //     vm.warp(block.timestamp + 289103);
    //     doomsday_impliedPricePerShare_never_changes_after_user_operation();

    //     vm.roll(block.number + 23);
    //     vm.warp(block.timestamp + 207);
    //     property_loss_soundness();

    //     vm.roll(block.number + 30304);
    //     vm.warp(block.timestamp + 184813);
    //     shortcut_deposit_sync(4369999,4369999);

    //     vm.roll(block.number + 812);
    //     vm.warp(block.timestamp + 179436);
    //     asset_mint(0x00000000000000000000000000000000FFFFfFFF,254654649788938682481275555495699994651);

    //     vm.roll(block.number + 739);
    //     vm.warp(block.timestamp + 80780);
    //     doomsday_mint(35272759136203263694042036505638400071145637186109866732714196025021428065682);

    //     vm.roll(block.number + 327);
    //     vm.warp(block.timestamp + 578);
    //     asset_mint(0x00000000000000000000000000000001fffffffE,281161934365195339739408089670334950655);

    //     vm.roll(block.number + 279);
    //     vm.warp(block.timestamp + 184359);
    //     hub_updateRestriction(865,hex"12");

    //     vm.roll(block.number + 24311);
    //     vm.warp(block.timestamp + 380);
    //     hub_notifyDeposit(635);

    //     vm.roll(block.number + 916);
    //     vm.warp(block.timestamp + 55830);
    //     restrictedTransfers_unfreeze();

    //     vm.roll(block.number + 1156);
    //     vm.warp(block.timestamp + 456);
    //     restrictedTransfers_updateMember(0x00000000000000000000000000000000FFFFfFFF,542);

    //     vm.roll(block.number + 60);
    //     vm.warp(block.timestamp + 661);
    //     hub_createHolding(IValuation(0x3dc1Bfbf03baa57682B2962a768E5A092E79ebea),4369999,0,1036150518,1723584528);

    //     vm.roll(block.number + 391);
    //     vm.warp(block.timestamp + 388);
    //     toggle_IsIncrease();

    //     vm.roll(block.number + 19835);
    //     vm.warp(block.timestamp + 1000);
    //     hub_updatePricePerShare(340282366920938463463374607431768211452);

    //     vm.roll(block.number + 23275);
    //     vm.warp(block.timestamp + 157736);
    //     asyncVault_6_withdraw(0x515af1367358c03c369854273E25598C6e573568,138);

    //     vm.roll(block.number + 821);
    //     vm.warp(block.timestamp + 273146);
    //     switch_actor(1524785991);

    //     vm.roll(block.number + 53152);
    //     vm.warp(block.timestamp + 603);
    //     property_sum_of_received_leq_fulfilled_inductive();

    //     vm.roll(block.number + 327);
    //     vm.warp(block.timestamp + 89);
    //     shortcut_claim_redemption(57122964084955903830176882492714390846414203471147414667251301014803947457350,1524785991);

    //     vm.roll(block.number + 523);
    //     vm.warp(block.timestamp + 128);
    //     vault_claimCancelDepositRequest(104741788980732935892112306713354232661436124603589435982873835718810611756887);

    //     vm.roll(block.number + 14138);
    //     vm.warp(block.timestamp + 195);
    //     hub_notifySharePrice_clamped();

    // }

    // forge test --match-test test_property_total_issuance_soundness_4 -vvv 
    // NOTE: should be fixed after pulling latest changes
    function test_property_total_issuance_soundness_4() public {

        shortcut_deployNewTokenPoolAndShare(3,1819561425533136599214985244969524260076429502780179402746880274575333,true,false,true);

        shortcut_deposit_and_claim(0,34,1,125,913239);

        hub_setQueue(0,true);

        shortcut_cancel_redeem_immediately_issue_and_revoke_clamped(1706619885034195991023004355069399157732325172077980,0,309819812686861817429624422743129768606034282271654);

        property_total_issuance_soundness();

    }

    // forge test --match-test test_property_accounting_and_holdings_soundness_5 -vvv 
    // NOTE: should be fixed after pulling latest changes, issue with overwriting the current holding
    function test_property_accounting_and_holdings_soundness_5() public {

        shortcut_deployNewTokenPoolAndShare(2,577772082,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        spoke_addShareClass(hex"12",2,0x0000000000000000000000000000000000000000);

        // this creates a new holding which gets queried by the property but it's overwriting existing accounts so incorrectly calculates accountValue
        hub_createHolding_clamped(false,0,0,0,0);

        spoke_deployVault(false);

        property_accounting_and_holdings_soundness();

    }

    // forge test --match-test test_shortcut_deposit_and_claim_1 -vvv 
    // NOTE: need to understand root cause, seems like a high NAV with low approval causes totalIssuance to not increase
    function test_shortcut_deposit_and_claim_1() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,true);

        shortcut_deposit_and_claim(6727958434,4371,1,228874694935815088166371182178478,0);

    }

    // forge test --match-test test_shortcut_deposit_queue_cancel_2 -vvv 
    // NOTE: breaks same property as test_shortcut_deposit_and_claim_1
    function test_shortcut_deposit_queue_cancel_2() public {

        shortcut_deployNewTokenPoolAndShare(2,13045993568939965054912701272819626693644111596468185488039780186690,true,false,true);

        shortcut_request_deposit(0,1,1,4671313240128511018167522711707051906224546157581869372783443067);

        shortcut_deposit_queue_cancel(334,1,7487057153920528824349177633578051140907494203171406115406,1,1775677109257105933,0);

    }


    /// === Categorized Issues === ///
    // forge test --match-test test_property_escrow_share_balance_8 -vvv 
    // NOTE: looks like an issue with ghost tracking
    function test_property_escrow_share_balance_8() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,true);

        shortcut_deposit_and_claim(0,4,1,25,0);

        shortcut_queue_redemption(1,0,0);

        property_escrow_share_balance();

    }

    // forge test --match-test test_property_sum_of_possible_account_balances_leq_escrow_13 -vvv 
    // NOTE: looks like a property implementation issue 
    function test_property_sum_of_possible_account_balances_leq_escrow_13() public {

        shortcut_deployNewTokenPoolAndShare(7,1,true,false,false);

        shortcut_mint_sync(0,100012070407234780089322828896);

        property_sum_of_possible_account_balances_leq_escrow();

    }

    // forge test --match-test test_property_actor_pending_and_queued_redemptions_15 -vvv 
    // NOTE: looks like an issue with ghost tracking
    function test_property_actor_pending_and_queued_redemptions_15() public {

        shortcut_deployNewTokenPoolAndShare(2,26110280501627174417963496637225013,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_queue_redemption(1,0,0);

        vault_requestRedeem(1,0);

        hub_notifyRedeem(1);

        property_actor_pending_and_queued_redemptions();

    }

    // forge test --match-test test_property_price_on_redeem_16 -vvv 
    // NOTE: looks like an issue with updating globals
    function test_property_price_on_redeem_16() public {

        shortcut_deployNewTokenPoolAndShare(2,2023043212183937121117125365820931693276147716,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_queue_redemption(1,1004036701446375220,5254288375605742773881224755342121000960484163);

        spoke_deployVault_clamped();

        hub_notifyRedeem(1);

        switch_vault(0);

        property_price_on_redeem();
    }

    // forge test --match-test test_property_sum_of_minted_equals_total_supply_1 -vvv 
    // NOTE: issue with shrinking, will need to do another run to determine the cause
    // function test_property_sum_of_minted_equals_total_supply_1() public {

    //     vm.warp(block.timestamp + 156190);

    //     vm.roll(block.number + 50499);

    //     vm.roll(block.number + 55117);
    //     vm.warp(block.timestamp + 588255);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     property_total_issuance_decreased_after_approve_redeems_and_revoke_shares();

    //     vm.warp(block.timestamp + 1715223);

    //     vm.roll(block.number + 189513);

    //     vm.roll(block.number + 38100);
    //     vm.warp(block.timestamp + 405856);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     restrictedTransfers_unfreeze(0x00000000000000000000000000000002fFffFffD);

    //     vm.roll(block.number + 54809);
    //     vm.warp(block.timestamp + 404997);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     canary_doesShareGetDeployed();

    //     vm.warp(block.timestamp + 463587);

    //     vm.roll(block.number + 24311);

    //     vm.roll(block.number + 42229);
    //     vm.warp(block.timestamp + 112444);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     property_total_issuance_increased_after_approve_deposits_and_issue_shares();

    //     vm.warp(block.timestamp + 33271);

    //     vm.roll(block.number + 561);

    //     vm.roll(block.number + 5237);
    //     vm.warp(block.timestamp + 10);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     toggle_EquityAccount(2127288528);

    //     vm.warp(block.timestamp + 1841106);

    //     vm.roll(block.number + 182077);

    //     vm.roll(block.number + 30256);
    //     vm.warp(block.timestamp + 207289);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     shortcut_deployNewTokenPoolAndShare(146,44162503087693492637048630226507605038248149277142374270796472314127281150497,true,true,true);

    //     vm.warp(block.timestamp + 303345);

    //     vm.roll(block.number + 37067);

    //     vm.roll(block.number + 12053);
    //     vm.warp(block.timestamp + 739);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     doomsday_accountValue_differential(57518505210151000312114314719602460973,1524785992);

    //     vm.warp(block.timestamp + 812151);

    //     vm.roll(block.number + 112868);

    //     vm.roll(block.number + 53451);
    //     vm.warp(block.timestamp + 628);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     shortcut_deposit_and_claim(1004,4370001,1524785993,625,1524785991);

    //     vm.roll(block.number + 1123);
    //     vm.warp(block.timestamp + 590978);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     property_sum_of_shares_received();

    //     vm.warp(block.timestamp + 447588);

    //     vm.roll(block.number + 1362);

    //     vm.roll(block.number + 59983);
    //     vm.warp(block.timestamp + 332369);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     property_gain_soundness();

    //     vm.warp(block.timestamp + 350272);

    //     vm.roll(block.number + 58157);

    //     vm.roll(block.number + 2512);
    //     vm.warp(block.timestamp + 401699);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     balanceSheet_resetPricePoolPerAsset();

    //     vm.warp(block.timestamp + 1915172);

    //     vm.roll(block.number + 93839);

    //     vm.roll(block.number + 19933);
    //     vm.warp(block.timestamp + 259);
    //     vm.prank(0x0000000000000000000000000000000000020000);
    //     asset_approve(0x0000000000000000000000000000000000000000,340282366920938463463374607431768211455);

    //     vm.roll(block.number + 42229);
    //     vm.warp(block.timestamp + 172101);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     balanceSheet_resetPricePoolPerAsset();

    //     vm.roll(block.number + 15005);
    //     vm.warp(block.timestamp + 82671);
    //     vm.prank(0x0000000000000000000000000000000000020000);
    //     property_system_addresses_never_receive_share_tokens();

    //     vm.warp(block.timestamp + 173875);

    //     vm.roll(block.number + 58024);

    //     vm.roll(block.number + 23403);
    //     vm.warp(block.timestamp + 116188);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     hub_notifySharePrice_clamped();

    //     vm.warp(block.timestamp + 404997);

    //     vm.roll(block.number + 2511);

    //     vm.roll(block.number + 60054);
    //     vm.warp(block.timestamp + 415353);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     toggle_AccountToUpdate(255);

    //     vm.roll(block.number + 1123);
    //     vm.warp(block.timestamp + 420078);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     hub_notifySharePrice(225);

    //     vm.roll(block.number + 800);
    //     vm.warp(block.timestamp + 322247);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     property_account_totalDebit_and_totalCredit_leq_max_int128();

    //     vm.warp(block.timestamp + 1348946);

    //     vm.roll(block.number + 48323);

    //     vm.roll(block.number + 45819);
    //     vm.warp(block.timestamp + 407328);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     property_sum_of_possible_account_balances_leq_escrow();

    //     vm.warp(block.timestamp + 598199);

    //     vm.roll(block.number + 23275);

    //     vm.roll(block.number + 9966);
    //     vm.warp(block.timestamp + 360624);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     property_loss_soundness();

    //     vm.warp(block.timestamp + 598199);

    //     vm.roll(block.number + 4223);

    //     vm.roll(block.number + 4896);
    //     vm.warp(block.timestamp + 16802);
    //     vm.prank(0x0000000000000000000000000000000000020000);
    //     property_sum_pending_user_redeem_geq_total_pending_redeem();

    //     vm.warp(block.timestamp + 209930);

    //     vm.roll(block.number + 2526);

    //     vm.roll(block.number + 36859);
    //     vm.warp(block.timestamp + 412373);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     spoke_unfreeze();

    //     vm.roll(block.number + 11905);
    //     vm.warp(block.timestamp + 379552);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     toggle_MaxClaims(4369999);

    //     vm.roll(block.number + 2497);
    //     vm.warp(block.timestamp + 482712);
    //     vm.prank(0x0000000000000000000000000000000000020000);
    //     shortcut_deposit_and_cancel(11368581075424,4370001,82231606512040365988015407449023285550578478571820891488580152292157184238913,239370871021043926144340344960572493770,18735060318170992511790157813086041536930740640949269457111508682625953501664);

    //     vm.warp(block.timestamp + 843701);

    //     vm.roll(block.number + 97101);

    //     vm.roll(block.number + 58783);
    //     vm.warp(block.timestamp + 49735);
    //     vm.prank(0x0000000000000000000000000000000000020000);
    //     property_holdings_balance_equals_escrow_balance();

    //     vm.warp(block.timestamp + 322374);

    //     vm.roll(block.number + 27958);

    //     vm.roll(block.number + 24987);
    //     vm.warp(block.timestamp + 465497);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     property_total_pending_and_approved();

    //     vm.roll(block.number + 1088);
    //     vm.warp(block.timestamp + 277232);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     property_loss_soundness();

    //     vm.roll(block.number + 12155);
    //     vm.warp(block.timestamp + 49735);
    //     vm.prank(0x0000000000000000000000000000000000020000);
    //     spoke_deployVault_clamped();

    //     vm.roll(block.number + 32737);
    //     vm.warp(block.timestamp + 195123);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     property_sum_of_possible_account_balances_leq_escrow();

    //     vm.warp(block.timestamp + 333329);

    //     vm.roll(block.number + 52187);

    //     vm.roll(block.number + 2497);
    //     vm.warp(block.timestamp + 284673);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     balanceSheet_overridePricePoolPerAsset(214898301581971330586984674666078195408);

    //     vm.roll(block.number + 32737);
    //     vm.warp(block.timestamp + 16802);
    //     vm.prank(0x0000000000000000000000000000000000020000);
    //     property_price_on_redeem();

    //     vm.roll(block.number + 30042);
    //     vm.warp(block.timestamp + 49735);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     balanceSheet_resetPricePoolPerAsset();

    //     vm.warp(block.timestamp + 522178);

    //     vm.roll(block.number + 960);

    //     vm.roll(block.number + 45819);
    //     vm.warp(block.timestamp + 482712);
    //     vm.prank(0x0000000000000000000000000000000000020000);
    //     restrictedTransfers_freeze();

    //     vm.roll(block.number + 45819);
    //     vm.warp(block.timestamp + 82672);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     property_sum_pending_user_deposit_geq_total_pending_deposit();

    //     vm.roll(block.number + 30042);
    //     vm.warp(block.timestamp + 65535);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     spoke_unlinkVault();

    //     vm.roll(block.number + 689);
    //     vm.warp(block.timestamp + 887);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     balanceSheet_overridePricePoolPerShare(235214940839871120579775308684433745640);

    //     vm.roll(block.number + 45819);
    //     vm.warp(block.timestamp + 400981);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     canary_doesTokenGetDeployed();

    //     vm.warp(block.timestamp + 414579);

    //     vm.roll(block.number + 33357);

    //     vm.roll(block.number + 23722);
    //     vm.warp(block.timestamp + 254414);
    //     vm.prank(0x0000000000000000000000000000000000020000);
    //     spoke_updateShareMetadata(hex"8252535458f3d351ef",hex"42b1624e554cbcf3b341b7694e03");

    //     vm.warp(block.timestamp + 298042);

    //     vm.roll(block.number + 55538);

    //     vm.roll(block.number + 27404);
    //     vm.warp(block.timestamp + 436727);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     toggle_IsLiability();

    //     vm.roll(block.number + 54155);
    //     vm.warp(block.timestamp + 414736);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     doomsday_pricePerShare_never_changes_after_user_operation();

    //     vm.roll(block.number + 60364);
    //     vm.warp(block.timestamp + 277232);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     property_accounting_and_holdings_soundness();

    //     vm.warp(block.timestamp + 838992);

    //     vm.roll(block.number + 66464);

    //     vm.roll(block.number + 22699);
    //     vm.warp(block.timestamp + 447588);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     spoke_linkVault_clamped();

    //     vm.roll(block.number + 18429);
    //     vm.warp(block.timestamp + 115085);
    //     vm.prank(0x0000000000000000000000000000000000020000);
    //     switch_actor(1524785991);

    //     vm.warp(block.timestamp + 519847);

    //     vm.roll(block.number + 15005);

    //     vm.roll(block.number + 58783);
    //     vm.warp(block.timestamp + 50417);
    //     vm.prank(0x0000000000000000000000000000000000020000);
    //     hub_setPoolMetadata(hex"181232f1f3f29d2e7890b8d411ccbd94558bb11f67e6564427dfdfdfdfdfdfdfdfdfdfdfdfdfdfdf5453545855908b");

    //     vm.roll(block.number + 1161);
    //     vm.warp(block.timestamp + 400981);
    //     vm.prank(0x0000000000000000000000000000000000020000);
    //     shortcut_cancel_redeem_claim_clamped(21010338243568875235369503438368474542805959972720350207323637971219949251688,144,1524785992);

    //     vm.roll(block.number + 42229);
    //     vm.warp(block.timestamp + 415217);
    //     vm.prank(0x0000000000000000000000000000000000010000);
    //     hub_updatePricePerShare(1524785993);

    //     vm.roll(block.number + 5053);
    //     vm.warp(block.timestamp + 559716);
    //     vm.prank(0x0000000000000000000000000000000000030000);
    //     toggle_EquityAccount(432043);

    //     vm.roll(block.number + 12338);
    //     vm.warp(block.timestamp + 605);
    //     vm.prank(0x0000000000000000000000000000000000020000);
    //     property_sum_of_minted_equals_total_supply();

    // }
    
    // forge test --match-test test_property_sum_of_assets_received_on_claim_cancel_deposit_request_15 -vvv 
    // NOTE: looks like issue with not tracking cancellations that get queued then claimed via `notifyDeposit`
    function test_property_sum_of_assets_received_on_claim_cancel_deposit_request_15() public {

        shortcut_deployNewTokenPoolAndShare(13,5516660714625968031527564836271718,true,false,true);

        shortcut_deposit_queue_cancel(28116632,1,247888342983059284870515782138539233336215874848693504774355995578,1,1,15932349122905649941988425867585084269396420944461629);

        hub_notifyDeposit(1);

        vault_claimCancelDepositRequest(0);

        property_sum_of_assets_received_on_claim_cancel_deposit_request();

    }

    /// === Newest Issues === ///

}
