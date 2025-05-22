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
    
    /// === Ghost Issues === ///
    // forge test --match-test test_property_escrow_share_balance_1 -vvv 
    // NOTE: fixed
    function test_property_escrow_share_balance_1() public {

        shortcut_deployNewTokenPoolAndShare(2,14177496652252639380981478672963823008698,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_cancel_redeem_clamped(1,0,0);

        property_escrow_share_balance();

    }

    // forge test --match-test test_property_escrow_balance_2 -vvv 
    // NOTE: fixed
    function test_property_escrow_balance_2() public {

        shortcut_deployNewTokenPoolAndShare(2,6220719125742280882885116494485473,true,false,true);

        shortcut_deposit_and_claim(0,1,2,1,0);

        shortcut_cancel_redeem_claim_clamped(1037046715235638606,1,8939997985963703993327973207429562758);

        hub_notifyRedeem(1);

        property_escrow_balance();

    }

    // forge test --match-test test_property_solvency_redemption_requests_5 -vvv 
    // NOTE: fixed
    function test_property_solvency_redemption_requests_5() public {

        shortcut_deployNewTokenPoolAndShare(2,1197990898591296055414719643049951363178,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        vault_requestRedeem_clamped(1,0);

        poolManager_deployVault(false);

        shortcut_queue_redemption(1,0,0);

        property_solvency_redemption_requests();

    }

    // forge test --match-test test_property_cancelled_and_processed_redemptions_soundness_6 -vvv 
    // NOTE: fixed by fixing tracking of processed redemptions to shareclass and asset level
    function test_property_cancelled_and_processed_redemptions_soundness_6() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,false);

        shortcut_mint_sync(2,10000422327224340172730307600109085);

        shortcut_cancel_redeem_clamped(1,0,0);

        poolManager_deployVault_clamped();

        hub_notifyRedeem(1);

        property_cancelled_and_processed_redemptions_soundness();
    }

    // forge test --match-test test_property_actor_pending_and_queued_deposits_10 -vvv 
    // NOTE: fixed by adding depositProcessed to sync mints
    function test_property_actor_pending_and_queued_deposits_10() public {

        shortcut_deployNewTokenPoolAndShare(4,1,true,false,false);

        shortcut_mint_sync(1,100427952388798661003401004989581);

        property_actor_pending_and_queued_deposits();

    }

    // forge test --match-test test_property_sum_of_minted_equals_total_supply_11 -vvv 
    // NOTE: fixed by changing location where executedRedemptions is updated to be inside revokeShares which burns shares
    function test_property_sum_of_minted_equals_total_supply_11() public {

        shortcut_deployNewTokenPoolAndShare(8,1,false,false,false);

        shortcut_mint_sync(2,100503941766022670033945);

        shortcut_cancel_redeem_clamped(1,0,0);

        property_sum_of_minted_equals_total_supply();

    }

    // forge test --match-test test_property_soundness_processed_redemptions_15 -vvv 
    // NOTE: fixed by fixing tracking for ghosts to include scId and assetId
    function test_property_soundness_processed_redemptions_15() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,false);

        shortcut_mint_sync(2,10001493698620430928097305628073781);

        shortcut_cancel_redeem_clamped(1,0,0);

        poolManager_deployVault_clamped();

        hub_notifyRedeem(1);

        property_soundness_processed_redemptions();

    }

    // forge test --match-test test_property_actor_pending_and_queued_redemptions_18 -vvv 
    // NOTE: fixed by fixing tracking for ghosts to include scId and assetId
    function test_property_actor_pending_and_queued_redemptions_18() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,false);

        shortcut_deposit_sync(1,1);

        vault_requestRedeem(1,0);

        poolManager_deployVault_clamped();

        property_actor_pending_and_queued_redemptions();

    }

    // forge test --match-test test_property_sum_of_assets_received_22 -vvv 
    // NOTE: fixed
    function test_property_sum_of_assets_received_22() public {

        shortcut_deployNewTokenPoolAndShare(2,1989486873372372528915163746500992494654651,true,false,true);

        shortcut_deposit_and_claim(0,1,3,1,0);

        add_new_asset(0);

        shortcut_redeem_and_claim_clamped(5639078477813265771514312817281638816374,1,587614949423672601016258534476771816487634586);

        property_sum_of_assets_received();

    }

    // === Implementation Issues === ///

    // forge test --match-test test_property_escrow_solvency_4 -vvv 
    // NOTE: fixed by fixing property implementation because it was incorrect, was checking that reserved >= holding but should be holding >= reserved
    function test_property_escrow_solvency_4() public {

        shortcut_deployNewTokenPoolAndShare(5,1,true,false,false);

        shortcut_mint_sync(1,10066993534062842573842051391315);

        property_escrow_solvency();

    }

    // forge test --match-test test_property_price_per_share_overall_7 -vvv 
    // NOTE: fixed by using correct asset balance in assetDelta calculation 
    function test_property_price_per_share_overall_7() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,false);

        IBaseVault vault = IBaseVault(_getVault());
        address asset = vault.asset();
        address poolEscrow = address(poolEscrowFactory.escrow(vault.poolId()));
        uint256 poolEscrowBalanceBefore = MockERC20(asset).balanceOf(poolEscrow);
        console2.log("poolEscrowBalanceBefore", poolEscrowBalanceBefore);

        shortcut_deposit_sync(1,1);

        uint256 poolEscrowBalanceAfter = MockERC20(asset).balanceOf(poolEscrow);
        console2.log("poolEscrowBalanceAfter", poolEscrowBalanceAfter);

        property_price_per_share_overall();

    }

    // forge test --match-test test_property_sum_of_account_balances_leq_escrow_12 -vvv 
    // NOTE: fixed, wasn't accounting for pool escrow balance
    function test_property_sum_of_account_balances_leq_escrow_12() public {

        shortcut_deployNewTokenPoolAndShare(2,202817328946178875990884541382869241,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_queue_redemption(1,1003528737181707744,0);

        hub_notifyRedeem(1);

        property_sum_of_account_balances_leq_escrow();

    }

    // forge test --match-test test_property_price_on_fulfillment_13 -vvv 
    // NOTE: fixed by updating cached price in globals whenever a deposit is canceled
    function test_property_price_on_fulfillment_13() public {

        shortcut_deployNewTokenPoolAndShare(13,115833232541743952731636843130624,true,false,true);

        shortcut_deposit_and_claim(0,1,29,1,0);

        shortcut_deposit_cancel_claim(166977638,1,89198889783443011232416108452159138080202841691510285825866430006,0,131122318721772452744012695522941701218970521149292692);

        property_price_on_fulfillment();

    }

    // forge test --match-test test_property_sum_of_pending_redeem_request_14 -vvv 
    // NOTE: fixed by redefining property because it was incorrect
    function test_property_sum_of_pending_redeem_request_14() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,false);

        shortcut_mint_sync(2,10001493698620430928097305628073781);

        shortcut_cancel_redeem_clamped(1,0,0);

        hub_notifyRedeem(1);

        property_sum_of_pending_redeem_request();

    }

    // forge test --match-test test_property_user_cannot_mutate_pending_redeem_17 -vvv 
    // NOTE: fixed by adding precondition to check that pending actually changed
    function test_property_user_cannot_mutate_pending_redeem_17() public {

        shortcut_deployNewTokenPoolAndShare(4,1,true,false,false);

        shortcut_mint_sync(2,100226024907937472287174369274618);

        shortcut_cancel_redeem_clamped(48266540483328231371004030046248961672990027205716,0,318538688645079951209647344638790798296308773414516);

        IBaseVault vault = IBaseVault(_getVault());
        AssetId assetId = hubRegistry.currency(vault.poolId());
        ShareClassId scId = vault.scId();
        bytes32 actor = CastLib.toBytes32(_getActor());
        
        console2.log("=== Here 0 === ");
        console2.log("lastUpdate:", _after.ghostRedeemRequest[scId][assetId][actor].lastUpdate);
        console2.log("latest redeem revoke:", _after.ghostEpochId[scId][assetId].revoke);
        hub_addShareClass(2);

        console2.log("=== Here 1 === ");
        console2.log("lastUpdate:", _after.ghostRedeemRequest[scId][assetId][actor].lastUpdate);
        console2.log("latest redeem revoke:", _after.ghostEpochId[scId][assetId].revoke);

        token_approve(0x0000000000000000000000000000000000000000,0);

        console2.log("=== Here 2 === ");
        console2.log("lastUpdate:", _after.ghostRedeemRequest[scId][assetId][actor].lastUpdate);
        console2.log("latest redeem revoke:", _after.ghostEpochId[scId][assetId].revoke);

        property_user_cannot_mutate_pending_redeem();

    }


    /// === Potential Issues === ///
    // forge test --match-test test_asyncVault_maxRedeem_8 -vvv 
    function test_asyncVault_maxRedeem_8() public {

        shortcut_deployNewTokenPoolAndShare(16,29654276389875203551777999997167602027943,true,false,true);

        shortcut_deposit_and_claim(0,1,143,1,0);

        shortcut_redeem_and_claim_clamped(44055836141804467353088311715299154505223682107,1,60194726908356682833407755266714281307);

        asyncVault_maxRedeem(0,0,0);

    }

    // forge test --match-test test_property_totalAssets_solvency_21 -vvv 
    function test_property_totalAssets_solvency_21() public {

        shortcut_deployNewTokenPoolAndShare(16,138703409147916997321469414388245120880630781437050655901962979,true,false,true);

        shortcut_deposit_and_claim(0,1,2,1,0);

        shortcut_request_deposit(251,1,0,0);

        property_totalAssets_solvency();

    }

    // forge test --match-test test_property_holdings_balance_equals_escrow_balance_16 -vvv 
    // NOTE: setting the queue causes holdings and escrow balance to be different
    function test_property_holdings_balance_equals_escrow_balance_16() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,false);

        hub_setQueue(0,true);

        shortcut_deposit_sync(1,5429837);

        property_holdings_balance_equals_escrow_balance();

    }

    // forge test --match-test test_property_total_pending_redeem_geq_sum_pending_user_redeem_20 -vvv 
    // NOTE: if a user cancels after a redeem has been approved, the user's pending redeem amount is not updated
    function test_property_total_pending_redeem_geq_sum_pending_user_redeem_20() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,true);

        IBaseVault vault = IBaseVault(_getVault());
        AssetId assetId = hubRegistry.currency(vault.poolId());
        ShareClassId scId = vault.scId();

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_cancel_redeem_clamped(1,0,0);

        property_total_pending_redeem_geq_sum_pending_user_redeem();

    }
}
