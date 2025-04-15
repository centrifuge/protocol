// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

import {Test, console2} from "forge-std/Test.sol";

import {PoolId, raw, newPoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {JournalEntry} from "src/hub/interfaces/IAccounting.sol";
import {AccountId} from "src/common/types/AccountId.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";

// forge test --match-contract CryticToFoundry --match-path test/hub/fuzzing/recon-hub/CryticToFoundry.sol -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    bytes32 INVESTOR = bytes32("Investor");
    string SC_NAME = "ExampleName";
    string SC_SYMBOL = "ExampleSymbol";
    uint256 SC_SALT = 123;
    bytes32 SC_HOOK = bytes32("ExampleHookData");
    uint32 CHAIN_CV = 6;

    uint128 constant INVESTOR_AMOUNT = 100 * 1e6; // USDC_C2
    uint128 constant SHARE_AMOUNT = 10 * 1e18; // Share from USD
    uint128 constant APPROVED_INVESTOR_AMOUNT = INVESTOR_AMOUNT / 5;
    uint128 constant APPROVED_SHARE_AMOUNT = SHARE_AMOUNT / 5;
    uint128 NAV_PER_SHARE = 2 * 1e18;

    PoolId poolId;
    ShareClassId scId;
    AssetId assetId;

    function setUp() public {
        setup();
    }

    /// Unit Tests 
    function _createPool() internal returns (PoolId) {
        // deploy new asset
        add_new_asset(18);

        //register asset 
        hub_registerAsset(123);

        // create pool 
        poolId = hub_createPool(address(this), 123);

        return poolId;
    }
    
    function test_request_deposit() public returns (PoolId, ShareClassId){
        poolId = _createPool();

        // request deposit
        scId = shareClassManager.previewNextShareClassId(poolId);
        assetId = newAssetId(123);

        // necessary setup via the PoolRouter
        hub_addShareClass(poolId.raw(), SC_SALT);
        hub_createAccount(poolId.raw(), ASSET_ACCOUNT, IS_DEBIT_NORMAL);
        hub_createAccount(poolId.raw(), EQUITY_ACCOUNT, IS_DEBIT_NORMAL);
        hub_createAccount(poolId.raw(), LOSS_ACCOUNT, IS_DEBIT_NORMAL);
        hub_createAccount(poolId.raw(), GAIN_ACCOUNT, IS_DEBIT_NORMAL);
        hub_createHolding(poolId.raw(), scId.raw(), identityValuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, LOSS_ACCOUNT, GAIN_ACCOUNT);
        
        // request deposit
        hub_depositRequest(poolId.raw(), scId.raw(), INVESTOR_AMOUNT);
        
        hub_approveDeposits(poolId.raw(), scId.raw(), assetId.raw(), APPROVED_INVESTOR_AMOUNT, identityValuation);
        hub_issueShares(poolId.raw(), scId.raw(), assetId.raw(), NAV_PER_SHARE);

        // claim deposit
        hub_claimDeposit(poolId.raw(), scId.raw(), assetId.raw());

        return (poolId, scId);
    }

    function test_request_redeem() public returns (PoolId, ShareClassId){
        (poolId, scId) = test_request_deposit();

        // request redemption
        hub_redeemRequest(poolId.raw(), scId.raw(), 123, SHARE_AMOUNT);

        // executed via the PoolRouter
        assetId = newAssetId(123);
        hub_approveRedeems(poolId.raw(), scId.raw(), assetId.raw(), uint128(10000000));
        hub_revokeShares(poolId.raw(), scId.raw(), assetId.raw(), 10000000, identityValuation);

        // claim redemption
        hub_claimRedeem(poolId.raw(), scId.raw(), 123);

        return (poolId, scId);
    }

    function test_shortcut_deposit_and_claim() public {
        shortcut_deposit_and_claim(18, 123, SC_SALT, true, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_redeem_and_claim() public {
        (poolId, scId) = shortcut_deposit_and_claim(18, 123, SC_SALT, true, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);
        
        shortcut_redeem_and_claim(poolId.raw(), scId.raw(), SHARE_AMOUNT, 123, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE, true);
    }

    function test_notify_share_class() public {
        (poolId, scId) = shortcut_deposit_and_claim(18, 123, SC_SALT, true, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);

        hub_notifyShareClass(poolId.raw(), CENTIFUGE_CHAIN_ID, scId.raw(), SC_HOOK);
    }

    function test_shortcut_deposit_claim_and_cancel() public {
        shortcut_deposit_claim_and_cancel(18, 123, SC_SALT, true, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_deposit_and_cancel() public {
        shortcut_deposit_and_cancel(18, 123, SC_SALT, true, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_deposit_redeem_and_claim() public {
        shortcut_deposit_redeem_and_claim(18, 123, SC_SALT, true, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_deposit_cancel_redemption() public {
        shortcut_deposit_cancel_redemption(18, 123, SC_SALT, true, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);
    }

    function test_cancel_redeem_request() public {
        (poolId, scId) = shortcut_deposit_and_claim(18, 123, SC_SALT, true, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);

        hub_redeemRequest(poolId.raw(), scId.raw(), 123, SHARE_AMOUNT);

        hub_cancelRedeemRequest(poolId.raw(), scId.raw(), 123);
    }

    function test_shortcut_notify_share_class() public {
        shortcut_notify_share_class(18, 123, SC_SALT, false, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_request_deposit_and_cancel() public {
        shortcut_request_deposit_and_cancel(18, 123, SC_SALT, false, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_calling_claimDeposit_directly() public {
        (poolId, scId) = shortcut_deposit_and_claim(18, 123, SC_SALT, true, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);

        shareClassManager.claimDeposit(poolId, scId, Helpers.addressToBytes32(address(this)), assetId);
    }

    function test_shortcut_create_pool_and_update_holding_amount_increase() public {
        shortcut_create_pool_and_update_holding_amount(18, 123, SC_SALT, false, 10e18, 20e18, 10e18, 10e18);
    }

    function test_shortcut_create_pool_and_update_holding_amount_decrease() public {
        // create the pool and update the holding amount
        shortcut_create_pool_and_update_holding_amount(18, 123, SC_SALT, false, 10e18, 20e18, 10e18, 10e18);
        
        // decrease the holding amount
        toggle_IsIncrease();
        hub_updateHoldingAmount_clamped(1,1,1,5e18,20e18,false);
    }

    function test_shortcut_create_pool_and_update_holding_value() public {
        shortcut_create_pool_and_update_holding_value(18, 123, SC_SALT, false);
    }

    function test_shortcut_create_pool_and_update_journal() public {
        shortcut_create_pool_and_update_journal(18, 123, SC_SALT, true, 3, 10e18, 10e18);
    }

    function test_hub_increaseShareIssuance() public {
        (poolId, scId) = test_request_deposit();

        hub_increaseShareIssuance(poolId.raw(), scId.raw(), NAV_PER_SHARE, SHARE_AMOUNT);
    }

    function test_hub_decreaseShareIssuance() public {
        (poolId, scId) = test_request_deposit();

        hub_increaseShareIssuance(poolId.raw(), scId.raw(), NAV_PER_SHARE, SHARE_AMOUNT);

        hub_decreaseShareIssuance(poolId.raw(), scId.raw(), NAV_PER_SHARE, SHARE_AMOUNT);
    }

    function test_hub_increaseShareIssuance_clamped() public {
        (poolId, scId) = test_request_deposit();

        hub_increaseShareIssuance_clamped(poolId.raw(), 2, NAV_PER_SHARE, SHARE_AMOUNT);
    }

    function test_hub_decreaseShareIssuance_clamped() public {
        (poolId, scId) = test_request_deposit();

        hub_increaseShareIssuance_clamped(poolId.raw(), 2, NAV_PER_SHARE, SHARE_AMOUNT);

        hub_decreaseShareIssuance_clamped(poolId.raw(), 2, NAV_PER_SHARE, SHARE_AMOUNT);
    }
    
    // forge test --match-test test_hub_depositRequest_0 -vvv 
    // function test_hub_depositRequest_0() public {

    //     (PoolId poolId, ShareClassId scId) = shortcut_create_pool_and_update_holding(6,1,hex"4e554c",hex"4e554c",hex"4e554c",hex"",false,0,d18(1));

    //     // downcasting to uint32 
    //     uint32 unsafePoolId;
    //     assembly {
    //         unsafePoolId := 4294967297
    //     }
        
    //     hub_depositRequest(newPoolId(CENTIFUGE_CHAIN_ID, unsafePoolId), scId, 0,0);

    //     // looks like this reverts because 4294967297 overflows the uint32 type 
    //     // shouldn't this make the handler revert though, this wouldn't even be callable with an overflowing input
    //     // hub_depositRequest(4294967297,hex"4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c",0,0);
    //     // hub.depositRequest(newPoolId(4294967297), scId, Helpers.addressToBytes32(_getActor()), newAssetId(123), 0);
    // }

    // forge test --match-test test_property_debited_transient_reset_6 -vvv 
    // NOTE: see this issue: https://github.com/Recon-Fuzz/centrifuge-review/issues/13#issuecomment-2752022094
    // function test_property_debited_transient_reset_6() public {

    //     shortcut_deposit(18,1,hex"4e554c",hex"4e554c",hex"4e554c",hex"",false,0,1,1,d18(1));

    //     property_debited_transient_reset();

    // }

    // forge test --match-test test_property_credited_transient_reset_7 -vvv 
    // NOTE: see this issue: https://github.com/Recon-Fuzz/centrifuge-review/issues/13#issuecomment-2752022094
    // function test_property_credited_transient_reset_7() public {

    //     shortcut_deposit_claim_and_cancel(18,1,hex"4e554c",hex"4e554c",hex"4e554c",hex"",false,0,1,1,d18(1));

    //     property_credited_transient_reset();

    // }

    // forge test --match-test test_hub_claimRedeem_clamped_3 -vvv 
    // TODO: seems like this might be a valid edge case, but need to understand the implications
    // it basically states that if a user calls claimRedeem before they have had their shares revoked, their lastUpdate gets out of sync with the epochId
    function test_hub_claimRedeem_clamped_3() public {

        shortcut_notify_share_class(6,1,1234,false,0,1,1);

        hub_claimRedeem_clamped(0,0);

    }

    // forge test --match-test test_hub_claimRedeem_clamped_0 -vvv 
    // TODO: come back to this to see if it actually messes up claiming flow if lastUpdate gets updated in middle of approve/revoke cycle
    function test_hub_claimRedeem_clamped_0() public {

        hub_createPool(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496,1);

        hub_addShareClass_clamped(0,1);

        hub_redeemRequest_clamped(0,0,1);

        hub_approveRedeems_clamped(0,0,1);

        hub_claimRedeem_clamped(0,0);

    }

    // forge test --match-test test_hub_redeemRequest_clamped_2 -vvv 
    function test_hub_redeemRequest_clamped_2() public {

        hub_createPool(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496,1);

        hub_addShareClass_clamped(0,1);

        hub_redeemRequest_clamped(0,0,1);

        hub_approveRedeems_clamped(0,0,1);

        hub_redeemRequest_clamped(0,0,0);

    }

    // forge test --match-test test_hub_claimDeposit_clamped_3 -vvv 
    function test_hub_claimDeposit_clamped_3() public {

        hub_createPool(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496,1);

        hub_addShareClass_clamped(0,1);

        hub_redeemRequest_clamped(0,0,1);

        hub_approveRedeems_clamped(0,0,1);

        hub_claimDeposit_clamped(0,0);

    }

    // test claiming in the middle of the approve/revoke cycle
    function test_hub_claimRedeem_in_middle_of_cycle() public {
        (poolId, scId) = shortcut_deposit_and_claim(18, 123, SC_SALT, true, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);

        // make a redeem request
        hub_redeemRequest_clamped(0,0,1);

        hub_approveRedeems_clamped(0,0,1);

        hub_claimRedeem_clamped(0,0);

        hub_revokeShares_clamped(0,0,1, false);

        hub_claimRedeem_clamped(0,0);

    }
}