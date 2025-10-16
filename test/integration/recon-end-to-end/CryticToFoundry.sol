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

    // forge test --match-test test_shortcut_cancel_redeem_clamped_0 -vvv
    function test_shortcut_cancel_redeem_clamped_0() public {
        shortcut_deployNewTokenPoolAndShare(
            18,
            39724410943193566942437836864763001383115667491159284883892,
            false,
            false,
            false,
            false
        );

        shortcut_mint_sync(1, 47666320813);

        shortcut_queue_redemption(1, 19235, 41897944682560144173);

        vault_deposit(1);

        shortcut_cancel_redeem_clamped(
            3,
            313835488417167055657,
            690240216577084952061679020521008104816194891247327445186846728
        );
    }

    // forge test --match-test test_asyncVault_maxWithdraw_3 -vvv
    // TODO: come back to this, might be a real issue
    function test_asyncVault_maxWithdraw_3() public {
        shortcut_deployNewTokenPoolAndShare(
            0,
            87456253102861400570196190842532000463762046048207829152,
            false,
            false,
            true,
            false
        );

        shortcut_deposit_sync(0, 0);

        balanceSheet_issue(2240061100030147735);

        shortcut_withdraw_and_claim_clamped(
            5185724309485154025505734544096073931221398836135925125465140960934,
            1,
            1902143307120540125351124365924111327437318010975259938589113922
        );

        asyncVault_maxWithdraw(0, 0, 57164611568627088);
    }

    // forge test --match-test test_property_asset_soundness_4 -vvv
    function test_property_asset_soundness_4() public {
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

    // forge test --match-test test_shortcut_cancel_redeem_immediately_issue_and_revoke_clamped_5 -vvv
    function test_shortcut_cancel_redeem_immediately_issue_and_revoke_clamped_5()
        public
    {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(0, 0);

        balanceSheet_issue(1);

        shortcut_cancel_redeem_immediately_issue_and_revoke_clamped(
            1,
            0,
            238367282084818977668128819095299490
        );
    }

    // forge test --match-test test_property_gain_soundness_9 -vvv
    function test_property_gain_soundness_9() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 1000053703097082978);

        balanceSheet_submitQueuedAssets(0);

        transientValuation_setPrice_clamped(0);

        hub_updateHoldingValue();

        transientValuation_setPrice_clamped(2000337288708108276);

        hub_updateHoldingValue();

        property_gain_soundness();
    }

    // forge test --match-test test_hub_notifyDeposit_clamped_12 -vvv
    function test_hub_notifyDeposit_clamped_12() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

        shortcut_deposit_queue_cancel(0, 0, 1, 1, 0, 0);

        hub_notifyDeposit_clamped(0);

        switch_actor(1);

        shortcut_deposit_queue_cancel(0, 0, 1, 1, 0, 0);

        switch_actor(0);

        vault_requestDeposit(1, 0);

        hub_notifyDeposit_clamped(0);
    }

    // forge test --match-test test_property_shareQueueFlipLogic_14 -vvv
    function test_property_shareQueueFlipLogic_14() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(0, 0);

        balanceSheet_issue(1);

        balanceSheet_submitQueuedShares(0);

        spoke_deployVault_clamped();

        property_shareQueueFlipLogic();
    }

    // forge test --match-test test_asyncVault_maxRedeem_18 -vvv
    function test_asyncVault_maxRedeem_18() public {
        shortcut_deployNewTokenPoolAndShare(
            39,
            578281926194066551989227579382852452747667104594196475927699918,
            false,
            false,
            false,
            false
        );

        shortcut_mint_sync(1, 119873638413);

        shortcut_queue_redemption(
            1,
            2032542148256948324,
            2438794333037897499498
        );

        vault_deposit(1);

        hub_notifyRedeem(1);

        asyncVault_maxRedeem(0, 0, 0);
    }

    // forge test --match-test test_property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive_19 -vvv
    function test_property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive_19()
        public
    {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

        shortcut_deposit_queue_cancel(0, 0, 2, 1, 0, 0);

        hub_notifyDeposit_clamped(0);

        spoke_deployVault(false);

        property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive();
    }

    // forge test --match-test test_property_total_yield_20 -vvv
    function test_property_total_yield_20() public {
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

    // forge test --match-test test_property_loss_soundness_22 -vvv
    function test_property_loss_soundness_22() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 1000368288321945536);

        balanceSheet_submitQueuedAssets(0);

        spoke_addShareClass(1, 2);

        hub_initializeHolding_clamped(false, 0, 2, 1, 1);

        property_loss_soundness();
    }

    // forge test --match-test test_vault_cancelRedeemRequest_23 -vvv
    function test_vault_cancelRedeemRequest_23() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 2);

        shortcut_withdraw_and_claim_clamped(1, 0, 0);

        vault_cancelRedeemRequest();
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
}
