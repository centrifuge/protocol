// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {console2} from "forge-std/console2.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {ShareToken} from "src/spoke/ShareToken.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId, newPoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {D18} from "src/misc/types/D18.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IValuation} from "src/common/interfaces/IValuation.sol";
import {PoolEscrow} from "src/common/PoolEscrow.sol";
import {MAX_MESSAGE_COST} from "src/common/interfaces/IGasService.sol";
import {RequestCallbackMessageLib} from "src/common/libraries/RequestCallbackMessageLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

// Component
import {ShareTokenTargets} from "./targets/ShareTokenTargets.sol";
import {VaultTargets} from "./targets/VaultTargets.sol";
import {SpokeTargets} from "./targets/SpokeTargets.sol";
import {ManagerTargets} from "./targets/ManagerTargets.sol";
import {Properties} from "./properties/Properties.sol";
import {AdminTargets} from "./targets/AdminTargets.sol";
import {HubTargets} from "./targets/HubTargets.sol";
import {ToggleTargets} from "./targets/ToggleTargets.sol";
import {DoomsdayTargets} from "./targets/DoomsdayTargets.sol";
import {BalanceSheetTargets} from "./targets/BalanceSheetTargets.sol";

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
    ToggleTargets,
    DoomsdayTargets
{
    bool hasDoneADeploy;

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
    )
        public
        returns (
            address _token,
            address _shareToken,
            address _vault,
            uint128 _assetId,
            bytes16 _scId
        )
    {
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

        decimals = uint8(between(decimals, 2, 24));

        // 1. Deploy new token and register it as an asset
        _newAsset(decimals);
        PoolId _poolId;

        {
            spoke_registerAsset(_getAsset(), 0);
        }

        // 2. Deploy new pool and register it
        {
            _poolId = newPoolId(CENTRIFUGE_CHAIN_ID, uint48(POOL_ID_COUNTER));
            hub_createPool(_poolId.raw(), _getActor(), _getAssetId().raw());

            spoke_addPool();

            POOL_ID_COUNTER++;
        }

        // 3. Deploy new share class and register it
        {
            // have to get share class like this because addShareClass doesn't return it
            ShareClassId scIdTemp = shareClassManager.previewNextShareClassId(
                _poolId
            );
            _scId = scIdTemp.raw();

            hub_addShareClass(salt);

            spoke_addShareClass(uint128(_scId), 18, address(fullRestrictions));
            ShareToken(_getShareToken()).rely(address(spoke));
            ShareToken(_getShareToken()).rely(address(balanceSheet));
        }

        // 4. Create accounts and holding/liability
        {
            IValuation valuation = isIdentityValuation
                ? IValuation(address(identityValuation))
                : IValuation(address(transientValuation));

            hub_createAccount(ASSET_ACCOUNT, isDebitNormal);
            hub_createAccount(EQUITY_ACCOUNT, isDebitNormal);
            hub_createAccount(LOSS_ACCOUNT, isDebitNormal);
            hub_createAccount(GAIN_ACCOUNT, isDebitNormal);
            
            if (isLiability) {
                // Create additional accounts needed for liability
                hub_createAccount(EXPENSE_ACCOUNT, isDebitNormal);
                hub_createAccount(LIABILITY_ACCOUNT, isDebitNormal);
                
                // Initialize liability holding
                hub_initializeLiability(
                    valuation,
                    EXPENSE_ACCOUNT,
                    LIABILITY_ACCOUNT
                );
            } else {
                // Initialize regular holding
                hub_initializeHolding(
                    valuation,
                    ASSET_ACCOUNT,
                    EQUITY_ACCOUNT,
                    LOSS_ACCOUNT,
                    GAIN_ACCOUNT
                );
            }
        }

        // 4a. Register request manager on hub side BEFORE deploying vaults (critical for async operations)
        {
            hub_setRequestManager(
                _getPool().raw(),
                _scId,
                _getAssetId().raw(),
                address(asyncRequestManager)
            );

            // Update balance sheet manager for async request manager
            hub_updateBalanceSheetManager(
                CENTRIFUGE_CHAIN_ID,
                _getPool().raw(),
                address(asyncRequestManager),
                true
            );
        }

        // 5. Deploy new vault and register it
        {
            spoke_deployVault(isAsyncVault);

            spoke_linkVault(address(_getVault()));

            asyncRequestManager.rely(address(_getVault()));
        }

        // 6. Set max reserve for sync vaults to maximum value to allow unlimited deposits (instead of default zero
        // max deposit)
        if (!isAsyncVault) {
            (address asset, uint256 tokenId) = spoke.idToAsset(
                _getAssetId()
            );
            syncManager.setMaxReserve(
                _getPool(),
                _getShareClassId(),
                asset,
                tokenId,
                type(uint128).max
            );
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
        uint64 /* pricePoolPerShare */,
        uint128 priceValuation,
        uint256 amount,
        uint256 toEntropy
    ) public {
        transientValuation_setPrice_clamped(priceValuation);

        hub_notifySharePrice_clamped();
        hub_notifyAssetPrice();
        spoke_updateMember(type(uint64).max);

        vault_requestDeposit(amount, toEntropy);
    }

    function shortcut_deposit_sync(uint256 assets, uint128 navPerShare) public {
        IBaseVault vault = _getVault();

        transientValuation_setPrice_clamped(navPerShare);
        hub_updateSharePrice(
            vault.poolId().raw(),
            uint128(vault.scId().raw()),
            navPerShare
        );

        hub_notifyAssetPrice();
        hub_notifySharePrice(CENTRIFUGE_CHAIN_ID);

        spoke_updateMember(type(uint64).max);

        vault_deposit(assets);
    }

    function shortcut_mint_sync(uint256 shares, uint128 navPerShare) public {
        IBaseVault vault = _getVault();

        transientValuation_setPrice_clamped(navPerShare);
        hub_updateSharePrice(
            vault.poolId().raw(),
            uint128(vault.scId().raw()),
            navPerShare
        );

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
        // This prevents assertion failures in hub_notifyDeposit when pending delta < payment amount
        shortcut_request_deposit(
            pricePoolPerShare,
            priceValuation,
            amount * 2,
            toEntropy
        );

        uint32 depositEpoch = shareClassManager.nowDepositEpoch(
            _getShareClassId(),
            _getAssetId()
        );
        shortcut_approve_and_issue_shares_safe(
            uint128(amount),
            depositEpoch,
            navPerShare
        );

        hub_notifyDeposit(MAX_CLAIMS);
        vault_deposit(amount);
    }

    function shortcut_deposit_and_cancel(
        uint64 pricePoolPerShare,
        uint128 priceValuation,
        uint256 amount,
        uint128 /* navPerShare */,
        uint256 toEntropy
    ) public {
        shortcut_request_deposit(
            pricePoolPerShare,
            priceValuation,
            amount,
            toEntropy
        );

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
        shortcut_request_deposit(
            pricePoolPerShare,
            priceValuation,
            depositAmount,
            toEntropy
        );

        uint32 nowDepositEpoch = shareClassManager.nowDepositEpoch(
            _getShareClassId(),
            _getAssetId()
        );
        hub_approveDeposits(nowDepositEpoch, approveAmount);
        hub_issueShares(nowDepositEpoch, navPerShare);

        vault_cancelDepositRequest();
    }

    function shortcut_deposit_cancel_claim(
        uint64 pricePoolPerShare,
        uint128 priceValuation,
        uint256 amount,
        uint128 /* navPerShare */,
        uint256 toEntropy
    ) public {
        shortcut_request_deposit(
            pricePoolPerShare,
            priceValuation,
            amount,
            toEntropy
        );

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
        shortcut_request_deposit(
            pricePoolPerShare,
            priceValuation,
            depositAmount,
            toEntropy
        );

        uint32 redeemEpoch = shareClassManager.nowDepositEpoch(
            _getShareClassId(),
            _getAssetId()
        );
        shortcut_approve_and_revoke_shares_safe(
            shares,
            redeemEpoch,
            navPerShare
        );
    }

    function shortcut_queue_redemption(
        uint256 shares,
        uint128 navPerShare,
        uint256 toEntropy
    ) public {
        // Clamp shares to user's actual share balance to prevent insufficient balance errors
        IBaseVault vault = _getVault();
        uint256 userShareBalance = MockERC20(address(vault.share())).balanceOf(
            _getActor()
        );

        // Request 2x shares to ensure sufficient pending after claiming the approved amount
        // But clamp to available balance
        uint256 requestShares = shares * 2;
        if (requestShares > userShareBalance) {
            requestShares = userShareBalance;
        }

        vault_requestRedeem(requestShares, toEntropy);

        uint32 redeemEpoch = shareClassManager.nowRedeemEpoch(
            _getShareClassId(),
            _getAssetId()
        );
        shortcut_approve_and_revoke_shares_safe(
            uint128(shares),
            redeemEpoch,
            navPerShare
        );
    }

    function shortcut_claim_withdrawal(
        uint256 assets,
        uint256 toEntropy
    ) public {
        hub_notifyRedeem(MAX_CLAIMS);

        vault_withdraw(assets, toEntropy);
    }

    function shortcut_claim_redemption(
        uint256 shares,
        uint256 toEntropy
    ) public {
        hub_notifyRedeem(MAX_CLAIMS);

        vault_redeem(shares, toEntropy);
    }

    function shortcut_redeem_and_claim(
        uint256 shares,
        uint128 navPerShare,
        uint256 toEntropy
    ) public {
        shortcut_queue_redemption(shares, navPerShare, toEntropy);
        shortcut_claim_withdrawal(shares, toEntropy);
    }

    function shortcut_withdraw_and_claim_clamped(
        uint256 shares,
        uint128 navPerShare,
        uint256 toEntropy
    ) public {
        // clamp with share balance here because the maxRedeem is only updated after notifyRedeem
        shares %= (MockERC20(address(_getVault().share()))
            .balanceOf(_getActor()) + 1);
        uint256 sharesAsAssets = _getVault().convertToAssets(
            shares
        );

        shortcut_queue_redemption(shares, navPerShare, toEntropy);
        shortcut_claim_withdrawal(sharesAsAssets, toEntropy);
    }

    function shortcut_redeem_and_claim_clamped(
        uint256 shares,
        uint128 navPerShare,
        uint256 toEntropy
    ) public {
        // clamp with share balance here because the maxRedeem is only updated after notifyRedeem
        shares %= (MockERC20(address(_getVault().share()))
            .balanceOf(_getActor()) + 1);
        shortcut_queue_redemption(shares, navPerShare, toEntropy);
        shortcut_claim_redemption(shares, toEntropy);
    }

    function shortcut_cancel_redeem_clamped(
        uint256 shares,
        uint128,
        /* navPerShare */ uint256 toEntropy
    ) public {
        // clamp with share balance here because the maxRedeem is only updated after notifyRedeem
        shares %= (MockERC20(address(_getVault().share()))
            .balanceOf(_getActor()) + 1);
        vault_requestRedeem(shares, toEntropy);

        vault_cancelRedeemRequest();
    }

    function shortcut_cancel_redeem_immediately_issue_and_revoke_clamped(
        uint256 shares,
        uint128 navPerShare,
        uint256 toEntropy
    ) public {
        shares %= (MockERC20(address(_getVault().share()))
            .balanceOf(_getActor()) + 1);
        shortcut_queue_redemption(shares, navPerShare, toEntropy);

        vault_cancelRedeemRequest();

        // After cancellation, check if there's still pending redeem to approve/revoke
        uint128 pendingRedeem = shareClassManager.pendingRedeem(
            _getShareClassId(),
            _getAssetId()
        );

        // Throw iff pending redeem == 0 to signal pruning
        uint32 redeemEpoch = shareClassManager.nowRedeemEpoch(
            _getShareClassId(),
            _getAssetId()
        );
        // Use safe approval function that will revert if pendingRedeem becomes 0
        shortcut_approve_and_revoke_shares_safe(
            pendingRedeem,
            redeemEpoch,
            navPerShare
        );
    }

    function shortcut_cancel_redeem_claim_clamped(
        uint256 shares,
        uint128,
        /* navPerShare */ uint256 toEntropy
    ) public {
        // clamp with share balance here because the maxRedeem is only updated after notifyRedeem
        shares %= (MockERC20(address(_getVault().share()))
            .balanceOf(_getActor()) + 1);
        vault_requestRedeem(shares, toEntropy);

        vault_cancelRedeemRequest();
        vault_claimCancelRedeemRequest(toEntropy);
    }

    // ═══════════════════════════════════════════════════════════════
    // POOL ADMIN SHORTCUTS
    // ═══════════════════════════════════════════════════════════════
    function shortcut_approve_and_issue_shares(
        uint128 maxApproval,
        uint32 nowDepositEpochId,
        uint128 navPerShare
    ) public {
        hub_approveDeposits(nowDepositEpochId, maxApproval);
        hub_issueShares(nowDepositEpochId, navPerShare);
    }

    function shortcut_approve_and_revoke_shares(
        uint128 maxApproval,
        uint32 epochId,
        uint128 navPerShare
    ) public {
        hub_approveRedeems(epochId, maxApproval);
        hub_revokeShares(epochId, navPerShare);
    }

    // ═══════════════════════════════════════════════════════════════
    // SAFE APPROVAL SHORTCUTS (WITH EXPLICIT REVERTS)
    // ═══════════════════════════════════════════════════════════════
    function shortcut_approve_and_issue_shares_safe(
        uint128 maxApproval,
        uint32 nowDepositEpochId,
        uint128 navPerShare
    ) public {
        uint128 pendingDeposit = shareClassManager.pendingDeposit(
            _getShareClassId(),
            _getAssetId()
        );
        require(pendingDeposit > 0, "InsufficientPending: pendingDeposit is 0");
        require(
            maxApproval <= pendingDeposit,
            "ExceedsPending: approval exceeds pending deposit"
        );

        hub_approveDeposits(nowDepositEpochId, maxApproval);
        hub_issueShares(nowDepositEpochId, navPerShare);
    }

    function shortcut_approve_and_revoke_shares_safe(
        uint128 maxApproval,
        uint32 epochId,
        uint128 navPerShare
    ) public {
        uint128 pendingRedeem = shareClassManager.pendingRedeem(
            _getShareClassId(),
            _getAssetId()
        );
        require(pendingRedeem > 0, "InsufficientPending: pendingRedeem is 0");
        require(
            maxApproval <= pendingRedeem,
            "ExceedsPending: approval exceeds pending redeem"
        );

        hub_approveRedeems(epochId, maxApproval);
        hub_revokeShares(epochId, navPerShare);
    }

    // ═══════════════════════════════════════════════════════════════
    // TRANSIENT VALUATION
    // ═══════════════════════════════════════════════════════════════
    function transientValuation_setPrice(
        AssetId base,
        AssetId quote,
        uint128 price
    ) public {
        IBaseVault vault = _getVault();
        if (address(vault) == address(0)) return;

        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        transientValuation.setPrice(poolId, scId, base, D18.wrap(price));
    }

    // set the price of the asset in the transient valuation for a given pool
    function transientValuation_setPrice_clamped(uint128 price) public {
        AssetId assetId = _getAssetId();

        transientValuation_setPrice(
            assetId,
            _getAssetId(),
            price
        );
    }

    // === PRICE CONTROL HANDLERS === //

    /// @dev Force price to zero for testing zero-price scenarios
    function hub_setPriceZero() public asAdmin {
        IBaseVault vault = _getVault();
        if (address(vault) == address(0)) return;

        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        hub.updateSharePrice(poolId, scId, D18.wrap(0));
    }

    /// @dev Set non-zero price with proper clamping for realistic testing
    function hub_setPriceNonZero_clamped(uint256 price) public asAdmin {
        if (price == 0) price = 1;
        if (price > type(uint128).max) price = type(uint128).max;

        IBaseVault vault = _getVault();
        if (address(vault) == address(0)) return;

        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        hub.updateSharePrice(poolId, scId, D18.wrap(uint128(price)));
    }

    /// @dev Set price to realistic range for testing normal operations
    function hub_setPriceRealistic_clamped(uint256 price) public asAdmin {
        // Clamp to realistic DeFi price range (0.001 to 1,000,000)
        // TODO: @Reviewer, is this range too restrictive?
        if (price < 1e15) price = 1e15;
        if (price > 1e24) price = 1e24;

        IBaseVault vault = _getVault();
        if (address(vault) == address(0)) return;

        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        hub.updateSharePrice(poolId, scId, D18.wrap(uint128(price)));
    }
}
