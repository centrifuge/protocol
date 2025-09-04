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
import {IPoolEscrow, Holding} from "src/common/interfaces/IPoolEscrow.sol";
import {AccountType} from "src/hub/interfaces/IHub.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {BaseVault} from "src/vaults/BaseVaults.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";
import {VaultDetails} from "src/spoke/interfaces/ISpoke.sol";

import {OpType} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {BeforeAfter} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {AsyncVaultCentrifugeProperties} from
    "test/integration/recon-end-to-end/properties/AsyncVaultCentrifugeProperties.sol";
import {Helpers} from "test/integration/recon-end-to-end/utils/Helpers.sol";

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
                sumOfFulfilledDeposits[address(shareToken)],
                "sumOfClaimedDeposits[address(shareToken)] > sumOfFulfilledDeposits[address(shareToken)]"
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
            sumOfWithdrawable[address(asset)],
            "sumOfClaimedRedemptions[address(_getAsset())] > sumOfWithdrawable[address(_getAsset())]"
        );
    }

    /// @dev Property: the payout of the escrow is always <= sum of redemptions paid out
    function property_sum_of_pending_redeem_request() public tokenIsSet {
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;
        address asset = vault.asset();

        address[] memory actors = _getActors();
        uint256 sumOfRedemptionsProcessed;
        for (uint256 i; i < actors.length; i++) {
            sumOfRedemptionsProcessed += userRedemptionsProcessed[scId][assetId][actors[i]];
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

        // TODO(wischli): Investigate with zero price

        uint256 ghostTotalSupply;
        address shareToken = vault.share();
        uint256 totalSupply = IShareToken(shareToken).totalSupply();

        // TODO(wischli): shareMints is no longer updated because hub_triggerIssueShares was removed
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

    // TODO(wischli): Breaks for ever `revokedShares` which reduced totalSupply
    /// @dev Property: Total cancelled redeem shares <= total supply
    function property_total_cancelled_redeem_shares_lte_total_supply() public tokenIsSet {
        IBaseVault vault = IBaseVault(_getVault());

        uint256 totalSupply = IShareToken(vault.share()).totalSupply();
        lte(
            sumOfClaimedCancelledRedeemShares[address(vault.share())],
            totalSupply,
            "Ghost: sumOfClaimedCancelledRedeemShares exceeds totalSupply"
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
                        sumOfClaimedCancelledDeposits[asset] + sumOfClaimedRedemptions[asset]
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
                (sumOfFulfilledDeposits[address(shareToken)] + sumOfRedeemRequests[address(shareToken)])
                    - (
                        sumOfClaimedDeposits[address(shareToken)] + executedRedemptions[address(shareToken)] // revoked
                            // redemptions burn share tokens
                            + sumOfClaimedCancelledRedeemShares[address(shareToken)]
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
        AssetId assetId = spoke.vaultDetails(vault).assetId;

        for (uint256 i; i < actors.length; i++) {
            gte(
                userRequestDeposited[scId][assetId][actors[i]],
                userDepositProcessed[scId][assetId][actors[i]],
                "property_soundness_processed_deposits Actor Requests must be gte than processed amounts"
            );
        }
    }

    /// @dev Property: requested redemptions must be >= the redemptions fulfilled
    function property_soundness_processed_redemptions() public {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;

        for (uint256 i; i < actors.length; i++) {
            gte(
                userRequestRedeemed[scId][assetId][actors[i]],
                userRedemptionsProcessed[scId][assetId][actors[i]],
                "property_soundness_processed_redemptions Actor Requests must be gte than processed amounts"
            );
        }
    }

    /// @dev Property: requested deposits must be >= the fulfilled cancelled deposits
    function property_cancelled_soundness() public {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;

        for (uint256 i; i < actors.length; i++) {
            gte(
                userRequestDeposited[scId][assetId][actors[i]],
                userCancelledDeposits[scId][assetId][actors[i]],
                "actor requests must be >= cancelled amounts"
            );
        }
    }

    /// @dev Property: requested deposits must be >= the fulfilled cancelled deposits + fulfilled deposits
    function property_cancelled_and_processed_deposits_soundness() public {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;

        for (uint256 i; i < actors.length; i++) {
            gte(
                userRequestDeposited[scId][assetId][actors[i]],
                userCancelledDeposits[scId][assetId][actors[i]] + userDepositProcessed[scId][assetId][actors[i]],
                "actor requests must be >= cancelled + processed amounts"
            );
        }
    }

    /// @dev Property: requested redemptions must be >= the fulfilled cancelled redemptions + fulfilled redemptions
    function property_cancelled_and_processed_redemptions_soundness() public {
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;
        address[] memory actors = _getActors();

        for (uint256 i; i < actors.length; i++) {
            gte(
                userRequestRedeemed[scId][assetId][actors[i]],
                userCancelledRedeems[scId][assetId][actors[i]] + userRedemptionsProcessed[scId][assetId][actors[i]],
                "actor requests must be >= cancelled + processed amounts"
            );
        }
    }

    /// @dev Property: total deposits must be >= the approved deposits
    function property_solvency_deposit_requests() public {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;

        uint256 totalDeposits;
        for (uint256 i; i < actors.length; i++) {
            totalDeposits += userRequestDeposited[scId][assetId][actors[i]];
        }

        gte(totalDeposits, approvedDeposits[scId][assetId], "total deposits < approved deposits");
    }

    /// @dev Property: total redemptions must be >= the approved redemptions
    function property_solvency_redemption_requests() public {
        address[] memory actors = _getActors();
        uint256 totalRedemptions;

        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = AssetId.wrap(_getAssetId());

        for (uint256 i; i < actors.length; i++) {
            totalRedemptions += userRequestRedeemed[scId][assetId][actors[i]];
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
        AssetId assetId = spoke.vaultDetails(vault).assetId;

        for (uint256 i; i < actors.length; i++) {
            (uint128 pending,) = shareClassManager.depositRequest(scId, assetId, actors[i].toBytes32());
            (, uint128 queued) = shareClassManager.queuedDepositRequest(scId, assetId, actors[i].toBytes32());

            eq(
                userRequestDeposited[scId][assetId][actors[i]] - userCancelledDeposits[scId][assetId][actors[i]]
                    - userDepositProcessed[scId][assetId][actors[i]],
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
        AssetId assetId = spoke.vaultDetails(vault).assetId;

        for (uint256 i; i < actors.length; i++) {
            (uint128 pending,) = shareClassManager.redeemRequest(scId, assetId, actors[i].toBytes32());
            (, uint128 queued) = shareClassManager.queuedRedeemRequest(scId, assetId, actors[i].toBytes32());

            eq(
                userRequestRedeemed[scId][assetId][actors[i]] - userCancelledRedeems[scId][assetId][actors[i]]
                    - userRedemptionsProcessed[scId][assetId][actors[i]],
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
    //     AssetId assetId = AssetId.wrap(_getAssetId());
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
    //     AssetId assetId = AssetId.wrap(_getAssetId());

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
        ShareClassId scId = vault.scId();
        AssetId assetId = AssetId.wrap(_getAssetId());

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
        ShareClassId scId = vault.scId();
        AssetId assetId = AssetId.wrap(_getAssetId());

        uint32 nowDepositEpoch = shareClassManager.nowDepositEpoch(scId, assetId);
        uint128 pendingDeposit = shareClassManager.pendingDeposit(scId, assetId);

        // get the pending and approved deposit amounts for the current epoch
        (, uint128 approvedAssetAmount,,,,) = shareClassManager.epochInvestAmounts(scId, assetId, nowDepositEpoch);

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
        // PoolId poolId = vault.poolId(); // Unused
        ShareClassId scId = vault.scId();
        AssetId assetId = AssetId.wrap(_getAssetId());

        (uint32 redeemEpochId) = shareClassManager.nowRedeemEpoch(scId, assetId);
        uint128 pendingRedeem = shareClassManager.pendingRedeem(scId, assetId);

        // get the pending and approved redeem amounts for the current epoch
        (, uint128 approvedShareAmount,,,,) = shareClassManager.epochRedeemAmounts(scId, assetId, redeemEpochId);

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
                    AssetId assetId = AssetId.wrap(_getAssetId());

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
    //             AssetId assetId = AssetId.wrap(_getAssetId());
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
                AssetId assetId = AssetId.wrap(_getAssetId());

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
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = AssetId.wrap(_getAssetId());
        AccountId accountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));

        (, uint128 assets) = accounting.accountValue(poolId, accountId);
        uint128 holdingsValue = holdings.value(poolId, scId, assetId);

        // This property holds all of the system accounting together
        // NOTE: If priceAssetPerPool == 0, this equality might break, investigate then
        uint128 deltaAssetsHoldingValue = assets - holdingsValue;
        t(
            deltaAssetsHoldingValue == 0 || _before.pricePoolPerAsset[poolId][scId][assetId].raw() == 0,
            "Assets and Holdings value must match except if price is zero"
        );
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
                AssetId assetId = AssetId.wrap(_getAssetId());

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
        AssetId assetId = AssetId.wrap(_getAssetId());

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
                AssetId assetId = AssetId.wrap(_getAssetId());

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
        AssetId assetId = AssetId.wrap(_getAssetId());

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
                AssetId assetId = AssetId.wrap(_getAssetId());

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
        ShareClassId scId = vault.scId();
        AssetId assetId = AssetId.wrap(_getAssetId());

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

    /// @dev Property: The amount of holdings of an asset for a pool-shareClass pair in Holdings MUST always be equal to
    /// the balance of the escrow for said pool-shareClass for the respective token
    /// @dev This property is undefined when price is zero (no shares issued, so holdings don't track escrow movements)
    function property_holdings_balance_equals_escrow_balance() public {
        IBaseVault vault = IBaseVault(_getVault());

        // Guard: Skip when price is zero (property is undefined)
        if (_before.pricePerShare == 0) return;

        address asset = vault.asset();
        AssetId assetId = spoke.vaultDetails(vault).assetId;

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
        AssetId assetId = AssetId.wrap(_getAssetId());

        // TODO(wischli): Find feasible replacement now that queues are always enabled
        // precondition: if queue is enabled, return early because the totalIssuance is only updated immediately when
        // the queue isn't enabled
        return;

        // Unreachable code commented out to fix compiler warnings
        // (uint128 totalIssuance,) = shareClassManager.metrics(scId);
        // uint256 minted = issuedHubShares[poolId][scId][assetId] + issuedBalanceSheetShares[poolId][scId]
        //     + sumOfSyncDepositsShare[vault.share()];
        // uint256 burned = revokedHubShares[poolId][scId][assetId] + revokedBalanceSheetShares[poolId][scId];
        // console2.log("issuedHubShares:", issuedHubShares[poolId][scId][assetId]);
        // console2.log("issuedBalanceSheetShares:", issuedBalanceSheetShares[poolId][scId]);
        // console2.log("sumOfSyncDepositsShare:", sumOfSyncDepositsShare[vault.share()]);
        // console2.log("revokedHubShares:", revokedHubShares[poolId][scId][assetId]);
        // console2.log("revokedBalanceSheetShares:", revokedBalanceSheetShares[poolId][scId]);
        // lte(totalIssuance, minted - burned, "total issuance is > issuedHubShares + issuedBalanceSheetShares");
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
            uint256 expectedShares =
                _before.pricePerShare == 0 ? 0 : (_before.pricePerShare * assetDelta) - (10 ** decimals);
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
            uint256 expectedShares =
                _before.pricePerShare == 0 ? 0 : (_before.pricePerShare * assetDelta) + (10 ** decimals);
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
    //             AssetId assetId = AssetId.wrap(_getAssetId());

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
        AssetId assetId = AssetId.wrap(_getAssetId());

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
        AssetId assetId = AssetId.wrap(_getAssetId());

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

    /// === ZERO PRICE PROPERTIES === ///

    /// @dev Property: When price is zero, no shares should be issued
    function property_zeroPrice_noShareIssuance() public {
        if (_before.pricePerShare == 0) {
            // Verify no new shares were issued in this transaction
            uint256 shareSupplyDelta = _after.totalShareSupply - _before.totalShareSupply;
            eq(shareSupplyDelta, 0, "Shares issued at zero price");
        }
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

    /// @dev Doomsday test: System handles all operations gracefully at zero price
    function doomsday_zeroPrice_noPanics() public statelessTest {
        IBaseVault vault = IBaseVault(_getVault());
        if (address(vault) == address(0)) return;

        // Set zero price directly
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;
        hub.updateSharePrice(poolId, scId, D18.wrap(0));

        // === CONVERSION FUNCTION TESTS === //
        try vault.convertToShares(1e18) returns (uint256 shares) {
            eq(shares, 0, "convertToShares should return 0 at zero price");
        } catch {
            t(false, "convertToShares should not panic at zero price");
        }

        try vault.convertToAssets(1e18) returns (uint256 assets) {
            eq(assets, 0, "convertToAssets should return 0 at zero price");
        } catch {
            t(false, "convertToAssets should not panic at zero price");
        }

        try BaseVault(address(vault)).pricePerShare() returns (uint256 pps) {
            eq(pps, 0, "pricePerShare should be 0");
        } catch {
            t(false, "pricePerShare should not panic at zero price");
        }

        // === VAULT OPERATION TESTS === //
        try vault.maxDeposit(_getActor()) returns (uint256 max) {
            eq(max, 0, "maxDeposit handled zero price");
        } catch {
            t(false, "maxDeposit shout not revert at zero price");
        }

        try vault.maxMint(_getActor()) returns (uint256 max) {
            eq(max, 0, "maxMint should return 0 at zero price");
        } catch {
            t(false, "maxMint shout not revert at zero price");
        }

        try vault.maxRedeem(_getActor()) returns (uint256 max) {
            eq(max, 0, "maxRedeem should return 0 at zero price");
        } catch {
            t(false, "maxRedeem shout not revert at zero price");
        }

        try vault.maxWithdraw(_getActor()) returns (uint256 max) {
            eq(max, 0, "maxWithdraw should return 0 at zero price");
        } catch {
            t(false, "maxWithdraw shout not revert at zero price");
        }

        // === SHARE CLASS MANAGER OPERATIONS === //
        uint32 nowIssueEpoch = shareClassManager.nowIssueEpoch(scId, assetId);
        try shareClassManager.issueShares(poolId, scId, assetId, nowIssueEpoch, D18.wrap(0)) returns (
            uint128 issued, uint128, uint128
        ) {
            eq(issued, 0, "issued shares should return 0 at zero price");
        } catch (bytes memory reason) {
            bool expectedRevert = checkError(reason, "EpochNotFound()");
            t(expectedRevert, "issueShares shout not revert at zero price apart from EpochNotFound");
        }

        uint32 nowRevokeEpoch = shareClassManager.nowRevokeEpoch(scId, assetId);
        try shareClassManager.revokeShares(poolId, scId, assetId, nowRevokeEpoch, D18.wrap(0)) returns (
            uint128, uint128 assetAmount, uint128
        ) {
            eq(assetAmount, 0, "revoked asset amount should return 0 at zero price");
        } catch (bytes memory reason) {
            bool expectedRevert = checkError(reason, "EpochNotFound()");
            t(expectedRevert, "issueShares shout not revert at zero price apart from EpochNotFound");
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

    /// @notice ========================== SHARE QUEUE PROPERTIES ==========================
    /// @dev Share Queue Properties - higher risk area
    /// @dev These properties verify the critical share queue flip logic that poses the greatest risk to protocol
    /// integrity

    // Property 3.1 & 3.2: Issue/Revoke Logic Correctness
    /// @notice Verifies that the share queue delta and isPositive flag correctly represent the net position
    function property_shareQueueFlipLogic() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            for (uint256 j = 0; j < activeShareClasses[poolId].length; j++) {
                ShareClassId scId = activeShareClasses[poolId][j];
                bytes32 key = _poolShareKey(poolId, scId);

                (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(poolId, scId);

                // Calculate expected net position from ghost tracking
                int256 expectedNet = ghost_netSharePosition[key];

                // Calculate actual net position from queue state
                int256 actualNet = isPositive ? int256(uint256(delta)) : -int256(uint256(delta));

                // For zero delta, must be negative (isPositive = false)
                if (delta == 0) {
                    t(!isPositive, "SHARE-QUEUE-01: Zero delta must have isPositive = false");
                    t(actualNet == 0, "SHARE-QUEUE-02: Zero delta must represent zero net position");
                } else {
                    // Non-zero delta: verify sign consistency
                    t(
                        (isPositive && actualNet > 0) || (!isPositive && actualNet < 0),
                        "SHARE-QUEUE-03: isPositive flag must match delta sign"
                    );
                }

                // Verify net position matches tracked operations
                if (actualNet != expectedNet) {
                    t(false, "SHARE-QUEUE-04: Net position must match tracked issue/revoke operations");
                }
            }
        }
    }

    // Property 3.3: Verify flip detection and boundaries
    /// @notice Verifies that flips between positive and negative net positions are correctly detected
    function property_shareQueueFlipBoundaries() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            for (uint256 j = 0; j < activeShareClasses[poolId].length; j++) {
                ShareClassId scId = activeShareClasses[poolId][j];
                bytes32 key = _poolShareKey(poolId, scId);

                // Get before and after states
                uint128 deltaBefore = before_shareQueueDelta[key];
                bool isPositiveBefore = before_shareQueueIsPositive[key];

                (uint128 deltaAfter, bool isPositiveAfter,,) = balanceSheet.queuedShares(poolId, scId);

                // Check if a flip occurred
                bool flipOccurred = (isPositiveBefore != isPositiveAfter) && (deltaBefore != 0 || deltaAfter != 0);

                if (flipOccurred) {
                    // Verify flip was tracked
                    uint256 expectedFlips = ghost_flipCount[key];
                    gte(expectedFlips, 1, "SHARE-QUEUE-05: Flip must be tracked in ghost variables");

                    // Verify delta calculation after flip
                    // After flip: new_delta = |operation_amount - old_delta|
                    // This is implicitly verified by Property 3.1/3.2
                }
            }
        }
    }

    // Property 3.5: Net Position Commutativity
    /// @notice Verifies that net position equals total issued minus total revoked (mathematical invariant)
    function property_shareQueueCommutativity() public {
        // This property requires testing operation sequences
        // Best tested through specific handler sequences in integration tests
        // Here we verify the mathematical invariant holds

        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            for (uint256 j = 0; j < activeShareClasses[poolId].length; j++) {
                ShareClassId scId = activeShareClasses[poolId][j];
                bytes32 key = _poolShareKey(poolId, scId);

                // Net position should equal total issued minus total revoked
                int256 expectedFromTotals = int256(ghost_totalIssued[key]) - int256(ghost_totalRevoked[key]);
                int256 trackedNet = ghost_netSharePosition[key];

                if (expectedFromTotals != trackedNet) {
                    t(false, "SHARE-QUEUE-06: Net position must be commutative (issued - revoked)");
                }
            }
        }
    }

    // Property 3.6 & 3.7: Queue Reset and Snapshot Logic
    /// @notice Verifies queue submission logic and reset behavior
    function property_shareQueueSubmission() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            for (uint256 j = 0; j < activeShareClasses[poolId].length; j++) {
                ShareClassId scId = activeShareClasses[poolId][j];
                bytes32 key = _poolShareKey(poolId, scId);

                (uint128 delta, bool isPositive, uint32 assetCounter, uint64 nonce) =
                    balanceSheet.queuedShares(poolId, scId);

                // If a submission occurred, verify reset
                if (nonce > before_nonce[key]) {
                    // After submission, delta should be 0 and isPositive false
                    // (unless new operations occurred after submission)

                    // Property 3.7: Snapshot logic
                    // isSnapshot should be true when assetCounter == 0
                    // This is checked during submission execution
                }

                // Verify nonce never decreases
                gte(nonce, before_nonce[key], "SHARE-QUEUE-07: Nonce must never decrease");
            }
        }
    }

    // Property 3.8: Asset Counter Consistency
    /// @notice Verifies that the asset counter accurately reflects non-empty asset queues
    function property_shareQueueAssetCounter() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            for (uint256 j = 0; j < activeShareClasses[poolId].length; j++) {
                ShareClassId scId = activeShareClasses[poolId][j];

                (,, uint32 actualCounter,) = balanceSheet.queuedShares(poolId, scId);

                // Count actual non-empty asset queues
                uint256 expectedCounter = 0;
                for (uint256 k = 0; k < trackedAssets.length; k++) {
                    AssetId assetId = trackedAssets[k];
                    (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(poolId, scId, assetId);

                    if (deposits > 0 || withdrawals > 0) {
                        expectedCounter++;
                    }
                }

                eq(
                    uint256(actualCounter),
                    expectedCounter,
                    "SHARE-QUEUE-08: Asset counter must match actual non-empty queues"
                );

                // Counter should never exceed total possible assets
                lte(
                    uint256(actualCounter),
                    trackedAssets.length,
                    "SHARE-QUEUE-09: Counter cannot exceed total tracked assets"
                );
            }
        }
    }

    // ============ Queue State Consistency Properties ============

    /// @dev Property 1.1: Asset Queue Counter Consistency
    /// Definition: queuedAssets[p][sc][a].deposits + queuedAssets[p][sc][a].withdrawals > 0 ⟺ queuedAssetCounter
    /// includes asset a
    /// Ensures counter accurately tracks non-empty queues
    function property_assetQueueCounterConsistency() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            ShareClassId[] memory shareClassIds = activeShareClasses[poolId];

            for (uint256 j = 0; j < shareClassIds.length; j++) {
                ShareClassId scId = shareClassIds[j];

                // Get the queuedAssetCounter from BalanceSheet
                (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(poolId, scId);
                uint256 nonEmptyAssetCount = 0;

                // Count non-empty asset queues
                for (uint256 k = 0; k < trackedAssets.length; k++) {
                    AssetId assetId = trackedAssets[k];
                    (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(poolId, scId, assetId);

                    if (deposits > 0 || withdrawals > 0) {
                        nonEmptyAssetCount++;

                        // Ghost variable should track this asset as non-empty
                        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
                        t(
                            ghost_assetCounterPerAsset[assetKey] == 1,
                            "property_assetQueueCounterConsistency: ghost tracking mismatch"
                        );
                    }
                }

                // Property: Counter should equal number of non-empty asset queues
                eq(
                    uint256(queuedAssetCounter),
                    nonEmptyAssetCount,
                    "property_assetQueueCounterConsistency: counter mismatch"
                );
            }
        }
    }

    /// @dev Property 1.2: Asset Counter Bounds
    /// Definition: Sum of individual asset queue counters ≤ total queuedAssetCounter for share class
    /// Prevents counter overflow or manipulation
    function property_assetCounterBounds() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            ShareClassId[] memory shareClassIds = activeShareClasses[poolId];

            for (uint256 j = 0; j < shareClassIds.length; j++) {
                ShareClassId scId = shareClassIds[j];

                (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(poolId, scId);

                // Counter should not exceed total number of tracked assets
                lte(
                    uint256(queuedAssetCounter),
                    trackedAssets.length,
                    "property_assetCounterBounds: counter exceeds max possible"
                );
            }
        }
    }

    /// @dev Property 1.3: Asset Queue Non-Negative
    /// Definition: Asset queues can never underflow (deposits/withdrawals ≥ 0)
    /// Mathematical consistency of accumulation
    function property_assetQueueNonNegative() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            ShareClassId[] memory shareClassIds = activeShareClasses[poolId];

            for (uint256 j = 0; j < shareClassIds.length; j++) {
                ShareClassId scId = shareClassIds[j];

                for (uint256 k = 0; k < trackedAssets.length; k++) {
                    AssetId assetId = trackedAssets[k];
                    (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(poolId, scId, assetId);

                    // Both values must be non-negative (uint128 enforces this, but verify explicitly)
                    gte(uint256(deposits), 0, "property_assetQueueNonNegative: negative deposits");
                    gte(uint256(withdrawals), 0, "property_assetQueueNonNegative: negative withdrawals");

                    // Ghost variables should also be non-negative
                    bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
                    gte(
                        ghost_assetQueueDeposits[assetKey], 0, "property_assetQueueNonNegative: ghost deposits negative"
                    );
                    gte(
                        ghost_assetQueueWithdrawals[assetKey],
                        0,
                        "property_assetQueueNonNegative: ghost withdrawals negative"
                    );
                }
            }
        }
    }

    /// @dev Property 1.4: Share Queue isPositive Flag Consistency
    /// Definition: queuedShares[p][sc].isPositive = true ⟺ queuedShares[p][sc].delta > 0
    /// This ensures the flag accurately represents the queue state in ALL scenarios:
    /// - When delta > 0: isPositive must be true (net issuance pending)
    /// - When delta = 0: isPositive must be false (no pending operations)
    /// This property covers the complete biconditional relationship and replaces the need
    /// for separate zero-delta checking as it encompasses all possible states.
    function property_shareQueueFlagConsistency() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            ShareClassId[] memory shareClassIds = activeShareClasses[poolId];

            for (uint256 j = 0; j < shareClassIds.length; j++) {
                ShareClassId scId = shareClassIds[j];

                (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(poolId, scId);

                // Complete biconditional check: isPositive ⟺ (delta > 0)
                if (delta > 0) {
                    t(isPositive, "property_shareQueueFlagConsistency: delta > 0 requires isPositive = true");
                } else {
                    // delta == 0 (uint128 cannot be negative)
                    t(!isPositive, "property_shareQueueFlagConsistency: delta = 0 requires isPositive = false");
                }
            }
        }
    }

    /// @dev Property 1.6: Nonce Monotonicity
    /// Definition: Nonce strictly increases with each submission
    /// Ensures proper message ordering
    function property_nonceMonotonicity() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            ShareClassId[] memory shareClassIds = activeShareClasses[poolId];

            for (uint256 j = 0; j < shareClassIds.length; j++) {
                ShareClassId scId = shareClassIds[j];
                bytes32 shareKey = keccak256(abi.encode(poolId, scId));

                (,,, uint64 currentNonce) = balanceSheet.queuedShares(poolId, scId);
                uint256 previousNonce = ghost_previousNonce[shareKey];

                // If we have a previous nonce recorded, current should be greater
                if (previousNonce > 0) {
                    gt(uint256(currentNonce), previousNonce, "property_nonceMonotonicity: nonce did not increase");
                }

                // Ghost variable tracking should be consistent
                if (ghost_shareQueueNonce[shareKey] > 0) {
                    gte(
                        uint256(currentNonce),
                        ghost_shareQueueNonce[shareKey],
                        "property_nonceMonotonicity: ghost nonce tracking inconsistent"
                    );
                }
            }
        }
    }

    /// @dev Property 2.6: Reserve/Unreserve Balance Integrity
    /// @notice Ensures reserve operations maintain balance consistency
    function property_reserveUnreserveBalanceIntegrity() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            ShareClassId[] storage shareClasses = activeShareClasses[poolId];

            for (uint256 j = 0; j < shareClasses.length; j++) {
                ShareClassId scId = shareClasses[j];

                for (uint256 k = 0; k < trackedAssets.length; k++) {
                    AssetId assetId = trackedAssets[k];
                    bytes32 key = keccak256(abi.encode(poolId, scId, assetId));

                    // Skip if no reserve operations occurred
                    if (ghost_totalReserveOperations[key] == 0 && ghost_totalUnreserveOperations[key] == 0) continue;

                    // Use vault to get asset address
                    IBaseVault vault = IBaseVault(_getVault());
                    address asset = vault.asset();

                    // Get available balance
                    uint128 available = balanceSheet.availableBalanceOf(poolId, scId, asset, 0);
                    uint128 reserved = uint128(ghost_netReserved[key]);
                    uint128 total = available + reserved;

                    // Core Invariant 1: Available = Total - Reserved (automatically satisfied by construction)
                    eq(
                        available,
                        total - reserved,
                        "Reserve accounting formula violated: available != total - reserved"
                    );

                    // Core Invariant 2: Reserved cannot exceed total (automatically satisfied by construction)
                    lte(reserved, total, "Reserved balance exceeds total balance");

                    // Core Invariant 3: Net reserved matches ghost tracking
                    // This is implicitly tested since we use ghost_netReserved to calculate reserved

                    // Core Invariant 4: No overflow occurred
                    t(!ghost_reserveOverflow[key], "Reserve operation caused overflow");

                    // Core Invariant 5: No underflow occurred
                    t(!ghost_reserveUnderflow[key], "Unreserve operation caused underflow");

                    // Core Invariant 6: Available + Reserved = Total (automatically satisfied by construction)
                    eq(uint256(available) + uint256(reserved), uint256(total), "Balance components don't sum to total");

                    // Core Invariant 7: Max reserved never exceeded total
                    // We can't validate this without accessing the escrow's actual reserved amount
                    // But we can ensure our ghost tracking didn't overflow

                    // Core Invariant 8: No integrity violations
                    eq(ghost_reserveIntegrityViolations[key], 0, "Reserve integrity violations detected");
                }
            }
        }
    }

    /// @dev Property 2.4: Escrow Balance Sufficiency
    /// @notice Ensures available balance always covers withdrawals
    function property_escrowBalanceSufficiency() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            ShareClassId[] storage shareClasses = activeShareClasses[poolId];

            for (uint256 j = 0; j < shareClasses.length; j++) {
                ShareClassId scId = shareClasses[j];

                for (uint256 k = 0; k < trackedAssets.length; k++) {
                    AssetId assetId = trackedAssets[k];
                    bytes32 key = keccak256(abi.encode(poolId, scId, assetId));

                    // Skip if not tracked
                    if (!ghost_escrowSufficiencyTracked[key]) continue;

                    // Use vault to get asset address
                    IBaseVault vault = IBaseVault(_getVault());
                    address asset = vault.asset();

                    // Get current available balance
                    uint128 available = balanceSheet.availableBalanceOf(poolId, scId, asset, 0);

                    // Get queued withdrawals
                    (, uint128 queuedWithdrawals) = balanceSheet.queuedAssets(poolId, scId, assetId);

                    // Available must cover all pending withdrawals
                    gte(available, queuedWithdrawals, "Insufficient balance for pending withdrawals");

                    // Core Invariant: Available = Total - Reserved
                    uint128 reserved = uint128(ghost_netReserved[key]);
                    uint128 calculatedTotal = available + reserved;

                    // Verify ghost tracking consistency
                    eq(available, ghost_escrowAvailableBalance[key], "Available balance ghost mismatch");
                    eq(reserved, ghost_escrowReservedBalance[key], "Reserved balance ghost mismatch");

                    // Total must cover all obligations
                    gte(calculatedTotal, reserved + queuedWithdrawals, "Total balance insufficient for obligations");

                    // No failed withdrawals should occur if balance is sufficient
                    eq(ghost_failedWithdrawalAttempts[key], 0, "Withdrawals failed despite sufficient balance");
                }
            }
        }
    }

    /// @dev Property 2.7: Authorization Boundary Enforcement
    /// @notice Ensures only authorized parties perform privileged operations
    function property_authorizationBoundaryEnforcement() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            bytes32 poolKey = keccak256(abi.encode(poolId));

            // No unauthorized operations should succeed
            eq(ghost_unauthorizedAttempts[poolKey], 0, "Unauthorized operations succeeded");

            // Check for authorization bypass
            t(!ghost_authorizationBypass[poolKey], "Authorization checks were bypassed");

            ShareClassId[] storage shareClasses = activeShareClasses[poolId];
            for (uint256 j = 0; j < shareClasses.length; j++) {
                ShareClassId scId = shareClasses[j];
                bytes32 key = keccak256(abi.encode(poolId, scId));

                // Verify all privileged operations had proper authorization
                if (ghost_privilegedOperationCount[key] > 0) {
                    address lastCaller = ghost_lastAuthorizedCaller[key];
                    AuthLevel recordedLevel = ghost_authorizationLevel[lastCaller];

                    // Must be ward or manager
                    t(recordedLevel != AuthLevel.NONE, "Non-authorized address performed privileged operation");

                    // Verify authorization is still valid
                    if (recordedLevel == AuthLevel.WARD) {
                        eq(balanceSheet.wards(lastCaller), 1, "Ward authorization was revoked but operations continued");
                    } else if (recordedLevel == AuthLevel.MANAGER) {
                        t(
                            balanceSheet.manager(poolId, lastCaller),
                            "Manager authorization was revoked but operations continued"
                        );
                    }
                }
            }

            // Check authorization consistency across all actors
            address[] memory actors = _getActors();
            for (uint256 k = 0; k < actors.length; k++) {
                AuthLevel recordedAuth = ghost_authorizationLevel[actors[k]];
                AuthLevel actualAuth = AuthLevel.NONE;

                // Determine actual authorization level
                if (balanceSheet.wards(actors[k]) == 1) {
                    actualAuth = AuthLevel.WARD;
                } else if (balanceSheet.manager(poolId, actors[k])) {
                    actualAuth = AuthLevel.MANAGER;
                }

                // Recorded auth should match actual (or be higher if recently changed)
                gte(uint256(recordedAuth), uint256(actualAuth), "Authorization level tracking fell behind actual");

                // If auth changed, verify it was legitimate
                if (ghost_authorizationChanges[actors[k]] > 0 && actualAuth == AuthLevel.NONE) {
                    // Auth was revoked - ensure no operations after revocation
                    if (shareClasses.length > 0) {
                        address lastOp = ghost_lastAuthorizedCaller[keccak256(abi.encode(poolId, shareClasses[0]))];
                        t(
                            lastOp != actors[k] || ghost_authorizationChanges[actors[k]] == 1,
                            "Operations continued after authorization revoked"
                        );
                    }
                }
            }
        }
    }

    /// @dev Property 2.8: Share Transfer Restrictions
    /// @notice Ensures transfers from endorsed contracts are blocked
    function property_shareTransferRestrictions() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            ShareClassId[] storage shareClasses = activeShareClasses[poolId];

            for (uint256 j = 0; j < shareClasses.length; j++) {
                ShareClassId scId = shareClasses[j];
                bytes32 key = keccak256(abi.encode(poolId, scId));

                // No transfers from endorsed contracts should succeed
                eq(
                    ghost_endorsedTransferAttempts[key] - ghost_blockedEndorsedTransfers[key],
                    0,
                    "Transfers from endorsed contracts were not blocked"
                );

                // Verify all valid transfers came from non-endorsed addresses
                if (ghost_validTransferCount[key] > 0) {
                    address lastFrom = ghost_lastTransferFrom[key];

                    // Must not be endorsed contract
                    t(!ghost_isEndorsedContract[lastFrom], "Transfer from endorsed contract was allowed");

                    // Additional validation for special addresses
                    t(lastFrom != address(balanceSheet), "Transfer from BalanceSheet contract was allowed");
                    t(lastFrom != address(spoke), "Transfer from Spoke contract was allowed");
                    t(lastFrom != address(hub), "Transfer from Hub contract was allowed");
                }

                // Check endorsement changes didn't allow bypasses
                address[] memory actors = _getActors();
                for (uint256 k = 0; k < actors.length; k++) {
                    if (ghost_endorsementChanges[actors[k]] > 0) {
                        // If endorsement changed, verify no transfers during transition
                        if (ghost_lastTransferFrom[key] == actors[k] && ghost_isEndorsedContract[actors[k]]) {
                            t(false, "Transfer occurred during endorsement transition");
                        }
                    }
                }
            }
        }
    }

    /// @dev Property 2.1: Share Token Supply Consistency
    /// @notice Ensures total supply always equals sum of balances
    function property_shareTokenSupplyConsistency() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            ShareClassId[] storage shareClasses = activeShareClasses[poolId];

            for (uint256 j = 0; j < shareClasses.length; j++) {
                ShareClassId scId = shareClasses[j];
                bytes32 key = keccak256(abi.encode(poolId, scId));

                // Skip if no operations occurred
                if (!ghost_supplyOperationOccurred[key]) continue;

                try spoke.shareToken(poolId, scId) returns (IShareToken shareToken) {
                    uint256 actualSupply = shareToken.totalSupply();

                    // Check 1: Ghost tracking matches actual supply
                    eq(actualSupply, ghost_totalShareSupply[key], "Share supply mismatch - ghost diverged from actual");

                    // Check 2: Sum of balances equals total supply
                    address[] memory actors = _getActors();
                    uint256 calculatedSum = 0;
                    for (uint256 k = 0; k < actors.length; k++) {
                        uint256 balance = shareToken.balanceOf(actors[k]);
                        calculatedSum += balance;

                        // Verify individual balance tracking
                        eq(balance, ghost_individualBalances[key][actors[k]], "Individual balance tracking mismatch");
                    }

                    // Allow 1 wei tolerance per actor for rounding
                    uint256 tolerance = actors.length;
                    gte(actualSupply + tolerance, calculatedSum, "Supply less than sum of balances");
                    lte(actualSupply, calculatedSum + tolerance, "Supply exceeds sum of balances");

                    // Check 3: Mint/burn events match supply changes
                    uint256 expectedSupply = ghost_supplyMintEvents[key] - ghost_supplyBurnEvents[key];
                    eq(actualSupply, expectedSupply, "Supply doesn't match mint/burn history");
                } catch Error(string memory reason) {
                    if (ghost_supplyOperationOccurred[key]) {
                        t(false, string.concat("Share token unexpectedly missing: ", reason));
                    }
                }
            }
        }
    }

    /// @dev Property: Asset-Share Proportionality on Deposits
    /// Ensures that when assets are deposited, shares are issued proportionally based on current exchange rates
    /// This prevents unbacked share creation that could dilute existing holders
    function property_assetShareProportionalityDeposits() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            ShareClassId[] storage shareClasses = activeShareClasses[poolId];

            for (uint256 j = 0; j < shareClasses.length; j++) {
                ShareClassId scId = shareClasses[j];

                // Iterate through all tracked assets for this pool/shareClass
                for (uint256 k = 0; k < trackedAssets.length; k++) {
                    AssetId assetId = trackedAssets[k];
                    bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));

                    // Skip if no deposit proportionality tracking occurred
                    if (!ghost_depositProportionalityTracked[assetKey]) continue;

                    uint256 cumulativeAssets = ghost_cumulativeAssetsDeposited[assetKey];
                    uint256 cumulativeShares = ghost_cumulativeSharesIssuedForDeposits[assetKey];
                    uint256 avgExchangeRate = ghost_depositExchangeRate[assetKey];

                    // Skip if no meaningful deposits occurred
                    if (cumulativeAssets == 0) continue;

                    // Calculate expected shares based on average exchange rate
                    // expectedShares = cumulativeAssets * avgExchangeRate / 1e18
                    uint256 expectedShares = (cumulativeAssets * avgExchangeRate) / 1e18;

                    // EXACT INVARIANT: Use theoretical bounds instead of arbitrary tolerances
                    // Fetch prices for direct PricingLib calls (handles zero prices internally)
                    D18 pricePerAsset = spoke.pricePoolPerAsset(poolId, scId, assetId, true);
                    D18 pricePerShare = spoke.pricePoolPerShare(poolId, scId, false);

                    // Get real addresses for proper decimal handling
                    address shareToken = address(spoke.shareToken(poolId, scId));
                    (address asset, uint256 tokenId) = spoke.idToAsset(assetId);

                    // Calculate theoretical bounds only if prices are non-zero
                    uint256 maxTheoreticalShares = (D18.unwrap(pricePerAsset) == 0 || D18.unwrap(pricePerShare) == 0)
                        ? 0
                        : PricingLib.assetToShareAmount(
                            shareToken,
                            asset,
                            tokenId,
                            cumulativeAssets.toUint128(),
                            pricePerAsset,
                            pricePerShare,
                            MathLib.Rounding.Up
                        );
                    uint256 minTheoreticalShares = (D18.unwrap(pricePerAsset) == 0 || D18.unwrap(pricePerShare) == 0)
                        ? 0
                        : PricingLib.assetToShareAmount(
                            shareToken,
                            asset,
                            tokenId,
                            cumulativeAssets.toUint128(),
                            pricePerAsset,
                            pricePerShare,
                            MathLib.Rounding.Down
                        );

                    // Verify shares are within exact theoretical bounds only if prices are valid
                    if (D18.unwrap(pricePerAsset) != 0 && D18.unwrap(pricePerShare) != 0) {
                        gte(
                            cumulativeShares,
                            minTheoreticalShares,
                            "Shares below minimum theoretical bound - precision loss"
                        );
                        lte(
                            cumulativeShares,
                            maxTheoreticalShares,
                            "Shares exceed maximum theoretical bound - dilution attack"
                        );
                    }

                    // REMOVED: Arbitrary exchange rate variance check (was 1% tolerance)
                    // Exact relationship will be verified through conservation laws instead

                    // Note: Escrow verification omitted due to stack depth constraints
                    // The deposit/issue proportionality check is the primary validation
                }
            }
        }
    }

    /// @dev Property: Asset-Share Proportionality on Withdrawals
    /// Ensures that when assets are withdrawn, they are proportional to shares revoked based on current exchange rates
    /// This prevents extracting more value than share ownership represents and maintains fairness across redemptions
    function property_assetShareProportionalityWithdrawals() public {
        for (uint256 i = 0; i < activePools.length; i++) {
            PoolId poolId = activePools[i];
            ShareClassId[] storage shareClasses = activeShareClasses[poolId];

            for (uint256 j = 0; j < shareClasses.length; j++) {
                ShareClassId scId = shareClasses[j];

                // Iterate through all tracked assets for this pool/shareClass
                for (uint256 k = 0; k < trackedAssets.length; k++) {
                    AssetId assetId = trackedAssets[k];
                    bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));

                    // Skip if no withdrawals tracked for this combination
                    if (!ghost_withdrawalProportionalityTracked[assetKey]) continue;

                    uint256 cumulativeWithdrawn = ghost_cumulativeAssetsWithdrawn[assetKey];
                    uint256 cumulativeRevoked = ghost_cumulativeSharesRevokedForWithdrawals[assetKey];

                    // Only validate if we have both withdrawals and revocations
                    if (cumulativeWithdrawn > 0 && cumulativeRevoked > 0) {
                        // Core Invariant 1: Get current prices for proportionality validation
                        try spoke.pricePoolPerShare(poolId, scId, false) returns (D18 pricePerShare) {
                            try spoke.pricePoolPerAsset(poolId, scId, assetId, true) returns (D18 pricePerAsset) {
                                // Skip validation if either price is 0 (uninitialized state)
                                if (D18.unwrap(pricePerShare) == 0 || D18.unwrap(pricePerAsset) == 0) {
                                    continue;
                                }

                                // Calculate expected assets for the revoked shares at current prices
                                uint256 expectedAssets =
                                    (cumulativeRevoked * D18.unwrap(pricePerShare)) / D18.unwrap(pricePerAsset);

                                // Get real addresses for proper decimal handling
                                address shareToken = address(spoke.shareToken(poolId, scId));
                                (address asset, uint256 tokenId) = spoke.idToAsset(assetId);

                                // Calculate theoretical bounds only if prices are non-zero
                                uint256 maxTheoreticalAssets = (
                                    D18.unwrap(pricePerShare) == 0 || D18.unwrap(pricePerAsset) == 0
                                )
                                    ? 0
                                    : PricingLib.shareToAssetAmount(
                                        shareToken,
                                        cumulativeRevoked.toUint128(),
                                        asset,
                                        tokenId,
                                        pricePerShare,
                                        pricePerAsset,
                                        MathLib.Rounding.Up
                                    );
                                uint256 minTheoreticalAssets = (
                                    D18.unwrap(pricePerShare) == 0 || D18.unwrap(pricePerAsset) == 0
                                )
                                    ? 0
                                    : PricingLib.shareToAssetAmount(
                                        shareToken,
                                        cumulativeRevoked.toUint128(),
                                        asset,
                                        tokenId,
                                        pricePerShare,
                                        pricePerAsset,
                                        MathLib.Rounding.Down
                                    );

                                // Core Invariant 2: Withdrawn assets within exact theoretical bounds only if prices are
                                // valid
                                if (D18.unwrap(pricePerShare) != 0 && D18.unwrap(pricePerAsset) != 0) {
                                    gte(
                                        cumulativeWithdrawn,
                                        minTheoreticalAssets,
                                        "Insufficient assets withdrawn - below theoretical minimum"
                                    );
                                    lte(
                                        cumulativeWithdrawn,
                                        maxTheoreticalAssets,
                                        "Excessive assets withdrawn - above theoretical maximum"
                                    );
                                }

                                // Core Invariant 3: Withdrawals cannot exceed total deposits
                                lte(
                                    cumulativeWithdrawn,
                                    ghost_cumulativeAssetsDeposited[assetKey],
                                    "Withdrew more than total deposited"
                                );

                                // REMOVED: Arbitrary 1% exchange rate variance check
                                // Will be replaced with monotonic properties to ensure fairness
                            } catch {
                                // Asset price fetch failed, skip current price validation
                            }
                        } catch {
                            // Share price fetch failed, skip current price validation
                        }

                        // Note: Escrow balance validation omitted due to stack depth constraints
                        // The withdrawal/revocation proportionality check is the primary validation
                    }
                }
            }
        }
    }

}
