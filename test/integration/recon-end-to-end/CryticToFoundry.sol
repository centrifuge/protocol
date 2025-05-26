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

    function test_balanceSheet_deposit() public {
        // Deploy new token, pool and share class with default decimals
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        // price needs to be set in valuation before calling updatePricePoolPerShare
        transientValuation_setPrice_clamped(1e18);

        hub_updatePricePerShare(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        // Set up test values
        uint256 tokenId = 0; // For ERC20
        uint128 depositAmount = 1e18;

        asset_approve(address(balanceSheet), depositAmount);
        // Call balanceSheet_deposit with test values
        balanceSheet_deposit(tokenId, depositAmount);
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

    // forge test --match-test test_shortcut_deposit_and_claim_1 -vvv 
    function test_shortcut_deposit_and_claim_1() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,true);

        shortcut_deposit_and_claim(6727958434,4371,1,228874694935815088166371182178478,0);

    }

    // forge test --match-test test_shortcut_deposit_queue_cancel_2 -vvv 
    function test_shortcut_deposit_queue_cancel_2() public {

        shortcut_deployNewTokenPoolAndShare(2,13045993568939965054912701272819626693644111596468185488039780186690,true,false,true);

        shortcut_request_deposit(0,1,1,4671313240128511018167522711707051906224546157581869372783443067);

        shortcut_deposit_queue_cancel(334,1,7487057153920528824349177633578051140907494203171406115406,1,1775677109257105933,0);

    }

    // forge test --match-test test_property_sum_of_received_leq_fulfilled_3 -vvv 
    function test_property_sum_of_received_leq_fulfilled_3() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        vault_requestRedeem_clamped(1,0);

        vault_cancelRedeemRequest();

        vault_claimCancelRedeemRequest(0);

        property_sum_of_received_leq_fulfilled();

    }

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

        poolManager_addShareClass(hex"12",2,0x0000000000000000000000000000000000000000);

        // this creates a new holding which gets queried by the property but it's overwriting existing accounts so incorrectly calculates accountValue
        hub_createHolding_clamped(false,0,0,0,0);

        poolManager_deployVault(false);

        property_accounting_and_holdings_soundness();

    }

    // forge test --match-test test_property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount_6 -vvv 
    function test_property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount_6() public {

        shortcut_deployNewTokenPoolAndShare(2,185317667447509018176949896872386463160691809537469,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_queue_redemption(1,0,0);

        vault_requestRedeem_clamped(1,1);

        shortcut_queue_redemption(1,0,280028406408398638308271608078347);

        hub_addShareClass(1);

        property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount();

    }

    // forge test --match-test test_property_escrow_share_balance_8 -vvv 
    function test_property_escrow_share_balance_8() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,true);

        shortcut_deposit_and_claim(0,4,1,25,0);

        shortcut_queue_redemption(1,0,0);

        property_escrow_share_balance();

    }

    // forge test --match-test test_asyncVault_maxRedeem_9 -vvv 
    function test_asyncVault_maxRedeem_9() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,true);

        shortcut_deposit_and_claim(0,1,2,1,0);

        shortcut_withdraw_and_claim_clamped(1000245318151562067,1,0);

        asyncVault_maxRedeem(0,0,0);

    }

    // forge test --match-test test_property_sum_of_pending_redeem_request_11 -vvv 
    function test_property_sum_of_pending_redeem_request_11() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,true);

        shortcut_deposit_and_claim(0,1,3,1,0);

        shortcut_redeem_and_claim_clamped(2000202949075920472,1,0);

        switch_actor(1);

        property_sum_of_pending_redeem_request();

    }

    // forge test --match-test test_property_sum_of_possible_account_balances_leq_escrow_13 -vvv 
    function test_property_sum_of_possible_account_balances_leq_escrow_13() public {

        shortcut_deployNewTokenPoolAndShare(7,1,true,false,false);

        shortcut_mint_sync(0,100012070407234780089322828896);

        property_sum_of_possible_account_balances_leq_escrow();

    }

    // forge test --match-test test_asyncVault_maxWithdraw_14 -vvv 
    function test_asyncVault_maxWithdraw_14() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_queue_redemption(1,2000526650452376978,0);

        hub_notifyRedeem(1);

        asyncVault_maxWithdraw(0,0,0);

    }

    // forge test --match-test test_property_actor_pending_and_queued_redemptions_15 -vvv 
    function test_property_actor_pending_and_queued_redemptions_15() public {

        shortcut_deployNewTokenPoolAndShare(2,26110280501627174417963496637225013,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_queue_redemption(1,0,0);

        vault_requestRedeem(1,0);

        hub_notifyRedeem(1);

        property_actor_pending_and_queued_redemptions();

    }

    // forge test --match-test test_property_price_on_redeem_16 -vvv 
    function test_property_price_on_redeem_16() public {

        shortcut_deployNewTokenPoolAndShare(2,2023043212183937121117125365820931693276147716,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_queue_redemption(1,1004036701446375220,5254288375605742773881224755342121000960484163);

        poolManager_deployVault_clamped();

        hub_notifyRedeem(1);

        switch_vault(0);

        property_price_on_redeem();
    }
}
