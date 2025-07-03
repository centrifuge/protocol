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
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {TargetFunctions} from "./TargetFunctions.sol";
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";

// forge test --match-contract CryticToFoundry --match-path test/hub/fuzzing/recon-hub/CryticToFoundry.sol -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    bytes32 INVESTOR = bytes32("Investor");
    string SC_NAME = "ExampleName";
    string SC_SYMBOL = "ExampleSymbol";
    uint256 SC_SALT = 567;
    uint32 ISO_CODE = 123;
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

        assetId = newAssetId(123);
    }

    /// Unit Tests
    function _createPool() internal returns (PoolId) {
        // deploy new asset
        add_new_asset(18);

        // register asset
        // FIXME(wischli): In subsequent PR, support pool currency != assetId
        hub_registerAsset(assetId.raw());

        // create pool
        poolId = hub_createPool(address(this), 1, ISO_CODE);

        return poolId;
    }

    function test_request_deposit() public returns (PoolId, ShareClassId) {
        poolId = _createPool();

        // request deposit
        scId = shareClassManager.previewNextShareClassId(poolId);

        // necessary setup via the PoolRouter
        hub_addShareClass(poolId.raw(), SC_SALT);
        hub_createAccount(poolId.raw(), ASSET_ACCOUNT, IS_DEBIT_NORMAL);
        hub_createAccount(poolId.raw(), EQUITY_ACCOUNT, IS_DEBIT_NORMAL);
        hub_createAccount(poolId.raw(), LOSS_ACCOUNT, IS_DEBIT_NORMAL);
        hub_createAccount(poolId.raw(), GAIN_ACCOUNT, IS_DEBIT_NORMAL);
        hub_initializeHolding(
            poolId.raw(), scId.raw(), identityValuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, LOSS_ACCOUNT, GAIN_ACCOUNT
        );

        // request deposit
        hub_depositRequest(poolId.raw(), scId.raw(), INVESTOR_AMOUNT);

        uint32 depositEpochId = shareClassManager.nowDepositEpoch(scId, assetId);
        hub_approveDeposits(poolId.raw(), scId.raw(), assetId.raw(), depositEpochId, APPROVED_INVESTOR_AMOUNT);
        hub_issueShares(poolId.raw(), scId.raw(), assetId.raw(), depositEpochId, NAV_PER_SHARE);

        // claim deposit
        hub_notifyDeposit(poolId.raw(), scId.raw(), assetId.raw(), MAX_CLAIMS);

        return (poolId, scId);
    }

    function test_request_redeem() public returns (PoolId, ShareClassId) {
        (poolId, scId) = test_request_deposit();

        // request redemption
        hub_redeemRequest(poolId.raw(), scId.raw(), assetId.raw(), SHARE_AMOUNT);

        // executed via the PoolRouter
        uint32 redeemEpochId = shareClassManager.nowRedeemEpoch(scId, assetId);
        hub_approveRedeems(poolId.raw(), scId.raw(), assetId.raw(), redeemEpochId, APPROVED_SHARE_AMOUNT);
        hub_revokeShares(poolId.raw(), scId.raw(), redeemEpochId, APPROVED_SHARE_AMOUNT);

        // claim redemption
        hub_notifyRedeem(poolId.raw(), scId.raw(), assetId.raw(), MAX_CLAIMS);

        return (poolId, scId);
    }

    function test_shortcut_deposit_and_claim() public {
        shortcut_deposit_and_claim(
            18, ISO_CODE, SC_SALT, true, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE
        );
    }

    function test_shortcut_redeem_and_claim() public {
        (poolId, scId) = shortcut_deposit_and_claim(
            18, ISO_CODE, SC_SALT, true, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE
        );

        shortcut_redeem_and_claim(
            poolId.raw(), scId.raw(), SHARE_AMOUNT, ISO_CODE, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE, true
        );
    }

    function test_notify_share_class() public {
        (poolId, scId) = shortcut_deposit_and_claim(
            18, ISO_CODE, SC_SALT, true, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE
        );

        hub_notifyShareClass(poolId.raw(), CENTIFUGE_CHAIN_ID, scId.raw(), SC_HOOK);
    }

    function test_shortcut_deposit_claim_and_cancel() public {
        shortcut_deposit_claim_and_cancel(
            18, ISO_CODE, SC_SALT, true, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE
        );
    }

    function test_deposit_and_cancel() public {
        shortcut_deposit_and_cancel(
            18, ISO_CODE, SC_SALT, true, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE
        );
    }

    function test_shortcut_deposit_redeem_and_claim() public {
        shortcut_deposit_redeem_and_claim(18, ISO_CODE, SC_SALT, true, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_deposit_cancel_redemption() public {
        shortcut_deposit_cancel_redemption(18, ISO_CODE, SC_SALT, true, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);
    }

    function test_cancel_redeem_request() public {
        (poolId, scId) = shortcut_deposit_and_claim(
            18, ISO_CODE, SC_SALT, true, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE
        );

        hub_redeemRequest(poolId.raw(), scId.raw(), ISO_CODE, SHARE_AMOUNT);

        hub_cancelRedeemRequest(poolId.raw(), scId.raw());
    }

    function test_shortcut_notify_share_class() public {
        shortcut_notify_share_class(18, ISO_CODE, SC_SALT, false, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_request_deposit_and_cancel() public {
        shortcut_request_deposit_and_cancel(
            18, ISO_CODE, SC_SALT, false, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE
        );
    }

    function test_calling_claimDeposit_directly() public {
        (poolId, scId) =
            shortcut_deposit(18, ISO_CODE, SC_SALT, true, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);

        shareClassManager.claimDeposit(poolId, scId, CastLib.toBytes32(address(this)), assetId);
    }

    function test_shortcut_create_pool_and_update_holding_amount_increase() public {
        shortcut_create_pool_and_update_holding_amount(18, ISO_CODE, SC_SALT, false, 10e18, 20e18, 10e18, 10e18);
    }

    function test_shortcut_create_pool_and_update_holding_amount_decrease() public {
        // create the pool and update the holding amount
        shortcut_create_pool_and_update_holding_amount(18, ISO_CODE, SC_SALT, false, 10e18, 20e18, 10e18, 10e18);

        // decrease the holding amount
        toggle_IsIncrease();
        // hub_updateHoldingAmount_clamped(1,1,1,5e18,20e18,false);
    }

    function test_shortcut_create_pool_and_update_holding_value() public {
        shortcut_create_pool_and_update_holding_value(18, ISO_CODE, SC_SALT, false);
    }

    function test_shortcut_create_pool_and_update_journal() public {
        shortcut_create_pool_and_update_journal(18, ISO_CODE, SC_SALT, true, 3, 10e18, 10e18);
    }

    /// === REPRODUCERS === ///

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

    // forge test --match-test test_property_accounting_and_holdings_soundness_0 -vvv
    // NOTE: updateHoldingAmount causes an unsafe overflow in the accounting.sol contract
    function test_property_accounting_and_holdings_soundness_0() public {
        toggle_IsDebitNormal();

        shortcut_deposit_and_cancel(6, 1, 2, false, 1, 1, 1);

        // hub_updateHoldingAmount_clamped(0,0,0,1000019115540989997,1,true);

        hub_addShareClass_clamped(0, 1);

        property_accounting_and_holdings_soundness();
        console2.log("uint128 max value", type(uint128).max);
    }

    // forge test --match-test test_property_user_cannot_mutate_pending_redeem_2 -vvv
    // TODO: come back to this
    function test_property_user_cannot_mutate_pending_redeem_2() public {
        shortcut_deposit_and_claim(6, 1, 1, false, 1, 1, 1);

        hub_addShareClass_clamped(0, 2);

        hub_redeemRequest_clamped(0, 0, 1);

        property_user_cannot_mutate_pending_redeem();
    }

    // forge test --match-test test_hub_depositRequest_clamped_4 -vvv
    function test_hub_depositRequest_clamped_4() public {
        shortcut_deposit_claim_and_cancel(6, 1, 1, false, 1, 1, 1001192756088957775);

        console2.log("before depositRequest_clamped");
        hub_depositRequest_clamped(0, 0, 0);
    }

    // forge test --match-test test_property_total_yield_7 -vvv
    function test_property_total_yield_7() public {
        shortcut_create_pool_and_update_holding_amount(6, 1, 2, false, 1, 1000246008662738933, 0, 0);

        hub_addShareClass_clamped(0, 1);

        property_total_yield();
    }

    // forge test --match-test test_property_decrease_valuation_no_increase_in_accountValue_8 -vvv
    // TODO: investigate further, seems like a real breakage but not sure if it's a bug or not
    function test_property_decrease_valuation_no_increase_in_accountValue_8() public {
        shortcut_update_valuation(6, 1, 2, true);

        hub_addShareClass_clamped(0, 1);

        // hub_updateHoldingAmount_clamped(0,0,0,1,2000612857814007812,true);

        hub_updateHoldingValue_clamped(0, 0);

        property_decrease_valuation_no_increase_in_accountValue();
    }

    // forge test --match-test test_property_loss_soundness_10 -vvv
    // TODO: come back to this, need to confirm that the accounts created and checked are the same
    function test_property_loss_soundness_10() public {
        shortcut_create_pool_and_holding(6, 1, 2, false);

        // hub_updateHoldingAmount_clamped(0,0,0,1000041545513794237,1,true);

        hub_addShareClass_clamped(0, 1);

        property_loss_soundness();
    }
}
