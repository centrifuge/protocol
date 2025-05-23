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
import {PoolEscrow} from "src/spokes/Escrow.sol";
import {AccountType} from "src/hub/interfaces/IHub.sol";
import {IBaseVault} from "src/spokes/interfaces/vaults/IBaseVaults.sol";
import {IShareToken} from "src/spokes/interfaces/IShareToken.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";
import {VaultDetails} from "src/spokes/interfaces/ISpoke.sol";

import {OpType} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {BeforeAfter} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {AsyncVaultCentrifugeProperties} from "test/integration/recon-end-to-end/properties/AsyncVaultCentrifugeProperties.sol";
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
        if(Helpers.isAsyncVault(address(vault))) {
            address shareToken = vault.share();
            lte(sumOfClaimedDeposits[address(shareToken)], sumOfFullfilledDeposits[address(shareToken)], "sumOfClaimedDeposits[address(shareToken)] > sumOfFullfilledDeposits[address(shareToken)]");
        }
    }

    /// @dev Property: the sum of assets received on redeem and withdraw <= sum of payout of fulfilledRedeemRequest
    function property_sum_of_assets_received() public assetIsSet {
        // Redeem and Withdraw
        IBaseVault vault = IBaseVault(_getVault());
        address asset = vault.asset();
        lte(sumOfClaimedRedemptions[address(asset)], currencyPayout[address(asset)], "sumOfClaimedRedemptions[address(_getAsset())] > currencyPayout[address(_getAsset())]");
    }

    /// @dev Property: the payout of the escrow is always <= sum of redemptions paid out
    function property_sum_of_pending_redeem_request() public tokenIsSet {
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());
        address asset = vault.asset();

        lte(sumOfClaimedRedemptions[address(asset)], requestRedeemedAssets[scId][assetId][_getActor()], "sumOfClaimedRedemptions > requestRedeemedAssets");
    }

    /// @dev Property: The sum of tranche tokens minted/transferred is equal to the total supply of tranche tokens
    function property_sum_of_minted_equals_total_supply() public tokenIsSet{
        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as token cannot overflow due to other
        // functions permanently reverting
        IBaseVault vault = IBaseVault(_getVault());
        uint256 ghostTotalSupply;
        address shareToken = vault.share();
        uint256 totalSupply = IShareToken(shareToken).totalSupply();

        unchecked {
            ghostTotalSupply = 
                (shareMints[address(shareToken)] + 
                executedInvestments[address(shareToken)]) -
                executedRedemptions[address(shareToken)];
        }
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
        // investmentManager_fulfillCancelDepositRequest
        IBaseVault vault = IBaseVault(_getVault());
        address asset = vault.asset();
        lte(sumOfClaimedDepositCancelations[address(asset)], cancelDepositCurrencyPayout[address(asset)], "sumOfClaimedDepositCancelations !<= cancelDepositCurrencyPayout");
    }

    /// @dev Property (inductive): Sum of assets received on claimCancelDepositRequest <= sum of fulfillCancelDepositRequest.assets
    function property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive() tokenIsSet public {
        // we only care about the case where the claimableCancelDepositRequest is decreasing because it indicates that a cancel deposit request was fulfilled
        if(
            _before.investments[_getActor()].claimableCancelDepositRequest > _after.investments[_getActor()].claimableCancelDepositRequest
        ) {
            uint256 claimableCancelDepositRequestDelta = _before.investments[_getActor()].claimableCancelDepositRequest - _after.investments[_getActor()].claimableCancelDepositRequest;
            // claiming a cancel deposit request means that the globalEscrow token balance decreases
            uint256 escrowAssetBalanceDelta = _before.escrowAssetBalance - _after.escrowAssetBalance;
            eq(claimableCancelDepositRequestDelta, escrowAssetBalanceDelta, "claimableCancelDepositRequestDelta != escrowAssetBalanceDelta");
        }
    }

    /// @dev Property: Sum of share class tokens received on claimCancelRedeemRequest <= sum of fulfillCancelRedeemRequest.shares
    function property_sum_of_received_leq_fulfilled() public tokenIsSet {
        // claimCancelRedeemRequest
        IBaseVault vault = IBaseVault(_getVault());
        lte(sumOfClaimedRedeemCancelations[address(vault.share())], cancelRedeemShareTokenPayout[address(vault.share())], "sumOfClaimedRedeemCancelations !<= cancelRedeemShareTokenPayout");
    }

    /// @dev Property (inductive): Sum of share class tokens received on claimCancelRedeemRequest <= sum of fulfillCancelRedeemRequest.shares
    function property_sum_of_received_leq_fulfilled_inductive() public tokenIsSet {
        // we only care about the case where the claimableCancelRedeemRequest is decreasing because it indicates that a cancel redeem request was fulfilled
        if(
            _before.investments[_getActor()].claimableCancelRedeemRequest > _after.investments[_getActor()].claimableCancelRedeemRequest
        ) {
            uint256 claimableCancelRedeemRequestDelta = _before.investments[_getActor()].claimableCancelRedeemRequest - _after.investments[_getActor()].claimableCancelRedeemRequest;
            // claiming a cancel redeem request means that the globalEscrow tranche token balance decreases
            uint256 escrowTrancheTokenBalanceDelta = _before.escrowTrancheTokenBalance - _after.escrowTrancheTokenBalance;
            eq(claimableCancelRedeemRequestDelta, escrowTrancheTokenBalanceDelta, "claimableCancelRedeemRequestDelta != escrowTrancheTokenBalanceDelta");
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
            // after a call to notifyDeposit the deposit price of the pool is set, so this checks that no other functions can modify the deposit price outside of the bounds
            lte(depositPrice, _after.investorsGlobals[_getVault()][_getActor()].maxDepositPrice, "depositPrice > maxDepositPrice");
            gte(depositPrice, _after.investorsGlobals[_getVault()][_getActor()].minDepositPrice, "depositPrice < minDepositPrice");
        }
    }

    /// @dev Property: The price at which a user redemption is made is bounded by the price when the request was fulfilled
    function property_price_on_redeem() public vaultIsSet {
        if (address(asyncRequestManager) == address(0)) {
            return;
        }

        // Get actor data
        {
            (, uint256 redeemPrice) = _getDepositAndRedeemPrice();

            lte(redeemPrice, _after.investorsGlobals[_getVault()][_getActor()].maxRedeemPrice, "redeemPrice > maxRedeemPrice");
            gte(redeemPrice, _after.investorsGlobals[_getVault()][_getActor()].minRedeemPrice, "redeemPrice < minRedeemPrice");
        }
    }

    /// @dev Property: The balance of currencies in Escrow is the sum of deposit requests -minus sum of claimed redemptions + transfers in -minus transfers out
    /// @dev NOTE: Ignores donations
    function property_escrow_balance() public assetIsSet {
        if (address(globalEscrow) == address(0)) {
            return;
        }

        IBaseVault vault = IBaseVault(_getVault());
        address asset = vault.asset();
        PoolId poolId = vault.poolId();
        address poolEscrow = address(poolEscrowFactory.escrow(poolId));
        uint256 balOfPoolEscrow = MockERC20(address(asset)).balanceOf(address(poolEscrow)); // The balance of tokens in Escrow is sum of deposit requests plus transfers in minus transfers out
        uint256 balOfGlobalEscrow = MockERC20(address(asset)).balanceOf(address(globalEscrow));

        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as assets cannot overflow due to other
        // functions permanently reverting
        uint256 ghostBalOfEscrow;
        unchecked {
            // Deposit Requests + Transfers In - Claimed Redemptions + TransfersOut
            /// @audit Minted by Asset Payouts by Investors
            ghostBalOfEscrow = (
                (sumOfDepositRequests[asset]  +
                sumOfSyncDeposits[vault.scId()][hubRegistry.currency(vault.poolId())]) -  
                (sumOfClaimedDepositCancelations[asset] +
                sumOfClaimedRedemptions[asset])
            );
            
        }

        eq(balOfPoolEscrow + balOfGlobalEscrow, ghostBalOfEscrow, "balOfEscrow != ghostBalOfEscrow");
    }

    /// @dev Property: The balance of share class tokens in Escrow is the sum of all fulfilled deposits - sum of all claimed deposits + sum of all redeem requests - sum of claimed redeem requests
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
                (sumOfFullfilledDeposits[address(shareToken)] + 
                sumOfRedeemRequests[address(shareToken)]) - 
                (sumOfClaimedDeposits[address(shareToken)] + 
                cancelRedeemShareTokenPayout[address(shareToken)] +
                sumOfClaimedRedeemCancelations[address(shareToken)])
            );
        }
        eq(balanceOfEscrow, ghostBalanceOfEscrow, "balanceOfEscrow != ghostBalanceOfEscrow");
    }

    // TODO: Multi Assets -> Iterate over all existing combinations

    /// @dev Property: The sum of account balances is always <= the balance of the escrow
    function property_sum_of_account_balances_leq_escrow() public vaultIsSet {
        IBaseVault vault = IBaseVault(_getVault());
        uint256 balOfEscrow = MockERC20(vault.asset()).balanceOf(address(globalEscrow));
        address poolEscrow = address(poolEscrowFactory.escrow(vault.poolId()));
        uint256 balOfPoolEscrow = MockERC20(vault.asset()).balanceOf(address(poolEscrow));

        // Use acc to track max amount withdrawable for each actor
        address[] memory actors = _getActors();
        uint256 acc;
        for (uint256 i; i < actors.length; i++) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo tranche
            try vault.maxWithdraw(actors[i]) returns (uint256 amt) {
                emit DebugWithString("maxWithdraw", amt);
                acc += amt;
            } catch {}
        }

        lte(acc, balOfEscrow + balOfPoolEscrow, "sum of account balances > balOfEscrow");
    }

    /// @dev Property: The sum of max claimable shares is always <= the share balance of the escrow
    function property_sum_of_possible_account_balances_leq_escrow() public vaultIsSet {
        IBaseVault vault = IBaseVault(_getVault());
        
        // Get the appropriate max value based on vault type
        uint256 max;
        if (!Helpers.isAsyncVault(_getVault())) {
            // Sync vault - use maxReserve
            AssetId assetId = hubRegistry.currency(vault.poolId());
            (address asset, uint256 tokenId) = spoke.idToAsset(assetId);
            uint256 maxAssets = uint256(syncRequestManager.maxReserve(vault.poolId(), vault.scId(), asset, tokenId));
            max = syncRequestManager.convertToShares(vault, maxAssets);
            console2.log("max %e", max);
        } else {
            // Async vault - use global escrow balance
            max = IShareToken(vault.share()).balanceOf(address(globalEscrow));
        }
        
        // Use acc to get maxMint for each actor
        address[] memory actors = _getActors();
        
        uint256 acc;
        for (uint256 i; i < actors.length; i++) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo share class
            try vault.maxMint(actors[i]) returns (uint256 amt) {
                acc += amt;
            } catch {}
        }

        console2.log("acc %e", acc);
        lte(acc, max, "account balance > max");
    }

    /// @dev Property: the totalAssets of a vault is always <= actual assets in the vault
    function property_totalAssets_solvency() public {
        IBaseVault vault = IBaseVault(_getVault());
        uint256 totalAssets = vault.totalAssets();
        address escrow = address(poolEscrowFactory.escrow(vault.poolId()));
        uint256 actualAssets = MockERC20(vault.asset()).balanceOf(escrow);
        
        uint256 differenceInAssets = totalAssets - actualAssets;
        uint256 differenceInShares = vault.convertToShares(differenceInAssets);

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

        for(uint256 i; i < actors.length; i++) {
            gte(requestDeposited[scId][assetId][actors[i]], depositProcessed[scId][assetId][actors[i]], "property_soundness_processed_deposits Actor Requests must be gte than processed amounts");
        }
    }

    /// @dev Property: requested redemptions must be >= the redemptions fulfilled
    function property_soundness_processed_redemptions() public {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());

        for(uint256 i; i < actors.length; i++) {
            gte(requestRedeemed[scId][assetId][actors[i]], redemptionsProcessed[scId][assetId][actors[i]], "property_soundness_processed_redemptions Actor Requests must be gte than processed amounts");
        }
    }

    /// @dev Property: requested deposits must be >= the fulfilled cancelled deposits
    function property_cancelled_soundness() public {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());


        for(uint256 i; i < actors.length; i++) {
            gte(requestDeposited[scId][assetId][actors[i]], cancelledDeposits[scId][assetId][actors[i]], "actor requests must be >= cancelled amounts");
        }
    }

    /// @dev Property: requested deposits must be >= the fulfilled cancelled deposits + fulfilled deposits
    function property_cancelled_and_processed_deposits_soundness() public {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());

        for(uint256 i; i < actors.length; i++) {
            gte(requestDeposited[scId][assetId][actors[i]], cancelledDeposits[scId][assetId][actors[i]] + depositProcessed[scId][assetId][actors[i]], "actor requests must be >= cancelled + processed amounts");
        }
    }

    /// @dev Property: requested redemptions must be >= the fulfilled cancelled redemptions + fulfilled redemptions
    function property_cancelled_and_processed_redemptions_soundness() public {
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());
        address[] memory actors = _getActors();

        for(uint256 i; i < actors.length; i++) {
            console2.log("Vault:", _getVault());
            console2.log("requestRedeemed:", requestRedeemed[scId][assetId][actors[i]]);
            console2.log("cancelledRedemptions:", cancelledRedemptions[scId][assetId][actors[i]]);
            console2.log("redemptionsProcessed:", redemptionsProcessed[scId][assetId][actors[i]]);
            gte(requestRedeemed[scId][assetId][actors[i]], cancelledRedemptions[scId][assetId][actors[i]] + redemptionsProcessed[scId][assetId][actors[i]], "actor requests must be >= cancelled + processed amounts");
        }
    }

    /// @dev Property: total deposits must be >= the approved deposits
    function property_solvency_deposit_requests() public {
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());

        uint256 totalDeposits;
        for(uint256 i; i < actors.length; i++) {
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

        for(uint256 i; i < actors.length; i++) {
            totalRedemptions += requestRedeemed[scId][assetId][actors[i]];
        }
        
        gte(totalRedemptions, approvedRedemptions[scId][assetId], "total redemptions < approved redemptions");
    }

    /// @dev Property: actor requested deposits - cancelled deposits - processed deposits actor pending deposits + queued deposits
    function property_actor_pending_and_queued_deposits() public {
        // Pending + Queued = Deposited?
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());

        for(uint256 i; i < actors.length; i++) {
            (uint128 pending, ) = shareClassManager.depositRequest(scId, assetId, actors[i].toBytes32());
            (, uint128 queued) = shareClassManager.queuedDepositRequest(scId, assetId, actors[i].toBytes32());

            eq(requestDeposited[scId][assetId][actors[i]] - cancelledDeposits[scId][assetId][actors[i]] - depositProcessed[scId][assetId][actors[i]], pending + queued, "actor requested deposits - cancelled deposits - processed deposits != actor pending deposits + queued deposits");
        }
    }

    /// @dev Property: actor requested redemptions - cancelled redemptions - processed redemptions actor pending redemptions + queued redemptions
    function property_actor_pending_and_queued_redemptions() public {
        // Pending + Queued = Deposited?
        address[] memory actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(vault.poolId());

        for(uint256 i; i < actors.length; i++) {
            (uint128 pending, ) = shareClassManager.redeemRequest(scId, assetId, actors[i].toBytes32());
            (, uint128 queued) = shareClassManager.queuedRedeemRequest(scId, assetId, actors[i].toBytes32());
            
            eq(requestRedeemed[scId][assetId][actors[i]] - cancelledRedemptions[scId][assetId][actors[i]] - redemptionsProcessed[scId][assetId][actors[i]], pending + queued, "property_actor_pending_and_queued_redemptions");
        }
    }

    /// @dev Property: escrow holding must be >= reserved
    function property_escrow_solvency() public {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);
        (address assetAddr, uint256 tokenId) = spoke.idToAsset(assetId);

        PoolEscrow poolEscrow = PoolEscrow(payable(address(poolEscrowFactory.escrow(poolId))));
        (uint128 holding, uint128 reserved) = poolEscrow.holding(scId, assetAddr, tokenId);
        gte(holding, reserved, "escrow holding must be >= reserved");
    }

    /// @dev Property: The price per share used in the entire system is ALWAYS provided by the admin
    function property_price_per_share_overall() public {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        // first check if the share amount changed 
        uint256 shareDelta;
        uint256 assetDelta;
        if(_before.totalShareSupply != _after.totalShareSupply) {
            if(_before.totalShareSupply > _after.totalShareSupply) {
                shareDelta = _before.totalShareSupply - _after.totalShareSupply;
                uint256 globalEscrowAssetDelta = _before.escrowAssetBalance - _after.escrowAssetBalance;
                uint256 poolEscrowAssetDelta = _before.poolEscrowAssetBalance - _after.poolEscrowAssetBalance;
                assetDelta = globalEscrowAssetDelta + poolEscrowAssetDelta;
            } else {
                shareDelta = _after.totalShareSupply - _before.totalShareSupply;
                uint256 globalEscrowAssetDelta = _after.escrowAssetBalance - _before.escrowAssetBalance;
                uint256 poolEscrowAssetDelta = _after.poolEscrowAssetBalance - _before.poolEscrowAssetBalance;
                assetDelta = globalEscrowAssetDelta + poolEscrowAssetDelta;
            }
            
            // calculate the expected share delta using the asset delta and the price per share
            VaultDetails memory vaultDetails = spoke.vaultDetails(vault);
            uint256 expectedShareDelta = PricingLib.assetToShareAmount(
                vault.share(),
                vaultDetails.asset,
                vaultDetails.tokenId,
                assetDelta.toUint128(),
                _before.pricePoolPerAsset[poolId][scId][assetId],
                _before.pricePoolPerShare[poolId][scId],
                MathLib.Rounding.Down
            );

            // if the share amount changed, check if it used the correct price per share set by the admin
            eq(shareDelta, expectedShareDelta, "shareDelta must be equal to expectedShareDelta");
        }
    }

    /// === HUB === ///

    /// @dev Property: The total pending asset amount pendingDeposit[..] is always >= the approved asset epochInvestAmounts[..].approvedAssetAmount
    function property_total_pending_and_approved() public {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        uint32 nowDepositEpoch = shareClassManager.nowDepositEpoch(scId, assetId);
        uint128 pendingDeposit = shareClassManager.pendingDeposit(scId, assetId);
        (uint128 pendingAssetAmount, uint128 approvedAssetAmount,,,,) = shareClassManager.epochInvestAmounts(scId, assetId, nowDepositEpoch);

        gte(pendingDeposit, approvedAssetAmount, "pendingDeposit < approvedAssetAmount");
        gte(pendingDeposit, pendingAssetAmount, "pendingDeposit < pendingAssetAmount");
    }

    /// @dev Property: The total pending redeem amount pendingRedeem[..] is always >= the sum of pending user redeem amounts redeemRequest[..]
    /// @dev Property: The total pending redeem amount pendingRedeem[..] is always >= the approved redeem amount epochRedeemAmounts[..].approvedShareAmount
    function property_total_pending_redeem_geq_sum_pending_user_redeem() public {
        address[] memory _actors = _getActors();
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        (uint32 redeemEpochId) = shareClassManager.nowRedeemEpoch(scId, assetId);
        uint128 pendingRedeem = shareClassManager.pendingRedeem(scId, assetId);

        // get the pending and approved redeem amounts for the current epoch
        (, uint128 approvedShareAmount, uint128 payoutAssetAmount,,,) = shareClassManager.epochRedeemAmounts(scId, assetId, redeemEpochId);
        
        uint128 totalPendingUserRedeem;
        for (uint256 k = 0; k < _actors.length; k++) {
            address actor = _actors[k];

            (uint128 pendingUserRedeem,) = shareClassManager.redeemRequest(scId, assetId, CastLib.toBytes32(actor));
            totalPendingUserRedeem += pendingUserRedeem;
        }
        
        // check that the pending redeem is >= the total pending user redeem
        gte(pendingRedeem, totalPendingUserRedeem, "pending redeem is < total pending user redeems");
        // check that the pending redeem is >= the approved redeem
        gte(pendingRedeem, approvedShareAmount, "pending redeem is < approved redeem");
    }  

    /// @dev Property: The total pending redeem amount pendingRedeem[..] is always >= the sum of pending user redeem amounts redeemRequest[..]
    /// @dev Property: The total pending redeem amount pendingRedeem[..] is always >= the approved redeem amount epochRedeemAmounts[..].approvedShareAmount
    // NOTE: previous implementation of the above property
    // function property_total_pending_redeem_geq_sum_pending_user_redeem() public {
    //     address[] memory _actors = _getActors();
    //     IBaseVault vault = IBaseVault(_getVault());
    //     PoolId poolId = vault.poolId();
    //     ShareClassId scId = vault.scId();
    //     AssetId assetId = hubRegistry.currency(poolId);

    //     (uint32 redeemEpochId,,,) = shareClassManager.epochId(scId, assetId);
    //     uint128 pendingRedeemCurrent = shareClassManager.pendingRedeem(scId, assetId);
        
    //     // get the pending and approved redeem amounts for the previous epoch
    //     (, uint128 approvedShareAmountPrevious, uint128 payoutAssetAmountPrevious,,,) = shareClassManager.epochRedeemAmounts(scId, assetId, redeemEpochId - 1);

    //     // get the pending and approved redeem amounts for the current epoch
    //     (, uint128 approvedShareAmountCurrent, uint128 payoutAssetAmountCurrent,,,) = shareClassManager.epochRedeemAmounts(scId, assetId, redeemEpochId);

    //     uint128 totalPendingUserRedeem = 0;
    //     for (uint256 k = 0; k < _actors.length; k++) {
    //         address actor = _actors[k];

    //         (uint128 pendingUserRedeemCurrent,) = shareClassManager.redeemRequest(scId, assetId, CastLib.toBytes32(actor));
    //         totalPendingUserRedeem += pendingUserRedeemCurrent;
            
    //         // pendingUserRedeem hasn't changed if the claimableAssetAmountPrevious is 0, so we can use it to calculate the claimableAssetAmount from the previous epoch 
    //         // uint128 approvedShareAmountPrevious = pendingUserRedeemCurrent.mulDiv(approvedShareAmountPrevious, payoutAssetAmountPrevious).toUint128();
    //         // console2.log("here properties 7");
    //         // uint128 claimableAssetAmountPrevious = uint256(approvedShareAmountPrevious).mulDiv(
    //         //     payoutAssetAmountPrevious, approvedShareAmountPrevious
    //         // ).toUint128();
    //         // account for the edge case where user claimed redemption in previous epoch but there was no claimable amount
    //         // in this case, the totalPendingUserRedeem will be greater than the pendingRedeemCurrent for this epoch 
            
    //         if(payoutAssetAmountPrevious > 0) {
    //             // check that the pending redeem is >= the total pending user redeem
    //             gte(pendingRedeemCurrent, totalPendingUserRedeem, "pending redeem is < total pending user redeems");
    //         }
    //     }
        
    //     // check that the pending redeem is >= the approved redeem
    //     gte(pendingRedeemCurrent, approvedShareAmountCurrent, "pending redeem is < approved redeem");
    // }  

    /// @dev Property: The epoch of a pool epochId[poolId] can increase at most by one within the same transaction (i.e. multicall/execute) independent of the number of approvals
    function property_epochId_can_increase_by_one_within_same_transaction() public {
        // precondition: there must've been a batch operation (call to execute/multicall)
        if(currentOperation == OpType.BATCH) {
            uint64[] memory _createdPools = _getPools();
            for (uint256 i = 0; i < _createdPools.length; i++) {
                PoolId poolId = PoolId.wrap(_createdPools[i]);
                uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
                // skip the first share class because it's never assigned
                for (uint32 j = 1; j < shareClassCount; j++) { 
                    ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                    AssetId assetId = hubRegistry.currency(poolId);
                    
                    uint32 depositEpochIdDifference = _after.ghostEpochId[scId][assetId].deposit - _before.ghostEpochId[scId][assetId].deposit;
                    uint32 redeemEpochIdDifference = _after.ghostEpochId[scId][assetId].redeem - _before.ghostEpochId[scId][assetId].redeem;
                    uint32 issueEpochIdDifference = _after.ghostEpochId[scId][assetId].issue - _before.ghostEpochId[scId][assetId].issue;
                    uint32 revokeEpochIdDifference = _after.ghostEpochId[scId][assetId].revoke - _before.ghostEpochId[scId][assetId].revoke;
                    
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
    function property_account_totalDebit_and_totalCredit_leq_max_int128() public {
        uint64[] memory _createdPools = _getPools();
        for (uint256 i = 0; i < _createdPools.length; i++) {
            PoolId poolId = PoolId.wrap(_createdPools[i]);
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);
                // loop over all account types defined in IHub::AccountType
                for(uint8 kind = 0; kind < 6; kind++) {
                    AccountId accountId = holdings.accountId(poolId, scId, assetId, kind);
                    (uint128 totalDebit, uint128 totalCredit,,,) = accounting.accounts(poolId, accountId);
                    lte(totalDebit, uint128(type(int128).max), "totalDebit is greater than max int128");
                    lte(totalCredit, uint128(type(int128).max), "totalCredit is greater than max int128");
                }
            }
        }
    }

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

                if(_before.ghostHolding[poolId][scId][assetId] > _after.ghostHolding[poolId][scId][assetId]) {
                    // loop over all account types defined in IHub::AccountType
                    for(uint8 kind = 0; kind < 6; kind++) {
                        AccountId accountId = holdings.accountId(poolId, scId, assetId, kind);
                        uint128 accountValueBefore = _before.ghostAccountValue[poolId][accountId];
                        uint128 accountValueAfter = _after.ghostAccountValue[poolId][accountId];
                        if(accountValueAfter > accountValueBefore) {
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
        console2.log("asset account", uint8(AccountType.Asset));
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
                AccountId assetAccountId = holdings.accountId(poolId, scId, assetId,  uint8(AccountType.Asset));
                AccountId equityAccountId = holdings.accountId(poolId, scId, assetId,  uint8(AccountType.Equity));
                AccountId gainAccountId = holdings.accountId(poolId, scId, assetId,  uint8(AccountType.Gain));
                AccountId lossAccountId = holdings.accountId(poolId, scId, assetId,  uint8(AccountType.Loss));

                (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
                (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);

                if(assets > equity) {
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
                AccountId assetAccountId = holdings.accountId(poolId, scId, assetId,  uint8(AccountType.Asset));
                AccountId equityAccountId = holdings.accountId(poolId, scId, assetId,  uint8(AccountType.Equity));
                AccountId gainAccountId = holdings.accountId(poolId, scId, assetId,  uint8(AccountType.Gain));
                AccountId lossAccountId = holdings.accountId(poolId, scId, assetId,  uint8(AccountType.Loss));

                (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
                (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);
                (, uint128 gain) = accounting.accountValue(poolId, gainAccountId);
                (, uint128 loss) = accounting.accountValue(poolId, lossAccountId);
                
                // equity = accountValue(Asset) + (ABS(accountValue(Loss)) - accountValue(Gain) // Loss comes back, gain is subtracted
                t(equity == assets + loss - gain, "property_equity_soundness"); // Loss comes back, gain is subtracted, since loss is negative we need to negate it                
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
                AccountId assetAccountId = holdings.accountId(poolId, scId, assetId,  uint8(AccountType.Asset));
                AccountId equityAccountId = holdings.accountId(poolId, scId, assetId,  uint8(AccountType.Equity));
                AccountId gainAccountId = holdings.accountId(poolId, scId, assetId,  uint8(AccountType.Gain));
                AccountId lossAccountId = holdings.accountId(poolId, scId, assetId,  uint8(AccountType.Loss));
                
                (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
                (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);
                (, uint128 gain) = accounting.accountValue(poolId, gainAccountId);
                (,uint128 loss) = accounting.accountValue(poolId, lossAccountId);   
                
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

    /// @dev Property: A user cannot mutate their pending redeem amount pendingRedeem[...] if the pendingRedeem[..].lastUpdate is <= the latest redeem approval epochId[..].redeem
    function property_user_cannot_mutate_pending_redeem() public {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        bytes32 actor = CastLib.toBytes32(_getActor());
        // precondition: user already has non-zero pending redeem and it has changed
        if(_before.ghostRedeemRequest[scId][assetId][actor].pending > 0 && _before.ghostRedeemRequest[scId][assetId][actor].pending != _after.ghostRedeemRequest[scId][assetId][actor].pending) {
            // check that the lastUpdate was > the latest redeem revoke pointer
            gt(_after.ghostRedeemRequest[scId][assetId][actor].lastUpdate, _after.ghostEpochId[scId][assetId].revoke, "lastUpdate is <= latest redeem revoke");
        }
    }

    /// @dev Property: The amount of holdings of an asset for a pool-shareClas pair in Holdings MUST always be equal to the balance of the escrow for said pool-shareClass for the respective token
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

    function property_total_issuance_soundness() public {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        (uint128 totalIssuance,) = shareClassManager.metrics(scId);
        
        uint256 minted = issuedHubShares[poolId][scId][assetId] + issuedBalanceSheetShares[poolId][scId] + sumOfSyncDeposits[scId][assetId];
        uint256 burned = revokedHubShares[poolId][scId][assetId] + revokedBalanceSheetShares[poolId][scId];
        lte(totalIssuance, minted - burned, "total issuance is > issuedHubShares + issuedBalanceSheetShares");
    }

    /// @dev Property: The amount of tokens existing in the AssetRegistry MUST always be <= the balance of the associated token in the escrow
    // TODO: confirm if this is correct because it seems like AssetRegistry would never be receiving tokens in the first place
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
    //             uint256 pendingShareClassEscrowBalance = assetRegistry.balanceOf(pendingShareClassEscrow, assetId.raw());
    //             uint256 shareClassEscrowBalance = assetRegistry.balanceOf(shareClassEscrow, assetId.raw());

    //             lte(assetRegistryBalance, pendingShareClassEscrowBalance + shareClassEscrowBalance, "assetRegistry balance > escrow balance");
    //         }
    //     }

    //     // TODO: check if this is the correct check
    //     // loop through all created assetIds
    //     // check if the asset is in the HubRegistry
    //     // if it is, check if there's any of the asset in the escrow
    // }


    /// Stateless Properties ///

    /// @dev Property: The sum of eligible user payoutShareAmount for an epoch is <= the number of issued epochInvestAmounts[..].pendingShareAmount
    /// @dev Property: The sum of eligible user payoutAssetAmount for an epoch is <= the number of issued asset epochInvestAmounts[..].pendingAssetAmount
    /// @dev Stateless because of the calls to claimDeposit which would make story difficult to read
    function property_eligible_user_deposit_amount_leq_deposit_issued_amount() public statelessTest {
        address[] memory _actors = _getActors();

        // sum up to the latest issuance epoch where users can claim deposits for 
        (uint32 latestDepositEpochId,, uint32 latestIssuanceEpochId,) = shareClassManager.epochId(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(_getAssetId()));
        
        uint128 sumDepositShares;
        uint128 sumDepositAssets;
        uint128 totalPayoutAssetAmount;
        uint128 totalPayoutShareAmount;
        for (uint32 epochId; epochId <= latestIssuanceEpochId; epochId++) {
            (uint128 pendingAssetAmount,,,,,) = shareClassManager.epochInvestAmounts(ShareClassId.wrap(_getShareClassId()), AssetId.wrap(_getAssetId()), epochId);
            sumDepositAssets += pendingAssetAmount;
            sumDepositShares = uint128(IBaseVault(_getVault()).convertToShares(pendingAssetAmount));
        
            // loop over all actors
            for (uint256 k = 0; k < _actors.length; k++) {
                address actor = _actors[k];
                
                // we claim via shareClassManager directly here because Hub doesn't return the payoutShareAmount
                (uint128 payoutShareAmount, uint128 payoutAssetAmount,,) = shareClassManager.claimDeposit(PoolId.wrap(_getPool()), ShareClassId.wrap(_getShareClassId()), CastLib.toBytes32(actor), AssetId.wrap(_getAssetId()));
                totalPayoutShareAmount += payoutShareAmount;
                totalPayoutAssetAmount += payoutAssetAmount;
            }

            // check that the totalPayoutAssetAmount is less than or equal to the approvedAssetAmount
            lte(totalPayoutAssetAmount, sumDepositAssets, "totalPayoutAssetAmount > sumDepositAssets");
            // check that the totalPayoutShareAmount is less than or equal to the pendingAssetAmount
            lte(totalPayoutShareAmount, sumDepositShares, "totalPayoutShareAmount > sumDepositShares");
            
            uint128 differenceShares = sumDepositShares - totalPayoutShareAmount;
            uint128 differenceAsset = sumDepositAssets - totalPayoutAssetAmount;
            // check that the totalPayoutShareAmount is no more than 1 wei less than the sumDepositShares
            lte(differenceShares, 1, "sumDepositShares - totalPayoutShareAmount difference is greater than 1");
            // check that the totalPayoutAssetAmount is no more than 1 wei less than the sumDepositAssets
            lte(differenceAsset, 1, "sumDepositAssets - totalPayoutAssetAmount difference is greater than 1");
        }
    }


    /// @dev Property: The sum of eligible user claim payout asset amounts for an epoch is <= the approved asset epochRedeemAmounts[..].approvedAssetAmount
    /// @dev Property: The sum of eligible user claim payment share amounts for an epoch is <= than the revoked share epochRedeemAmounts[..].pendingAssetAmount
    /// @dev This doesn't sum over previous epochs because it can be assumed that it'll be called by the fuzzer for each current epoch
    function property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount() public statelessTest {
        address[] memory _actors = _getActors();

        // loop over all created pools
        uint64[] memory _createdPools = _getPools();
        for (uint256 i = 0; i < _createdPools.length; i++) {
            PoolId poolId = PoolId.wrap(_createdPools[i]);
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // loop over all share classes in the pool
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                (,,, uint32 latestRevocationEpochId) = shareClassManager.epochId(scId, assetId);
                // sum up to the latest revocation epoch where users can claim redemptions for 
                uint128 sumRedeemApprovedShares;
                uint128 sumRedeemAssets;
                for (uint32 epochId; epochId <= latestRevocationEpochId; epochId++) {
                    (uint128 redeemAssets, uint128 redeemApprovedShares,,,,) = shareClassManager.epochRedeemAmounts(scId, assetId, epochId);
                    sumRedeemApprovedShares += redeemApprovedShares;
                    sumRedeemAssets += redeemAssets;
                }

                // sum eligible user claim payoutAssetAmount for the epoch
                uint128 totalPayoutAssetAmount = 0;
                uint128 totalPaymentShareAmount = 0;
                for (uint256 k = 0; k < _actors.length; k++) {
                    address actor = _actors[k];
                    // we claim via shareClassManager directly here because PoolRouter doesn't return the payoutAssetAmount
                    (uint128 payoutAssetAmount, uint128 paymentShareAmount,,) = shareClassManager.claimRedeem(poolId, scId, CastLib.toBytes32(actor), assetId);
                    totalPayoutAssetAmount += payoutAssetAmount;
                    totalPaymentShareAmount += paymentShareAmount;
                }

                // check that the totalPayoutAssetAmount is less than or equal to the sum of redeemAssets
                lte(totalPayoutAssetAmount, sumRedeemAssets, "total payout asset amount is > redeem assets");
                // check that the totalPaymentShareAmount is less than or equal to the sum of redeemApprovedShares
                lte(totalPaymentShareAmount, sumRedeemApprovedShares, "total payment share amount is > redeem shares revoked");

                uint128 differenceAsset = sumRedeemAssets - totalPayoutAssetAmount;
                uint128 differenceShare = sumRedeemApprovedShares - totalPaymentShareAmount;
                // check that the totalPayoutAssetAmount is no more than 1 wei less than the sum of redeemAssets
                lte(differenceAsset, 1, "sumRedeemAssets - totalPayoutAssetAmount difference is greater than 1");
                // check that the totalPaymentShareAmount is no more than 1 wei less than the sum of redeemApproved
                lte(differenceShare, 1, "sumRedeemApprovedShares - totalPaymentShareAmount difference is greater than 1");
            }
        }
    }

    /// === DOOMSDAY TESTS === ///

    /// @dev Property: pricePerShare never changes after a user operation
    function doomsday_pricePerShare_never_changes_after_user_operation() public {
        if(currentOperation != OpType.ADMIN) {
            eq(_before.pricePerShare, _after.pricePerShare, "pricePerShare changed after user operation");
        }
    }

    /// @dev Property: implied pricePerShare (totalAssets / totalSupply) never changes after a user operation
    function doomsday_impliedPricePerShare_never_changes_after_user_operation() public {
        if(currentOperation != OpType.ADMIN) {
            uint256 impliedPricePerShareBefore = _before.totalAssets / _before.totalShareSupply;
            uint256 impliedPricePerShareAfter = _after.totalAssets / _after.totalShareSupply;
            eq(impliedPricePerShareBefore, impliedPricePerShareAfter, "impliedPricePerShare changed after user operation");
        }
    }

    /// @dev Property: accounting.accountValue should never revert
    function doomsday_accountValue(uint64 poolIdAsUint, uint32 accountAsInt) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        AccountId account = AccountId.wrap(accountAsInt);
        
        try accounting.accountValue(poolId, account) {
        } catch (bytes memory reason) {
            bool expectedRevert = checkError(reason, "AccountDoesNotExist()");
            t(expectedRevert, "accountValue should never revert");
        }
    }

    // === OPTIMIZATION TESTS === // 

    /// @dev Optimzation test to check if the difference between totalAssets and actualAssets is greater than 1 share
    function optimize_totalAssets_solvency() public view returns (int256) {
        uint256 totalAssets = IBaseVault(_getVault()).totalAssets();
        uint256 actualAssets = MockERC20(IBaseVault(_getVault()).asset()).balanceOf(address(globalEscrow));
        uint256 difference = totalAssets - actualAssets;

        uint256 differenceInShares = IBaseVault(_getVault()).convertToShares(difference);

        if (differenceInShares > (10 ** IShareToken(_getShareToken()).decimals()) - 1) {
            return int256(difference);
        }

        return 0;
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
        systemAddresses[4] = address(syncRequestManager);
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
