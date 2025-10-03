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
        return shareClassManager.nowDepositEpoch(vault.scId(), spoke.vaultDetails(vault).assetId);
    }

    /// @dev Get the current redeem epoch for the current vault
    function nowRedeemEpoch() private view returns (uint32) {
        IBaseVault vault = IBaseVault(_getVault());
        return shareClassManager.nowRedeemEpoch(vault.scId(), spoke.vaultDetails(vault).assetId);
    }

    /// === SANITY CHECKS === ///
    function test_shortcut_deployNewTokenPoolAndShare_deposit() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        spoke_updateMember(type(uint64).max);

        vault_requestDeposit(1e18, 0);
    }

    function test_vault_deposit_and_fulfill() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

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
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, false);
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
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, 0);
    }

    function test_vault_deposit_and_redeem() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

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

    function test_shortcut_deposit_and_cancel_notify() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        shortcut_request_deposit(1e18, 1e18, 1e18, 0);

        uint32 _nowDepositEpoch = nowDepositEpoch();
        hub_approveDeposits(_nowDepositEpoch, 5e17);
        hub_issueShares(_nowDepositEpoch, 5e17);

        vault_cancelDepositRequest();

        hub_notifyDeposit(1);
    }

    function test_shortcut_deposit_queue_cancel() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        shortcut_deposit_queue_cancel(1e18, 1e18, 1e18, 5e17, 1e18, 0);

        hub_notifyDeposit(1);
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

        hub_notifySharePrice_clamped();
        hub_notifyAssetPrice();
        spoke_updateMember(type(uint64).max);
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

    function test_balanceSheet_deposit() public {
        // Deploy new token, pool and share class with default decimals
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);

        // price needs to be set in valuation before calling updatePricePoolPerShare
        transientValuation_setPrice_clamped(1e18);

        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        // Set up test values
        uint256 tokenId = 0; // For ERC20
        uint128 depositAmount = 1e18;

        asset_approve(address(balanceSheet), depositAmount);
        // Call balanceSheet_deposit with test values
        balanceSheet_deposit(tokenId, depositAmount);
    }

    function test_balanceSheet_issue_basic() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);
        
        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        spoke_updateMember(type(uint64).max);
        
        // Issue shares - verify no revert
        balanceSheet_issue(100e18);
    }

    function test_balanceSheet_revoke_basic() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);
        
        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        spoke_updateMember(type(uint64).max);
        
        // Issue shares first
        balanceSheet_issue(200e18);
        
        // Approve and revoke
        IBaseVault vault = IBaseVault(_getVault());
        vm.startPrank(_getActor());
        spoke.shareToken(vault.poolId(), vault.scId()).approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        balanceSheet_revoke(100e18);
    }

    function test_balanceSheet_withdraw_basic() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);
        
        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Deposit first
        asset_approve(address(balanceSheet), 200e18);
        balanceSheet_deposit(0, 200e18);
        
        // Withdraw
        balanceSheet_withdraw(0, 100e18);
    }

    function test_balanceSheet_submitQueuedShares_basic() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);
        
        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        spoke_updateMember(type(uint64).max);
        
        // Queue some shares
        balanceSheet_issue(100e18);
        
        // Submit queued shares
        balanceSheet_submitQueuedShares(0);
    }

    function test_balanceSheet_submitQueuedAssets_basic() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);
        
        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Queue some assets
        asset_approve(address(balanceSheet), 100e18);
        balanceSheet_deposit(0, 100e18);
        
        // Submit queued assets
        balanceSheet_submitQueuedAssets(0);
    }

    function test_queue_issue_revoke_sequence() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);
        
        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        spoke_updateMember(type(uint64).max);
        
        // Issue initial batch
        balanceSheet_issue(200e18);
        
        // Approve for revocations
        IBaseVault vault = IBaseVault(_getVault());
        vm.startPrank(_getActor());
        spoke.shareToken(vault.poolId(), vault.scId()).approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        // Execute sequence
        balanceSheet_revoke(50e18);
        balanceSheet_issue(75e18);
        balanceSheet_revoke(100e18);
    }

    function test_queue_deposit_withdraw_sequence() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);
        
        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        spoke_updateMember(type(uint64).max);
        
        // Approve for all operations
        asset_approve(address(balanceSheet), 1000e18);
        
        // Execute sequence
        balanceSheet_deposit(0, 200e18);
        balanceSheet_withdraw(0, 50e18);
        balanceSheet_deposit(0, 100e18);
    }
}
