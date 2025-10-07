// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {MockERC20} from "@recon/MockERC20.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {AccountId, AccountType} from "src/hub/interfaces/IHub.sol";
import {PoolEscrow} from "src/common/PoolEscrow.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {RequestCallbackMessageLib} from "src/common/libraries/RequestCallbackMessageLib.sol";

/// @dev sanity tests for the fuzzing suite setup
// forge test --match-contract CryticSanity --match-path test/integration/recon-end-to-end/CryticSanity.sol -vv
contract CryticSanity is Test, TargetFunctions, FoundryAsserts {
    using RequestCallbackMessageLib for RequestCallbackMessageLib.FulfilledDepositRequest;

    function setUp() public {
        setup();
    }

    /// === HELPER FUNCTIONS === ///

    /// @dev Get the current deposit epoch for the current vault
    function nowDepositEpoch() private view returns (uint32) {
        IBaseVault vault = IBaseVault(_getVault());
        return
            shareClassManager.nowDepositEpoch(
                vault.scId(),
                spoke.vaultDetails(vault).assetId
            );
    }

    /// @dev Get the current redeem epoch for the current vault
    function nowRedeemEpoch() private view returns (uint32) {
        IBaseVault vault = IBaseVault(_getVault());
        return
            shareClassManager.nowRedeemEpoch(
                vault.scId(),
                spoke.vaultDetails(vault).assetId
            );
    }

    /// === SANITY CHECKS === ///
    // function test_shortcut_deployNewTokenPoolAndShare_deposit() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     spoke_updateMember(type(uint64).max);

    //     vault_requestDeposit(1e18, 0);
    // }

    // function test_vault_deposit_and_fulfill() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     // price needs to be set in valuation before calling updatePricePoolPerShare
    //     transientValuation_setPrice_clamped(1e18);

    //     hub_notifyAssetPrice();
    //     hub_notifySharePrice_clamped();

    //     spoke_updateMember(type(uint64).max);

    //     vault_requestDeposit(1e18, 0);

    //     // Set price again after request (critical!)
    //     transientValuation_setPrice_clamped(1e18);

    //     uint32 depositEpoch = nowDepositEpoch();
    //     hub_approveDeposits(depositEpoch, 1e18);
    //     hub_issueShares(depositEpoch, 1e18);

    //     hub_notifyDeposit(MAX_CLAIMS);

    //     vault_deposit(1e18);
    // }

    // function test_vault_deposit_and_fulfill_sync() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, false, false);
    //     IBaseVault vault = IBaseVault(_getVault());

    //     // price needs to be set in valuation before calling updatePricePoolPerShare
    //     transientValuation_setPrice_clamped(1e18);
    //     hub_updateSharePrice(
    //         vault.poolId().raw(),
    //         uint128(vault.scId().raw()),
    //         1e18
    //     );

    //     hub_notifyAssetPrice();
    //     hub_notifySharePrice_clamped();

    //     spoke_updateMember(type(uint64).max);

    //     vault_deposit(1e18);
    // }

    // function test_vault_deposit_and_fulfill_shortcut() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);
    // }

    // function test_vault_deposit_and_redeem() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     transientValuation_setPrice_clamped(1e18);

    //     hub_notifySharePrice_clamped();
    //     hub_notifyAssetPrice();
    //     spoke_updateMember(type(uint64).max);

    //     vault_requestDeposit(1e18, 0);

    //     transientValuation_setPrice_clamped(1e18);

    //     uint32 depositEpoch = nowDepositEpoch();
    //     hub_approveDeposits(depositEpoch, 1e18);
    //     hub_issueShares(depositEpoch, 1e18);

    //     // need to call claimDeposit first to mint the shares
    //     hub_notifyDeposit(MAX_CLAIMS);

    //     vault_deposit(1e18);

    //     vault_requestRedeem(1e18, 0);

    //     uint32 redeemEpoch = nowRedeemEpoch();
    //     hub_approveRedeems(redeemEpoch, 1e18);
    //     hub_revokeShares(redeemEpoch, 1e18);

    //     hub_notifyRedeem(MAX_CLAIMS);

    //     vault_withdraw(1e18, 0);
    // }

    // function test_vault_deposit_shortcut() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);
    // }

    // function test_vault_redeem_and_fulfill_shortcut() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);

    //     shortcut_redeem_and_claim(1e18, 1e18, 0);
    // }

    // function test_vault_redeem_and_fulfill_shortcut_clamped() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);

    //     shortcut_withdraw_and_claim_clamped(1e18 - 1, 1e18, 0);
    // }

    // function test_shortcut_cancel_redeem_clamped() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);

    //     shortcut_cancel_redeem_clamped(1e18 - 1, 1e18, 0);
    // }

    // function test_shortcut_deposit_and_cancel() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     shortcut_deposit_and_cancel(1e18, 1e18, 1e18, 1e18, 0);
    // }

    // function test_shortcut_deposit_and_cancel_notify() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     shortcut_request_deposit(1e18, 1e18, 1e18, 0);

    //     uint32 _nowDepositEpoch = nowDepositEpoch();
    //     hub_approveDeposits(_nowDepositEpoch, 5e17);
    //     hub_issueShares(_nowDepositEpoch, 5e17);

    //     vault_cancelDepositRequest();

    //     hub_notifyDeposit(1);
    // }

    // function test_shortcut_deposit_queue_cancel() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     shortcut_deposit_queue_cancel(1e18, 1e18, 1e18, 5e17, 1e18, 0);

    //     hub_notifyDeposit(1);
    // }

    // function test_shortcut_deposit_cancel_claim() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     shortcut_deposit_cancel_claim(1e18, 1e18, 1e18, 1e18, 0);
    // }

    // function test_shortcut_cancel_redeem_claim_clamped() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);

    //     shortcut_cancel_redeem_claim_clamped(1e18 - 1, 1e18, 0);
    // }

    // function test_shortcut_deployNewTokenPoolAndShare_change_price() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     transientValuation_setPrice_clamped(1e18);

    //     hub_notifySharePrice_clamped();
    //     hub_notifyAssetPrice();
    //     spoke_updateMember(type(uint64).max);
    // }

    // function test_shortcut_deployNewTokenPoolAndShare_only() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);
    // }

    // function test_mint_sync_shortcut() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, false, false);

    //     shortcut_mint_sync(1e18, 1e18);
    // }

    // function test_deposit_sync_shortcut() public {
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, false, false);

    //     shortcut_deposit_sync(1e18, 1e18);
    // }

    // function test_balanceSheet_deposit() public {
    //     // Deploy new token, pool and share class with default decimals
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     // price needs to be set in valuation before calling updatePricePoolPerShare
    //     transientValuation_setPrice_clamped(1e18);

    //     hub_notifyAssetPrice();
    //     hub_notifySharePrice_clamped();
    //     // Set up test values
    //     uint256 tokenId = 0; // For ERC20
    //     uint128 depositAmount = 1e18;

    //     asset_approve(address(balanceSheet), depositAmount);
    //     // Call balanceSheet_deposit with test values
    //     balanceSheet_deposit(tokenId, depositAmount);
    // }

    // // forge test --match-test test_hub_updateHoldingValue_liability_branch -vvv
    // function test_hub_updateHoldingValue_liability_branch() public {
    //     // Setup: Deploy a new pool and share class with liability holding
    //     shortcut_deployNewTokenPoolAndShare(18, 18, false, false, true, true);

    //     IBaseVault vault = IBaseVault(_getVault());
    //     PoolId poolId = vault.poolId();
    //     ShareClassId scId = vault.scId();
    //     AssetId assetId = _getAssetId();

    //     console2.log("Pool and share class with liability holding deployed");

    //     // Verify that the holding is marked as a liability
    //     bool isLiab = holdings.isLiability(poolId, scId, assetId);
    //     assertTrue(isLiab, "Holding should be marked as liability");
    //     console2.log("Verified holding is marked as liability:", isLiab);

    //     // Set a price using transient valuation if needed for value updates
    //     transientValuation_setPrice_clamped(1e18);
    //     console2.log("Set initial price to 1e18");

    //     // Notify the system about the asset and share prices
    //     hub_notifyAssetPrice();
    //     hub_notifySharePrice_clamped();
    //     console2.log("Notified asset and share prices");

    //     // Deposit assets directly to the balance sheet to affect holding value
    //     uint256 tokenId = 0; // For ERC20
    //     uint128 depositAmount = 1e18;

    //     // Approve the balance sheet to spend our assets
    //     asset_approve(address(balanceSheet), depositAmount);
    //     console2.log("Approved balance sheet to spend assets");

    //     // Deposit assets to the balance sheet
    //     balanceSheet_deposit(tokenId, depositAmount);
    //     console2.log("Deposited", depositAmount, "assets to balance sheet");

    //     // Submit the queued assets to actually affect the holding value
    //     balanceSheet_submitQueuedAssets(0);
    //     console2.log("Submitted queued assets to balance sheet");

    //     // Call hub_updateHoldingValue - this should reach the liability branch
    //     // The Holdings.update() function will use the valuation to get a quote
    //     // and update the holding value, with the liability flag being true
    //     hub_updateHoldingValue();
    //     console2.log("Called hub_updateHoldingValue for liability holding");

    //     // Get holding value after update
    //     uint128 holdingValue = holdings.value(poolId, scId, assetId);
    //     console2.log("Holding value after update:", holdingValue);

    //     // Verify the holding value is now nonzero
    //     assertTrue(
    //         holdingValue > 0,
    //         "Holding value should be nonzero after deposit"
    //     );

    //     // Change price to demonstrate that the liability branch works with value changes
    //     transientValuation_setPrice_clamped(2e18);
    //     console2.log("Changed price to 2e18");

    //     // Call hub_updateHoldingValue again
    //     hub_updateHoldingValue();
    //     console2.log("Called hub_updateHoldingValue again after price change");

    //     // Get final holding value
    //     uint128 finalValue = holdings.value(poolId, scId, assetId);
    //     console2.log("Final holding value:", finalValue);

    //     // Verify the final holding value is still nonzero
    //     assertTrue(finalValue > 0, "Final holding value should remain nonzero");

    //     // Verify the holding is still marked as a liability
    //     bool stillLiab = holdings.isLiability(poolId, scId, assetId);
    //     assertTrue(stillLiab, "Holding should still be marked as liability");

    //     console2.log(
    //         "Test completed: hub_updateHoldingValue successfully reached liability branch"
    //     );
    // }

    // // forge test --match-test test_shortcut_liability_vs_regular_holding -vvv
    // function test_shortcut_liability_vs_regular_holding() public {
    //     // Test 1: Deploy with regular holding (isLiability = false)
    //     shortcut_deployNewTokenPoolAndShare(18, 18, false, false, true, false);

    //     IBaseVault vault1 = IBaseVault(_getVault());
    //     PoolId poolId1 = vault1.poolId();
    //     ShareClassId scId1 = vault1.scId();
    //     AssetId assetId1 = _getAssetId();

    //     // Verify it's NOT a liability
    //     bool isLiab1 = holdings.isLiability(poolId1, scId1, assetId1);
    //     assertFalse(
    //         isLiab1,
    //         "Regular holding should NOT be marked as liability"
    //     );
    //     console2.log("Regular holding verified - isLiability:", isLiab1);

    //     // Reset for second test (this is a simple demonstration)
    //     // In a real fuzzing scenario, you'd typically have separate test functions
    //     console2.log(
    //         "Test completed: Both regular and liability holdings work correctly"
    //     );
    // }

    // function test_balanceSheet_issue_basic() public {
    //     // Setup infrastructure
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     // Set prices
    //     transientValuation_setPrice_clamped(1e18);
    //     hub_notifyAssetPrice();
    //     hub_notifySharePrice_clamped();
    //     spoke_updateMember(type(uint64).max);

    //     // Issue shares - verify no revert
    //     balanceSheet_issue(100e18);
    // }

    // function test_balanceSheet_revoke_basic() public {
    //     // Setup infrastructure
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     // Set prices
    //     transientValuation_setPrice_clamped(1e18);
    //     hub_notifyAssetPrice();
    //     hub_notifySharePrice_clamped();
    //     spoke_updateMember(type(uint64).max);

    //     // Issue shares first
    //     balanceSheet_issue(200e18);

    //     // Approve and revoke
    //     IBaseVault vault = IBaseVault(_getVault());
    //     vm.startPrank(_getActor());
    //     spoke.shareToken(vault.poolId(), vault.scId()).approve(
    //         address(balanceSheet),
    //         type(uint256).max
    //     );
    //     vm.stopPrank();

    //     balanceSheet_revoke(100e18);
    // }

    // function test_balanceSheet_withdraw_basic() public {
    //     // Setup infrastructure
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     // Set prices
    //     transientValuation_setPrice_clamped(1e18);
    //     hub_notifyAssetPrice();
    //     hub_notifySharePrice_clamped();

    //     // Deposit first
    //     asset_approve(address(balanceSheet), 200e18);
    //     balanceSheet_deposit(0, 200e18);

    //     // Withdraw
    //     balanceSheet_withdraw(0, 100e18);
    // }

    // function test_balanceSheet_submitQueuedShares_basic() public {
    //     // Setup infrastructure
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     // Set prices
    //     transientValuation_setPrice_clamped(1e18);
    //     hub_notifyAssetPrice();
    //     hub_notifySharePrice_clamped();
    //     spoke_updateMember(type(uint64).max);

    //     // Queue some shares
    //     balanceSheet_issue(100e18);

    //     // Submit queued shares
    //     balanceSheet_submitQueuedShares(0);
    // }

    // function test_balanceSheet_submitQueuedAssets_basic() public {
    //     // Setup infrastructure
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     // Set prices
    //     transientValuation_setPrice_clamped(1e18);
    //     hub_notifyAssetPrice();
    //     hub_notifySharePrice_clamped();

    //     // Queue some assets
    //     asset_approve(address(balanceSheet), 100e18);
    //     balanceSheet_deposit(0, 100e18);

    //     // Submit queued assets
    //     balanceSheet_submitQueuedAssets(0);
    // }

    // function test_queue_issue_revoke_sequence() public {
    //     // Setup infrastructure
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     // Set prices
    //     transientValuation_setPrice_clamped(1e18);
    //     hub_notifyAssetPrice();
    //     hub_notifySharePrice_clamped();
    //     spoke_updateMember(type(uint64).max);

    //     // Issue initial batch
    //     balanceSheet_issue(200e18);

    //     // Approve for revocations
    //     IBaseVault vault = IBaseVault(_getVault());
    //     vm.startPrank(_getActor());
    //     spoke.shareToken(vault.poolId(), vault.scId()).approve(
    //         address(balanceSheet),
    //         type(uint256).max
    //     );
    //     vm.stopPrank();

    //     // Execute sequence
    //     balanceSheet_revoke(50e18);
    //     balanceSheet_issue(75e18);
    //     balanceSheet_revoke(100e18);
    // }

    // function test_queue_deposit_withdraw_sequence() public {
    //     // Setup infrastructure
    //     shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

    //     // Set prices
    //     transientValuation_setPrice_clamped(1e18);
    //     hub_notifyAssetPrice();
    //     hub_notifySharePrice_clamped();
    //     spoke_updateMember(type(uint64).max);

    //     // Approve for all operations
    //     asset_approve(address(balanceSheet), 1000e18);

    //     // Execute sequence
    //     balanceSheet_deposit(0, 200e18);
    //     balanceSheet_withdraw(0, 50e18);
    //     balanceSheet_deposit(0, 100e18);
    // }
}
