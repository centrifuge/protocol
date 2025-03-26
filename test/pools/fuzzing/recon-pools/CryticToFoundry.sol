// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

import {Test, console2} from "forge-std/Test.sol";

import {PoolId, raw, newPoolId} from "src/pools/types/PoolId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {Helpers} from "test/pools/fuzzing/recon-pools/utils/Helpers.sol";

// forge test --match-contract CryticToFoundry --match-path test/pools/fuzzing/recon-pools/CryticToFoundry.sol -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    function test_create_pool() public {
        // deploy new asset
        add_new_asset(18);

        //register asset 
        poolRouter_registerAsset(123);

        // create pool 
        poolRouter_createPool(address(this), 123, multiShareClass);
    }

    bytes32 INVESTOR = bytes32("Investor");
    string SC_NAME = "ExampleName";
    string SC_SYMBOL = "ExampleSymbol";
    bytes32 SC_SALT = bytes32("ExampleSalt");
    bytes32 SC_HOOK = bytes32("ExampleHookData");
    uint32 CHAIN_CV = 6;

    uint128 constant INVESTOR_AMOUNT = 100 * 1e6; // USDC_C2
    uint128 constant SHARE_AMOUNT = 10 * 1e18; // Share from USD
    uint128 constant APPROVED_INVESTOR_AMOUNT = INVESTOR_AMOUNT / 5;
    uint128 constant APPROVED_SHARE_AMOUNT = SHARE_AMOUNT / 5;
    D18 NAV_PER_SHARE = d18(2, 1);

    PoolId poolId;
    ShareClassId scId;
    AssetId assetId;

    /// Unit Tests 
    function _createPool() internal returns (PoolId) {
        // deploy new asset
        add_new_asset(18);

        //register asset 
        poolRouter_registerAsset(123);

        // create pool 
        PoolId poolId = poolRouter_createPool(address(this), 123, multiShareClass);

        return poolId;
    }
    
    function test_request_deposit() public returns (PoolId poolId, ShareClassId scId){
        poolId = _createPool();

        // request deposit
        scId = multiShareClass.previewNextShareClassId(poolId);
        assetId = newAssetId(123);

        // necessary setup via the PoolRouter
        poolRouter_addShareClass(SC_NAME, SC_SYMBOL, SC_SALT, bytes(""));
        poolRouter_createHolding(scId, assetId, identityValuation, 0x01);
        poolRouter_execute_clamped(poolId);
        
        // request deposit
        poolRouter_depositRequest(poolId, scId, 123, INVESTOR_AMOUNT);
        
        poolRouter_approveDeposits(scId, assetId, APPROVED_INVESTOR_AMOUNT, identityValuation);
        poolRouter_issueShares(scId, assetId, NAV_PER_SHARE);
        poolRouter_execute_clamped(poolId);

        // claim deposit
        poolRouter_claimDeposit(poolId, scId, 123);

        return (poolId, scId);
    }

    function test_request_redeem() public returns (PoolId poolId, ShareClassId scId){
        (poolId, scId) = test_request_deposit();

        // request redemption
        poolRouter_redeemRequest(poolId, scId, 123, SHARE_AMOUNT);

        // executed via the PoolRouter
        poolRouter_approveRedeems(scId, 123, uint128(10000000));
        poolRouter_revokeShares(scId, 123, d18(10000000), identityValuation);
        poolRouter_execute_clamped(poolId);

        // claim redemption
        poolRouter_claimRedeem(poolId, scId, 123);
    }

    function test_shortcut_create_pool_and_update_holding() public {
        (PoolId poolId, ShareClassId scId) = shortcut_create_pool_and_holding(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01);
    
        assetId = newAssetId(123);
        poolRouter_updateHolding(scId, assetId);
        poolRouter_execute_clamped(poolId); 
    }

    function test_shortcut_deposit_and_claim() public {
        shortcut_deposit_and_claim(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_redeem_and_claim() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);
        
        shortcut_redeem_and_claim(poolId, scId, SHARE_AMOUNT, 123, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE, true);
    }

    function test_notify_share_class() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);

        poolRouter_notifyShareClass(CHAIN_CV, scId, SC_HOOK);
        poolRouter_execute_clamped(poolId);
    }

    function test_shortcut_deposit_claim_and_cancel() public {
        shortcut_deposit_claim_and_cancel(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_deposit_and_cancel() public {
        shortcut_deposit_and_cancel(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_deposit_redeem_and_claim() public {
        shortcut_deposit_redeem_and_claim(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_deposit_cancel_redemption() public {
        shortcut_deposit_cancel_redemption(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_cancel_redeem_request() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);

        poolRouter_redeemRequest(poolId, scId, 123, SHARE_AMOUNT);

        poolRouter_cancelRedeemRequest(poolId, scId, 123);
    }

    function test_shortcut_update_holding() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), false, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);

        shortcut_update_holding(123, d18(20e18));
    }

    function test_shortcut_notify_share_class() public {
        shortcut_notify_share_class(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), false, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_request_deposit_and_cancel() public {
        shortcut_request_deposit_and_cancel(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), false, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_calling_claimDeposit_directly() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);

        multiShareClass.claimDeposit(poolId, scId, Helpers.addressToBytes32(address(this)), assetId);
    }

    /// Reproducers 
    
    // forge test --match-test test_poolRouter_depositRequest_0 -vvv 
    function test_poolRouter_depositRequest_0() public {

        (PoolId poolId, ShareClassId scId) = shortcut_create_pool_and_update_holding(1,1,hex"4e554c",hex"4e554c",hex"4e554c",hex"",false,0,d18(1));

        // downcasting to uint32 
        uint32 unsafePoolId;
        assembly {
            unsafePoolId := 4294967297
        }
        
        poolRouter_depositRequest(newPoolId(unsafePoolId), scId, 0,0);

        // looks like this reverts because 4294967297 overflows the uint32 type 
        // shouldn't this make the handler revert though, this wouldn't even be callable with an overflowing input
        // poolRouter_depositRequest(4294967297,hex"4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c4e554c",0,0);
        // poolRouter.depositRequest(newPoolId(4294967297), scId, Helpers.addressToBytes32(_getActor()), newAssetId(123), 0);
    }

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

    // forge test --match-test test_property_total_pending_redeem_geq_sum_pending_user_redeem_1 -vvv 
    function test_property_total_pending_redeem_geq_sum_pending_user_redeem_1() public {

        shortcut_deposit_redeem_and_claim(6,1,hex"4e554c",hex"4e554c",hex"4e554c",hex"",false,0,1,1,1,d18(1));

        poolRouter_addShareClass(hex"4e554c",hex"4e554c",hex"4e554d",hex"");

        uint32 unsafePoolId;
        assembly {
            unsafePoolId := 4294967297
        }
        poolRouter_execute_clamped(newPoolId(unsafePoolId));

        property_total_pending_redeem_geq_sum_pending_user_redeem();

    }

    
}