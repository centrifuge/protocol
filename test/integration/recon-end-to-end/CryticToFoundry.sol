// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {MockERC20} from "@recon/MockERC20.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IShareToken} from "src/spokes/interfaces/IShareToken.sol";
import {IBaseVault} from "src/spokes/interfaces/vaults/IBaseVaults.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {AccountId, AccountType} from "src/hub/interfaces/IHub.sol";
import {PoolEscrow} from "src/spokes/Escrow.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

// forge test --match-contract CryticToFoundry --match-path test/integration/recon-end-to-end/CryticToFoundry.sol -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    /// === SANITY CHECKS === ///
    function test_shortcut_deployNewTokenPoolAndShare_deposit() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        // poolManager_updatePricePoolPerShare(1e18, type(uint64).max);
        poolManager_updateMember(type(uint64).max);

        vault_requestDeposit(1e18, 0);
    }

    function test_vault_deposit_and_fulfill() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        // price needs to be set in valuation before calling updatePricePoolPerShare
        transientValuation_setPrice_clamped(1e18);

        hub_updatePricePerShare(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        poolManager_updateMember(type(uint64).max);
        
        vault_requestDeposit(1e18, 0);

        hub_approveDeposits(1, 1e18);
        hub_issueShares(1, 1e18);
       
        // need to call claimDeposit first to mint the shares
        hub_notifyDeposit(MAX_CLAIMS);

        vault_deposit(1e18);
    }

    function test_vault_deposit_and_fulfill_sync() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, false);

        // price needs to be set in valuation before calling updatePricePoolPerShare
        transientValuation_setPrice_clamped(1e18);

        hub_updatePricePerShare(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        poolManager_updateMember(type(uint64).max);

        vault_deposit(1e18);
    }

    function test_vault_deposit_and_fulfill_shortcut() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);
        
        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);
    }

    function test_vault_deposit_and_redeem() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        transientValuation_setPrice_clamped(1e18);

        hub_updatePricePerShare(1e18);
        hub_notifySharePrice_clamped();
        hub_notifyAssetPrice();
        poolManager_updateMember(type(uint64).max);
        
        vault_requestDeposit(1e18, 0);

        transientValuation_setPrice_clamped(1e18);

        hub_approveDeposits(1, 1e18);
        hub_issueShares(1, 1e18);
       
        // need to call claimDeposit first to mint the shares
        hub_notifyDeposit(MAX_CLAIMS);

        vault_deposit(1e18);

        vault_requestRedeem(1e18, 0);

        hub_approveRedeems(1, 1e18);
        hub_revokeShares(1, 1e18);
        
        hub_notifyRedeem(MAX_CLAIMS);

        vault_withdraw(1e18, 0);
    }

    function test_vault_deposit_shortcut() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);
    }

    function test_vault_redeem_and_fulfill_shortcut() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);

        shortcut_redeem_and_claim(1e18, 1e18, 0);
    }

    function test_vault_redeem_and_fulfill_shortcut_clamped() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);

        shortcut_withdraw_and_claim_clamped(1e18 - 1, 1e18, 0);
    }

    function test_shortcut_cancel_redeem_clamped() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);

        shortcut_cancel_redeem_clamped(1e18 - 1, 1e18, 0);
    }

    function test_shortcut_deposit_and_cancel() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        shortcut_deposit_and_cancel(1e18, 1e18, 1e18, 1e18, 0);
    }

    function test_shortcut_deposit_and_cancel_notify() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        shortcut_request_deposit(1e18, 1e18, 1e18, 0);

        uint32 nowDepositEpoch = shareClassManager.nowDepositEpoch(IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId()));
        hub_approveDeposits(nowDepositEpoch, 5e17);
        hub_issueShares(nowDepositEpoch, 5e17);

        vault_cancelDepositRequest();

        hub_notifyDeposit(1);
    }

    function test_shortcut_deposit_queue_cancel() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        shortcut_deposit_queue_cancel(1e18, 1e18, 1e18, 5e17, 1e18, 0);
       
        hub_notifyDeposit(1);
    }

    function test_shortcut_deposit_cancel_claim() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        shortcut_deposit_cancel_claim(1e18, 1e18, 1e18, 1e18, 0);
    }

    function test_shortcut_cancel_redeem_claim_clamped() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);

        shortcut_cancel_redeem_claim_clamped(1e18 - 1, 1e18, 0);
    }

    function test_shortcut_deployNewTokenPoolAndShare_change_price() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        transientValuation_setPrice_clamped(1e18);

        hub_updatePricePerShare(1e18);
        hub_notifySharePrice_clamped();
        hub_notifyAssetPrice();
        poolManager_updateMember(type(uint64).max);
    }

    function test_shortcut_deployNewTokenPoolAndShare_only() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);
    }

    function test_mint_sync_shortcut() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, false);

        shortcut_mint_sync(1e18, 1e18);
    }

    function test_deposit_sync_shortcut() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, false);

        shortcut_deposit_sync(1e18, 1e18);
    }

    /// === REPRODUCERS === ///

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

    // forge test --match-test test_property_holdings_balance_equals_escrow_balance_16 -vvv 
    // NOTE: setting the queue causes holdings and escrow balance to be different
    function test_property_holdings_balance_equals_escrow_balance_16() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,false);

        hub_setQueue(0,true);

        shortcut_deposit_sync(1,5429837);

        property_holdings_balance_equals_escrow_balance();

    }

    // forge test --match-test test_property_sum_pending_user_redeem_geq_total_pending_redeem_20 -vvv 
    // NOTE: if a user cancels after a redeem has been approved, the user's pending redeem amount is not updated
    function test_property_sum_pending_user_redeem_geq_total_pending_redeem_20() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,true);

        IBaseVault vault = IBaseVault(_getVault());
        AssetId assetId = hubRegistry.currency(vault.poolId());
        ShareClassId scId = vault.scId();

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_cancel_redeem_immediately_issue_and_revoke_clamped(1,0,0);

        property_sum_pending_user_redeem_geq_total_pending_redeem();

    }

    // forge test --match-test test_property_escrow_solvency_1 -vvv 
    // NOTE: passing in too large of a navPerShare value results in a payoutAssetAmount calculation that's larger than what's available in escrow
    // seems like an admin mistake but worth noting and potentially providing guardrails for
    function test_property_escrow_solvency_1() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,true);

        PoolEscrow poolEscrow = PoolEscrow(payable(address(poolEscrowFactory.escrow(IBaseVault(_getVault()).poolId()))));
        (uint128 total, uint128 reserved) = poolEscrow.holding(IBaseVault(_getVault()).scId(), IBaseVault(_getVault()).asset(), 0);
        console2.log("total before deposit", total);
        console2.log("reserved before deposit", reserved);
        shortcut_deposit_and_claim(0,1,1,1,0);

        (total, reserved) = poolEscrow.holding(IBaseVault(_getVault()).scId(), IBaseVault(_getVault()).asset(), 0);
        console2.log("total after deposit", total);
        console2.log("reserved after deposit", reserved);

        shortcut_queue_redemption(1,2001291687957964765,0);

        (total, reserved) = poolEscrow.holding(IBaseVault(_getVault()).scId(), IBaseVault(_getVault()).asset(), 0);
        console2.log("total after queue redemption", total);
        console2.log("reserved after queue redemption", reserved);

        property_escrow_solvency();

    }

    // forge test --match-test test_property_sum_of_account_balances_leq_escrow_6 -vvv 
    // NOTE: high navPerShare value results in a redeemPrice much large than it should be, resulting in a maxWithdraw that's too large
    // admin mistake so not sure how this should be handled, we can clamp it out if out of scope
    function test_property_sum_of_account_balances_leq_escrow_6() public {

        shortcut_deployNewTokenPoolAndShare(2,2,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_withdraw_and_claim_clamped(1,2003146627978594795,0);

        property_sum_of_account_balances_leq_escrow();

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

    // forge test --match-test test_property_total_issuance_soundness_10 -vvv 
    function test_property_total_issuance_soundness_10() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        hub_setQueue(0,true);

        shortcut_cancel_redeem_immediately_issue_and_revoke_clamped(1,0,0);

        property_total_issuance_soundness();

    }


    /// === Newest Issues === ///
    // forge test --match-test test_property_escrow_share_balance_0 -vvv 
    // NOTE: fixed by fixing cancelRedeemShareTokenPayout updates because was double counting redemptions
    function test_property_escrow_share_balance_0() public {

        shortcut_deployNewTokenPoolAndShare(2,27375225089210502568009843503560445409762803412186428856264,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_queue_redemption(1,0,0);

        vault_requestRedeem_clamped(1,71025053373258);

        hub_notifyRedeem(1);

        property_escrow_share_balance();

    }

    // forge test --match-test test_shortcut_deposit_and_claim_2 -vvv 
    function test_shortcut_deposit_and_claim_2() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,true);

        shortcut_deposit_and_claim(96385975138,305,1,3282566406150499976165378360743277,19372257);

    }

    // forge test --match-test test_property_price_per_share_overall_3 -vvv 
    // NOTE: needs property to be redefined as inlined
    function test_property_price_per_share_overall_3() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_queue_redemption(1,0,0);

        // property_price_per_share_overall();

    }

    // forge test --match-test test_property_sum_of_received_leq_fulfilled_4 -vvv 
    function test_property_sum_of_received_leq_fulfilled_4() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        vault_requestRedeem_clamped(1,0);

        vault_cancelRedeemRequest();

        vault_claimCancelRedeemRequest(0);

        property_sum_of_received_leq_fulfilled();

    }

    // forge test --match-test test_asyncVault_maxRedeem_5 -vvv 
    function test_asyncVault_maxRedeem_5() public {

        shortcut_deployNewTokenPoolAndShare(14,20558237568184443049325641247625745086914139883268,true,false,true);

        shortcut_deposit_and_claim(0,1,15729,1,0);

        shortcut_redeem_and_claim_clamped(1023925932769714174721975675985105062704166329526501,1,870916210420457408788070349184163260980957325747155880842);

        asyncVault_maxRedeem(0,0,0);

    }

    // forge test --match-test test_property_sum_of_pending_redeem_request_7 -vvv 
    // NOTE: fixed by updating the ghost variable being used to correct one that tracks redemptions processed
    function test_property_sum_of_pending_redeem_request_7() public {

        shortcut_deployNewTokenPoolAndShare(2,25725147251764676839597255942169173080736397,true,false,true);

        shortcut_deposit_and_claim(0,1,3,1,0);

        shortcut_redeem_and_claim_clamped(1650721406441457310759138659,1,1401828250902675629349282686303399219355066003);

        property_sum_of_pending_redeem_request();

    }

    // forge test --match-test test_property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount_9 -vvv 
    function test_property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount_9() public {

        shortcut_deployNewTokenPoolAndShare(2,185317667447509018176949896872386463160691809537469,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_queue_redemption(1,0,0);

        vault_requestRedeem_clamped(1,1);

        shortcut_queue_redemption(1,0,8096028870856468804808715074553131);

        hub_addShareClass(1);

        property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount();

    }

    // forge test --match-test test_asyncVault_maxWithdraw_10 -vvv 
    function test_asyncVault_maxWithdraw_10() public {

        shortcut_deployNewTokenPoolAndShare(2,315986864084192335972666194673,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_queue_redemption(1,2000526650452376978,0);

        hub_notifyRedeem(1);

        asyncVault_maxWithdraw(0,0,0);

    }

    // forge test --match-test test_property_actor_pending_and_queued_redemptions_11 -vvv 
    function test_property_actor_pending_and_queued_redemptions_11() public {

        shortcut_deployNewTokenPoolAndShare(2,38975175145967320715796416471125175760113593166570356513061284060,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,3);

        shortcut_queue_redemption(1,0,0);

        vault_requestRedeem(1,0);

        hub_notifyRedeem(1);

        property_actor_pending_and_queued_redemptions();

    }

    // forge test --match-test test_property_sum_pending_user_redeem_geq_total_pending_redeem_12 -vvv 
    function test_property_sum_pending_user_redeem_geq_total_pending_redeem_12() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_cancel_redeem_clamped(1,0,0);

        property_sum_pending_user_redeem_geq_total_pending_redeem();

    }

}
