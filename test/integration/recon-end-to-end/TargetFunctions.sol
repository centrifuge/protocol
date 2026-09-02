// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps

import {HubTargets} from "./targets/HubTargets.sol";
import {HookTargets} from "./targets/HookTargets.sol";
import {Properties} from "./properties/Properties.sol";
import {AdminTargets} from "./targets/AdminTargets.sol";
import {SpokeTargets} from "./targets/SpokeTargets.sol";
import {VaultTargets} from "./targets/VaultTargets.sol";
import {ManagerTargets} from "./targets/ManagerTargets.sol";
import {DoomsdayTargets} from "./targets/DoomsdayTargets.sol";
import {ShareTokenTargets} from "./targets/ShareTokenTargets.sol";
import {BalanceSheetTargets} from "./targets/BalanceSheetTargets.sol";

import {D18} from "../../../src/misc/types/D18.sol";

import {AssetId} from "../../../src/core/types/AssetId.sol";
import {PoolId, newPoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {IValuation} from "../../../src/core/hub/interfaces/IValuation.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";

import {MockERC20} from "@recon/MockERC20.sol";
import {ShareToken} from "../../../src/token/ShareToken.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

// Dependencies

// Component

/// @dev Local account-role taxonomy, used only to derive distinct account IDs for the fuzzer.
///      Maps onto core settlement slots ({AccountKind}) inside hub_initializeHolding/Liability.
enum AccountType {
    // AccountId(0) is the protocol's unset-slot sentinel and cannot be a real account
    // (Accounting.createAccount rejects it), so harness account ids start at 1.
    Unset,
    Asset,
    Equity,
    Loss,
    Gain,
    Expense,
    Liability
}

abstract contract TargetFunctions is
    BaseTargetFunctions,
    Properties,
    ShareTokenTargets,
    VaultTargets,
    SpokeTargets,
    ManagerTargets,
    HubTargets,
    BalanceSheetTargets,
    AdminTargets,
    DoomsdayTargets,
    HookTargets
{
    bool hasDoneADeploy;

    // ═══════════════════════════════════════════════════════════════
    // CANARIES
    // ═══════════════════════════════════════════════════════════════
    // ═══════════════════════════════════════════════════════════════
    // CANARIES
    // ═══════════════════════════════════════════════════════════════
    function canary_doesTokenGetDeployed() public view returns (bool) {
        if (RECON_TOGGLE_CANARY_TESTS) {
            return _getAssets().length < 10;
        }

        return true;
    }

    function canary_doesShareGetDeployed() public view returns (bool) {
        if (RECON_TOGGLE_CANARY_TESTS) {
            return _getShareTokens().length < 10;
        }

        return true;
    }

    function canary_doesVaultGetDeployed() public view returns (bool) {
        if (RECON_TOGGLE_CANARY_TESTS) {
            return _getVaults().length < 10;
        }

        return true;
    }

    // ═══════════════════════════════════════════════════════════════
    // SHORTCUT FUNCTIONS
    // ═══════════════════════════════════════════════════════════════
    /// @dev This is the main system setup function done like this to explore more possible states
    /// @dev Deploy new asset, add asset to pool, deploy share class, deploy vault
    function shortcut_deployNewTokenPoolAndShare(
        uint8 decimals,
        uint256 salt,
        bool isIdentityValuation,
        bool isDebitNormal,
        bool isAsyncVault,
        bool isLiability
    ) public returns (address _token, address _shareToken, address _vault, uint128 _assetId, bytes16 _scId) {
        // NOTE: TEMPORARY
        require(!hasDoneADeploy); // This bricks the function for this one for Medusa
        // Meaning we only deploy one token, one Pool, one share class

        if (RECON_USE_SINGLE_DEPLOY) {
            hasDoneADeploy = true;
        }

        if (RECON_USE_HARDCODED_DECIMALS) {
            decimals = 18;
        }

        // NOTE END TEMPORARY

        // Match the protocol's registerAsset bounds [0, 18]. The old upper bound of 24 was dead: the real
        // spoke.registerAsset enforces MAX_DECIMALS = 18, so 19-24 always reverted TooManyDecimals and wasted
        // fuzzer cycles. The lower bound now exercises 0-5 decimals after the [2,18] -> [0,18] relaxation.
        decimals = uint8(between(decimals, 0, 18));

        // 1. Deploy new token and register it as an asset
        _newAsset(decimals);
        PoolId _poolId;

        {
            spoke_registerAsset(_getAsset(), 0);
        }

        // 2. Deploy new pool and register it
        {
            _poolId = newPoolId(CENTRIFUGE_CHAIN_ID, uint48(POOL_ID_COUNTER));
            _hub_createPool(_poolId.raw(), _getActor(), _getAssetId().raw());

            spoke_addPool();

            // Register managers for this pool
            spokeRegistry.updateManager(_poolId, address(asyncRequestManager), true);
            spokeRegistry.updateManager(_poolId, address(syncManager), true);
            spokeRegistry.updateManager(_poolId, address(this), true);

            POOL_ID_COUNTER++;
        }

        // 3. Deploy new share class and register it
        {
            // have to get share class like this because addShareClass doesn't return it
            ShareClassId scIdTemp = shareClassManager.previewNextShareClassId(_poolId);
            _scId = scIdTemp.raw();

            hub_addShareClass(salt);

            // Share decimals must equal pool decimals: BatchRequestManager.shareToAssetAmount assumes it
            spoke_addShareClass(uint128(_scId), decimals);
            ShareToken(_getShareToken()).rely(address(spoke));
            ShareToken(_getShareToken()).rely(address(spoke));
        }

        // 4. Create accounts and holding/liability
        {
            IValuation valuation =
                isIdentityValuation ? IValuation(address(identityValuation)) : IValuation(address(transientValuation));

            // The hub values the holding immediately on initialize (Holdings.update -> valuation.getQuote), so
            // MockValuation needs a price set beforehand; IdentityValuation always returns 1.0 and needs no setup.
            if (!isIdentityValuation) {
                transientValuation.setPrice(_poolId, ShareClassId.wrap(_scId), _getAssetId(), D18.wrap(1e18));
            }

            hub_createAccount(uint32(AccountType.Asset), isDebitNormal);
            hub_createAccount(uint32(AccountType.Equity), isDebitNormal);
            hub_createAccount(uint32(AccountType.Loss), isDebitNormal);
            hub_createAccount(uint32(AccountType.Gain), isDebitNormal);

            if (isLiability) {
                // Create additional accounts needed for liability
                hub_createAccount(uint32(AccountType.Expense), isDebitNormal);
                hub_createAccount(uint32(AccountType.Liability), isDebitNormal);

                // Initialize liability holding
                hub_initializeLiability(valuation, uint32(AccountType.Expense), uint32(AccountType.Liability));
            } else {
                // Initialize regular holding
                hub_initializeHolding(
                    valuation,
                    uint32(AccountType.Asset),
                    uint32(AccountType.Equity),
                    uint32(AccountType.Loss),
                    uint32(AccountType.Gain)
                );
            }
        }

        // 4a. Register request manager on hub side BEFORE deploying vaults (critical for async operations)
        {
            hub_setRequestManager(_getPool().raw(), _scId, _getAssetId().raw(), address(asyncRequestManager));

            // Update balance sheet manager for async request manager
            hub_updateSpokeManager(CENTRIFUGE_CHAIN_ID, _getPool().raw(), address(asyncRequestManager), true);
            hub_updateSpokeManager(CENTRIFUGE_CHAIN_ID, _getPool().raw(), address(syncManager), true);
            hub_updateSpokeManager(CENTRIFUGE_CHAIN_ID, _getPool().raw(), address(this), true); // register admin actor as a balance sheet manager
        }

        // 5. Deploy new vault and register it (DeployAndLink atomically)
        {
            spoke_deployAndLinkVault(isAsyncVault);

            asyncRequestManager.rely(address(_getVault()));
        }

        // 6. Set max reserve for sync vaults to maximum value to allow unlimited deposits (instead of default zero
        // max deposit)
        if (!isAsyncVault) {
            (address asset, uint256 tokenId) = spokeRegistry.idToAsset(_getAssetId());
            syncManager.setMaxReserve(_getPool(), _getShareClassId(), asset, tokenId, type(uint128).max);
        }

        // 7. approve and mint initial amount of underlying asset to all actors
        address[] memory approvals = new address[](3);
        approvals[0] = address(spoke);
        approvals[1] = address(_getVault());
        _finalizeAssetDeployment(_getActors(), approvals, type(uint88).max);

        _token = _getAsset();
        _shareToken = _getShareToken();
        _vault = address(_getVault());
        _assetId = _getAssetId().raw();
        _scId = _getShareClassId().raw();

        return (_token, _shareToken, _vault, _assetId, _scId);
    }

    function shortcut_request_deposit(
        uint64,
        /* pricePoolPerShare */
        uint128 priceValuation,
        uint256 amount,
        uint256 toEntropy
    )
        public
    {
        transientValuation_setPrice_clamped(priceValuation);

        hub_notifySharePrice_clamped();
        hub_notifyAssetPrice();
        spoke_updateMember(type(uint64).max);

        vault_requestDeposit(amount, toEntropy);
    }

    function shortcut_deposit_sync(uint256 assets, uint128 navPerShare) public {
        IBaseVault vault = _getVault();

        navPerShare = _clampToPriceBand(navPerShare);

        transientValuation_setPrice_clamped(navPerShare);
        hub_updateSharePrice(vault.poolId().raw(), uint128(vault.scId().raw()), navPerShare);

        hub_notifyAssetPrice();
        hub_notifySharePrice(CENTRIFUGE_CHAIN_ID);

        spoke_updateMember(type(uint64).max);

        vault_deposit(assets);
    }

    function shortcut_mint_sync(uint256 shares, uint128 navPerShare) public {
        IBaseVault vault = _getVault();

        navPerShare = _clampToPriceBand(navPerShare);

        transientValuation_setPrice_clamped(navPerShare);
        hub_updateSharePrice(vault.poolId().raw(), uint128(vault.scId().raw()), navPerShare);

        hub_notifyAssetPrice();
        hub_notifySharePrice(CENTRIFUGE_CHAIN_ID);

        spoke_updateMember(type(uint64).max);

        vault_mint(shares);
    }

    function shortcut_deposit_and_claim(
        uint64 pricePoolPerShare,
        uint128 priceValuation,
        uint256 amount,
        uint128 navPerShare,
        uint256 toEntropy
    ) public {
        // Request 2x amount to ensure sufficient pending after claiming the approved amount
        // This prevents assertion failures in hub_notifyDeposit when pending delta < payment amount.
        // Bound to half the balance first: a raw uint256 draw overflows `amount * 2` and reverts the
        // whole shortcut, and the 2x request only outlives the claim while it stays funded.
        amount = amount % (_getTokenAndBalanceForVault() / 2 + 1);

        shortcut_request_deposit(pricePoolPerShare, priceValuation, amount * 2, toEntropy);

        uint32 depositEpoch = batchRequestManager.nowDepositEpoch(_getPool(), _getShareClassId(), _getAssetId());

        shortcut_approve_and_issue_shares_safe(uint128(amount), depositEpoch, navPerShare);

        hub_notifyDeposit(MAX_CLAIMS);
        vault_deposit(amount);
    }

    /// @dev Stops before the claim to leave a notified, unclaimed position, else the vault_max* properties stay dark
    function shortcut_deposit_and_notify(
        uint64 pricePoolPerShare,
        uint128 priceValuation,
        uint256 amount,
        uint128 navPerShare,
        uint256 toEntropy
    ) public {
        // Bound to half the balance: a raw uint256 draw overflows `amount * 2`, and the 2x request must stay
        // funded for pending to survive the approval.
        amount = amount % (_getTokenAndBalanceForVault() / 2 + 1);

        shortcut_request_deposit(pricePoolPerShare, priceValuation, amount * 2, toEntropy);

        uint32 depositEpoch = batchRequestManager.nowDepositEpoch(_getPool(), _getShareClassId(), _getAssetId());
        shortcut_approve_and_issue_shares_safe(uint128(amount), depositEpoch, navPerShare);

        hub_notifyDeposit(_maxDepositClaims());
    }

    function shortcut_deposit_and_cancel(
        uint64 pricePoolPerShare,
        uint128 priceValuation,
        uint256 amount,
        uint128,
        /* navPerShare */
        uint256 toEntropy
    ) public {
        shortcut_request_deposit(pricePoolPerShare, priceValuation, amount, toEntropy);

        vault_cancelDepositRequest();
    }

    function shortcut_deposit_queue_cancel(
        uint64 pricePoolPerShare,
        uint128 priceValuation,
        uint256 depositAmount,
        uint128 approveAmount,
        uint128 navPerShare,
        uint256 toEntropy
    ) public {
        shortcut_request_deposit(pricePoolPerShare, priceValuation, depositAmount, toEntropy);

        uint32 nowDepositEpoch = batchRequestManager.nowDepositEpoch(_getPool(), _getShareClassId(), _getAssetId());
        hub_approveDeposits(nowDepositEpoch, approveAmount);
        hub_issueShares(nowDepositEpoch, navPerShare);

        vault_cancelDepositRequest();
    }

    function shortcut_deposit_cancel_claim(
        uint64 pricePoolPerShare,
        uint128 priceValuation,
        uint256 amount,
        uint128,
        /* navPerShare */
        uint256 toEntropy
    ) public {
        shortcut_request_deposit(pricePoolPerShare, priceValuation, amount, toEntropy);

        vault_cancelDepositRequest();

        vault_claimCancelDepositRequest(toEntropy);
    }

    function shortcut_queue_deposit(
        uint64 pricePoolPerShare,
        uint128 priceValuation,
        uint256 depositAmount,
        uint128 navPerShare,
        uint256 toEntropy,
        uint128 shares
    ) public {
        shortcut_request_deposit(pricePoolPerShare, priceValuation, depositAmount, toEntropy);

        uint32 redeemEpoch = batchRequestManager.nowDepositEpoch(_getPool(), _getShareClassId(), _getAssetId());
        shortcut_approve_and_revoke_shares_safe(shares, redeemEpoch, navPerShare);
    }

    function shortcut_queue_redemption(uint256 shares, uint128 navPerShare, uint256 toEntropy) public {
        // Clamp shares to user's actual share balance to prevent insufficient balance errors
        IBaseVault vault = _getVault();
        uint256 userShareBalance = MockERC20(address(vault.share())).balanceOf(_getActor());

        // Request 2x shares to ensure sufficient pending after claiming the approved amount
        // NOTE: if-guard is correct here (shortcut, not clamped handler) — ensures requestShares <= balance
        uint256 requestShares = shares * 2;
        if (requestShares > userShareBalance) {
            requestShares = userShareBalance;
        }

        vault_requestRedeem(requestShares, toEntropy);

        uint32 redeemEpoch = batchRequestManager.nowRedeemEpoch(_getPool(), _getShareClassId(), _getAssetId());
        shortcut_approve_and_revoke_shares_safe(uint128(shares), redeemEpoch, navPerShare);
    }

    function shortcut_claim_withdrawal(uint256 assets, uint256 toEntropy) public {
        hub_notifyRedeem(MAX_CLAIMS);

        vault_withdraw(assets, toEntropy);
    }

    function shortcut_claim_redemption(uint256 shares, uint256 toEntropy) public {
        hub_notifyRedeem(MAX_CLAIMS);

        vault_redeem(shares, toEntropy);
    }

    function shortcut_redeem_and_claim(uint256 shares, uint128 navPerShare, uint256 toEntropy) public {
        shortcut_queue_redemption(shares, navPerShare, toEntropy);
        shortcut_claim_withdrawal(shares, toEntropy);
    }

    /// @dev Redeem twin of shortcut_deposit_and_notify: leaves a non-zero max for vault_maxWithdraw/maxRedeem
    function shortcut_redeem_and_notify(uint256 shares, uint128 navPerShare, uint256 toEntropy) public {
        shortcut_queue_redemption(shares, navPerShare, toEntropy);
        hub_notifyRedeem(_maxRedeemClaims());
    }

    function shortcut_withdraw_and_claim_clamped(uint256 shares, uint128 navPerShare, uint256 toEntropy) public {
        // clamp with share balance here because the maxRedeem is only updated after notifyRedeem
        shares %= (MockERC20(address(_getVault().share())).balanceOf(_getActor()) + 1);
        uint256 sharesAsAssets = _getVault().convertToAssets(shares);

        shortcut_queue_redemption(shares, navPerShare, toEntropy);
        shortcut_claim_withdrawal(sharesAsAssets, toEntropy);
    }

    function shortcut_redeem_and_claim_clamped(uint256 shares, uint128 navPerShare, uint256 toEntropy) public {
        // clamp with share balance here because the maxRedeem is only updated after notifyRedeem
        shares %= (MockERC20(address(_getVault().share())).balanceOf(_getActor()) + 1);
        shortcut_queue_redemption(shares, navPerShare, toEntropy);
        shortcut_claim_redemption(shares, toEntropy);
    }

    function shortcut_cancel_redeem_clamped(
        uint256 shares,
        uint128,
        /* navPerShare */
        uint256 toEntropy
    )
        public
    {
        // clamp with share balance here because the maxRedeem is only updated after notifyRedeem
        shares %= (MockERC20(address(_getVault().share())).balanceOf(_getActor()) + 1);
        vault_requestRedeem(shares, toEntropy);

        vault_cancelRedeemRequest();
    }

    function shortcut_cancel_redeem_immediately_issue_and_revoke_clamped(
        uint256 shares,
        uint128 navPerShare,
        uint256 toEntropy
    ) public {
        shares %= (MockERC20(address(_getVault().share())).balanceOf(_getActor()) + 1);
        shortcut_queue_redemption(shares, navPerShare, toEntropy);

        vault_cancelRedeemRequest();

        // After cancellation, check if there's still pending redeem to approve/revoke
        uint128 pendingRedeem = batchRequestManager.pendingRedeem(_getPool(), _getShareClassId(), _getAssetId());

        // Throw iff pending redeem == 0 to signal pruning
        uint32 redeemEpoch = batchRequestManager.nowRedeemEpoch(_getPool(), _getShareClassId(), _getAssetId());
        // Use safe approval function that will revert if pendingRedeem becomes 0
        shortcut_approve_and_revoke_shares_safe(pendingRedeem, redeemEpoch, navPerShare);
    }

    function shortcut_cancel_redeem_claim_clamped(
        uint256 shares,
        uint128,
        /* navPerShare */
        uint256 toEntropy
    )
        public
    {
        // clamp with share balance here because the maxRedeem is only updated after notifyRedeem
        shares %= (MockERC20(address(_getVault().share())).balanceOf(_getActor()) + 1);
        vault_requestRedeem(shares, toEntropy);

        vault_cancelRedeemRequest();
        vault_claimCancelRedeemRequest(toEntropy);
    }

    /// @dev property_assetShareProportionalityWithdrawals needs a manager withdrawal AND a revoke on the same
    ///      (pool, share class, asset), in that order: balanceSheet_revoke only accumulates revoked shares once
    ///      balanceSheet_withdraw has flagged the asset as tracked. The fuzzer never produced that conjunction,
    ///      leaving all three of the property's bounds unevaluated.
    /// @dev The share leg is the share-equivalent of the asset leg, so both the deposit- and withdrawal-side
    ///      proportionality properties hold by construction. Taking `shares` as an independent fuzzer input instead
    ///      made them fail on the shortcut's own arithmetic rather than on protocol behaviour.
    /// @dev Allowances go through the existing `asset_approve`/`token_approve` handlers rather than a local
    ///      `vm.prank`, so the shortcut carries no cheatcode dependency onto the fuzzer entry path.
    function shortcut_manager_withdraw_and_revoke(uint128 assetAmount) public {
        IBaseVault vault = _getVault();

        assetAmount = uint128(uint256(assetAmount) % (MockERC20(vault.asset()).balanceOf(_getActor()) + 1));
        uint128 shares = uint128(vault.convertToShares(assetAmount));

        asset_approve(address(spoke), assetAmount);
        balanceSheet_deposit(0, assetAmount);
        balanceSheet_issue(shares);

        balanceSheet_withdraw(0, assetAmount);
        token_approve(address(spoke), shares);
        balanceSheet_revoke(shares);
    }

    // ═══════════════════════════════════════════════════════════════
    // POOL ADMIN SHORTCUTS
    // ═══════════════════════════════════════════════════════════════
    function shortcut_approve_and_issue_shares(uint128 maxApproval, uint32 nowDepositEpochId, uint128 navPerShare)
        public
    {
        hub_approveDeposits(nowDepositEpochId, maxApproval);
        hub_issueShares(nowDepositEpochId, navPerShare);
    }

    function shortcut_approve_and_revoke_shares(uint128 maxApproval, uint32 epochId, uint128 navPerShare) public {
        hub_approveRedeems(epochId, maxApproval);
        hub_revokeShares(epochId, navPerShare);
    }

    // ═══════════════════════════════════════════════════════════════
    // SAFE APPROVAL SHORTCUTS (WITH EXPLICIT REVERTS)
    // ═══════════════════════════════════════════════════════════════
    function shortcut_approve_and_issue_shares_safe(uint128 maxApproval, uint32 nowDepositEpochId, uint128 navPerShare)
        public
    {
        uint128 pendingDeposit = batchRequestManager.pendingDeposit(_getPool(), _getShareClassId(), _getAssetId());
        require(pendingDeposit > 0, "InsufficientPending: pendingDeposit is 0");
        require(maxApproval <= pendingDeposit, "ExceedsPending: approval exceeds pending deposit");

        hub_approveDeposits(nowDepositEpochId, maxApproval);
        hub_issueShares(nowDepositEpochId, navPerShare);
    }

    function shortcut_approve_and_revoke_shares_safe(uint128 maxApproval, uint32 epochId, uint128 navPerShare) public {
        uint128 pendingRedeem = batchRequestManager.pendingRedeem(_getPool(), _getShareClassId(), _getAssetId());
        require(pendingRedeem > 0, "InsufficientPending: pendingRedeem is 0");
        require(maxApproval <= pendingRedeem, "ExceedsPending: approval exceeds pending redeem");

        hub_approveRedeems(epochId, maxApproval);
        hub_revokeShares(epochId, navPerShare);
    }

    // ═══════════════════════════════════════════════════════════════
    // TRANSIENT VALUATION
    // ═══════════════════════════════════════════════════════════════
    function transientValuation_setPrice(
        AssetId base,
        AssetId,
        /* quote */
        uint128 price
    )
        public
    {
        IBaseVault vault = _getVault();
        if (address(vault) == address(0)) return;

        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        transientValuation.setPrice(poolId, scId, base, D18.wrap(price));
    }

    // set the price of the asset in the transient valuation for a given pool
    function transientValuation_setPrice_clamped(uint128 price) public {
        AssetId assetId = _getAssetId();

        price = _clampToPriceBand(price);

        transientValuation_setPrice(assetId, _getAssetId(), price);
    }

    // === PRICE CONTROL HANDLERS === //

    /// @dev Force price to zero for testing zero-price scenarios
    function hub_setSharePrice(uint128 price) public asAdmin {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        hub.updateSharePrice{value: 0.1 ether}(poolId, scId, D18.wrap(price), uint64(block.timestamp));
    }

    /// @dev Force price to zero for testing zero-price scenarios
    function hub_setPriceZero() public {
        hub_setSharePrice(0);
    }

    /// @dev Set non-zero price with modulo clamping
    function hub_setPriceNonZero_clamped(uint128 price) public {
        price = uint128((uint256(price) % type(uint128).max) + 1);
        hub_setSharePrice(price);
    }

    /// @dev Set price to realistic DeFi range (0.001 to 1M)
    function hub_setPriceRealistic_clamped(uint128 price) public {
        uint128 minPrice = 1e15;
        uint128 maxPrice = 1e24;
        price = minPrice + uint128(uint256(price) % (maxPrice - minPrice + 1));
        hub_setSharePrice(price);
    }

    /// === Toggling State Variables === ///

    function toggle_MaxClaims(uint32 maxClaims) public {
        MAX_CLAIMS = maxClaims;
    }
}
