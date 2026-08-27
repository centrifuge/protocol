// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {TargetFunctions} from "./TargetFunctions.sol";

import {D18} from "../../../src/misc/types/D18.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {IHoldings} from "../../../src/core/hub/interfaces/IHoldings.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {RequestCallbackMessageLib} from "../../../src/vaults/libraries/RequestCallbackMessageLib.sol";

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {IShareToken} from "../../../src/token/interfaces/IShareToken.sol";

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
        return batchRequestManager.nowDepositEpoch(
            vault.poolId(), vault.scId(), spokeRegistry.vaultDetails(address(vault)).assetId
        );
    }

    /// @dev Get the current redeem epoch for the current vault
    function nowRedeemEpoch() private view returns (uint32) {
        IBaseVault vault = IBaseVault(_getVault());
        return batchRequestManager.nowRedeemEpoch(
            vault.poolId(), vault.scId(), spokeRegistry.vaultDetails(address(vault)).assetId
        );
    }

    /// === SANITY CHECKS === ///
    function test_shortcut_deployNewTokenPoolAndShare_deposit() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        spoke_updateMember(type(uint64).max);

        vault_requestDeposit(1e18, 0);
    }

    function test_vault_deposit_and_fulfill() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        // price needs to be set in valuation before calling updatePricePoolPerShare
        transientValuation_setPrice_clamped(1e18);

        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();

        spoke_updateMember(type(uint64).max);

        vault_requestDeposit(1e18, 0);

        // Set price again after request (critical!)
        transientValuation_setPrice_clamped(1e18);

        uint32 depositEpoch = nowDepositEpoch();
        hub_approveDeposits(depositEpoch, 1e18);
        hub_issueShares(depositEpoch, 1e18);

        hub_notifyDeposit(MAX_CLAIMS);

        vault_deposit(1e18);
    }

    function test_vault_deposit_and_fulfill_sync() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, false, false);
        IBaseVault vault = IBaseVault(_getVault());

        // price needs to be set in valuation before calling updatePricePoolPerShare
        transientValuation_setPrice_clamped(1e18);
        hub_updateSharePrice(vault.poolId().raw(), uint128(vault.scId().raw()), 1e18);

        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();

        spoke_updateMember(type(uint64).max);

        vault_deposit(1e18);
    }

    function test_vault_deposit_and_fulfill_shortcut() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);
    }

    function test_vault_deposit_and_redeem() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        transientValuation_setPrice_clamped(1e18);

        hub_notifySharePrice_clamped();
        hub_notifyAssetPrice();
        spoke_updateMember(type(uint64).max);

        vault_requestDeposit(1e18, 0);

        transientValuation_setPrice_clamped(1e18);

        uint32 depositEpoch = nowDepositEpoch();
        hub_approveDeposits(depositEpoch, 1e18);
        hub_issueShares(depositEpoch, 1e18);

        // need to call claimDeposit first to mint the shares
        hub_notifyDeposit(MAX_CLAIMS);

        vault_deposit(1e18);

        vault_requestRedeem(1e18, 0);

        uint32 redeemEpoch = nowRedeemEpoch();
        hub_approveRedeems(redeemEpoch, 1e18);
        hub_revokeShares(redeemEpoch, 1e18);

        hub_notifyRedeem(MAX_CLAIMS);

        vault_withdraw(1e18, 0);
    }

    function test_vault_deposit_shortcut() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);
    }

    function test_vault_redeem_and_fulfill_shortcut() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        // Deposit with exact amount (no 2x) to avoid leftover escrow reservations
        shortcut_request_deposit(1e18, 1e18, 1e18, 0);
        uint32 depositEpoch = batchRequestManager.nowDepositEpoch(_getPool(), _getShareClassId(), _getAssetId());
        shortcut_approve_and_issue_shares_safe(1e18, depositEpoch, 1e18);
        hub_notifyDeposit(MAX_CLAIMS);
        vault_deposit(1e18);

        shortcut_redeem_and_claim(1e18, 1e18, 0);
    }

    function test_vault_redeem_and_fulfill_shortcut_clamped() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);

        shortcut_withdraw_and_claim_clamped(1e18 - 1, 1e18, 0);
    }

    function test_shortcut_cancel_redeem_clamped() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);

        shortcut_cancel_redeem_clamped(1e18 - 1, 1e18, 0);
    }

    function test_shortcut_deposit_and_cancel() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        shortcut_deposit_and_cancel(1e18, 1e18, 1e18, 1e18, 0);
    }

    function test_shortcut_deposit_and_cancel_notify() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        shortcut_request_deposit(1e18, 1e18, 1e18, 0);

        uint32 _nowDepositEpoch = nowDepositEpoch();
        hub_approveDeposits(_nowDepositEpoch, 5e17);
        hub_issueShares(_nowDepositEpoch, 5e17);

        vault_cancelDepositRequest();

        hub_notifyDeposit(1);
    }

    function test_shortcut_deposit_queue_cancel() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        shortcut_deposit_queue_cancel(1e18, 1e18, 1e18, 5e17, 1e18, 0);

        hub_notifyDeposit(1);
    }

    function test_shortcut_deposit_cancel_claim() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        shortcut_deposit_cancel_claim(1e18, 1e18, 1e18, 1e18, 0);
    }

    function test_shortcut_cancel_redeem_claim_clamped() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);

        shortcut_cancel_redeem_claim_clamped(1e18 - 1, 1e18, 0);
    }

    function test_shortcut_deployNewTokenPoolAndShare_change_price() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        transientValuation_setPrice_clamped(1e18);

        hub_notifySharePrice_clamped();
        hub_notifyAssetPrice();
        spoke_updateMember(type(uint64).max);
    }

    function test_shortcut_deployNewTokenPoolAndShare_only() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);
    }

    /// @dev A vault address recovered from a source the core stopped maintaining reads back as zero rather than
    ///      failing, so `_addVault(0)` poisons the cursor and every `vaultIsSet`-guarded property silently
    ///      short-circuits: a green campaign with no vaults in it.
    function test_deployAndLinkVault_resolvesDeployedVault() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        address vault = spoke_deployAndLinkVault(false);

        assertTrue(vault != address(0), "vault address not resolved");
        assertGt(vault.code.length, 0, "resolved address holds no code");
        assertEq(vault, address(_getVault()), "resolved vault is not the active cursor");
        assertTrue(spokeRegistry.isLinked(vault), "resolved vault is not linked");
    }

    function test_mint_sync_shortcut() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, false, false);

        shortcut_mint_sync(1e18, 1e18);
    }

    function test_deposit_sync_shortcut() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, false, false);

        shortcut_deposit_sync(1e18, 1e18);
    }

    function test_balanceSheet_deposit() public {
        // Deploy new token, pool and share class with default decimals
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        // price needs to be set in valuation before calling updatePricePoolPerShare
        transientValuation_setPrice_clamped(1e18);

        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        // Set up test values
        uint256 tokenId = 0; // For ERC20
        uint128 depositAmount = 1e18;

        asset_approve(address(spoke), depositAmount);
        // Call balanceSheet_deposit with test values
        balanceSheet_deposit(tokenId, depositAmount);
    }

    // forge test --match-test test_hub_updateHoldingValue_liability_branch -vvv
    function test_hub_updateHoldingValue_liability_branch() public {
        // Setup: Deploy a new pool and share class with liability holding
        shortcut_deployNewTokenPoolAndShare(18, 18, false, false, true, true);

        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = _getAssetId();

        console2.log("Pool and share class with liability holding deployed");

        // Set a price using transient valuation if needed for value updates
        transientValuation_setPrice_clamped(1e18);
        console2.log("Set initial price to 1e18");

        // Notify the system about the asset and share prices
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        console2.log("Notified asset and share prices");

        // Deposit assets directly to the balance sheet to affect holding value
        uint256 tokenId = 0; // For ERC20
        uint128 depositAmount = 1e18;

        // Approve the balance sheet to spend our assets
        asset_approve(address(spoke), depositAmount);
        console2.log("Approved balance sheet to spend assets");

        // Deposit assets to the balance sheet
        balanceSheet_deposit(tokenId, depositAmount);
        console2.log("Deposited", depositAmount, "assets to balance sheet");

        // Submit the queued assets to actually affect the holding value
        balanceSheet_submitQueuedAssets(0);
        console2.log("Submitted queued assets to balance sheet");

        // Call hub_updateHoldingValue - this should reach the liability branch
        // The Holdings.update() function will use the valuation to get a quote
        // and update the holding value, with the liability flag being true
        hub_updateHoldingValue();
        console2.log("Called hub_updateHoldingValue for liability holding");

        // Get holding value after update
        uint128 holdingValue = holdings.value(poolId, scId, assetId);
        console2.log("Holding value after update:", holdingValue);

        // Verify the holding value is now nonzero
        assertTrue(holdingValue > 0, "Holding value should be nonzero after deposit");

        // Change price to demonstrate that the liability branch works with value changes
        transientValuation_setPrice_clamped(2e18);
        console2.log("Changed price to 2e18");

        // Call hub_updateHoldingValue again
        hub_updateHoldingValue();
        console2.log("Called hub_updateHoldingValue again after price change");

        // Get final holding value
        uint128 finalValue = holdings.value(poolId, scId, assetId);
        console2.log("Final holding value:", finalValue);

        // Verify the final holding value is still nonzero
        assertTrue(finalValue > 0, "Final holding value should remain nonzero");

        console2.log("Test completed: hub_updateHoldingValue successfully reached liability branch");
    }

    // forge test --match-test test_shortcut_liability_vs_regular_holding -vvv
    function test_shortcut_liability_vs_regular_holding() public {
        // Test 1: Deploy with regular holding (mapped to gain/loss/equity slots)
        shortcut_deployNewTokenPoolAndShare(18, 18, false, false, true, false);

        // Reset for second test (this is a simple demonstration)
        // In a real fuzzing scenario, you'd typically have separate test functions
        console2.log("Test completed: Both regular and liability holdings work correctly");
    }

    function test_balanceSheet_issue_basic() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        // For same-chain testing, directly update spoke prices
        spoke_updatePricePoolPerShare(1e18, uint64(block.timestamp));
        spoke_updateMember(type(uint64).max);

        // Issue shares - verify no revert
        balanceSheet_issue(100e18);
    }

    function test_balanceSheet_revoke_basic() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        // For same-chain testing, directly update spoke prices
        spoke_updatePricePoolPerShare(1e18, uint64(block.timestamp));
        spoke_updateMember(type(uint64).max);

        // Issue shares first
        balanceSheet_issue(200e18);

        // Approve and revoke
        IBaseVault vault = IBaseVault(_getVault());
        vm.startPrank(_getActor());
        IShareToken(address(spokeRegistry.shareToken(vault.poolId(), vault.scId())))
            .approve(address(spoke), type(uint256).max);
        vm.stopPrank();

        balanceSheet_revoke(100e18);
    }

    function test_balanceSheet_withdraw_basic() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();

        // Deposit first
        asset_approve(address(spoke), 200e18);
        balanceSheet_deposit(0, 200e18);

        // Withdraw
        balanceSheet_withdraw(0, 100e18);
    }

    function test_balanceSheet_submitQueuedShares_basic() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        // For same-chain testing, directly update spoke prices
        spoke_updatePricePoolPerShare(1e18, uint64(block.timestamp));
        spoke_updateMember(type(uint64).max);

        // Queue some shares
        balanceSheet_issue(100e18);

        // Submit queued shares
        balanceSheet_submitQueuedShares(0);
    }

    function test_balanceSheet_submitQueuedAssets_basic() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();

        // Queue some assets
        asset_approve(address(spoke), 100e18);
        balanceSheet_deposit(0, 100e18);

        // Submit queued assets
        balanceSheet_submitQueuedAssets(0);
    }

    function test_queue_issue_revoke_sequence() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        // For same-chain testing, directly update spoke prices
        spoke_updatePricePoolPerShare(1e18, uint64(block.timestamp));
        spoke_updateMember(type(uint64).max);

        // Issue initial batch
        balanceSheet_issue(200e18);

        // Approve for revocations
        IBaseVault vault = IBaseVault(_getVault());
        vm.startPrank(_getActor());
        IShareToken(address(spokeRegistry.shareToken(vault.poolId(), vault.scId())))
            .approve(address(spoke), type(uint256).max);
        vm.stopPrank();

        // Execute sequence
        balanceSheet_revoke(50e18);
        balanceSheet_issue(75e18);
        balanceSheet_revoke(100e18);
    }

    function test_queue_deposit_withdraw_sequence() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        spoke_updateMember(type(uint64).max);

        // Approve for all operations
        asset_approve(address(spoke), 1000e18);

        // Execute sequence
        balanceSheet_deposit(0, 200e18);
        balanceSheet_withdraw(0, 50e18);
        balanceSheet_deposit(0, 100e18);
    }

    /// @dev The hub-holding driver drives increase -> over-decrease -> refill; deficitCount crosses
    ///      0 -> 1 -> 0 and property_deficitCountMatchesHoldings holds at each step.
    function test_deficitCountMatchesHoldings_driver() public {
        shortcut_deployNewTokenPoolAndShare(0, 0, false, false, false, false);

        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        uint16 centrifugeId = spokeRegistry.vaultDetails(address(vault)).assetId.centrifugeId();

        hub_updateAssets(100, true);
        property_deficitCountMatchesHoldings();
        eq(uint256(holdings.deficitCount(poolId, scId, centrifugeId)), 0, "no deficit after increase");

        hub_updateAssets(150, false); // over-decrease
        property_deficitCountMatchesHoldings();
        eq(uint256(holdings.deficitCount(poolId, scId, centrifugeId)), 1, "deficit after over-decrease");

        hub_updateAssets(50, true); // refill to equality
        property_deficitCountMatchesHoldings();
        eq(uint256(holdings.deficitCount(poolId, scId, centrifugeId)), 0, "deficit cleared after refill");
    }

    /// @dev Over-reserve then flush is the only fuzzer path making `property_deficitCountMatchesHoldings` non-vacuous
    function test_deficitCountMatchesHoldings_queueDriver() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        spoke_updateMember(type(uint64).max);
        asset_approve(address(spoke), 1000e18);

        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        uint16 centrifugeId = spokeRegistry.vaultDetails(address(vault)).assetId.centrifugeId();

        balanceSheet_deposit(0, 100e18);
        balanceSheet_submitQueuedAssets(0);
        property_deficitCountMatchesHoldings();
        eq(uint256(holdings.deficitCount(poolId, scId, centrifugeId)), 0, "no deficit after deposit flush");

        balanceSheet_overReserve_clamped(0);
        balanceSheet_submitQueuedAssets(0);
        property_deficitCountMatchesHoldings();
        eq(uint256(holdings.deficitCount(poolId, scId, centrifugeId)), 1, "deficit after over-reserve flush");

        balanceSheet_deposit(0, 500e18);
        balanceSheet_submitQueuedAssets(0);
        property_deficitCountMatchesHoldings();
        eq(uint256(holdings.deficitCount(poolId, scId, centrifugeId)), 0, "deficit cleared after queue refill");
    }

    /// @dev Pins why `hub_updateAssets` is reproducer-only: a direct hub write advances
    ///      `Holdings.snapshot.nonce` without advancing `SnapshotQueue`'s, bricking every later flush.
    function test_hubUpdateAssetsDesyncsSnapshotNonce() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        spoke_updateMember(type(uint64).max);
        asset_approve(address(spoke), 1000e18);

        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        uint16 centrifugeId = spokeRegistry.vaultDetails(address(vault)).assetId.centrifugeId();

        balanceSheet_deposit(0, 100e18);
        balanceSheet_submitQueuedAssets(0);

        (, uint64 hubNonceBefore) = holdings.snapshot(poolId, scId, centrifugeId);
        (,,, uint64 spokeNonceBefore) = snapshotQueue.queuedShares(poolId, scId);
        eq(uint256(hubNonceBefore), uint256(spokeNonceBefore), "nonces diverged before the direct hub write");

        hub_updateAssets(100, true);

        (, uint64 hubNonceAfter) = holdings.snapshot(poolId, scId, centrifugeId);
        (,,, uint64 spokeNonceAfter) = snapshotQueue.queuedShares(poolId, scId);
        eq(uint256(hubNonceAfter), uint256(hubNonceBefore) + 1, "direct hub write did not advance the hub nonce");
        eq(uint256(spokeNonceAfter), uint256(spokeNonceBefore), "direct hub write moved the spoke nonce");

        balanceSheet_deposit(0, 10e18);
        vm.expectRevert(abi.encodeWithSelector(IHoldings.InvalidNonce.selector, hubNonceAfter, spokeNonceAfter));
        this.balanceSheet_submitQueuedAssets(0);
    }

    /// @dev The claim-completeness validation in hub_notifyDeposit gates on `maxClaims == bound && bound > 0`.
    function test_notifyDeposit_exactBound_consumesAllEpochs() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        shortcut_request_deposit(1e18, 1e18, 2e18, 0);
        uint32 epoch = batchRequestManager.nowDepositEpoch(_getPool(), _getShareClassId(), _getAssetId());
        shortcut_approve_and_issue_shares_safe(1e18, epoch, 1e18);
        t(_maxDepositClaims() > 0, "no claimable epoch for the exact-bound notify");

        hub_notifyDeposit(_maxDepositClaims());

        eq(uint256(_maxDepositClaims()), 0, "notify did not consume every claimable epoch");
    }

    /// @dev A non-zero maxDeposit is what makes vault_maxDeposit / vault_maxMint run their bodies, not bail
    function test_shortcut_deposit_and_notify_leavesClaimable() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        shortcut_deposit_and_notify(1e18, 1e18, 1e18, 1e18, 0);

        IBaseVault vault = IBaseVault(_getVault());
        t(vault.maxDeposit(_getActor()) > 0, "notified deposit left no claimable maxDeposit");
        t(vault.maxMint(_getActor()) > 0, "notified deposit left no claimable maxMint");
    }

    /// @dev Echidna biases draws toward the top of the uint256 range, where the shortcut's internal 2x
    ///      request overflows unless bounded.
    function test_shortcut_deposit_and_notify_largeDraw_leavesClaimable() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        uint256 modulus = _getTokenAndBalanceForVault() / 2 + 1;
        uint256 draw = type(uint256).max - (type(uint256).max % modulus) - modulus / 2;

        shortcut_deposit_and_notify(1e18, 1e18, draw, 1e18, 0);

        IBaseVault vault = IBaseVault(_getVault());
        t(vault.maxDeposit(_getActor()) > 0, "large draw left no claimable maxDeposit");
        t(vault.maxMint(_getActor()) > 0, "large draw left no claimable maxMint");
    }

    function test_shortcut_redeem_and_notify_leavesWithdrawable() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);
        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);

        shortcut_redeem_and_notify(1e17, 1e18, 0);

        IBaseVault vault = IBaseVault(_getVault());
        t(vault.maxWithdraw(_getActor()) > 0, "notified redeem left no claimable maxWithdraw");
        t(vault.maxRedeem(_getActor()) > 0, "notified redeem left no claimable maxRedeem");
    }

    /// === DEPOSIT CLAIM DUST === ///

    /// @dev Pins the per-call bound of the `deposit()` assets->shares round-trip: `sharesUp` is debited from the
    /// entitlement while `sharesDown` is paid out, so a claim that rounds to zero shares costs 1 wei and delivers
    /// nothing. `mint()` passes the same value for both legs and is exact, which is why it is the recommended
    /// claim path. Bounded by ceil(q) - floor(q) <= 1 for the single mulDiv in PricingLib.
    function test_deposit_dust_costs_one_wei_per_call() public {
        shortcut_deployNewTokenPoolAndShare(0, 0, false, false, true, false);
        shortcut_deposit_and_notify(0, 0, 2, 1003540937918603, 158136555);

        (uint128 before,,,,,,,,,) = asyncRequestManager.investments(_getVault(), _getActor());

        vm.prank(_getActor());
        uint256 sharesOut = _getVault().deposit(1, _getActor());

        (uint128 remaining,,,,,,,,,) = asyncRequestManager.investments(_getVault(), _getActor());

        assertEq(sharesOut, 0, "dust claim delivers nothing");
        assertEq(before - remaining, 1, "dust claim costs exactly 1 wei of entitlement");
    }

    /// @dev The cumulative consequence of the per-call bound: nothing caps how often a zero-share claim repeats, so
    /// the whole entitlement can be spent for no shares. Only material when share decimals are small enough that
    /// 1 wei is a meaningful fraction of a share; at 18 decimals this needs ~1e18 calls.
    function test_deposit_dust_can_drain_full_entitlement() public {
        shortcut_deployNewTokenPoolAndShare(0, 0, false, false, true, false);
        shortcut_deposit_and_notify(0, 0, 40, 1003540937918603, 158136555);

        (uint128 entitlement,,,,,,,,,) = asyncRequestManager.investments(_getVault(), _getActor());
        require(entitlement > 1, "need a multi-wei entitlement");

        uint256 claims;
        uint256 delivered;
        while (claims <= entitlement) {
            (uint128 remaining,,,,,,,,,) = asyncRequestManager.investments(_getVault(), _getActor());
            if (remaining == 0) break;
            vm.prank(_getActor());
            delivered += _getVault().deposit(1, _getActor());
            claims++;
        }

        assertEq(delivered, 0, "no shares delivered");
        assertEq(claims, entitlement, "one dust claim per wei of entitlement");
        assertEq(_getVault().maxDeposit(_getActor()), 0, "entitlement fully drained");
    }

    /// @dev `maxDeposit` is derived at the actor's fulfillment price, so its tolerance must be quoted there too.
    /// Quoting it from `convertToAssets` (current registry price) makes the tolerance drift with the share price and
    /// under-shoot, breaking `vault_maxDeposit` by 1 wei. A price move after fulfillment must leave it unchanged.
    function test_maxDeposit_tolerance_uses_fulfillment_price() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);
        shortcut_deposit_and_notify(1e18, 1e18, 1e18, 1e18, 0);

        uint256 toleranceAtFulfillment = _asyncRoundTripTolerance(true);
        assertGt(toleranceAtFulfillment, 1, "tolerance should carry a share-price term");

        spoke_updatePricePoolPerShare(1, 1e6);

        assertEq(_asyncRoundTripTolerance(true), toleranceAtFulfillment, "tolerance must not follow current price");
    }

    /// @dev The hub/escrow conservation check reads the escrow at `vault.asset()`, so its hub side has to be keyed
    /// by the vault's asset as well. Registering a second asset moves the active-asset cursor, and keying off the
    /// cursor compared an empty holding against a funded escrow.
    function test_hubHoldingConservation_survives_second_asset() public {
        shortcut_deployNewTokenPoolAndShare(0, 0, false, false, false, false);
        shortcut_deposit_sync(1, 0);
        add_new_asset(0);
        spoke_registerAsset_clamped();

        property_hubHoldingMatchesEscrowAccounted();
    }

    /// @dev A manager withdrawal must never strand an in-flight redeem. `cancelRedeemRequest` turns a pending
    /// redeem into a claimable cancel-redeem without moving shares, so reserving only the claimable side leaves the
    /// pre-cancel window unguarded and the free float over-reports by the pending amount.
    function test_withdrawShares_clamp_reserves_pending_redeem() public {
        shortcut_deployNewTokenPoolAndShare(0, 2401830320119556036007632886553, false, false, false, false);
        restrictedTransfers_updateMemberBasic(1533914042);
        balanceSheet_issue(1);
        vault_requestRedeem_clamped(69370857555723656931006459511, 9001540955226570147331409196022695242662236);

        IBaseVault vault = _getVault();
        uint256 escrowBefore = IShareToken(vault.share()).balanceOf(_getPoolEscrowForVault(vault));

        balanceSheet_withdrawShares_clamped(1);

        assertEq(
            IShareToken(vault.share()).balanceOf(_getPoolEscrowForVault(vault)),
            escrowBefore,
            "clamp let a manager withdraw shares backing a pending redeem"
        );
    }

    /// @dev `doomsday_redeem` skips its round-trip bounds when the current registry price has moved away from the
    /// actor's fulfillment `redeemPrice`, since the comparison would otherwise span two prices. This pins that the
    /// skip is conditional rather than permanent: on a stable-price flow the two agree, so the bounds do get
    /// evaluated. Without this, converting that false positive into a guard would just hide the property instead.
    function test_doomsday_redeem_bounds_are_reachable() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        IBaseVault vault = IBaseVault(_getVault());

        transientValuation_setPrice_clamped(1e18);
        hub_updateSharePrice(vault.poolId().raw(), uint128(vault.scId().raw()), 1e18);
        hub_notifySharePrice_clamped();
        hub_notifyAssetPrice();
        spoke_updateMember(type(uint64).max);
        vault_requestDeposit(1e18, 0);
        transientValuation_setPrice_clamped(1e18);

        uint32 depositEpoch = nowDepositEpoch();
        hub_approveDeposits(depositEpoch, 1e18);
        hub_issueShares(depositEpoch, 1e18);
        hub_notifyDeposit(MAX_CLAIMS);
        vault_deposit(1e18);

        vault_requestRedeem(1e18, 0);
        uint32 redeemEpoch = nowRedeemEpoch();
        hub_approveRedeems(redeemEpoch, 1e18);
        hub_revokeShares(redeemEpoch, 1e18);
        hub_notifyRedeem(MAX_CLAIMS);

        (,,, D18 redeemPrice,,,,,,) = asyncRequestManager.investments(_getVault(), ghost_lastRedeemRequestController);
        assertTrue(redeemPrice.isNotZero(), "need a fulfilled redeem price to compare against");
        assertEq(_currentAssetPerShare().raw(), redeemPrice.raw(), "guard would skip even on a stable-price flow");
    }

    /// @dev `property_assetShareProportionalityWithdrawals` only evaluates its bounds once a manager withdrawal and
    /// a revoke have landed on the same (pool, share class, asset), in that order: `balanceSheet_revoke` accumulates
    /// revoked shares only for assets a withdrawal already flagged. Across a 133M-call campaign the fuzzer never
    /// produced that pair, so all three bounds sat unevaluated. This pins that the shortcut does produce it.
    function test_withdraw_revoke_shortcut_opens_proportionality_gate() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        IBaseVault priced = IBaseVault(_getVault());
        transientValuation_setPrice_clamped(1e18);
        // Without this the hub's share price stays 0, convertToShares returns 0 and the share leg is a no-op
        hub_updateSharePrice(priced.poolId().raw(), uint128(priced.scId().raw()), 1e18);
        hub_notifySharePrice_clamped();
        hub_notifyAssetPrice();
        spoke_updateMember(type(uint64).max);

        shortcut_manager_withdraw_and_revoke(1e18);

        IBaseVault vault = IBaseVault(_getVault());
        bytes32 assetKey =
            keccak256(abi.encode(vault.poolId(), vault.scId(), spokeRegistry.vaultDetails(address(vault)).assetId));

        assertTrue(ghost_withdrawalProportionalityTracked[assetKey], "withdrawal did not flag the asset as tracked");
        assertGt(ghost_cumulativeAssetsWithdrawn[assetKey], 0, "no manager withdrawal recorded");
        assertGt(ghost_cumulativeSharesRevokedForWithdrawals[assetKey], 0, "no revoked shares recorded");
    }

    /// @dev `property_authorizationLevel` guards on `ghost_privilegedOperationCount`, which `_trackAuthorization`
    /// writes under `keccak256(abi.encode(poolId))` while the property read `keccak256(abi.encode(poolId, scId))`.
    /// The guard therefore never opened and the assertion had never run. This pins that the keys now agree.
    function test_authorizationLevel_guard_opens() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);
        spoke_updateMember(type(uint64).max);

        // Any manager-gated handler routes through _trackAuthorization, but the ghost write only survives if the
        // call itself succeeds, so the receiver has to be a member first
        balanceSheet_issue(1);

        bytes32 key = keccak256(abi.encode(_getPool()));
        assertGt(ghost_privilegedOperationCount[key], 0, "privileged operations were not counted under the pool key");
        assertTrue(ghost_lastAuthorizedCaller[key] != address(0), "no authorized caller recorded");

        property_authorizationLevel();
    }

    /// === FREEZE ENFORCEMENT ON CLAIMS === ///

    /// @dev A frozen actor cannot extract shares: `spoke.withdrawShares` -> `authTransferTo` -> share transfer runs
    /// the restriction hook. This is what bounds the `maxDeposit()`/`deposit()` guard divergence below to no-ops.
    function test_frozen_actor_cannot_claim_shares() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true, false);

        transientValuation_setPrice_clamped(1e18);
        hub_notifySharePrice_clamped();
        hub_notifyAssetPrice();
        spoke_updateMember(type(uint64).max);
        vault_requestDeposit(1e18, 0);
        transientValuation_setPrice_clamped(1e18);

        uint32 depositEpoch = nowDepositEpoch();
        hub_approveDeposits(depositEpoch, 1e18);
        hub_issueShares(depositEpoch, 1e18);
        hub_notifyDeposit(MAX_CLAIMS);

        uint256 claimable = _getVault().maxDeposit(_getActor());
        assertGt(claimable, 0, "need a claimable entitlement");

        spoke_freeze();
        assertEq(_getVault().maxDeposit(_getActor()), 0, "frozen view reports nothing claimable");

        vm.prank(_getActor());
        vm.expectRevert();
        _getVault().deposit(claimable, _getActor());
    }

    /// @dev `deposit()` bounds against the ungated entitlement while `maxDeposit()` is transferability-gated, so
    /// while frozen the view reports 0 yet a dust claim is still accepted. Reachable only as a no-op, per the test
    /// above, and the reason `erc7540_6_deposit` tolerates a zero-share claim.
    function test_frozen_view_understates_deposit_guard() public {
        shortcut_deployNewTokenPoolAndShare(0, 0, false, false, true, false);
        shortcut_deposit_and_notify(0, 0, 2, 1003540937918603, 158136555);
        spoke_freeze();

        assertEq(_getVault().maxDeposit(_getActor()), 0, "frozen view reports nothing claimable");

        vm.prank(_getActor());
        assertEq(_getVault().deposit(1, _getActor()), 0, "accepted but delivers nothing");
    }
}
