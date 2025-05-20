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

    function _logVals() internal {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        // get the account ids for each account
        AccountId assetAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));
        AccountId equityAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Equity));
        AccountId gainAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Gain));
        AccountId lossAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Loss));

        (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
        (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);
        (, uint128 gain) = accounting.accountValue(poolId, gainAccountId);
        (, uint128 loss) = accounting.accountValue(poolId, lossAccountId);

        // assets = accountValue(Equity) + accountValue(Gain) - accountValue(Loss)
        console2.log("assets:", assets);
        console2.log("equity:", equity);
        console2.log("gain:", gain);
        console2.log("loss:", loss);
        console2.log("equity + gain - loss:", equity + gain - loss);
    }

    // forge test --match-test test_property_asset_soundness_7 -vvv 
    function test_property_asset_soundness_7() public {

        shortcut_deployNewTokenPoolAndShare(2,2,false,false,false);

        shortcut_deposit_sync(1,1000597925025159896);

        console2.log("========= before create holding =========");
        _logVals();

        hub_createHolding_clamped(false,0,0,0,2);
        // the existing accounts have ids 1-4
        hub_createHolding(transientValuation, 1, 1, 1, 3);

        console2.log("========= after create holding =========");
        _logVals();

        hub_addShareClass(1);

        console2.log("========= after add share class =========");
        _logVals();

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

        // hub_createHolding_clamped(false,0,2,0,0);
        hub_createHolding_clamped(false,0,0,0,0);

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
    // NOTE: related to overwriting the existing holding
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

    // forge test --match-test test_property_loss_soundness_1 -vvv 
    // NOTE: related to overwriting the existing holding
    function test_property_loss_soundness_1() public {

        shortcut_deployNewTokenPoolAndShare(2,2,true,false,false);

        shortcut_deposit_sync(1,1);

        hub_addShareClass(1);

        hub_createHolding_clamped(false,0,2,0,0);

        property_loss_soundness();

    }

    // forge test --match-test test_property_equity_soundness_3 -vvv 
    // NOTE: related to overwriting the existing holding
    function test_property_equity_soundness_3() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,false);

        shortcut_deposit_sync(1,1);

        hub_addShareClass(2);

        hub_createHolding_clamped(false,0,0,0,2);

        property_equity_soundness();

    }

    // forge test --match-test test_property_price_per_share_overall_13 -vvv 
    function test_property_price_per_share_overall_13() public {

        shortcut_deployNewTokenPoolAndShare(12,1,false,false,false);

        shortcut_deposit_sync(1000037,1000604);

        property_price_per_share_overall();

    }

    // forge test --match-test test_property_total_yield_20 -vvv 
    function test_property_total_yield_20() public {

        shortcut_deployNewTokenPoolAndShare(2,2,true,false,false);

        shortcut_deposit_sync(1,1);

        hub_addShareClass(1);

        hub_createHolding_clamped(false,0,2,0,2);

        property_total_yield();

    }

    // forge test --match-test test_property_accounting_and_holdings_soundness_23 -vvv 
    // NOTE: related to overwriting the existing holding
    function test_property_accounting_and_holdings_soundness_23() public {

        shortcut_deployNewTokenPoolAndShare(9,2,false,false,false);

        shortcut_deposit_sync(1000190147,1001915877);

        hub_addShareClass(1);

        hub_initializeLiability_clamped(false,0,0);

        property_accounting_and_holdings_soundness();

    }

    // forge test --match-test test_property_asset_soundness_24 -vvv 
    // NOTE: related to overwriting the existing holding
    function test_property_asset_soundness_24() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,false);

        shortcut_deposit_sync(1,1);

        hub_createHolding_clamped(false,0,0,0,0);

        hub_addShareClass(2);

        property_asset_soundness();

    }

    // forge test --match-test test_property_sum_of_possible_account_balances_leq_escrow_25 -vvv 
    function test_property_sum_of_possible_account_balances_leq_escrow_25() public {

        shortcut_deployNewTokenPoolAndShare(3,1,true,false,false);

        shortcut_mint_sync(0,1000051331928575182604192358708530);

        property_sum_of_possible_account_balances_leq_escrow();
    }

    // forge test --match-test test_property_gain_soundness_28 -vvv 
    function test_property_gain_soundness_28() public {

        shortcut_deployNewTokenPoolAndShare(9,2,false,false,false);

        shortcut_deposit_sync(1000091037,1000792738);

        hub_addShareClass(1);

        hub_createHolding_clamped(false,0,0,2,0);

        property_gain_soundness();

    }

    // forge test --match-test test_doomsday_accountValue_differential_3 -vvv 
    function test_doomsday_accountValue_differential_3() public {

        doomsday_accountValue_differential(0,1);

    }

    // forge test --match-test test_property_totalAssets_solvency_9 -vvv 
    function test_property_totalAssets_solvency_9() public {

        shortcut_deployNewTokenPoolAndShare(15,1,true,false,true);

        shortcut_deposit_and_claim(1,0,45,1,0);

        shortcut_request_deposit(1045,0,0,0);

        property_totalAssets_solvency();

    }

    // forge test --match-test test_property_holdings_balance_equals_escrow_balance_15 -vvv 
    function test_property_holdings_balance_equals_escrow_balance_15() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,false);

        hub_initializeLiability_clamped(true,0,0);

        shortcut_mint_sync(1,10000478396350502620584353829305928);

        IBaseVault vault = IBaseVault(_getVault());
        address asset = vault.asset();
        AssetId assetId = hubRegistry.currency(vault.poolId());
        (uint128 holdingAssetAmount,,,) = holdings.holding(vault.poolId(), vault.scId(), assetId);
        console2.log("holdingAssetAmount in previous holding %e", holdingAssetAmount);

        // creating new holding overrides the existing holding for the given poolId, scId, and assetId
        // hub_createHolding_clamped(false,0,0,0,0);
        hub_createAccount(10, false);
        hub_createAccount(11, false);
        hub_createAccount(12, false);
        hub_createAccount(13, false);
        hub_createHolding(transientValuation, 10, 11, 12, 13);

        // NOTE: issue seems to be that the 
        vault = IBaseVault(_getVault());
        asset = vault.asset();
        assetId = hubRegistry.currency(vault.poolId());
        (holdingAssetAmount,,,) = holdings.holding(vault.poolId(), vault.scId(), assetId);
        console2.log("holdingAssetAmount in new holding %e", holdingAssetAmount);

        property_holdings_balance_equals_escrow_balance();

    }

    // forge test --match-test test_property_accounting_and_holdings_soundness_16 -vvv 
    function test_property_accounting_and_holdings_soundness_16() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,false);

        hub_createHolding_clamped(false,0,0,0,0);

        shortcut_deposit_sync(1,1000184571638551883);

        property_accounting_and_holdings_soundness();

    }

    // forge test --match-test test_vault_requestDeposit_17 -vvv 
    function test_vault_requestDeposit_17() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,true);

        shortcut_deposit_and_cancel(0,1,0,0,0);

        switch_actor(1);

        restrictedTransfers_freeze();

        vault_requestDeposit(1,0);

    }

    // forge test --match-test test_property_sum_of_minted_equals_total_supply_0 -vvv 
    function test_property_sum_of_minted_equals_total_supply_0() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,false);

        shortcut_mint_sync(2,10000505065913087102990555253782379);

        console2.log("share total supply before cancel redeem:", IShareToken(IBaseVault(_getVault()).share()).totalSupply());
        shortcut_cancel_redeem_clamped(1,0,0);
        console2.log("share total supply after cancel redeem:", IShareToken(IBaseVault(_getVault()).share()).totalSupply());
        console2.log("user shares after cancel redeem:", IShareToken(IBaseVault(_getVault()).share()).balanceOf(_getActor()));
        
        property_sum_of_minted_equals_total_supply();

    }

    // forge test --match-test test_property_price_per_share_overall_8 -vvv 
    function test_property_price_per_share_overall_8() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,false);

        shortcut_deposit_sync(1,1);

        property_price_per_share_overall();
    }

    // forge test --match-test test_property_sum_of_received_leq_fulfilled_9 -vvv 
    function test_property_sum_of_received_leq_fulfilled_9() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,true);

        shortcut_deposit_and_claim(1,0,1,1,0);

        vault_requestRedeem_clamped(1,0);

        vault_cancelRedeemRequest();

        vault_claimCancelRedeemRequest(0);

        property_sum_of_received_leq_fulfilled();

    }

    // forge test --match-test test_property_sum_of_pending_redeem_request_11 -vvv 
    function test_property_sum_of_pending_redeem_request_11() public {

        shortcut_deployNewTokenPoolAndShare(2,1,true,false,false);

        // mint 2 shares
        shortcut_mint_sync(2,10001493698620430928097305628073781);

        // burn 1 share
        shortcut_cancel_redeem_clamped(1,0,0);

        address poolEscrow = address(poolEscrowFactory.escrow(IBaseVault(_getVault()).poolId()));
        console2.log("pool escrow balance before notifyRedeem:", IERC20(IBaseVault(_getVault()).asset()).balanceOf(poolEscrow));
        // claim remaining 1 share
        hub_notifyRedeem(1);
        console2.log("pool escrow balance after notifyRedeem:", IERC20(IBaseVault(_getVault()).asset()).balanceOf(poolEscrow));

        property_sum_of_pending_redeem_request();

    }

    // forge test --match-test test_property_user_cannot_mutate_pending_redeem_17 -vvv 
    function test_property_user_cannot_mutate_pending_redeem_17() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,false);

        hub_initializeLiability_clamped(true,0,0);

        shortcut_mint_sync(2,10017567812503563737449888822777011);

        shortcut_cancel_redeem_clamped(1,0,0);

        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);
        bytes32 actor = CastLib.toBytes32(_getActor());

        console2.log("Before addShareClass - lastUpdate:", _before.ghostRedeemRequest[scId][assetId][actor].lastUpdate);
        console2.log("Before addShareClass - revoke:", _before.ghostEpochId[scId][assetId].revoke);
        hub_addShareClass(2);
        console2.log("After addShareClass - lastUpdate:", _before.ghostRedeemRequest[scId][assetId][actor].lastUpdate);
        console2.log("After addShareClass - revoke:", _before.ghostEpochId[scId][assetId].revoke);
       
        hub_notifySharePrice(0);
        console2.log("After notifySharePrice - lastUpdate:", _before.ghostRedeemRequest[scId][assetId][actor].lastUpdate);
        console2.log("After notifySharePrice - revoke:", _before.ghostEpochId[scId][assetId].revoke);

        property_user_cannot_mutate_pending_redeem();

    }
 
    
}
