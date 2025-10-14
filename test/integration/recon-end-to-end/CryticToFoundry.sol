// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {MockERC20} from "@recon/MockERC20.sol";

import {ShareClassId} from "src/core/types/ShareClassId.sol";
import {IShareToken} from "src/core/spoke/interfaces/IShareToken.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {AssetId} from "src/core/types/AssetId.sol";
import {PoolId} from "src/core/types/PoolId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {AccountId, AccountType} from "src/core/hub/interfaces/IHub.sol";
import {PoolEscrow} from "src/core/spoke/PoolEscrow.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {IValuation} from "src/core/hub/interfaces/IValuation.sol";
import {D18} from "src/misc/types/D18.sol";
import {RequestMessageLib} from "src/vaults/libraries/RequestMessageLib.sol";
import {IShareToken} from "src/core/spoke/interfaces/IShareToken.sol";

import {Helpers} from "test/integration/recon-end-to-end/utils/Helpers.sol";
import {TargetFunctions} from "./TargetFunctions.sol";
import {CryticSanity} from "./CryticSanity.sol";

// forge test --match-contract CryticToFoundry -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    // Helper functions to handle bytes calldata parameters
    function hub_updateRestriction_wrapper(uint16 /* chainId */) external {
        // TODO: Fix bytes calldata issue - skipping for now
        // hub_updateRestriction(chainId, "");
    }

    function hub_updateRestriction_clamped_wrapper() external {
        // TODO: Fix bytes calldata issue - skipping for now
        // hub_updateRestriction_clamped("");
    }

    // forge test --match-test test_crytic -vvv
    function test_crytic() public {}

    /// === Potential Issues === ///

    // forge test --match-test test_property_assetQueueCounterConsistency_11 -vvv
    function test_property_assetQueueCounterConsistency_11() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

        shortcut_deposit_queue_cancel(0, 0, 1, 1, 0, 0);

        property_assetQueueCounterConsistency();
    }

    // forge test --match-test test_property_shareQueueFlipBoundaries_26 -vvv
    function test_property_shareQueueFlipBoundaries_26() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_request_deposit(0, 0, 0, 0);

        balanceSheet_issue(1);

        property_shareQueueFlipBoundaries();
    }

    // forge test --match-test test_property_escrow_share_balance_9 -vvv
    function test_property_escrow_share_balance_9() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

        // creates a deposit request which is handled on hub side then cancelled by user
        shortcut_deposit_queue_cancel(0, 0, 1, 1, 0, 0);

        // admin calls notifyDeposit to process the deposit on the Spoke side
        hub_notifyDeposit_clamped(0);

        property_escrow_share_balance();
    }

    // forge test --match-test test_property_shareQueueFlipLogic_11 -vvv
    function test_property_shareQueueFlipLogic_11() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(0, 0);

        balanceSheet_issue(1);

        balanceSheet_submitQueuedShares(0);

        spoke_deployVault_clamped();

        property_shareQueueFlipLogic();
    }

    // forge test --match-test test_property_user_cannot_mutate_pending_redeem_15 -vvv
    function test_property_user_cannot_mutate_pending_redeem_15() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

        shortcut_deposit_cancel_claim(0, 0, 1, 0, 0);

        balanceSheet_issue(2);

        shortcut_cancel_redeem_immediately_issue_and_revoke_clamped(1, 0, 0);

        hub_notifyRedeem_clamped(0);

        property_user_cannot_mutate_pending_redeem();
    }

    // forge test --match-test test_property_escrow_share_balance_4 -vvv
    function test_property_escrow_share_balance_4() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

        shortcut_deposit_queue_cancel(0, 0, 1, 1, 0, 0);

        hub_notifyDeposit_clamped(0);

        property_escrow_share_balance();
    }

    // forge test --match-test test_asyncVault_maxDeposit_5 -vvv
    function test_asyncVault_maxDeposit_5() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, true, false, true, false);

        shortcut_deposit_queue_cancel(
            0,
            0,
            70043326780006531036508,
            1,
            1,
            9067487205123489
        );

        hub_notifyDeposit_clamped(0);

        asyncVault_maxDeposit(0, 0, 0);
    }

    // forge test --match-test test_property_assetQueueCounterConsistency_10 -vvv
    function test_property_assetQueueCounterConsistency_10() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(0, 0);

        balanceSheet_noteDeposit(0, 1);

        property_assetQueueCounterConsistency();
    }

    // forge test --match-test test_property_total_yield_0 -vvv
    function test_property_total_yield_0() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 1000368288321945536);

        balanceSheet_submitQueuedAssets(0);

        transientValuation_setPrice_clamped(0);

        hub_updateHoldingValue();

        transientValuation_setPrice_clamped(2000033918479566113);

        hub_updateHoldingValue();

        hub_addShareClass(2);

        property_total_yield();
    }

    // forge test --match-test test_property_shareTokenSupplyConsistency_7 -vvv
    function test_property_shareTokenSupplyConsistency_7() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(0, 0);

        balanceSheet_issue(2);

        shortcut_cancel_redeem_immediately_issue_and_revoke_clamped(1, 0, 0);

        property_shareTokenSupplyConsistency();
    }

    // forge test --match-test test_property_deposit_share_balance_delta_8 -vvv
    function test_property_deposit_share_balance_delta_8() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, true, false, true, false);

        shortcut_deposit_queue_cancel(0, 0, 1, 1, 1, 0);

        hub_notifyDeposit_clamped(0);

        shortcut_mint_sync(1, 0);

        switch_actor(1);

        property_deposit_share_balance_delta();
    }

    // forge test --match-test test_hub_notifyDeposit_clamped_10 -vvv
    function test_hub_notifyDeposit_clamped_10() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

        shortcut_deposit_queue_cancel(0, 0, 1, 1, 0, 0);

        hub_notifyDeposit_clamped(0);

        switch_actor(1);

        shortcut_deposit_queue_cancel(0, 0, 1, 1, 0, 0);

        switch_actor(0);

        vault_requestDeposit(1, 0);

        hub_notifyDeposit_clamped(0);
    }

    // forge test --match-test test_asyncVault_maxMint_12 -vvv
    function test_asyncVault_maxMint_12() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, true, false, true, false);

        shortcut_deposit_queue_cancel(0, 0, 1, 1, 1, 0);

        hub_notifyDeposit_clamped(0);

        asyncVault_maxMint(0, 0, 0);
    }

    // forge test --match-test test_property_sum_of_received_leq_fulfilled_inductive_14 -vvv
    function test_property_sum_of_received_leq_fulfilled_inductive_14() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 10010101439671995);

        spoke_deployVault(true);

        switch_vault(0);

        shortcut_withdraw_and_claim_clamped(1, 0, 0);

        vault_cancelRedeemRequest();

        switch_vault(1);

        property_sum_of_received_leq_fulfilled_inductive();
    }

    // forge test --match-test test_property_assetQueueCounterConsistency_18 -vvv
    function test_property_assetQueueCounterConsistency_18() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(0, 0);

        balanceSheet_noteDeposit(0, 1);

        property_assetQueueCounterConsistency();
    }

    // forge test --match-test test_property_escrowBalanceSufficiency_19 -vvv
    function test_property_escrowBalanceSufficiency_19() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 0);

        balanceSheet_withdraw(0, 1);

        property_escrowBalanceSufficiency();
    }

    // forge test --match-test test_balanceSheet_withdraw_20 -vvv
    function test_balanceSheet_withdraw_20() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

        shortcut_deposit_cancel_claim(0, 0, 1, 0, 0);

        balanceSheet_noteDeposit(0, 1);

        balanceSheet_withdraw(0, 1);
    }

    // forge test --match-test test_doomsday_deposit_21 -vvv
    function test_doomsday_deposit_21() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, true, false, true, false);

        hub_updateSharePrice(0, 0, 473209924842317865);

        shortcut_deposit_queue_cancel(
            0,
            0,
            40372594246256258819060065534945294444693266406994695269609128,
            1,
            1,
            0
        );

        hub_notifyDeposit_clamped(0);

        doomsday_deposit(1);
    }

    // forge test --match-test test_property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive_22 -vvv
    function test_property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive_22()
        public
    {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

        shortcut_deposit_queue_cancel(0, 0, 2, 1, 0, 0);

        hub_notifyDeposit_clamped(0);

        spoke_deployVault(false);

        property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive();
    }

    // forge test --match-test test_property_loss_soundness_24 -vvv
    function test_property_loss_soundness_24() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 1000368288321945536);

        balanceSheet_submitQueuedAssets(0);

        spoke_addShareClass(1, 2, 0x0000000000000000000000000000000000000000);

        hub_initializeHolding_clamped(false, 0, 2, 1, 1);

        property_loss_soundness();
    }

    // forge test --match-test test_property_accounting_and_holdings_soundness_25 -vvv
    function test_property_accounting_and_holdings_soundness_25() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 0);

        balanceSheet_submitQueuedAssets(0);

        transientValuation_setPrice_clamped(1001115705050327642);

        add_new_asset(2);

        hub_updateHoldingValue();

        spoke_registerAsset_clamped();

        hub_notifyAssetPrice();

        hub_initializeHolding_clamped(false, 0, 1, 1, 1);

        property_accounting_and_holdings_soundness();
    }

    // forge test --match-test test_property_last_update_on_request_redeem_26 -vvv
    function test_property_last_update_on_request_redeem_26() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 10020231884082945);

        vault_requestRedeem_clamped(1, 0);

        switch_actor(1);

        property_last_update_on_request_redeem();
    }

    // forge test --match-test test_property_asset_soundness_27 -vvv
    function test_property_asset_soundness_27() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 0);

        balanceSheet_submitQueuedAssets(0);

        transientValuation_setPrice_clamped(1000204270152897072);

        add_new_asset(2);

        hub_updateHoldingValue();

        spoke_registerAsset_clamped();

        hub_initializeHolding_clamped(false, 1, 0, 0, 0);

        property_asset_soundness();
    }

    // forge test --match-test test_property_asset_balance_delta_29 -vvv
    function test_property_asset_balance_delta_29() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

        shortcut_request_deposit(0, 0, 1, 0);

        switch_actor(1);

        property_asset_balance_delta();
    }

    // forge test --match-test test_property_gain_soundness_30 -vvv
    function test_property_gain_soundness_30() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 1000053703097082978);

        balanceSheet_submitQueuedAssets(0);

        transientValuation_setPrice_clamped(0);

        hub_updateHoldingValue();

        transientValuation_setPrice_clamped(2000337288708108276);

        hub_updateHoldingValue();

        property_gain_soundness();
    }

    /// === Categorized Issues === ///

    // forge test --match-test test_doomsday_zeroPrice_noPanics_3 -vvv
    // NOTE: doesn't return 0 for maxDeposit if there's a nonzero maxReserve set
    // NOTE: see issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/3
    function test_doomsday_zeroPrice_noPanics_3() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        doomsday_zeroPrice_noPanics();
    }

    // forge test --match-test test_asyncVault_maxDeposit_11 -vvv
    // NOTE: see issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/4
    function test_asyncVault_maxDeposit_11() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, true, false, true, false);

        shortcut_deposit_queue_cancel(0, 0, 1, 1, 1, 0);

        hub_notifyDeposit_clamped(0);

        asyncVault_maxDeposit(0, 0, 0);
    }

    // forge test --match-test test_property_holdings_balance_equals_escrow_balance_13 -vvv
    // NOTE: see issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/5
    function test_property_holdings_balance_equals_escrow_balance_13() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        // Log the pool ID from the first vault
        PoolId firstPoolId = _getVault().poolId();
        console2.log("First vault poolId:", firstPoolId.raw());

        // Log the escrow address after first deployment
        address firstEscrow = address(poolEscrowFactory.escrow(firstPoolId));
        console2.log("Escrow address after first deployment:", firstEscrow);
        console2.log(
            "Escrow exists (code size > 0):",
            firstEscrow.code.length > 0
        );

        shortcut_deposit_sync(1, 10002467100007527);

        // Log before deploying second vault
        console2.log(
            "About to deploy second vault with spoke_deployVault_clamped()..."
        );
        spoke_deployVault_clamped();

        // Log the pool ID from the second vault
        PoolId secondPoolId = _getVault().poolId();
        console2.log("Second vault poolId:", secondPoolId.raw());
        console2.log(
            "Pool IDs are same:",
            firstPoolId.raw() == secondPoolId.raw()
        );

        // Log the escrow address after second deployment
        address secondEscrow = address(poolEscrowFactory.escrow(secondPoolId));
        console2.log("Escrow address after second deployment:", secondEscrow);
        console2.log("Escrow addresses are same:", firstEscrow == secondEscrow);
        console2.log(
            "Second escrow exists (code size > 0):",
            secondEscrow.code.length > 0
        );

        property_holdings_balance_equals_escrow_balance();
    }

    // forge test --match-test test_property_availableGtQueued_26 -vvv
    // NOTE: see issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/6
    // more of an admin gotcha that should be monitored
    function test_property_availableGtQueued_26() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 0);

        balanceSheet_withdraw(0, 1);

        property_availableGtQueued();
    }

    // forge test --match-test test_property_shareQueueFlagConsistency_31 -vvv
    // NOTE: see issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/7
    function test_property_shareQueueFlagConsistency_31() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(0, 0);

        balanceSheet_issue(1);

        balanceSheet_submitQueuedShares(0);

        shortcut_withdraw_and_claim_clamped(1, 0, 0);

        property_shareQueueFlagConsistency();
    }
}
