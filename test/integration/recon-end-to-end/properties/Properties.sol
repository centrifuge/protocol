// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Asserts} from "@chimera/Asserts.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {console2} from "forge-std/console2.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {D18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {PoolEscrow} from "src/common/PoolEscrow.sol";
import {AccountType} from "src/hub/interfaces/IHub.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";
import {VaultDetails} from "src/spoke/interfaces/ISpoke.sol";

import {OpType} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {BeforeAfter} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {AsyncVaultCentrifugeProperties} from
    "test/integration/recon-end-to-end/properties/AsyncVaultCentrifugeProperties.sol";
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";

import "forge-std/console2.sol";

abstract contract Properties is BeforeAfter, Asserts, AsyncVaultCentrifugeProperties {
    using CastLib for *;
    using MathLib for D18;
    using MathLib for uint128;
    using MathLib for uint256;

    event DebugWithString(string, uint256);
    event DebugNumber(uint256);

    // == SENTINEL == //
    /// Sentinel properties are used to flag that coverage was reached
    // These can be useful during development, but may also be kept at latest stages
    // They indicate that salient state transitions have happened, which can be helpful at all stages of development

    /// @dev This Property demonstrates that the current actor can reach a non-zero balance
    // This helps get coverage in other areas
    function property_sentinel_token_balance() public tokenIsSet {
        if (!RECON_USE_SENTINEL_TESTS) {
            return; // Skip if setting is off
        }

        // Dig until we get non-zero share class balance
        // Afaict this will never work
        IBaseVault vault = IBaseVault(_getVault());
        eq(IShareToken(vault.share()).balanceOf(_getActor()), 0, "token.balanceOf(getActor()) != 0");
    }

    // == VAULT == //

    /// @dev Property: Sum of share tokens received on `deposit` and `mint` <= sum of fulfilledDepositRequest.shares
    function property_sum_of_shares_received() public tokenIsSet {
        // only valid for async vaults because sync vaults don't have to fulfill deposit requests
        IBaseVault vault = IBaseVault(_getVault());
        if (Helpers.isAsyncVault(address(vault))) {
            address shareToken = vault.share();
            lte(
                sumOfClaimedDeposits[address(shareToken)],
                sumOfFullfilledDeposits[address(shareToken)],
                "sumOfClaimedDeposits[address(shareToken)] > sumOfFullfilledDeposits[address(shareToken)]"
            );
        }
    }

    /// @dev Property: the sum of assets received on redeem and withdraw <= sum of payout of fulfilledRedeemRequest
    function property_sum_of_assets_received() public assetIsSet {
        // Redeem and Withdraw
        IBaseVault vault = IBaseVault(_getVault());
        address asset = vault.asset();
        lte(
            sumOfClaimedRedemptions[address(asset)],
            currencyPayout[address(asset)],
            "sumOfClaimedRedemptions[address(_getAsset())] > currencyPayout[address(_getAsset())]"
        );
    }

    /// @dev Property: the payout of the escrow is always <= sum of redemptions paid out
    function property_sum_of_pending_redeem_request() public tokenIsSet {
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());
        address asset = vault.asset();

        address[] memory actors = _getActors();
        uint256 sumOfRedemptionsProcessed;
        for (uint256 i; i < actors.length; i++) {
            sumOfRedemptionsProcessed += redemptionsProcessed[scId][assetId][actors[i]];
        }

        lte(
            sumOfClaimedRedemptions[address(asset)],
            sumOfRedemptionsProcessed,
            "sumOfClaimedRedemptions > sumOfRedemptionsProcessed"
        );
    }

    /// @dev Property: The sum of tranche tokens minted/transferred is equal to the total supply of tranche tokens
    function property_sum_of_minted_equals_total_supply() public tokenIsSet {
        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as token cannot overflow due to other
        // functions permanently reverting
        IBaseVault vault = IBaseVault(_getVault());
        uint256 ghostTotalSupply;
        address shareToken = vault.share();
        uint256 totalSupply = IShareToken(shareToken).totalSupply();

        // NOTE: shareMints is no longer updated because hub_triggerIssueShares was removed
        unchecked {
            ghostTotalSupply = (shareMints[address(shareToken)] + executedInvestments[address(shareToken)])
                - executedRedemptions[address(shareToken)];
        }
        console2.log("totalSupply", totalSupply);
        eq(totalSupply, ghostTotalSupply, "totalSupply != ghostTotalSupply");
    }

    /// @dev Property: System addresses should never receive share tokens
    function property_system_addresses_never_receive_share_tokens() public assetIsSet {
        address[] memory systemAddresses = _getSystemAddresses();
        uint256 SYSTEM_ADDRESSES_LENGTH = systemAddresses.length;
        IBaseVault vault = IBaseVault(_getVault());
        address asset = vault.asset();
        address shareToken = vault.share();

        // NOTE: Skipping root and gateway since we mocked them
        for (uint256 i; i < SYSTEM_ADDRESSES_LENGTH; i++) {
            if (MockERC20(asset).balanceOf(systemAddresses[i]) > 0) {
                emit DebugNumber(i); // Number to index
                eq(IShareToken(shareToken).balanceOf(systemAddresses[i]), 0, "token.balanceOf(systemAddresses[i]) != 0");
            }
        }
    }

    /// @dev Property: Sum of assets received on claimCancelDepositRequest <= sum of fulfillCancelDepositRequest.assets
    function property_sum_of_assets_received_on_claim_cancel_deposit_request() public assetIsSet {
        // claimCancelDepositRequest
        // requestManager_fulfillCancelDepositRequest
        IBaseVault vault = IBaseVault(_getVault());
        address asset = vault.asset();

        lte(
            sumOfClaimedDepositCancelations[address(asset)],
            cancelDepositCurrencyPayout[address(asset)],
            "sumOfClaimedDepositCancelations !<= cancelDepositCurrencyPayout"
        );
    }

    /// @dev Property (inductive): Sum of assets received on claimCancelDepositRequest <= sum of
    /// fulfillCancelDepositRequest.assets
    function property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive() public tokenIsSet {
        // we only care about the case where the claimableCancelDepositRequest is decreasing because it indicates that a
        // cancel deposit request was fulfilled
        if (
            _before.investments[_getActor()].claimableCancelDepositRequest
                > _after.investments[_getActor()].claimableCancelDepositRequest
        ) {
            uint256 claimableCancelDepositRequestDelta = _before.investments[_getActor()].claimableCancelDepositRequest
                - _after.investments[_getActor()].claimableCancelDepositRequest;
            // claiming a cancel deposit request means that the globalEscrow token balance decreases
            uint256 escrowAssetBalanceDelta = _before.escrowAssetBalance - _after.escrowAssetBalance;
            eq(
                claimableCancelDepositRequestDelta,
                escrowAssetBalanceDelta,
                "claimableCancelDepositRequestDelta != escrowAssetBalanceDelta"
            );
        }
    }

    /// @dev Property: Sum of share class tokens received on claimCancelRedeemRequest <= sum of
    /// fulfillCancelRedeemRequest.shares
    function property_sum_of_received_leq_fulfilled() public tokenIsSet {
        // claimCancelRedeemRequest
        IBaseVault vault = IBaseVault(_getVault());
        lte(
            sumOfClaimedRedeemCancelations[address(vault.share())],
            cancelRedeemShareTokenPayout[address(vault.share())],
            "sumOfClaimedRedeemCancelations !<= cancelRedeemShareTokenPayout"
        );
    }

    /// @dev Property (inductive): Sum of share class tokens received on claimCancelRedeemRequest <= sum of
    /// fulfillCancelRedeemRequest.shares
    function property_sum_of_received_leq_fulfilled_inductive() public tokenIsSet {
        // we only care about the case where the claimableCancelRedeemRequest is decreasing because it indicates that a
        // cancel redeem request was fulfilled
        if (
            _before.investments[_getActor()].claimableCancelRedeemRequest
                > _after.investments[_getActor()].claimableCancelRedeemRequest
        ) {
            uint256 claimableCancelRedeemRequestDelta = _before.investments[_getActor()].claimableCancelRedeemRequest
                - _after.investments[_getActor()].claimableCancelRedeemRequest;
            // claiming a cancel redeem request means that the globalEscrow tranche token balance decreases
            uint256 escrowTrancheTokenBalanceDelta =
                _before.escrowTrancheTokenBalance - _after.escrowTrancheTokenBalance;
            eq(
                claimableCancelRedeemRequestDelta,
                escrowTrancheTokenBalanceDelta,
                "claimableCancelRedeemRequestDelta != escrowTrancheTokenBalanceDelta"
            );
        }
    }

    // == SHARE CLASS TOKENS == //

    /// @dev Property: Sum of balances equals total supply
    function property_sum_of_balances() public tokenIsSet {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        address shareToken = vault.share();

        uint256 acc;
        for (uint256 i; i < actors.length; i++) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo tranche
            try IShareToken(shareToken).balanceOf(actors[i]) returns (uint256 bal) {
                acc += bal;
            } catch {}
        }

        // NOTE: This ensures that supply doesn't overflow
        lte(acc, IShareToken(shareToken).totalSupply(), "sum of user balances > token.totalSupply()");
    }

    /// @dev Property: The price at which a user deposit is made is bounded by the price when the request was fulfilled
    function property_price_on_fulfillment() public vaultIsSet {
        if (address(asyncRequestManager) == address(0)) {
            return;
        }

        // Get actor data
        {
            (uint256 depositPrice,) = _getDepositAndRedeemPrice();

            // NOTE: Specification | Obv this breaks when you switch pools etc..
            // after a call to notifyDeposit the deposit price of the pool is set, so this checks that no other
            // functions can modify the deposit price outside of the bounds
            lte(
                depositPrice,
                _after.investorsGlobals[_getVault()][_getActor()].maxDepositPrice,
                "depositPrice > maxDepositPrice"
            );
            gte(
                depositPrice,
                _after.investorsGlobals[_getVault()][_getActor()].minDepositPrice,
                "depositPrice < minDepositPrice"
            );
        }
    }

    /// @dev Property: The price at which a user redemption is made is bounded by the price when the request was
    /// fulfilled
    function property_price_on_redeem() public vaultIsSet {
        if (address(asyncRequestManager) == address(0)) {
            return;
        }

        // changing vault messes up tracking so vault must have not changed
        if (_before.vault != _after.vault) {
            return;
        }

        // Get actor data
        {
            (, uint256 redeemPrice) = _getDepositAndRedeemPrice();

            lte(
                redeemPrice,
                _after.investorsGlobals[_getVault()][_getActor()].maxRedeemPrice,
                "redeemPrice > maxRedeemPrice"
            );
            gte(
                redeemPrice,
                _after.investorsGlobals[_getVault()][_getActor()].minRedeemPrice,
                "redeemPrice < minRedeemPrice"
            );
        }
    }

    /// @dev Property: The balance of currencies in Escrow is the sum of deposit requests -minus sum of claimed
    /// redemptions + transfers in -minus transfers out
    /// @dev NOTE: Ignores donations
    function property_escrow_balance() public assetIsSet {
        if (address(globalEscrow) == address(0)) {
            return;
        }

        IBaseVault vault = IBaseVault(_getVault());
        address asset = vault.asset();
        PoolId poolId = vault.poolId();
        address poolEscrow = address(poolEscrowFactory.escrow(poolId));
        uint256 balOfPoolEscrow = MockERC20(address(asset)).balanceOf(address(poolEscrow)); // The balance of tokens in
            // Escrow is sum of deposit requests plus transfers in minus transfers out
        uint256 balOfGlobalEscrow = MockERC20(address(asset)).balanceOf(address(globalEscrow));

        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as assets cannot overflow due to other
        // functions permanently reverting
        uint256 ghostBalOfEscrow;
        unchecked {
            // Deposit Requests + Transfers In - Claimed Redemptions + TransfersOut
            /// @audit Minted by Asset Payouts by Investors
            ghostBalOfEscrow = (
                (sumOfDepositRequests[asset] + sumOfSyncDepositsAsset[asset] + sumOfManagerDeposits[asset])
                    - (
                        sumOfClaimedDepositCancelations[asset] + sumOfClaimedRedemptions[asset]
                            + sumOfManagerWithdrawals[asset]
                    )
            );
        }

        eq(balOfPoolEscrow + balOfGlobalEscrow, ghostBalOfEscrow, "balOfEscrow != ghostBalOfEscrow");
    }

    /// @dev Property: The balance of share class tokens in Escrow is the sum of all fulfilled deposits - sum of all
    /// claimed deposits + sum of all redeem requests - sum of claimed redeem requests
    /// @dev NOTE: Ignores donations
    function property_escrow_share_balance() public tokenIsSet {
        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as token cannot overflow due to other
        // functions permanently reverting
        IBaseVault vault = IBaseVault(_getVault());
        address shareToken = vault.share();
        uint256 ghostBalanceOfEscrow;
        uint256 balanceOfEscrow = IShareToken(shareToken).balanceOf(address(globalEscrow));

        unchecked {
            ghostBalanceOfEscrow = (
                (sumOfFullfilledDeposits[address(shareToken)] + sumOfRedeemRequests[address(shareToken)])
                    - (
                        sumOfClaimedDeposits[address(shareToken)] + executedRedemptions[address(shareToken)] // revoked
                            // redemptions burn share tokens
                            + sumOfClaimedRedeemCancelations[address(shareToken)]
                    )
            ); // claims of cancelled amount can happen in claimCancelRedeemRequest or notifyRedeem
        }
        eq(balanceOfEscrow, ghostBalanceOfEscrow, "balanceOfEscrow != ghostBalanceOfEscrow");
    }

    // TODO: Multi Assets -> Iterate over all existing combinations

    /// @dev Property: The sum of account balances is always <= the balance of the escrow
    // TODO: this can't currently hold, requires a different implementation
    // function property_sum_of_account_balances_leq_escrow() public vaultIsSet {
    //     IBaseVault vault = IBaseVault(_getVault());
    //     uint256 balOfEscrow = MockERC20(vault.asset()).balanceOf(address(globalEscrow));
    //     address poolEscrow = address(poolEscrowFactory.escrow(vault.poolId()));
    //     uint256 balOfPoolEscrow = MockERC20(vault.asset()).balanceOf(address(poolEscrow));

    //     // Use acc to track max amount withdrawable for each actor
    //     address[] memory actors = _getActors();
    //     uint256 acc;
    //     for (uint256 i; i < actors.length; i++) {
    //         // NOTE: Accounts for scenario in which we didn't deploy the demo tranche
    //         try vault.maxWithdraw(actors[i]) returns (uint256 amt) {
    //             emit DebugWithString("amt", amt);
    //             acc += amt;
    //         } catch {}
    //     }

    //     lte(acc, balOfEscrow + balOfPoolEscrow, "sum of account balances > balOfEscrow");
    // }

    /// @dev Property: The sum of max claimable shares is always <= the share balance of the escrow
    function property_sum_of_possible_account_balances_leq_escrow() public vaultIsSet {
        // only check for async vaults because sync vaults claim minted shares immediately
        if (!Helpers.isAsyncVault(_getVault())) {
            return;
        }

        IBaseVault vault = IBaseVault(_getVault());
        uint256 max = IShareToken(vault.share()).balanceOf(address(globalEscrow));
        address[] memory actors = _getActors();

        uint256 acc; // Use acc to get maxMint for each actor
        for (uint256 i; i < actors.length; i++) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo share class
            try vault.maxMint(actors[i]) returns (uint256 shareAmt) {
                acc += shareAmt;
            } catch {}
        }

        lte(acc, max, "account balance > max");
    }

    /// @dev Property: the totalAssets of a vault is always <= actual assets in the vault
    // NOTE: if this still breaks with the added precondition, will most likely need to be removed because there's not a
    // simple fix for clamping NAV in hub_updateSharePrice that trivially breaks this
    function property_totalAssets_solvency() public {
        // precondition: if the last call was an update to the share price by the admin, return early because it can
        // incorrectly set the value of the shares greater than what it should be
        if (currentOperation == OpType.UPDATE) {
            return;
        }

        IBaseVault vault = IBaseVault(_getVault());
        uint256 totalAssets = vault.totalAssets();
        address escrow = address(poolEscrowFactory.escrow(vault.poolId()));
        uint256 actualAssets = MockERC20(vault.asset()).balanceOf(escrow);

        uint256 differenceInAssets = totalAssets - actualAssets;
        uint256 differenceInShares = vault.convertToShares(differenceInAssets);
        console2.log("differenceInShares", differenceInShares);
        console2.log("totalAssets", totalAssets);
        console2.log("actualAssets", actualAssets);

        // precondition: check if the difference is greater than one share
        if (differenceInShares > (10 ** IShareToken(vault.share()).decimals()) - 1) {
            lte(totalAssets, actualAssets, "totalAssets > actualAssets");
        }
    }

    /// @dev Property: difference between totalAssets and actualAssets only increases
    function property_totalAssets_insolvency_only_increases() public {
        uint256 differenceBefore = _before.totalAssets - _before.actualAssets;
        uint256 differenceAfter = _after.totalAssets - _after.actualAssets;

        gte(differenceAfter, differenceBefore, "insolvency decreased");
    }

    /// @dev Property: requested deposits must be >= the deposits fulfilled
    function property_soundness_processed_deposits() public {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());

        for (uint256 i; i < actors.length; i++) {
            gte(
                requestDeposited[scId][assetId][actors[i]],
                depositProcessed[scId][assetId][actors[i]],
                "property_soundness_processed_deposits Actor Requests must be gte than processed amounts"
            );
        }
    }

    /// @dev Property: requested redemptions must be >= the redemptions fulfilled
    function property_soundness_processed_redemptions() public {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());

        for (uint256 i; i < actors.length; i++) {
            gte(
                requestRedeemed[scId][assetId][actors[i]],
                redemptionsProcessed[scId][assetId][actors[i]],
                "property_soundness_processed_redemptions Actor Requests must be gte than processed amounts"
            );
        }
    }

    /// @dev Property: requested deposits must be >= the fulfilled cancelled deposits
    function property_cancelled_soundness() public {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());

        for (uint256 i; i < actors.length; i++) {
            gte(
                requestDeposited[scId][assetId][actors[i]],
                cancelledDeposits[scId][assetId][actors[i]],
                "actor requests must be >= cancelled amounts"
            );
        }
    }

    /// @dev Property: requested deposits must be >= the fulfilled cancelled deposits + fulfilled deposits
    function property_cancelled_and_processed_deposits_soundness() public {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());

        for (uint256 i; i < actors.length; i++) {
            gte(
                requestDeposited[scId][assetId][actors[i]],
                cancelledDeposits[scId][assetId][actors[i]] + depositProcessed[scId][assetId][actors[i]],
                "actor requests must be >= cancelled + processed amounts"
            );
        }
    }

    /// @dev Property: requested redemptions must be >= the fulfilled cancelled redemptions + fulfilled redemptions
    function property_cancelled_and_processed_redemptions_soundness() public {
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());
        address[] memory actors = _getActors();

        for (uint256 i; i < actors.length; i++) {
            gte(
                requestRedeemed[scId][assetId][actors[i]],
                cancelledRedemptions[scId][assetId][actors[i]] + redemptionsProcessed[scId][assetId][actors[i]],
                "actor requests must be >= cancelled + processed amounts"
            );
        }
    }

    /// @dev Property: total deposits must be >= the approved deposits
    function property_solvency_deposit_requests() public {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());

        uint256 totalDeposits;
        for (uint256 i; i < actors.length; i++) {
            totalDeposits += requestDeposited[scId][assetId][actors[i]];
        }

        gte(totalDeposits, approvedDeposits[scId][assetId], "total deposits < approved deposits");
    }

    /// @dev Property: total redemptions must be >= the approved redemptions
    function property_solvency_redemption_requests() public {
        address[] memory actors = _getActors();
        uint256 totalRedemptions;

        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        PoolId poolId = vault.poolId();
        AssetId assetId = hubRegistry.currency(poolId);

        for (uint256 i; i < actors.length; i++) {
            totalRedemptions += requestRedeemed[scId][assetId][actors[i]];
        }

        gte(totalRedemptions, approvedRedemptions[scId][assetId], "total redemptions < approved redemptions");
    }

    /// @dev Property: actor requested deposits - cancelled deposits - processed deposits actor pending deposits +
    /// queued deposits
    function property_actor_pending_and_queued_deposits() public {
        // Pending + Queued = Deposited?
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());

        for (uint256 i; i < actors.length; i++) {
            (uint128 pending,) = shareClassManager.depositRequest(scId, assetId, actors[i].toBytes32());
            (, uint128 queued) = shareClassManager.queuedDepositRequest(scId, assetId, actors[i].toBytes32());

            eq(
                requestDeposited[scId][assetId][actors[i]] - cancelledDeposits[scId][assetId][actors[i]]
                    - depositProcessed[scId][assetId][actors[i]],
                pending + queued,
                "actor requested deposits - cancelled deposits - processed deposits != actor pending deposits + queued deposits"
            );
        }
    }

    /// @dev Property: actor requested redemptions - cancelled redemptions - processed redemptions = actor pending
    /// redemptions + queued redemptions
    function property_actor_pending_and_queued_redemptions() public {
        // Pending + Queued = Deposited?
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());

        for (uint256 i; i < actors.length; i++) {
            (uint128 pending,) = shareClassManager.redeemRequest(scId, assetId, actors[i].toBytes32());
            (, uint128 queued) = shareClassManager.queuedRedeemRequest(scId, assetId, actors[i].toBytes32());

            eq(
                requestRedeemed[scId][assetId][actors[i]] - cancelledRedemptions[scId][assetId][actors[i]]
                    - redemptionsProcessed[scId][assetId][actors[i]],
                pending + queued,
                "property_actor_pending_and_queued_redemptions"
            );
        }
    }

    /// @dev Property: escrow total must be >= reserved
    // TODO: this can't currently hold, requires a different implementation
    // function property_escrow_solvency() public {
    //     IBaseVault vault = IBaseVault(_getVault());
    //     PoolId poolId = vault.poolId();
    //     ShareClassId scId = vault.scId();
    //     AssetId assetId = hubRegistry.currency(poolId);
    //     (address assetAddr, uint256 tokenId) = spoke.idToAsset(assetId);

    //     PoolEscrow poolEscrow = PoolEscrow(payable(address(poolEscrowFactory.escrow(poolId))));
    //     (uint128 total, uint128 reserved) = poolEscrow.holding(scId, assetAddr, tokenId);
    //     gte(total, reserved, "escrow total must be >= reserved");
    // }

    /// @dev Property: The price per share used in the entire system is ALWAYS provided by the admin
    // TODO: this needs to be redefined as an inline property in the target functions where assets are transferred and
    // shares are minted/burned
    // function property_price_per_share_overall() public {
    //     IBaseVault vault = IBaseVault(_getVault());
    //     PoolId poolId = vault.poolId();
    //     ShareClassId scId = vault.scId();
    //     AssetId assetId = hubRegistry.currency(poolId);

    //     // first check if the share amount changed
    //     uint256 shareDelta;
    //     uint256 assetDelta;
    //     if(_before.totalShareSupply != _after.totalShareSupply) {
    //         if(_before.totalShareSupply > _after.totalShareSupply) {
    //             shareDelta = _before.totalShareSupply - _after.totalShareSupply;
    //             uint256 globalEscrowAssetDelta = _before.escrowAssetBalance - _after.escrowAssetBalance;
    //             uint256 poolEscrowAssetDelta = _before.poolEscrowAssetBalance - _after.poolEscrowAssetBalance;
    //             assetDelta = globalEscrowAssetDelta + poolEscrowAssetDelta;
    //         } else {
    //             shareDelta = _after.totalShareSupply - _before.totalShareSupply;
    //             uint256 globalEscrowAssetDelta = _after.escrowAssetBalance - _before.escrowAssetBalance;
    //             uint256 poolEscrowAssetDelta = _after.poolEscrowAssetBalance - _before.poolEscrowAssetBalance;
    //             assetDelta = globalEscrowAssetDelta + poolEscrowAssetDelta;
    //         }

    //         // calculate the expected share delta using the asset delta and the price per share
    //         VaultDetails memory vaultDetails = spoke.vaultDetails(vault);
    //         console2.log("shareDelta", shareDelta);
    //         console2.log("assetDelta", assetDelta);
    //         console2.log("pricePoolPerAsset", _before.pricePoolPerAsset[poolId][scId][assetId].raw());
    //         console2.log("pricePoolPerShare", _before.pricePoolPerShare[poolId][scId].raw());
    //         uint256 expectedShareDelta = PricingLib.assetToShareAmount(
    //             vault.share(),
    //             vaultDetails.asset,
    //             vaultDetails.tokenId,
    //             assetDelta.toUint128(),
    //             _before.pricePoolPerAsset[poolId][scId][assetId],
    //             _before.pricePoolPerShare[poolId][scId],
    //             MathLib.Rounding.Down
    //         );

    //         // if the share amount changed, check if it used the correct price per share set by the admin
    //         eq(shareDelta, expectedShareDelta, "shareDelta must be equal to expectedShareDelta");
    //     }
    // }

    /// === HUB === ///

    /// @dev Property: The total pending asset amount pendingDeposit[..] is always >= the approved asset
    /// epochInvestAmounts[..].approvedAssetAmount
    function property_total_pending_and_approved() public {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        uint32 nowDepositEpoch = shareClassManager.nowDepositEpoch(scId, assetId);
        uint128 pendingDeposit = shareClassManager.pendingDeposit(scId, assetId);
        (uint128 pendingAssetAmount, uint128 approvedAssetAmount,,,,) =
            shareClassManager.epochInvestAmounts(scId, assetId, nowDepositEpoch);

        gte(pendingDeposit, approvedAssetAmount, "pendingDeposit < approvedAssetAmount");
        gte(pendingDeposit, pendingAssetAmount, "pendingDeposit < pendingAssetAmount");
    }

    /// @dev Property: The sum of pending user deposit amounts depositRequest[..] is always >= total pending deposit
    /// amount pendingDeposit[..]
    /// @dev Property: The total pending deposit amount pendingDeposit[..] is always >= the approved deposit amount
    /// epochInvestAmounts[..].approvedAssetAmount
    function property_sum_pending_user_deposit_geq_total_pending_deposit() public {
        address[] memory _actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        uint32 nowDepositEpoch = shareClassManager.nowDepositEpoch(scId, assetId);
        uint128 pendingDeposit = shareClassManager.pendingDeposit(scId, assetId);

        // get the pending and approved deposit amounts for the current epoch
        (uint128 pendingAssetAmount, uint128 approvedAssetAmount,,,,) =
            shareClassManager.epochInvestAmounts(scId, assetId, nowDepositEpoch);

        uint128 totalPendingUserDeposit;
        for (uint256 k = 0; k < _actors.length; k++) {
            address actor = _actors[k];

            (uint128 pendingUserDeposit,) = shareClassManager.depositRequest(scId, assetId, CastLib.toBytes32(actor));
            totalPendingUserDeposit += pendingUserDeposit;
        }

        // check that the pending deposit is >= the total pending user deposit
        gte(totalPendingUserDeposit, pendingDeposit, "total pending user deposits is < pending deposit");
        // check that the pending deposit is >= the approved deposit
        gte(pendingDeposit, approvedAssetAmount, "pending deposit is < approved deposit");
    }

    /// @dev Property: The sum of pending user redeem amounts redeemRequest[..] is always >= total pending redeem amount
    /// pendingRedeem[..]
    /// @dev Property: The total pending redeem amount pendingRedeem[..] is always >= the approved redeem amount
    /// epochRedeemAmounts[..].approvedShareAmount
    function property_sum_pending_user_redeem_geq_total_pending_redeem() public {
        address[] memory _actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        (uint32 redeemEpochId) = shareClassManager.nowRedeemEpoch(scId, assetId);
        uint128 pendingRedeem = shareClassManager.pendingRedeem(scId, assetId);

        // get the pending and approved redeem amounts for the current epoch
        (, uint128 approvedShareAmount, uint128 payoutAssetAmount,,,) =
            shareClassManager.epochRedeemAmounts(scId, assetId, redeemEpochId);

        uint128 totalPendingUserRedeem;
        for (uint256 k = 0; k < _actors.length; k++) {
            address actor = _actors[k];

            (uint128 pendingUserRedeem,) = shareClassManager.redeemRequest(scId, assetId, CastLib.toBytes32(actor));
            totalPendingUserRedeem += pendingUserRedeem;
        }

        // check that the pending redeem is >= the total pending user redeem
        gte(totalPendingUserRedeem, pendingRedeem, "total pending user redeems is < pending redeem");
        // check that the pending redeem is >= the approved redeem
        gte(pendingRedeem, approvedShareAmount, "pending redeem is < approved redeem");
    }

    /// @dev Property: The epoch of a pool epochId[poolId] can increase at most by one within the same transaction (i.e.
    /// multicall/execute) independent of the number of approvals
    function property_epochId_can_increase_by_one_within_same_transaction() public {
        // precondition: there must've been a batch operation (call to execute/multicall)
        if (currentOperation == OpType.BATCH) {
            uint64[] memory _createdPools = _getPools();
            for (uint256 i = 0; i < _createdPools.length; i++) {
                PoolId poolId = PoolId.wrap(_createdPools[i]);
                uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
                // skip the first share class because it's never assigned
                for (uint32 j = 1; j < shareClassCount; j++) {
                    ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                    AssetId assetId = hubRegistry.currency(poolId);

                    uint32 depositEpochIdDifference =
                        _after.ghostEpochId[scId][assetId].deposit - _before.ghostEpochId[scId][assetId].deposit;
                    uint32 redeemEpochIdDifference =
                        _after.ghostEpochId[scId][assetId].redeem - _before.ghostEpochId[scId][assetId].redeem;
                    uint32 issueEpochIdDifference =
                        _after.ghostEpochId[scId][assetId].issue - _before.ghostEpochId[scId][assetId].issue;
                    uint32 revokeEpochIdDifference =
                        _after.ghostEpochId[scId][assetId].revoke - _before.ghostEpochId[scId][assetId].revoke;

                    // check that the epochId increased by at most 1
                    lte(depositEpochIdDifference, 1, "deposit epochId increased by more than 1");
                    lte(redeemEpochIdDifference, 1, "redeem epochId increased by more than 1");
                    lte(issueEpochIdDifference, 1, "issue epochId increased by more than 1");
                    lte(revokeEpochIdDifference, 1, "revoke epochId increased by more than 1");
                }
            }
        }
    }

    /// @dev Property: account.totalDebit and account.totalCredit is always less than uint128(type(int128).max)
    // NOTE: this property is not relevant anymore with the latest implementation of the accountValue using uint128
    // instead of int128
    // function property_account_totalDebit_and_totalCredit_leq_max_int128() public {
    //     uint64[] memory _createdPools = _getPools();
    //     for (uint256 i = 0; i < _createdPools.length; i++) {
    //         PoolId poolId = PoolId.wrap(_createdPools[i]);
    //         uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
    //         // skip the first share class because it's never assigned
    //         for (uint32 j = 1; j < shareClassCount; j++) {
    //             ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
    //             AssetId assetId = hubRegistry.currency(poolId);
    //             // loop over all account types defined in IHub::AccountType
    //             for(uint8 kind = 0; kind < 6; kind++) {
    //                 AccountId accountId = holdings.accountId(poolId, scId, assetId, kind);
    //                 (uint128 totalDebit, uint128 totalCredit,,,) = accounting.accounts(poolId, accountId);
    //                 lte(totalDebit, uint128(type(int128).max), "totalDebit is greater than max int128");
    //                 lte(totalCredit, uint128(type(int128).max), "totalCredit is greater than max int128");
    //             }
    //         }
    //     }
    // }

    /// @dev Property: Any decrease in valuation should not result in an increase in accountValue
    function property_decrease_valuation_no_increase_in_accountValue() public {
        uint64[] memory _createdPools = _getPools();
        for (uint256 i = 0; i < _createdPools.length; i++) {
            PoolId poolId = PoolId.wrap(_createdPools[i]);
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                if (_before.ghostHolding[poolId][scId][assetId] > _after.ghostHolding[poolId][scId][assetId]) {
                    // loop over all account types defined in IHub::AccountType
                    for (uint8 kind = 0; kind < 6; kind++) {
                        AccountId accountId = holdings.accountId(poolId, scId, assetId, kind);
                        uint128 accountValueBefore = _before.ghostAccountValue[poolId][accountId];
                        uint128 accountValueAfter = _after.ghostAccountValue[poolId][accountId];
                        if (accountValueAfter > accountValueBefore) {
                            t(false, "accountValue increased");
                        }
                    }
                }
            }
        }
    }

    /// @dev Property: Value of Holdings == accountValue(Asset)
    function property_accounting_and_holdings_soundness() public {
        uint64[] memory _createdPools = _getPools();
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);
        AccountId accountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));

        (, uint128 assets) = accounting.accountValue(poolId, accountId);
        uint128 holdingsValue = holdings.value(poolId, scId, assetId);

        // This property holds all of the system accounting together
        eq(assets, holdingsValue, "Assets and Holdings value must match");
    }

    /// @dev Property: Total Yield = assets - equity
    function property_total_yield() public {
        uint64[] memory _createdPools = _getPools();
        for (uint256 i = 0; i < _createdPools.length; i++) {
            PoolId poolId = PoolId.wrap(_createdPools[i]);
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                // get the account ids for each account
                AccountId assetAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));
                AccountId equityAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Equity));
                AccountId gainAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Gain));
                AccountId lossAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Loss));

                (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
                (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);

                if (assets > equity) {
                    // Yield
                    (, uint128 yield) = accounting.accountValue(poolId, gainAccountId);
                    t(yield == assets - equity, "property_total_yield gain");
                } else if (assets < equity) {
                    // Loss
                    (, uint128 loss) = accounting.accountValue(poolId, lossAccountId);
                    t(loss == assets - equity, "property_total_yield loss"); // Loss is negative
                }
            }
        }
    }

    /// @dev Property: assets = equity + gain + loss
    function property_asset_soundness() public {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        // get the account ids for each account
        AccountId assetAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));
        AccountId equityAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Equity));
        AccountId gainAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Gain));
        AccountId lossAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Loss));

        (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
        (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);
        (, uint128 gain) = accounting.accountValue(poolId, gainAccountId);
        (, uint128 loss) = accounting.accountValue(poolId, lossAccountId);

        // assets = accountValue(Equity) + accountValue(Gain) - accountValue(Loss)
        console2.log("assets:", assets);
        console2.log("equity:", equity);
        console2.log("gain:", gain);
        console2.log("loss:", loss);
        console2.log("equity + gain - loss:", equity + gain - loss);
        t(assets == equity + gain - loss, "property_asset_soundness"); // Loss is already negative
    }

    /// @dev Property: equity = assets - loss - gain
    function property_equity_soundness() public {
        uint64[] memory _createdPools = _getPools();
        for (uint256 i = 0; i < _createdPools.length; i++) {
            PoolId poolId = PoolId.wrap(_createdPools[i]);
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                // get the account ids for each account
                AccountId assetAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));
                AccountId equityAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Equity));
                AccountId gainAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Gain));
                AccountId lossAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Loss));

                (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
                (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);
                (, uint128 gain) = accounting.accountValue(poolId, gainAccountId);
                (, uint128 loss) = accounting.accountValue(poolId, lossAccountId);

                // equity = accountValue(Asset) + (ABS(accountValue(Loss)) - accountValue(Gain) // Loss comes back, gain
                // is subtracted
                t(equity == assets + loss - gain, "property_equity_soundness"); // Loss comes back, gain is subtracted,
                    // since loss is negative we need to negate it
            }
        }
    }

    /// @dev Property: gain = totalYield + loss
    function property_gain_soundness() public {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        // get the account ids for each account
        AccountId assetAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));
        AccountId equityAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Equity));
        AccountId gainAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Gain));
        AccountId lossAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Loss));

        (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
        (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);
        (, uint128 gain) = accounting.accountValue(poolId, gainAccountId);
        (, uint128 loss) = accounting.accountValue(poolId, lossAccountId);

        uint128 totalYield = assets - equity; // Can be positive or negative
        t(gain == (totalYield - loss), "property_gain_soundness");
    }

    /// @dev Property: loss = totalYield - gain
    function property_loss_soundness() public {
        uint64[] memory _createdPools = _getPools();
        for (uint256 i = 0; i < _createdPools.length; i++) {
            PoolId poolId = PoolId.wrap(_createdPools[i]);
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                // get the account ids for each account
                AccountId assetAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));
                AccountId equityAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Equity));
                AccountId gainAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Gain));
                AccountId lossAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Loss));

                (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
                (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);
                (, uint128 gain) = accounting.accountValue(poolId, gainAccountId);
                (, uint128 loss) = accounting.accountValue(poolId, lossAccountId);

                uint128 totalYield = assets - equity; // Can be positive or negative
                console2.log("loss:", loss);
                console2.log("assets:", assets);
                console2.log("equity:", equity);
                console2.log("totalYield:", totalYield);
                console2.log("gain:", gain);
                console2.log("totalYield - gain:", totalYield - gain);
                t(loss == totalYield - gain, "property_loss_soundness");
            }
        }
    }

    /// @dev Property: A user cannot mutate their pending redeem amount pendingRedeem[...] if the
    /// pendingRedeem[..].lastUpdate is <= the latest redeem approval epochId[..].redeem
    function property_user_cannot_mutate_pending_redeem() public {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        bytes32 actor = CastLib.toBytes32(_getActor());
        // precondition: user already has non-zero pending redeem and it has changed
        if (
            _before.ghostRedeemRequest[scId][assetId][actor].pending > 0
                && _before.ghostRedeemRequest[scId][assetId][actor].pending
                    != _after.ghostRedeemRequest[scId][assetId][actor].pending
        ) {
            // check that the lastUpdate was > the latest redeem revoke pointer
            gt(
                _after.ghostRedeemRequest[scId][assetId][actor].lastUpdate,
                _after.ghostEpochId[scId][assetId].revoke,
                "lastUpdate is <= latest redeem revoke"
            );
        }
    }

    /// @dev Property: The amount of holdings of an asset for a pool-shareClas pair in Holdings MUST always be equal to
    /// the balance of the escrow for said pool-shareClass for the respective token
    function property_holdings_balance_equals_escrow_balance() public {
        address[] memory _actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        address asset = vault.asset();
        AssetId assetId = hubRegistry.currency(vault.poolId());

        (uint128 holdingAssetAmount,,,) = holdings.holding(vault.poolId(), vault.scId(), assetId);
        address poolEscrow = address(poolEscrowFactory.escrow(vault.poolId()));
        uint256 escrowBalance = MockERC20(asset).balanceOf(poolEscrow);

        eq(holdingAssetAmount, escrowBalance, "holding != escrow balance");
    }

    /// @dev Property: The total issuance of a share class is <= the sum of issued shares and burned shares
    function property_total_issuance_soundness() public {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        // TODO(wischli): Find feasible replacement now that queues are always enabled
        // precondition: if queue is enabled, return early because the totalIssuance is only updated immediately when
        // the queue isn't enabled
        return;

        (uint128 totalIssuance,) = shareClassManager.metrics(scId);

        uint256 minted = issuedHubShares[poolId][scId][assetId] + issuedBalanceSheetShares[poolId][scId]
            + sumOfSyncDepositsShare[vault.share()];
        uint256 burned = revokedHubShares[poolId][scId][assetId] + revokedBalanceSheetShares[poolId][scId];
        console2.log("issuedHubShares:", issuedHubShares[poolId][scId][assetId]);
        console2.log("issuedBalanceSheetShares:", issuedBalanceSheetShares[poolId][scId]);
        console2.log("sumOfSyncDepositsShare:", sumOfSyncDepositsShare[vault.share()]);
        console2.log("revokedHubShares:", revokedHubShares[poolId][scId][assetId]);
        console2.log("revokedBalanceSheetShares:", revokedBalanceSheetShares[poolId][scId]);
        lte(totalIssuance, minted - burned, "total issuance is > issuedHubShares + issuedBalanceSheetShares");
    }

    function property_additions_dont_cause_ppfs_loss() public {
        if (currentOperation == OpType.ADD) {
            gte(_after.totalAssets, _before.totalAssets, "total assets must increase when adding");
            gte(_after.totalShareSupply, _before.totalShareSupply, "total supply must increase when adding");
        }
    }

    function property_removals_dont_cause_ppfs_loss() public {
        if (currentOperation == OpType.REMOVE) {
            lte(_after.totalAssets, _before.totalAssets, "total assets must decrease when removing");
            lte(_after.totalShareSupply, _before.totalShareSupply, "total supply must decrease when removing");
        }
    }

    /// @dev Property: If user deposits assets, they must always receive at least the pricePerShare
    function property_additions_use_correct_price() public {
        IBaseVault vault = IBaseVault(_getVault());
        uint256 decimals = MockERC20(vault.asset()).decimals();

        if (currentOperation == OpType.ADD) {
            uint256 assetDelta = _after.totalAssets - _before.totalAssets;
            uint256 shareDelta = _after.totalShareSupply - _before.totalShareSupply;
            uint256 expectedShares = (_before.pricePerShare * assetDelta) - (10 ** decimals);
            if (expectedShares > shareDelta) {
                // difference between expected and how much they actually paid
                uint256 expectedVsActual = shareDelta - expectedShares;
                // difference should be less than 1 atom
                lte(expectedVsActual, (10 ** decimals), "shareDelta must be >= expectedShares using pricePerShare");
            }
        }
    }

    /// @dev Property: If user redeems shares, they must always pay at least the pricePerShare
    function property_removals_use_correct_price() public {
        IBaseVault vault = IBaseVault(_getVault());
        uint256 decimals = MockERC20(vault.asset()).decimals();

        if (currentOperation == OpType.REMOVE) {
            uint256 assetDelta = _after.totalAssets - _before.totalAssets;
            uint256 shareDelta = _after.totalShareSupply - _before.totalShareSupply;
            uint256 expectedShares = (_before.pricePerShare * assetDelta) + (10 ** decimals);
            if (expectedShares > shareDelta) {
                // difference between expected and how much they actually paid
                uint256 expectedVsActual = expectedShares - shareDelta;
                // difference should be less than 1 atom
                lte(expectedVsActual, (10 ** decimals), "shareDelta must be >= expectedShares using pricePerShare");
            }
        }
    }

    /// @dev Property: The amount of tokens existing in the AssetRegistry MUST always be <= the balance of the
    /// associated token in the escrow
    // TODO: confirm if this is correct because it seems like AssetRegistry would never be receiving tokens in the first
    // place
    // TODO: verify if this should be applied to the vaults side instead
    // function property_assetRegistry_balance_leq_escrow_balance() public {
    //     address[] memory _actors = _getActors();

    //     for (uint256 i = 0; i < createdPools.length; i++) {
    //         PoolId poolId = createdPools[i];
    //         uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
    //         // skip the first share class because it's never assigned
    //         for (uint32 j = 1; j < shareClassCount; j++) {
    //             ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
    //             AssetId assetId = hubRegistry.currency(poolId);

    //             address pendingShareClassEscrow = hub.escrow(poolId, scId, EscrowId.PendingShareClass);
    //             address shareClassEscrow = hub.escrow(poolId, scId, EscrowId.ShareClass);
    //             uint256 assetRegistryBalance = assetRegistry.balanceOf(address(assetRegistry), assetId.raw());
    //             uint256 pendingShareClassEscrowBalance = assetRegistry.balanceOf(pendingShareClassEscrow,
    // assetId.raw());
    //             uint256 shareClassEscrowBalance = assetRegistry.balanceOf(shareClassEscrow, assetId.raw());

    //             lte(assetRegistryBalance, pendingShareClassEscrowBalance + shareClassEscrowBalance, "assetRegistry
    // balance > escrow balance");
    //         }
    //     }

    //     // TODO: check if this is the correct check
    //     // loop through all created assetIds
    //     // check if the asset is in the HubRegistry
    //     // if it is, check if there's any of the asset in the escrow
    // }

    /// Stateless Properties ///

    /// @dev Property: The sum of eligible user payoutShareAmount for an epoch is <= the number of issued
    /// epochInvestAmounts[..].pendingAssetAmount converted to shares
    /// @dev Property: The sum of eligible user payoutAssetAmount for an epoch is <= the number of issued asset
    /// epochInvestAmounts[..].pendingAssetAmount
    /// @dev Stateless because of the calls to claimDeposit which would make story difficult to read
    function property_eligible_user_deposit_amount_leq_deposit_issued_amount() public statelessTest {
        address[] memory _actors = _getActors();

        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        // get the current deposit epoch
        uint32 epochId = shareClassManager.nowDepositEpoch(scId, assetId);
        uint128 totalDepositAssets;
        uint128 totalDepositShares;
        for (uint32 i = 0; i < epochId; i++) {
            (uint128 pendingAssetAmount,,,,,) = shareClassManager.epochInvestAmounts(scId, assetId, i);
            totalDepositAssets += pendingAssetAmount;
            // TODO: confirm if this share calculation is correct
            totalDepositShares += uint128(vault.convertToShares(pendingAssetAmount));
        }

        // sum eligible user claim payoutShareAmount for the epoch
        uint128 totalPayoutAssetAmount;
        uint128 totalPayoutShareAmount;
        for (uint256 k = 0; k < _actors.length; k++) {
            address actor = _actors[k];
            (uint128 payoutShareAmount, uint128 payoutAssetAmount,) =
                hubHelpers.notifyDeposit(poolId, scId, assetId, CastLib.toBytes32(actor), MAX_CLAIMS);
            totalPayoutAssetAmount += payoutAssetAmount;
            totalPayoutShareAmount += payoutShareAmount;
        }

        lte(totalPayoutAssetAmount, totalDepositAssets, "totalPayoutAssetAmount > totalDepositAssets");
        lte(totalPayoutShareAmount, totalDepositShares, "totalPayoutShareAmount > totalDepositShares");

        // NOTE: removed because the totalPayoutAssetAmount, totalPaymentShareAmount are dependent on the NAV passed in
        // by the admin when approving/revoking so can easily allow the admin to wreck the user
        // checks above prevent underflow here
        // uint128 differenceShares = totalDepositShares - totalPayoutShareAmount;
        // uint128 differenceAsset = totalDepositAssets - totalPayoutAssetAmount;
        // // check that the totalPayoutShareAmount is no more than 1 atom less than the totalDepositShares
        // lte(differenceShares, 1, "totalDepositShares - totalPayoutShareAmount difference is greater than 1");
        // // check that the totalPayoutAssetAmount is no more than 1 atom less than the totalDepositAssets
        // lte(differenceAsset, 1, "totalDepositAssets - totalPayoutAssetAmount difference is greater than 1");
    }

    /// @dev Property: The sum of eligible user claim payout asset amounts for an epoch is <= the asset amount of
    /// revoked share class tokens epochRedeemAmounts[..].payoutAssetAmount
    /// @dev Property: The sum of eligible user claim payment share amounts for an epoch is <= the approved amount of
    /// redeemed share class tokens epochRedeemAmounts[..].approvedShareAmount
    /// @dev This doesn't sum over previous epochs because it can be assumed that it'll be called by the fuzzer for each
    /// current epoch
    function property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount() public statelessTest {
        address[] memory _actors = _getActors();

        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        // get the current redeem epoch
        uint32 epochId = shareClassManager.nowRedeemEpoch(scId, assetId);
        uint128 totalPayoutAssetAmountEpochs;
        uint128 totalApprovedShareAmountEpochs;
        for (uint32 i = 0; i < epochId; i++) {
            (, uint128 approvedShareAmount, uint128 payoutAssetAmount,,,) =
                shareClassManager.epochRedeemAmounts(scId, assetId, i);
            totalPayoutAssetAmountEpochs += payoutAssetAmount;
            totalApprovedShareAmountEpochs += approvedShareAmount;
        }

        // sum eligible user claim payoutAssetAmount for the epoch
        uint128 totalPayoutAssetAmount;
        uint128 totalPaymentShareAmount;
        for (uint256 k = 0; k < _actors.length; k++) {
            address actor = _actors[k];
            (uint128 payoutAssetAmount, uint128 paymentShareAmount,) =
                hubHelpers.notifyRedeem(poolId, scId, assetId, CastLib.toBytes32(actor), MAX_CLAIMS);
            totalPayoutAssetAmount += payoutAssetAmount;
            totalPaymentShareAmount += paymentShareAmount;
        }

        lte(totalPayoutAssetAmount, totalPayoutAssetAmountEpochs, "total payout asset amount is > redeem assets");
        lte(
            totalPaymentShareAmount,
            totalApprovedShareAmountEpochs,
            "total payment share amount is > redeem shares approved"
        );

        // NOTE: removed because the totalPayoutAssetAmount, totalPaymentShareAmount are dependent on the NAV passed in
        // by the admin when approving/revoking so can easily allow the admin to wreck the user
        // checks above prevent underflow here
        // uint128 differenceAsset = totalPayoutAssetAmountEpochs - totalPayoutAssetAmount;
        // uint128 differenceShare = totalApprovedShareAmountEpochs - totalPaymentShareAmount;
        // // check that the totalPayoutAssetAmount is no more than 1 atom less than the payoutAssetAmount
        // lte(differenceAsset, 1, "sumRedeemAssets - totalPayoutAssetAmount difference is greater than 1");
        // // check that the totalPaymentShareAmount is no more than 1 atom less than the approvedShareAmount
        // lte(differenceShare, 1, "sumRedeemApprovedShares - totalPaymentShareAmount difference is greater than 1");
    }

    /// === DOOMSDAY TESTS === ///

    /// @dev Property: pricePerShare never changes after a user operation
    function doomsday_pricePerShare_never_changes_after_user_operation() public {
        if (currentOperation != OpType.ADMIN) {
            eq(_before.pricePerShare, _after.pricePerShare, "pricePerShare changed after user operation");
        }
    }

    /// @dev Property: implied pricePerShare (totalAssets / totalSupply) never changes after a user operation
    function doomsday_impliedPricePerShare_never_changes_after_user_operation() public {
        if (currentOperation != OpType.ADMIN) {
            uint256 impliedPricePerShareBefore = _before.totalAssets / _before.totalShareSupply;
            uint256 impliedPricePerShareAfter = _after.totalAssets / _after.totalShareSupply;
            eq(
                impliedPricePerShareBefore,
                impliedPricePerShareAfter,
                "impliedPricePerShare changed after user operation"
            );
        }
    }

    /// @dev Property: accounting.accountValue should never revert
    function doomsday_accountValue(uint64 poolIdAsUint, uint32 accountAsInt) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        AccountId account = AccountId.wrap(accountAsInt);

        try accounting.accountValue(poolId, account) {}
        catch (bytes memory reason) {
            bool expectedRevert = checkError(reason, "AccountDoesNotExist()");
            t(expectedRevert, "accountValue should never revert");
        }
    }

    // === OPTIMIZATION TESTS === //

    /// @dev Optimization test to increase the difference between totalAssets and actualAssets is greater than 1 share
    function optimize_totalAssets_solvency() public view returns (int256) {
        uint256 totalAssets = IBaseVault(_getVault()).totalAssets();
        uint256 actualAssets = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(address(globalEscrow));
        uint256 difference = totalAssets - actualAssets;

        return int256(difference);
        // uint256 differenceInShares = IBaseVault(_getVault()).convertToShares(difference);

        // if (differenceInShares > (10 ** IShareToken(_getShareToken()).decimals()) - 1) {
        //     return int256(difference);
        // }

        // return 0;
    }

    function optimize_maxDeposit_greater() public view returns (int256) {
        return maxDepositGreater;
    }

    function optimize_maxDeposit_less() public view returns (int256) {
        return maxDepositLess;
    }

    function optimize_maxRedeem_greater() public view returns (int256) {
        return maxRedeemGreater;
    }

    function optimize_maxRedeem_less() public view returns (int256) {
        return maxRedeemLess;
    }

    /// === HELPERS === ///

    /// @dev Lists out all system addresses, used to check that no dust is left behind
    /// NOTE: A more advanced dust check would have 100% of actors withdraw, to ensure that the sum of operations is
    /// sound
    function _getSystemAddresses() internal view returns (address[] memory systemAddresses) {
        // uint256 SYSTEM_ADDRESSES_LENGTH = GOV_FUZZING ? 10 : 8;
        uint256 SYSTEM_ADDRESSES_LENGTH = 10;

        systemAddresses = new address[](SYSTEM_ADDRESSES_LENGTH);

        // NOTE: Skipping escrow which can have non-zero bal
        systemAddresses[0] = address(asyncVaultFactory);
        systemAddresses[1] = address(syncVaultFactory);
        systemAddresses[2] = address(tokenFactory);
        systemAddresses[3] = address(asyncRequestManager);
        systemAddresses[4] = address(syncManager);
        systemAddresses[5] = address(spoke);
        systemAddresses[6] = address(IBaseVault(_getVault()));
        systemAddresses[7] = address(IBaseVault(_getVault()).asset());
        systemAddresses[8] = _getShareToken();
        systemAddresses[9] = address(fullRestrictions);

        // if (GOV_FUZZING) {
        //     systemAddresses[8] = address(gateway);
        //     systemAddresses[9] = address(root);
        // }

        return systemAddresses;
    }

    /// @dev Can we donate to this address?
    /// We explicitly preventing donations since we check for exact balances
    function _canDonate(address to) internal view returns (bool) {
        if (to == address(globalEscrow)) {
            return false;
        }

        return true;
    }

    /// @dev utility to ensure the target is not in the system addresses
    function _isInSystemAddress(address x) internal view returns (bool) {
        address[] memory systemAddresses = _getSystemAddresses();
        uint256 SYSTEM_ADDRESSES_LENGTH = systemAddresses.length;

        for (uint256 i; i < SYSTEM_ADDRESSES_LENGTH; i++) {
            if (systemAddresses[i] == x) return true;
        }

        return false;
    }

    /// NOTE: Example of checked overflow, unused as we have changed tracking of Tranche tokens to be based on Global_3
    function _decreaseTotalShareSent(address asset, uint256 amt) internal {
        uint256 cachedTotal = totalShareSent[asset];
        unchecked {
            totalShareSent[asset] -= amt;
        }

        // Check for overflow here
        gte(cachedTotal, totalShareSent[asset], " _decreaseTotalShareSent Overflow");
    }
}
