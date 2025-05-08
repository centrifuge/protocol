// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {MockERC20} from "@recon/MockERC20.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";

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
    // forge test --match-test test_property_price_per_share_overall_2 -vvv 
    function test_property_price_per_share_overall_2() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,false);

        shortcut_deposit_sync(1,1);

        property_price_per_share_overall();
    }

    // forge test --match-test test_property_global_1_6 -vvv 
    function test_property_global_1_6() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,false);

        shortcut_deposit_sync(1,1);

        property_sum_of_shares_received();
    }

    // forge test --match-test test_property_asset_soundness_7 -vvv 
    function test_property_asset_soundness_7() public {

        shortcut_deployNewTokenPoolAndShare(2,2,false,false,false);

        shortcut_deposit_sync(1,1000597925025159896);

        hub_createHolding_clamped(false,0,0,0,2);

        hub_addShareClass(1);

        property_asset_soundness();

    }

    // forge test --match-test test_property_user_cannot_mutate_pending_redeem_8 -vvv 
    function test_property_user_cannot_mutate_pending_redeem_8() public {

        shortcut_deployNewTokenPoolAndShare(2,356,true,false,true);

        hub_addShareClass(154591680653806130421);

        shortcut_deposit_and_claim(33321005491,6432384007748401500056681183121112,4369999,4369999,292948973611283239402029828536645829108380928802296476463930447206379624861);

        vault_requestRedeem_clamped(79314606078668675351414686616174580970519539374726669971771,2144343559908308263444127176406281849471917493390513644671787);

        property_user_cannot_mutate_pending_redeem();

    }

    // forge test --match-test test_vault_requestDeposit_clamped_18 -vvv 
    // NOTE: most likely an incorrect property spec which needs to include a check for if the recipient is a member instead of the controller
    function test_vault_requestDeposit_clamped_18() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,true);

        shortcut_request_deposit(0,1,0,0);

        switch_actor(1);

        address to = _getRandomActor(0);
        (bool isMember,) = fullRestrictions.isMember(_getShareToken(), _getActor());
        (bool isMemberTo,) = fullRestrictions.isMember(_getShareToken(), to);
        // caller of requestDeposit is not a member
        console2.log("actor isMember:", isMember);
        // recipient of requestDeposit is a member
        console2.log("to isMember:", isMemberTo);
        vault_requestDeposit_clamped(1,0);
    }

    // forge test --match-test test_property_loss_soundness_21 -vvv 
    function test_property_loss_soundness_21() public {

        shortcut_deployNewTokenPoolAndShare(11,2,true,false,false);

        shortcut_mint_sync(1,10001530783476391801262800);

        hub_createHolding_clamped(false,0,2,0,0);

        hub_addShareClass(1);

        property_loss_soundness();

    }

    // forge test --match-test test_property_accounting_and_holdings_soundness_22 -vvv 
    function test_property_accounting_and_holdings_soundness_22() public {

        shortcut_deployNewTokenPoolAndShare(3,1,false,false,false);

        hub_createHolding_clamped(true,0,0,0,0);

        hub_addShareClass(2);

        shortcut_mint_sync(1,1000928848737691948490550833297442);

        property_accounting_and_holdings_soundness();

    }

    // forge test --match-test test_vault_requestDeposit_23 -vvv 
    // NOTE: same as test_vault_requestDeposit_clamped_18
    function test_vault_requestDeposit_23() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,true);

        poolManager_updateMember(1524841016);

        switch_actor(1);

        vault_requestDeposit(1,0);

    }

    // forge test --match-test test_property_gain_soundness_25 -vvv 
    function test_property_gain_soundness_25() public {

        shortcut_deployNewTokenPoolAndShare(18,2,false,false,false);

        shortcut_mint_sync(1,1000408793793931473);

        hub_createHolding_clamped(false,0,0,2,0);

        hub_addShareClass(1);

        property_gain_soundness();

    }

    // forge test --match-test test_property_totalAssets_solvency_27 -vvv 
    function test_property_totalAssets_solvency_27() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,false);

        shortcut_deposit_sync(1,1);

        property_totalAssets_solvency();

    }
}
