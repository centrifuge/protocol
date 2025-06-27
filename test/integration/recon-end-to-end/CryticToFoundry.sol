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
import {PoolEscrow} from "src/common/PoolEscrow.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {IValuation} from "src/common/interfaces/IValuation.sol";
import {D18} from "src/misc/types/D18.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {CryticSanity} from "./CryticSanity.sol";

// forge test --match-contract CryticToFoundry -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    // Helper functions to handle bytes calldata parameters
    function hub_updateRestriction_wrapper(uint16 chainId) external {
        // TODO: Fix bytes calldata issue - skipping for now
        // hub_updateRestriction(chainId, "");
    }

    function hub_updateRestriction_clamped_wrapper() external {
        // TODO: Fix bytes calldata issue - skipping for now
        // hub_updateRestriction_clamped("");
    }

    // forge test --match-test test_crytic -vvv
    function test_crytic() public {
        // TODO: add failing property tests here for debugging
    }

    // forge test --match-test test_optimize_maxDeposit_less_c8ty -vvv
    function test_optimize_maxDeposit_less_c8ty() public {
        // Max value: 12;

        vm.roll(block.number + 53451);
        vm.warp(block.timestamp + 31594);
        property_sum_pending_user_deposit_geq_total_pending_deposit();

        vm.roll(block.number + 59982);
        vm.warp(block.timestamp + 490448);
        property_solvency_deposit_requests();

        vm.roll(block.number + 20243);
        vm.warp(block.timestamp + 271957);
        property_loss_soundness();

        vm.roll(block.number + 34720);
        vm.warp(block.timestamp + 444463);
        root_scheduleRely(0x00000000000000000000000000000001fffffffE);

        vm.roll(block.number + 53166);
        vm.warp(block.timestamp + 33605);
        spoke_freeze();

        vm.roll(block.number + 15005);
        vm.warp(block.timestamp + 439556);
        toggle_IsLiability();

        vm.roll(block.number + 60364);
        vm.warp(block.timestamp + 127);
        switch_vault(64031118910615742709547914950422627952713422074091777308315801545051878430174);

        vm.roll(block.number + 12338);
        vm.warp(block.timestamp + 414736);
        vault_cancelDepositRequest();

        vm.roll(block.number + 60267);
        vm.warp(block.timestamp + 16802);
        balanceSheet_recoverTokens(
            0x0000000000000000000000000000000000000F01,
            83005198606510331621904458052541327432001103634935962363367839616250934933187
        );

        vm.roll(block.number + 57994);
        vm.warp(block.timestamp + 292304);
        canary_doesVaultGetDeployed();

        vm.roll(block.number + 59552);
        vm.warp(block.timestamp + 490448);
        shortcut_deployNewTokenPoolAndShare(
            242, 83518001260717324063042894427758244095233325890446972284372150779325824329029, false, true, true
        );

        vm.roll(block.number + 15368);
        vm.warp(block.timestamp + 213);
        spoke_linkVault(0x00000000000000000000000000000000FFFFfFFF);

        vm.roll(block.number + 47075);
        vm.warp(block.timestamp + 511822);
        asyncVault_6_mint(
            0x00000000000000000000000000000000FFFFfFFF,
            27786747970961585877266460213817746462920662921570149977659176792813735259326
        );

        property_sum_of_assets_received_on_claim_cancel_deposit_request();

        vm.roll(block.number + 561);
        vm.warp(block.timestamp + 379552);
        asyncVault_9_mint(0x00000000000000000000000000000001fffffffE);

        vm.roll(block.number + 59981);
        vm.warp(block.timestamp + 560586);
        hub_updateHoldingValue();

        vm.roll(block.number + 55538);
        vm.warp(block.timestamp + 407328);
        hub_notifyPool(65535);

        vm.roll(block.number + 1984);
        vm.warp(block.timestamp + 405856);
        hub_setHoldingAccountId(492, 19, 2147386247);

        vm.roll(block.number + 12338);
        vm.warp(block.timestamp + 569114);
        hub_updateHoldingValuation_clamped(true);

        vm.roll(block.number + 9966);
        vm.warp(block.timestamp + 490448);
        vault_withdraw(
            92653446890381415908949946703214928903546641655516038168005309050170631364211,
            27394621309398685112638102201327728907038212320963644525533053805379107894322
        );

        vm.roll(block.number + 59552);
        vm.warp(block.timestamp + 117472);
        shortcut_cancel_redeem_immediately_issue_and_revoke_clamped(
            31373841727014350401773378424415788277965508846640799188917225632584143213238,
            117324192864800759558445712124619175515,
            4370001
        );

        vm.roll(block.number + 24987);
        vm.warp(block.timestamp + 338920);
        asyncVault_5(0xa0Cb889707d426A7A386870A03bc70d1b0697598);

        vm.roll(block.number + 45261);
        vm.warp(block.timestamp + 82672);
        property_actor_pending_and_queued_deposits();

        vm.roll(block.number + 59983);
        vm.warp(block.timestamp + 195123);
        spoke_updateMember(9691220614056050811);

        vm.roll(block.number + 30784);
        vm.warp(block.timestamp + 387829);
        property_cancelled_soundness();

        vm.roll(block.number + 932);
        vm.warp(block.timestamp + 772);
        shortcut_deposit_queue_cancel(
            9069252751600562995,
            121792211959312788656096637188959608309,
            1524785992,
            179,
            98140418062370283696547039649210684098,
            4370001
        );

        vm.roll(block.number + 213);
        vm.warp(block.timestamp + 834);
        hub_updateHoldingValuation_clamped(false);

        vm.roll(block.number + 11349);
        vm.warp(block.timestamp + 404385);
        vault_requestRedeem_clamped(
            60572681156793594829509576321602357117179994297001946007861424433392620078774, 4369999
        );

        vm.roll(block.number + 474);
        vm.warp(block.timestamp + 270720);
        spoke_linkVault(0x00000000000000000000000000000001fffffffE);

        vm.roll(block.number + 9920);
        vm.warp(block.timestamp + 381925);
        hub_multicall_clamped();

        vm.roll(block.number + 6);
        vm.warp(block.timestamp + 876);
        vault_requestDeposit_clamped(
            4370001, 104667860870852208955409837396737859517364009876327477007243065490835494831958
        );

        vm.roll(block.number + 479);
        vm.warp(block.timestamp + 322374);
        property_cancelled_and_processed_redemptions_soundness();

        vm.roll(block.number + 24311);
        vm.warp(block.timestamp + 257);
        balanceSheet_noteDeposit(
            58318896982458077512744685134746148256971497547674332669711186508685973286553,
            340282366920938463463374607431768211455
        );

        vm.roll(block.number + 518);
        vm.warp(block.timestamp + 503);
        // Note: Using this.emptyBytes() to get bytes calldata
        this.hub_updateRestriction_wrapper(65535);

        vm.roll(block.number + 52510);
        vm.warp(block.timestamp + 860);
        // Note: Using this.emptyBytes() to get bytes calldata
        this.hub_updateRestriction_clamped_wrapper();

        vm.roll(block.number + 213);
        vm.warp(block.timestamp + 427);
        balanceSheet_recoverTokens(0x03A6a84cD762D9707A21605b548aaaB891562aAb, 4370001);

        vm.roll(block.number + 1023);
        vm.warp(block.timestamp + 225906);
        property_equity_soundness();

        vm.roll(block.number + 26247);
        vm.warp(block.timestamp + 706);
        toggle_GainAccount(1524785993);

        vm.roll(block.number + 12155);
        vm.warp(block.timestamp + 489);
        toggle_IsIncrease();
    }

    // forge test --match-test test_optimize_maxRedeem_less_06o4 -vvv
    function test_optimize_maxRedeem_less_06o4() public {
        // Max value: 325991547000000000000000000;

        vm.roll(block.number + 393);
        vm.warp(block.timestamp + 569114);
        asyncVault_maxDeposit(3565510, 230556812, 4369999);

        vm.roll(block.number + 5237);
        vm.warp(block.timestamp + 815);
        vault_cancelDepositRequest();

        vm.roll(block.number + 24589);
        vm.warp(block.timestamp + 340319);
        balanceSheet_deny();

        vm.roll(block.number + 352);
        vm.warp(block.timestamp + 179109);
        property_sum_of_minted_equals_total_supply();

        vm.roll(block.number + 36061);
        vm.warp(block.timestamp + 33271);
        balanceSheet_withdraw(0, 1524785993);

        vm.roll(block.number + 213);
        vm.warp(block.timestamp + 361136);
        canary_doesVaultGetDeployed();

        vm.roll(block.number + 2512);
        vm.warp(block.timestamp + 198598);
        asyncVault_8(0xD4aEf50C842F0Ce6A698Ade3caC546Cf4Ed38f62);

        vm.roll(block.number + 55437);
        vm.warp(block.timestamp + 115085);
        spoke_linkVault(0x00000000000000000000000000000000FFFFfFFF);

        vm.roll(block.number + 35200);
        vm.warp(block.timestamp + 184);
        token_approve(
            0x00000000000000000000000000000001fffffffE,
            63422993037460882066889507224887646575547039191781957652407947075144955785170
        );

        switch_vault(4370000);

        vm.roll(block.number + 476);
        vm.warp(block.timestamp + 319397);
        balanceSheet_deposit(49644356330802152010550915880366850853026469975503955465000796658858669910012, 554);

        vm.roll(block.number + 1362);
        vm.warp(block.timestamp + 88917);
        property_system_addresses_never_receive_share_tokens();

        vm.roll(block.number + 56407);
        vm.warp(block.timestamp + 82672);
        restrictedTransfers_updateMemberBasic(4600062292567074627);

        vm.roll(block.number + 15368);
        vm.warp(block.timestamp + 69688);
        asyncVault_7(
            0x1aF7f588A501EA2B5bB3feeFA744892aA2CF00e6,
            8039896624951396957343957577632058955824044032608795687727206768660975352841
        );

        vm.roll(block.number + 9084);
        vm.warp(block.timestamp + 19029);
        shortcut_approve_and_revoke_shares(
            332184458868845293826594013324070629778, 2223432785, 70527105126359058749798556033768216295
        );

        vm.roll(block.number + 561);
        vm.warp(block.timestamp + 10899);
        property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive();

        vm.roll(block.number + 24084);
        vm.warp(block.timestamp + 269009);
        balanceSheet_issue(4370001);

        vm.roll(block.number + 23275);
        vm.warp(block.timestamp + 963);
        hub_notifyPool(48672);

        vm.roll(block.number + 283);
        vm.warp(block.timestamp + 547623);
        spoke_addPool();

        vm.roll(block.number + 5140);
        vm.warp(block.timestamp + 275394);
        property_escrow_share_balance();

        vm.roll(block.number + 4131);
        vm.warp(block.timestamp + 269009);
        toggle_EquityAccount(743511597);

        vm.roll(block.number + 4626);
        vm.warp(block.timestamp + 82671);
        shortcut_cancel_redeem_clamped(
            76129382358607128610989205034598918732134551409046205175318966608041837733841,
            4370001,
            115792089237316195423570985008687907853269984665640564039457584007913129639935
        );

        vm.roll(block.number + 4896);
        vm.warp(block.timestamp + 706);
        canary_doesVaultGetDeployed();

        vm.roll(block.number + 37914);
        vm.warp(block.timestamp + 323407);
        switch_share_token(4369999);

        vm.roll(block.number + 22839);
        vm.warp(block.timestamp + 159744);
        hub_initializeLiability(IValuation(0x0000000000000000000000000000000000000f04), 4370001, 239164852);

        vm.roll(block.number + 35248);
        vm.warp(block.timestamp + 213);
        property_gain_soundness();

        vm.roll(block.number + 9996);
        vm.warp(block.timestamp + 130937);
        balanceSheet_overridePricePoolPerAsset(D18.wrap(332748105653534330666704950356365151900));

        vm.roll(block.number + 45852);
        vm.warp(block.timestamp + 363);
        hub_notifySharePrice(65535);

        vm.roll(block.number + 706);
        vm.warp(block.timestamp + 349073);
        property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive();

        vm.roll(block.number + 601);
        vm.warp(block.timestamp + 339917);
        shortcut_redeem_and_claim_clamped(4370001, 1524785992, 4370000);

        vm.roll(block.number + 942);
        vm.warp(block.timestamp + 275861);
        toggle_AccountToUpdate(255);

        vm.roll(block.number + 60267);
        vm.warp(block.timestamp + 16803);
        toggle_EquityAccount(1503177424);

        vm.roll(block.number + 829);
        vm.warp(block.timestamp + 33271);
        hub_initializeHolding(
            IValuation(0x00000000000000000000000000000000FFFFfFFF), 194, 3508937430, 2846711460, 766761565
        );

        vm.roll(block.number + 968);
        vm.warp(block.timestamp + 66543);
        spoke_linkVault_clamped();

        vm.roll(block.number + 51236);
        vm.warp(block.timestamp + 31594);
        hub_setHoldingAccountId(4370001, 255, 1524785992);

        hub_notifyShareClass_clamped(bytes32(0));

        vm.roll(block.number + 44274);
        vm.warp(block.timestamp + 82672);
        hub_createHolding_clamped(true, 42, 255, 200, 255);

        balanceSheet_noteDeposit(
            72471746956481084129564862480901384905404482248830751860681287593528932139081,
            199442617378997895988140814992292323492
        );

        vm.roll(block.number + 4896);
        vm.warp(block.timestamp + 358061);
        hub_createPool(3924026, 0x0000000000000000000000000000000000000000, 162010803642650372228429149707753379226);

        vm.roll(block.number + 255);
        vm.warp(block.timestamp + 76905);
        vault_withdraw(77935814114920331116702449040913653437128986384090975585619307698770214708007, 377);

        vm.roll(block.number + 4462);
        vm.warp(block.timestamp + 45142);
        doomsday_impliedPricePerShare_never_changes_after_user_operation();

        property_loss_soundness();

        vm.roll(block.number + 9966);
        vm.warp(block.timestamp + 206186);
        hub_addShareClass(28594764310253931526142921972331381355339153937405120777051844087810933120871);

        vm.roll(block.number + 32737);
        vm.warp(block.timestamp + 323);
        spoke_addPool();

        vm.roll(block.number + 36061);
        vm.warp(block.timestamp + 588255);
        shortcut_withdraw_and_claim_clamped(
            4381017380292099653810868959637362770935353436900125163496266960974859101462,
            1524785993,
            51167312597845988303461900608476118202049710107480752907500188013846936018625
        );

        vm.roll(block.number + 53166);
        vm.warp(block.timestamp + 322247);
        property_total_pending_and_approved();

        vm.roll(block.number + 50081);
        vm.warp(block.timestamp + 63374);
        toggle_IsLiability();

        hub_approveDeposits(990838828, 18821290395352027304816624427471301921);

        vm.roll(block.number + 1881);
        vm.warp(block.timestamp + 32767);
        vault_requestRedeem(4370000, 39);

        vm.roll(block.number + 508);
        vm.warp(block.timestamp + 519847);
        hub_notifyPool(19745);

        vm.roll(block.number + 57685);
        vm.warp(block.timestamp + 209930);
        shortcut_deposit_cancel_claim(
            17516274811153487887,
            1524785992,
            115792089237316195423570985008687907853269984665640564039457584007913129639932,
            848,
            97894710967488590989747343035758855644983612533747424953222345431887902174395
        );

        vm.roll(block.number + 3661);
        vm.warp(block.timestamp + 329263);
        balanceSheet_issue(2);

        vm.roll(block.number + 52126);
        vm.warp(block.timestamp + 19029);
        asyncVault_6_mint(0x00000000000000000000000000000002fFffFffD, 1524785993);

        vm.roll(block.number + 53011);
        vm.warp(block.timestamp + 720);
        shortcut_cancel_redeem_clamped(
            75977623593163147592717106190397113226301674463349278433550188243618991808660,
            4369999,
            79379105447792375495463838948377488194618092989057417339341836187955271687755
        );

        vm.roll(block.number + 15118);
        vm.warp(block.timestamp + 414579);
        property_cancelled_and_processed_deposits_soundness();

        vm.roll(block.number + 388);
        vm.warp(block.timestamp + 32767);
        asyncVault_maxRedeem(
            15412857445291280269, 2233420, 93280091385454298768023578685324433787622924241309309437240022306363004454425
        );
    }

    // forge test --match-test test_optimize_totalAssets_solvency_r9di -vvv
    function test_optimize_totalAssets_solvency_r9di() public {
        // Max value: 340282366920938451679371842713960990430;

        hub_notifyShareClass_clamped(bytes32(0));

        vm.roll(block.number + 141);
        vm.warp(block.timestamp + 181);

        vm.roll(block.number + 643);
        vm.warp(block.timestamp + 205820);
        hub_notifySharePrice_clamped();
    }

    // forge test --match-test test_optimize_maxDeposit_greater_qx63 -vvv
    function test_optimize_maxDeposit_greater_qx63() public {
        // Max value: 125748077226094910146257096;

        hub_notifyShareClass_clamped(bytes32(0));

        vm.roll(block.number + 60248);
        vm.warp(block.timestamp + 395);

        vm.roll(block.number + 786);
        vm.warp(block.timestamp + 136392);
        shortcut_cancel_redeem_clamped(
            98400458664801435918389492680917058896031245284541626554882538297582355647852,
            285206931649261004069424882847045744350,
            58657796297957969014668979973325241632751742498456482854652408771796533732222
        );

        vm.roll(block.number + 9920);
        vm.warp(block.timestamp + 417903);
        token_approve(
            0x00000000000000000000000000000000FFFFfFFF,
            83890301760789798042697428350080430756845546025029970945766414744041690333773
        );

        vm.roll(block.number + 5023);
        vm.warp(block.timestamp + 439556);
        switch_asset(62656852884772475984730109869609410410096108437280586738664712996839274056315);

        vm.roll(block.number + 55538);
        vm.warp(block.timestamp + 19029);
        spoke_freeze();

        vm.roll(block.number + 427);
        vm.warp(block.timestamp + 559599);
        balanceSheet_transferSharesFrom(
            0x00000000000000000000000000000002fFffFffD,
            112153437835330216359730155040672944290790938705286275503645200251939863612607
        );

        vm.roll(block.number + 51058);
        vm.warp(block.timestamp + 442806);
        property_sum_pending_user_redeem_geq_total_pending_redeem();

        vm.roll(block.number + 755);
        vm.warp(block.timestamp + 209930);
        toggle_AccountToUpdate(146);

        vm.roll(block.number + 1984);
        vm.warp(block.timestamp + 440097);
        balanceSheet_withdraw(101021346504303992005487136343937253323921760435842061583674079311899147732249, 4370000);

        vm.roll(block.number + 60364);
        vm.warp(block.timestamp + 566039);
        shortcut_queue_redemption(
            4617319470127605631716738463004158172263929666702520048236733297181271016685,
            340282366920938463463374607431768211451,
            115792089237316195423570985008687907853269984665640564039457584007913129639932
        );

        vm.roll(block.number + 12155);
        vm.warp(block.timestamp + 269009);
        property_soundness_processed_redemptions();

        vm.roll(block.number + 687);
        vm.warp(block.timestamp + 301059);
        asyncVault_6_withdraw(
            0x00000000000000000000000000000000FFFFfFFF,
            73730384247478049308144323638281838061606655347432441995131038850389003006602
        );

        vm.roll(block.number + 599);
        vm.warp(block.timestamp + 531);
        hub_approveRedeems(4370001, 291495985884110393973711438023156604349);

        vm.roll(block.number + 842);
        vm.warp(block.timestamp + 322247);
        balanceSheet_withdraw(56840698144165594979879683076673593995065120014528421477945543342478735908554, 4369999);

        balanceSheet_resetPricePoolPerShare();

        vm.roll(block.number + 5237);
        vm.warp(block.timestamp + 73040);
        shortcut_cancel_redeem_immediately_issue_and_revoke_clamped(4370001, 1524785992, 519);

        vm.roll(block.number + 464);
        vm.warp(block.timestamp + 447588);
        spoke_updateMember(3089367837700724777);

        vm.roll(block.number + 592);
        vm.warp(block.timestamp + 19029);
        property_equity_soundness();

        vm.roll(block.number + 23750);
        vm.warp(block.timestamp + 177);
        hub_forceCancelRedeemRequest();

        vm.roll(block.number + 845);
        vm.warp(block.timestamp + 82672);
        property_sum_of_balances();

        switch_pool(72450619142952393603266225432831775106625421348626273718330996093679486044741);

        vm.roll(block.number + 18429);
        vm.warp(block.timestamp + 842);
        hub_setMaxSharePriceAge(65535, 3886511742);

        vm.roll(block.number + 786);
        vm.warp(block.timestamp + 361000);
        property_totalAssets_solvency();

        vm.roll(block.number + 2293);
        vm.warp(block.timestamp + 733);
        add_new_asset(255);

        vm.roll(block.number + 6234);
        vm.warp(block.timestamp + 127251);
        hub_notifyAssetPrice();

        vm.roll(block.number + 987);
        vm.warp(block.timestamp + 755);
        asyncVault_5(0x00000000000000000000000000000000FFFFfFFF);

        vm.roll(block.number + 23750);
        vm.warp(block.timestamp + 414579);
        add_new_asset(125);

        vm.roll(block.number + 15207);
        vm.warp(block.timestamp + 489251);
        property_additions_use_correct_price();

        vm.roll(block.number + 27404);
        vm.warp(block.timestamp + 420167);
        property_total_issuance_soundness();

        vm.roll(block.number + 38350);
        vm.warp(block.timestamp + 570729);
        asyncVault_maxDeposit(466208069385767732, 4089857612, 125748077226094910146257096);
    }
}
