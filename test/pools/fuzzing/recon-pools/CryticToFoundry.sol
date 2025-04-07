// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

import {Test, console2} from "forge-std/Test.sol";

import {PoolId, raw, newPoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";
import {JournalEntry} from "src/common/libraries/JournalEntryLib.sol";
import {AccountId} from "src/common/types/AccountId.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {Helpers} from "test/pools/fuzzing/recon-pools/utils/Helpers.sol";

// forge test --match-contract CryticToFoundry --match-path test/pools/fuzzing/recon-pools/CryticToFoundry.sol -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
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
        PoolId poolId = hub_createPool(address(this), 123, multiShareClass);

        return poolId;
    }
    
    function test_request_deposit() public returns (PoolId poolId, ShareClassId scId){
        poolId = _createPool();

        // request deposit
        scId = multiShareClass.previewNextShareClassId(poolId);
        assetId = newAssetId(123);

        // necessary setup via the PoolRouter
        hub_addShareClass(SC_SALT);
        hub_createHolding(scId.raw(), assetId.raw(), identityValuation, IS_LIABILITY, 0x01);
        hub_execute_clamped(poolId.raw());
        
        // request deposit
        hub_depositRequest(poolId.raw(), scId.raw(), 123, INVESTOR_AMOUNT);
        
        hub_approveDeposits(scId.raw(), assetId.raw(), APPROVED_INVESTOR_AMOUNT, identityValuation);
        hub_issueShares(scId.raw(), assetId.raw(), NAV_PER_SHARE);
        hub_execute_clamped(poolId.raw());

        // claim deposit
        hub_claimDeposit(poolId.raw(), scId.raw(), 123);

        return (poolId, scId);
    }

    function test_request_redeem() public returns (PoolId poolId, ShareClassId scId){
        (poolId, scId) = test_request_deposit();

        // request redemption
        hub_redeemRequest(poolId.raw(), scId.raw(), 123, SHARE_AMOUNT);

        // executed via the PoolRouter
        hub_approveRedeems(scId.raw(), 123, uint128(10000000));
        hub_revokeShares(scId.raw(), 123, d18(10000000), identityValuation);
        hub_execute_clamped(poolId.raw());

        // claim redemption
        hub_claimRedeem(poolId.raw(), scId.raw(), 123);
    }

    function test_shortcut_create_pool_and_update_holding() public {
        (PoolId poolId, ShareClassId scId) = shortcut_create_pool_and_holding(18, 123, SC_SALT, true, 0x01);
    
        assetId = newAssetId(123);
        hub_updateHolding(scId.raw(), assetId.raw());
        hub_execute_clamped(poolId.raw()); 
    }

    function test_shortcut_deposit_and_claim() public {
        shortcut_deposit_and_claim(18, 123, SC_SALT, true, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_redeem_and_claim() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_SALT, true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);
        
        shortcut_redeem_and_claim(poolId.raw(), scId.raw(), SHARE_AMOUNT, 123, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE, true);
    }

    function test_notify_share_class() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_SALT, true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);

        hub_notifyShareClass(CHAIN_CV, scId.raw(), SC_HOOK);
        hub_execute_clamped(poolId.raw());
    }

    function test_shortcut_deposit_claim_and_cancel() public {
        shortcut_deposit_claim_and_cancel(18, 123, SC_SALT, true, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_deposit_and_cancel() public {
        shortcut_deposit_and_cancel(18, 123, SC_SALT, true, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_deposit_redeem_and_claim() public {
        shortcut_deposit_redeem_and_claim(18, 123, SC_SALT, true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_deposit_cancel_redemption() public {
        shortcut_deposit_cancel_redemption(18, 123, SC_SALT, true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_cancel_redeem_request() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_SALT, true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);

        hub_redeemRequest(poolId.raw(), scId.raw(), 123, SHARE_AMOUNT);

        hub_cancelRedeemRequest(poolId.raw(), scId.raw(), 123);
    }

    function test_shortcut_update_holding() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_SALT, false, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);

        shortcut_update_holding(123, d18(20e18));
    }

    function test_shortcut_notify_share_class() public {
        shortcut_notify_share_class(18, 123, SC_SALT, false, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_request_deposit_and_cancel() public {
        shortcut_request_deposit_and_cancel(18, 123, SC_SALT, false, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_calling_claimDeposit_directly() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_SALT, true, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);

        multiShareClass.claimDeposit(poolId, scId, Helpers.addressToBytes32(address(this)), assetId);
    }

    function test_shortcut_create_pool_and_update_holding_amount() public {
        shortcut_create_pool_and_update_holding_amount(18, 123, SC_SALT, false, 0x01, 10e18, d18(20e18), 10e18, 10e18);
    }

    function test_shortcut_create_pool_and_update_holding_value() public {
        shortcut_create_pool_and_update_holding_value(18, 123, SC_SALT, false, 0x01, d18(20e18));
    }

    function test_shortcut_create_pool_and_update_journal() public {
        shortcut_create_pool_and_update_journal(18, 123, SC_SALT, true, 0x01, 3, 10e18, 10e18);
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

    // forge test --match-test test_property_total_pending_redeem_geq_sum_pending_user_redeem_1 -vvv 
    // function test_property_total_pending_redeem_geq_sum_pending_user_redeem_1() public {

    //     shortcut_deposit_redeem_and_claim(6,1,hex"4e554c",hex"4e554c",hex"4e554c",hex"",false,0,1,1,1,d18(1));

    //     hub_addShareClass(hex"4e554c",hex"4e554c",hex"4e554d",hex"");

    //     uint32 unsafePoolId;
    //     assembly {
    //         unsafePoolId := 4294967297
    //     }
    //     hub_execute_clamped(newPoolId(CENTIFUGE_CHAIN_ID, unsafePoolId));

    //     property_total_pending_redeem_geq_sum_pending_user_redeem();

    // }

    // function test_property_epochId_strictly_greater_than_any_latest_pointer_0() public {
    //     // First deposit and cancel
    //     shortcut_deposit_and_cancel(
    //         11, 
    //         231625,
    //         hex"4e554c", // NUL
    //         hex"4e554c", // NUL
    //         hex"4e554c", // NUL
    //         hex"",
    //         false,
    //         40,
    //         186274820,
    //         21064724530200365952599476352700964209,
    //         d18(7599135)
    //     );

    //     // Second deposit
    //     shortcut_deposit(155,17830390,hex"4e554c",hex"4e554c",hex"4e554c",hex"4e554c4e554c",false,8194,970970,89489842622818510814187366251834293,d18(8000723674554975097995165562484974407));

    //     // Request deposit and cancel
    //     shortcut_request_deposit_and_cancel(
    //         7,
    //         1972975575,
    //         hex"4e554c",
    //         hex"4e554c",
    //         hex"4e554c",
    //         hex"",
    //         false,
    //         1843183,
    //         1,
    //         123302058802511609732387337468765464524,
    //         d18(8)
    //     );

    //     // Create pool
    //     hub_createPool(
    //         address(0x00000000000000000000000000000000DeaDBeef),
    //         1023699,
    //         IShareClassManager(address(0x00000000000000000000000000000000DeaDBeef))
    //     );

    //     // Another request deposit and cancel
    //     shortcut_request_deposit_and_cancel(
    //         43,
    //         4370001,
    //         hex"4e554c",
    //         hex"4e554c",
    //         hex"4e554c",
    //         hex"",
    //         false,
    //         471154
    //     );

    //     // Create pool and update holding
    //     shortcut_create_pool_and_update_holding(
    //         12,
    //         4369999,
    //         hex"4e554c",
    //         hex"4e554c",
    //         hex"4e554c",
    //         hex"",
    //         false,
    //         4369999,
    //         19923839938303255665225135416549532091
    //     );

    //     // Deposit redeem and claim
    //     shortcut_deposit_redeem_and_claim(
    //         20,
    //         4369999,
    //         hex"4e554c",
    //         hex"4e554c",
    //         hex"4e554c",
    //         hex"",
    //         false,
    //         141414,
    //         94020619615429788657416085770482785784,
    //         250944993137682155761303781233570772911,
    //         90431958653484416703417109440850164570,
    //         340282366920938463463374607431768211454
    //     );

    //     // Add share class
    //     hub_addShareClass(
    //         hex"4e554c",
    //         hex"4e554c",
    //         hex"4e554c",
    //         hex""
    //     );

    //     // Add share class and holding
    //     shortcut_add_share_class_and_holding(
    //         newPoolId(CENTIFUGE_CHAIN_ID, 4294967302),
    //         hex"4e554c",
    //         "ffee414fb773cbbccce6fa",
    //         hex"4e554c",
    //         hex"4e554c",
    //         hex"",
    //         newAssetId(4370001),
    //         false,
    //         471154
    //     );

    //     // Check property
    //     property_epochId_strictly_greater_than_any_latest_pointer();
    // }
    
    // forge test --match-test test_property_total_pending_and_approved_1 -vvv 
    // function test_property_total_pending_and_approved_1() public {

    //     shortcut_deposit_and_cancel(13,34043220,hex"4e554c",hex"4e554c",hex"4e554c",hex"4e554c",false,30637,13664773,19288649223584090130307761987587327128,d18(574011315));

    //     shortcut_deposit(11,5101,hex"4e554c",hex"4e554c",hex"4e554d",hex"",false,5257,130,1846860118252866097254605272929929290,d18(4172300155504997405390627055677731889));

    //     console2.log("here 1");
    //     shortcut_request_deposit_and_cancel(7,5690176,hex"4e554c",hex"4e554c",hex"4e554e",hex"",false,2284391,7,46022909005592245925175521490221428955,d18(1));

    //     console2.log("here 2");
    //     hub_createPool(0x00000000000000000000000000000000DeaDBeef,1045068,IShareClassManager(address(0x00000000000000000000000000000000DeaDBeef)));

    //     console2.log("here 3");
    //     shortcut_request_deposit_and_cancel(
    //         251,
    //         4370001,
    //         "dd2631eb87857b5ea5e7a1e399e376c7cdb2695ed43ccc2636bb790f03c79ed7742d",
    //         "placeholder",
    //         hex"4e554f",
    //         hex"",
    //         false,
    //         1155411,
    //         227814729679397614415470769389471609097,
    //         271322649206203999124031367669938254,
    //         d18(273667469541612969616800276769160738)
    //     );

    //     console2.log("here 4");
    //     shortcut_deposit_redeem_and_claim(
    //         128,
    //         4369999,
    //         hex"4e554c4e554c4e554c4e554c4e554c4e554c",
    //         "placeholder",
    //         hex"4e55",
    //         hex"4e554c4e554cb2",
    //         false,
    //         779198,
    //         88070234755801575843541645624506187549,
    //         11658423912668426775158231870156279758,
    //         6164197134070440692987190595473481941,
    //         d18(79957049650174916258680150891679403807)
    //     );

    //     console2.log("here 5");
    //     hub_addShareClass(hex"4e554c",hex"4e554c",hex"4e554c",hex"");

    //     console2.log("here 6");
    //     shortcut_add_share_class_and_holding(
    //         PoolId.wrap(4294967302),
    //         hex"4e554c5372",
    //         hex"4e554c",
    //         hex"4e554c",
    //         hex"4e554c",
    //         ShareClassId.wrap(hex"4e554c"),
    //         AssetId.wrap(4370001),
    //         false,
    //         343206
    //     );

    //     console2.log("here 7");
    //     property_total_pending_and_approved();

    // }
}