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
import {PoolEscrow} from "src/vaults/Escrow.sol";
import {AccountType} from "src/hub/interfaces/IHub.sol";

import {OpType} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {BeforeAfter} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {AsyncVaultCentrifugeProperties} from "test/integration/recon-end-to-end/properties/AsyncVaultCentrifugeProperties.sol";

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
    function property_sentinel_token_balance() public {
        if (!RECON_USE_SENTINEL_TESTS) {
            return; // Skip if setting is off
        }

        if (address(token) == address(0)) {
            return; // Skip
        }
        
        // Dig until we get non-zero share class balance
        // Afaict this will never work
        eq(token.balanceOf(_getActor()), 0, "token.balanceOf(getActor()) != 0");
    }

    // == VAULT == //

    /// @dev Property: Sum of share class tokens received on `deposit` and `mint` <= sum of fulfilledDepositRequest.shares
    function property_global_1() public tokenIsSet {
        // Mint and Deposit
        lte(sumOfClaimedDeposits[address(token)], sumOfFullfilledDeposits[address(token)], "sumOfClaimedDeposits[address(token)] > sumOfFullfilledDeposits[address(token)]");
    }

    function property_global_2() public assetIsSet {
        // Redeem and Withdraw
        lte(sumOfClaimedRedemptions[address(_getAsset())], mintedByCurrencyPayout[address(_getAsset())], "sumOfClaimedRedemptions[address(_getAsset())] > mintedByCurrencyPayout[address(_getAsset())]");
    }

    function property_global_2_inductive() public tokenIsSet {
        // we only care about the case where the pendingRedeemRequest is decreasing because it indicates that a redeem was fulfilled
        // we also need to ensure that the claimableCancelRedeemRequest is the same because if it's not, the redeem request was cancelled
        if(
            _before.investments[_getActor()].pendingRedeemRequest > _after.investments[_getActor()].pendingRedeemRequest &&
            _before.investments[_getActor()].claimableCancelRedeemRequest ==  _after.investments[_getActor()].claimableCancelRedeemRequest 
        ) {
            uint256 pendingRedeemRequestDelta = _before.investments[_getActor()].pendingRedeemRequest - _after.investments[_getActor()].pendingRedeemRequest;
            // tranche tokens get burned when redeemed so the escrowTrancheTokenBalance decreases
            uint256 escrowTokenDelta = _before.escrowTrancheTokenBalance - _after.escrowTrancheTokenBalance;
                        
            eq(pendingRedeemRequestDelta, escrowTokenDelta, "pendingRedeemRequest != fullfilledRedeem");
        }
    }

    // The sum of tranche tokens minted/transferred is equal to the total supply of tranche tokens
    function property_global_3() public tokenIsSet{
        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as token cannot overflow due to other
        // functions permanently reverting
        uint256 ghostTotalSupply;
        uint256 totalSupply = token.totalSupply();
        unchecked {
            
            // NOTE: Includes `shareMints` which are arbitrary mints
            ghostTotalSupply = shareMints[address(token)] + executedInvestments[address(token)] + incomingTransfers[address(token)]
                - outGoingTransfers[address(token)] - executedRedemptions[address(token)];
        }
        eq(totalSupply, ghostTotalSupply, "totalSupply != ghostTotalSupply");
    }

    function property_global_4() public assetIsSet {

        address[] memory systemAddresses = _getSystemAddresses();
        uint256 SYSTEM_ADDRESSES_LENGTH = systemAddresses.length;

        // NOTE: Skipping root and gateway since we mocked them
        for (uint256 i; i < SYSTEM_ADDRESSES_LENGTH; i++) {
            if (MockERC20(_getAsset()).balanceOf(systemAddresses[i]) > 0) {
                emit DebugNumber(i); // Number to index
                eq(token.balanceOf(systemAddresses[i]), 0, "token.balanceOf(systemAddresses[i]) != 0");
            }
        }
    }

    // Sum of assets received on `claimCancelDepositRequest`<= sum of fulfillCancelDepositRequest.assets
    function property_global_5() public assetIsSet {
        // claimCancelDepositRequest
        // investmentManager_fulfillCancelDepositRequest
        lte(sumOfClaimedDepositCancelations[address(vault.asset())], cancelDepositCurrencyPayout[address(vault.asset())], "sumOfClaimedDepositCancelations !<= cancelDepositCurrencyPayout");
    }

    // Inductive implementation of property_global_5
    function property_global_5_inductive() tokenIsSet public {
        // we only care about the case where the claimableCancelDepositRequest is decreasing because it indicates that a cancel deposit request was fulfilled
        if(
            _before.investments[_getActor()].claimableCancelDepositRequest > _after.investments[_getActor()].claimableCancelDepositRequest
        ) {
            uint256 claimableCancelDepositRequestDelta = _before.investments[_getActor()].claimableCancelDepositRequest - _after.investments[_getActor()].claimableCancelDepositRequest;
            // claiming a cancel deposit request means that the globalEscrow token balance decreases
            uint256 escrowTokenDelta = _before.escrowTokenBalance - _after.escrowTokenBalance;
            eq(claimableCancelDepositRequestDelta, escrowTokenDelta, "claimableCancelDepositRequestDelta != escrowTokenDelta");
        }
    }

    // Sum of share class tokens received on `claimCancelRedeemRequest`<= sum of
    // fulfillCancelRedeemRequest.shares
    function property_global_6() public tokenIsSet {
        // claimCancelRedeemRequest
        lte(sumOfClaimedRedeemCancelations[address(token)], cancelRedeemShareTokenPayout[address(token)], "sumOfClaimedRedeemCancelations !<= cancelRedeemTrancheTokenPayout");
    }

    // Inductive implementation of property_global_6
    function property_global_6_inductive() public tokenIsSet {
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
    // TT-1
    // On the function handler, both transfer, transferFrom, perhaps even mint

    /// @notice Sum of balances equals total supply
    function property_tt_2() public tokenIsSet {
        address[] memory actors = _getActors();

        uint256 acc;
        for (uint256 i; i < actors.length; i++) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo tranche
            try token.balanceOf(actors[i]) returns (uint256 bal) {
                acc += bal;
            } catch {}
        }

        // NOTE: This ensures that supply doesn't overflow
        lte(acc, token.totalSupply(), "sum of user balances > token.totalSupply()");
    }

    function property_IM_1() public {
        if (address(asyncRequestManager) == address(0)) {
            return;
        }
        if (address(vault) == address(0)) {
            return;
        }
        if (_getActor() != address(this)) {
            return; // Canary for actor swaps
        }

        // Get actor data
        {
            (uint256 depositPrice,) = _getDepositAndRedeemPrice();

            // NOTE: Specification | Obv this breaks when you switch pools etc..
            // NOTE: Should reset
            // OR: Separate the check per actor | tranche instead of being so simple
            lte(depositPrice, _investorsGlobals[_getActor() ].maxDepositPrice, "depositPrice > maxDepositPrice");
            gte(depositPrice, _investorsGlobals[_getActor()].minDepositPrice, "depositPrice < minDepositPrice");
        }
    }

    function property_IM_2() public {
        if (address(asyncRequestManager) == address(0)) {
            return;
        }
        if (address(vault) == address(0)) {
            return;
        }
        if (_getActor() != address(this)) {
            return; // Canary for actor swaps
        }

        // Get actor data
        {
            (, uint256 redeemPrice) = _getDepositAndRedeemPrice();

            lte(redeemPrice, _investorsGlobals[_getActor()].maxRedeemPrice, "redeemPrice > maxRedeemPrice");
            gte(redeemPrice, _investorsGlobals[_getActor()].minRedeemPrice, "redeemPrice < minRedeemPrice");
        }
    }

    // Escrow

    /**
     * The balance of currencies in Escrow is
     *     sum of deposit requests
     *     minus sum of claimed redemptions
     *     plus transfers in
     *     minus transfers out
     *
     *     NOTE: Ignores donations
     */
    function property_E_1() public tokenIsSet {
        if (address(globalEscrow) == address(0)) {
            return;
        }
        if (_getAsset() == address(0)) {
            return;
        }

        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as assets cannot overflow due to other
        // functions permanently reverting
        
        uint256 ghostBalOfEscrow;
        address asset = vault.asset();
        // The balance of tokens in Escrow is sum of deposit requests plus transfers in minus transfers out
        uint256 balOfEscrow = MockERC20(address(asset)).balanceOf(address(globalEscrow)); // The balance of tokens in Escrow is sum of deposit requests plus transfers in minus transfers out
        unchecked {
            // Deposit Requests + Transfers In
            /// @audit Minted by Asset Payouts by Investors
            ghostBalOfEscrow = (
                mintedByCurrencyPayout[asset] + sumOfDepositRequests[asset]
                    + sumOfTransfersIn[asset]
                // Minus Claimed Redemptions and TransfersOut
                - sumOfClaimedRedemptions[asset] - sumOfClaimedDepositCancelations[asset]
                    - sumOfTransfersOut[asset]
            );
        }
        eq(balOfEscrow, ghostBalOfEscrow, "balOfEscrow != ghostBalOfEscrow");
    }

    // Escrow
    /**
     * The balance of share class tokens in Escrow
     *     is sum of all fulfilled deposits
     *     minus sum of all claimed deposits
     *     plus sum of all redeem requests
     *     minus sum of claimed
     *
     *     NOTE: Ignores donations
     */
    function property_E_2() public tokenIsSet {
        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as token cannot overflow due to other
        // functions permanently reverting
        uint256 ghostBalanceOfEscrow;
        uint256 balanceOfEscrow = token.balanceOf(address(globalEscrow));
        unchecked {
            ghostBalanceOfEscrow = (
                sumOfFullfilledDeposits[address(token)] + sumOfRedeemRequests[address(token)]
                        - sumOfClaimedDeposits[address(token)] - sumOfClaimedRedeemCancelations[address(token)]
                        - sumOfClaimedRequests[address(token)]
            );
        }
        eq(balanceOfEscrow, ghostBalanceOfEscrow, "balanceOfEscrow != ghostBalanceOfEscrow");
    }

    // TODO: Multi Assets -> Iterate over all existing combinations

    function property_E_3() public {
        if (address(vault) == address(0)) {
            return;
        }

        // if (_getActor() != address(this)) {
        //     return; // Canary for actor swaps
        // }

        uint256 balOfEscrow = MockERC20(_getAsset()).balanceOf(address(globalEscrow));

        // Use acc to track max amount withdrawn for each actor
        address[] memory actors = _getActors();
        uint256 acc;
        for (uint256 i; i < actors.length; i++) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo tranche
            try vault.maxWithdraw(actors[i]) returns (uint256 amt) {
                emit DebugWithString("maxWithdraw", amt);
                acc += amt;
            } catch {}
        }

        lte(acc, balOfEscrow, "sum of account balances > balOfEscrow");
    }

    function property_E_4() public {
        if (address(vault) == address(0)) {
            return;
        }

        // if (_getActor() != address(this)) {
        //     return; // Canary for actor swaps
        // }

        uint256 balOfEscrow = token.balanceOf(address(globalEscrow));
        emit DebugWithString("balOfEscrow", balOfEscrow);

        // Use acc to get maxMint for each actor
        address[] memory actors = _getActors();
        
        uint256 acc;
        for (uint256 i; i < actors.length; i++) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo share class
            try vault.maxMint(actors[i]) returns (uint256 amt) {
                emit DebugWithString("maxMint", amt);
                acc += amt;
            } catch {}
        }

        emit DebugWithString("acc - balOfEscrow", balOfEscrow < acc ? acc - balOfEscrow : 0);
        lte(acc, balOfEscrow, "account balance > balOfEscrow");
    }

    /// @dev Property: the totalAssets of a vault is always <= actual assets in the vault
    function property_totalAssets_solvency() public {
        uint256 totalAssets = vault.totalAssets();
        uint256 actualAssets = MockERC20(vault.asset()).balanceOf(address(globalEscrow));
        
        uint256 differenceInAssets = totalAssets - actualAssets;
        uint256 differenceInShares = vault.convertToShares(differenceInAssets);

        // precondition: check if the difference is greater than one share
        if (differenceInShares > (10 ** token.decimals()) - 1) {
            lte(totalAssets, actualAssets, "totalAssets > actualAssets");
        }
    }

    /// @dev Property: difference between totalAssets and actualAssets only increases
    function property_totalAssets_insolvency_only_increases() public {
        uint256 differenceBefore = _before.totalAssets - _before.actualAssets;
        uint256 differenceAfter = _after.totalAssets - _after.actualAssets;

        gte(differenceAfter, differenceBefore, "insolvency decreased");
    }

    function property_soundness_processed_deposits() public {
        address[] memory actors = _getActors();

        for(uint256 i; i < actors.length; i++) {
            gte(requestDeposited[actors[i]], depositProcessed[actors[i]], "property_soundness_processed_deposits Actor Requests must be gte than processed amounts");
        }
    }

    function property_soundness_processed_redemptions() public {
        address[] memory actors = _getActors();


        for(uint256 i; i < actors.length; i++) {
            gte(requestRedeeemed[actors[i]], redemptionsProcessed[actors[i]], "property_soundness_processed_redemptions Actor Requests must be gte than processed amounts");
        }
    }

    function property_cancelled_soundness() public {
        address[] memory actors = _getActors();


        for(uint256 i; i < actors.length; i++) {
            gte(requestDeposited[actors[i]], cancelledDeposits[actors[i]], "property_cancelled_soundness Actor Requests must be gte than cancelled amounts");
        }
    }

    function property_cancelled_and_processed_deposits_soundness() public {
        address[] memory actors = _getActors();


        for(uint256 i; i < actors.length; i++) {
            gte(requestDeposited[actors[i]], cancelledDeposits[actors[i]] + depositProcessed[actors[i]], "property_cancelled_and_processed_deposits_soundness Actor Requests must be gte than cancelled + processed amounts");
        }
    }

    function property_cancelled_and_processed_redemptions_soundness() public {
        address[] memory actors = _getActors();


        for(uint256 i; i < actors.length; i++) {
            gte(requestRedeeemed[actors[i]], cancelledRedemptions[actors[i]] + redemptionsProcessed[actors[i]], "property_cancelled_and_processed_redemptions_soundness Actor Requests must be gte than cancelled + processed amounts");
        }
    }

    function property_solvency_deposit_requests() public {
        address[] memory actors = _getActors();
        uint256 totalDeposits;


        for(uint256 i; i < actors.length; i++) {
            totalDeposits += requestDeposited[actors[i]];
        }


        gte(totalDeposits, approvedDeposits, "Total Deposits must always be less than totalDeposits");
    }

    function property_solvency_redemption_requests() public {
        address[] memory actors = _getActors();
        uint256 totalRedemptions;


        for(uint256 i; i < actors.length; i++) {
            totalRedemptions += requestRedeeemed[actors[i]];
        }


        gte(totalRedemptions, approvedRedemptions, "Total Redemptions must always be less than approvedRedemptions");
    }

    function property_actor_pending_and_queued_deposits() public {
        // Pending + Queued = Deposited?
        address[] memory actors = _getActors();


        for(uint256 i; i < actors.length; i++) {
            (uint128 pending, ) = shareClassManager.depositRequest(ShareClassId.wrap(scId), AssetId.wrap(assetId), actors[i].toBytes32());
            (, uint128 queued) = shareClassManager.queuedDepositRequest(ShareClassId.wrap(scId), AssetId.wrap(assetId), actors[i].toBytes32());


            // user order pending
            // user order amount


            // NOTE: We are missign the cancellation part, we're assuming that won't matter but idk
            eq(requestDeposited[actors[i]] - cancelledDeposits[actors[i]] - depositProcessed[actors[i]], pending + queued, "property_actor_pending_and_queued_deposits");
        }
    }

    function property_actor_pending_and_queued_redemptions() public {
        // Pending + Queued = Deposited?
        address[] memory actors = _getActors();

        for(uint256 i; i < actors.length; i++) {
            (uint128 pending, ) = shareClassManager.redeemRequest(ShareClassId.wrap(scId), AssetId.wrap(assetId), actors[i].toBytes32());
            (, uint128 queued) = shareClassManager.queuedRedeemRequest(ShareClassId.wrap(scId), AssetId.wrap(assetId), actors[i].toBytes32());

            // user order pending
            // user order amount

            // NOTE: We are missign the cancellation part, we're assuming that won't matter but idk
            eq(requestRedeeemed[actors[i]] - cancelledRedemptions[actors[i]] - redemptionsProcessed[actors[i]], pending + queued, "property_actor_pending_and_queued_redemptions");
        }
    }

    function property_escrow_solvency() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId _poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(_poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId _scId = shareClassManager.previewShareClassId(_poolId, j);
                AssetId _assetId = hubRegistry.currency(_poolId);
                (, uint256 _tokenId) = poolManager.idToAsset(_assetId);

                PoolEscrow poolEscrow = PoolEscrow(payable(address(poolEscrowFactory.escrow(_poolId))));

                (uint128 holding, uint128 reserved) = poolEscrow.holding(_scId, _assetId.addr(), _tokenId);
                gte(reserved, holding, "reserved must be greater than holding");
            }
        }
    }

    /// @dev Property: The price per share used in the entire system is ALWAYS provided by the admin
    function property_price_per_share_overall() public {
        // first check if the share amount changed 
        uint256 shareDelta;
        uint256 assetDelta;
        if(_before.totalShareSupply != _after.totalShareSupply) {
            if(_before.totalShareSupply > _after.totalShareSupply) {
                shareDelta = _before.totalShareSupply - _after.totalShareSupply;
                assetDelta = _before.totalAssets - _after.totalAssets;
            } else {
                shareDelta = _after.totalShareSupply - _before.totalShareSupply;
                assetDelta = _after.totalAssets - _before.totalAssets;
            }

            // if the share amount changed, check if it used the correct price per share set by the admin
            (, D18 navPerShare) = shareClassManager.metrics(ShareClassId.wrap(scId));
            uint256 expectedShareDelta = navPerShare.mulUint256(assetDelta, MathLib.Rounding.Down);
            eq(shareDelta, expectedShareDelta, "shareDelta must be equal to expectedShareDelta");
        }
    }

    /// === HUB === ///

    /// @dev Property: The total pending asset amount pendingDeposit[..] is always >= the approved asset epochInvestAmounts[..].approvedAssetAmount
    function property_total_pending_and_approved() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                (uint32 depositEpochId,,,) = shareClassManager.epochId(scId, assetId);
                uint128 pendingDeposit = shareClassManager.pendingDeposit(scId, assetId);
                (uint128 pendingAssetAmount, uint128 approvedAssetAmount,,,,) = shareClassManager.epochInvestAmounts(scId, assetId, depositEpochId);

                gte(pendingDeposit, approvedAssetAmount, "pendingDeposit < approvedAssetAmount");
                gte(pendingDeposit, pendingAssetAmount, "pendingDeposit < pendingAssetAmount");
            }
        }
    }

    /// @dev Property: The total pending redeem amount pendingRedeem[..] is always >= the sum of pending user redeem amounts redeemRequest[..]
    /// @dev Property: The total pending redeem amount pendingRedeem[..] is always >= the approved redeem amount epochRedeemAmounts[..].approvedShareAmount
    // TODO: come back to this to check if accounting for case is correct
    function property_total_pending_redeem_geq_sum_pending_user_redeem() public {
        address[] memory _actors = _getActors();

        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) { 
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                (uint32 redeemEpochId,,,) = shareClassManager.epochId(scId, assetId);
                uint128 pendingRedeemCurrent = shareClassManager.pendingRedeem(scId, assetId);
                
                // get the pending and approved redeem amounts for the previous epoch
                (, uint128 approvedShareAmountPrevious, uint128 payoutAssetAmountPrevious,,,) = shareClassManager.epochRedeemAmounts(scId, assetId, redeemEpochId - 1);

                // get the pending and approved redeem amounts for the current epoch
                (, uint128 approvedShareAmountCurrent, uint128 payoutAssetAmountCurrent,,,) = shareClassManager.epochRedeemAmounts(scId, assetId, redeemEpochId);

                uint128 totalPendingUserRedeem = 0;
                for (uint256 k = 0; k < _actors.length; k++) {
                    address actor = _actors[k];

                    (uint128 pendingUserRedeemCurrent,) = shareClassManager.redeemRequest(scId, assetId, CastLib.toBytes32(actor));
                    totalPendingUserRedeem += pendingUserRedeemCurrent;
                    
                    // pendingUserRedeem hasn't changed if the claimableAssetAmountPrevious is 0, so we can use it to calculate the claimableAssetAmount from the previous epoch 
                    uint128 approvedShareAmountPrevious = pendingUserRedeemCurrent.mulDiv(approvedShareAmountPrevious, payoutAssetAmountPrevious).toUint128();
                    uint128 claimableAssetAmountPrevious = uint256(approvedShareAmountPrevious).mulDiv(
                        payoutAssetAmountPrevious, approvedShareAmountPrevious
                    ).toUint128();

                    // account for the edge case where user claimed redemption in previous epoch but there was no claimable amount
                    // in this case, the totalPendingUserRedeem will be greater than the pendingRedeemCurrent for this epoch 
                    if(claimableAssetAmountPrevious > 0) {
                        // check that the pending redeem is >= the total pending user redeem
                        gte(pendingRedeemCurrent, totalPendingUserRedeem, "pending redeem is < total pending user redeems");
                    }
                }
                
                // check that the pending redeem is >= the approved redeem
                gte(pendingRedeemCurrent, approvedShareAmountCurrent, "pending redeem is < approved redeem");
            }
        }
    }  

    /// @dev Property: The epoch of a pool epochId[poolId] can increase at most by one within the same transaction (i.e. multicall/execute) independent of the number of approvals
    function property_epochId_can_increase_by_one_within_same_transaction() public {
        // precondition: there must've been a batch operation (call to execute/multicall)
        if(currentOperation == OpType.BATCH) {
            for (uint256 i = 0; i < createdPools.length; i++) {
                PoolId poolId = createdPools[i];

                uint32 epochIdDifference = _after.ghostEpochId[poolId] - _before.ghostEpochId[poolId];
                // check that the epochId increased by at most 1
                lte(epochIdDifference, 1, "epochId increased by more than 1");
            }
        }
    }

    /// @dev Property: account.totalDebit and account.totalCredit is always less than uint128(type(int128).max)
    function property_account_totalDebit_and_totalCredit_leq_max_int128() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
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
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
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
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);
                AccountId accountId = holdings.accountId(poolId, scId, assetId,  uint8(AccountType.Asset));
                
                (, uint128 assets) = accounting.accountValue(poolId, accountId);
                uint128 holdingsValue = holdings.value(poolId, scId, assetId);
                
                // This property holds all of the system accounting together
                eq(assets, holdingsValue, "Assets and Holdings value must match");
            }
        }
    }

    /// @dev Property: Total Yield = assets - equity
    function property_total_yield() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
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
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
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

                // assets = accountValue(Equity) + accountValue(Gain) - accountValue(Loss)
                t(assets == equity + gain - loss, "property_asset_soundness"); // Loss is already negative
            }
        }
    }

    /// @dev Property: equity = assets - loss - gain
    function property_equity_soundness() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
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
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
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

                uint128 totalYield = assets - equity; // Can be positive or negative
                t(gain == (totalYield - loss), "property_gain_soundness");
            }   
        }
    }

    /// @dev Property: loss = totalYield - gain
    function property_loss_soundness() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
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
                t(loss == totalYield - gain, "property_loss_soundness");    
            }
        }
    } 

    /// @dev Property: A user cannot mutate their pending redeem amount pendingRedeem[...] if the pendingRedeem[..].lastUpdate is <= the latest redeem approval epochId[..].redeem
    function property_user_cannot_mutate_pending_redeem() public {
        address[] memory _actors = _getActors();

        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                // loop over all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    bytes32 actor = CastLib.toBytes32(_actors[k]);
                    // precondition: pending has changed 
                    if (_before.ghostRedeemRequest[scId][assetId][actor].pending != _after.ghostRedeemRequest[scId][assetId][actor].pending) {
                        // check that the lastUpdate was >= the latest redeem approval pointer
                        gt(_before.ghostRedeemRequest[scId][assetId][actor].lastUpdate, _before.ghostLatestRedeemApproval, "lastUpdate is > latest redeem approval");
                    }
                }
            }
        }
    }

    /// @dev Property: After FM performs approveDeposits and revokeShares with non-zero navPerShare, the total issuance totalIssuance[..] is increased
    /// @dev WIP, this may not be possible to prove because these calls are made via execute which makes determining the before and after state difficult
    // function property_total_issuance_increased_after_approve_deposits_and_revoke_shares() public {
        
    //     bool hasApprovedDeposits = false;
    //     bool hasRevokedShares = false;
    //     for(uint256 i = 0; i < queuedOps.length; i++) {
    //         QueuedOp queuedOp = queuedOps[i];
    //         if(queuedOp.op == Op.APPROVE_DEPOSITS) {
    //             hasApprovedDeposits = true;
    //         }

    //         // there has to have been an approveDeposits call before a revokeShares call
    //         if(queuedOp.op == Op.REVOKE_SHARES && hasApprovedDeposits) {
    //             hasRevokedShares = true;
    //         }
    //     }

    //     // if(hasApprovedDeposits && hasRevokedShares) {
    //     //     shareClassManager.metrics(scId);
    //     // }
    // }


    /// Stateless Properties ///

    /// @dev Property: The sum of eligible user payoutShareAmount for an epoch is <= the number of issued epochInvestAmounts[..].pendingShareAmount
    /// @dev Property: The sum of eligible user payoutAssetAmount for an epoch is <= the number of issued asset epochInvestAmounts[..].pendingAssetAmount
    /// @dev Stateless because of the calls to claimDeposit which would make story difficult to read
    // TODO: fix stack too deep error
    // TODO: no longer have a pendingShareAmount in EpochInvestAmounts
    // function property_eligible_user_deposit_amount_leq_deposit_issued_amount() public statelessTest {
    //     address[] memory _actors = _getActors();

    //     // loop over all created pools
    //     for (uint256 i = 0; i < createdPools.length; i++) {
    //         PoolId poolId = createdPools[i];
    //         uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            
    //         // check that the epoch has ended, if not, skip
    //         // we know an epoch has ended if the epochId changed after an operation which we cache in the before/after structs
    //         if (_before.ghostEpochId[poolId] == _after.ghostEpochId[poolId]) {
    //             continue;
    //         }

    //         // loop over all share classes in the pool
    //         uint128 totalPayoutShareAmount = 0;
    //         uint128 totalPayoutAssetAmount = 0;
    //         // skip the first share class because it's never assigned
    //         for (uint32 j = 1; j < shareClassCount; j++) {
    //             ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
    //             AssetId assetId = hubRegistry.currency(poolId);

    //             (uint32 latestDepositEpochId,, uint32 latestIssuanceEpochId,) = shareClassManager.epochId(scId, assetId);
    //             // sum up to the latest issuance epoch where users can claim deposits for 
    //             uint128 sumDepositApprovedShares;
    //             uint128 sumDepositAssets;
    //             for (uint32 epochId; epochId <= latestIssuanceEpochId; epochId++) {
    //                 (uint128 depositSharesIssued,, uint128 depositPoolApproved,,,) = shareClassManager.epochInvestAmounts(scId, assetId, latestDepositEpochId);
    //                 sumDepositApprovedShares += depositPoolApproved;
    //                 sumDepositAssets += depositSharesIssued;
    //             }

    //             // loop over all actors
    //             for (uint256 k = 0; k < _actors.length; k++) {
    //                 address actor = _actors[k];
                    
    //                 // we claim via shareClassManager directly here because PoolRouter doesn't return the payoutShareAmount
    //                 (uint128 payoutShareAmount, uint128 payoutAssetAmount,,) = shareClassManager.claimDeposit(poolId, scId, CastLib.toBytes32(actor), assetId);
    //                 totalPayoutShareAmount += payoutShareAmount;
    //                 totalPayoutAssetAmount += payoutAssetAmount;
    //             }

    //             // check that the totalPayoutShareAmount is less than or equal to the depositSharesIssued
    //             lte(totalPayoutShareAmount, sumDepositAssets, "totalPayoutShareAmount is greater than sumDepositAssets");
    //             // check that the totalPayoutAssetAmount is less than or equal to the depositPoolApproved
    //             lte(totalPayoutAssetAmount, sumDepositApprovedShares, "totalPayoutAssetAmount is greater than sumDepositApprovedShares");

    //             uint128 differenceShares = sumDepositAssets - totalPayoutShareAmount;
    //             uint128 differenceAsset = sumDepositApprovedShares - totalPayoutAssetAmount;
    //             // check that the totalPayoutShareAmount is no more than 1 wei less than the depositSharesIssued
    //             lte(differenceShares, 1, "sumDepositAssets - totalPayoutShareAmount difference is greater than 1");
    //             // check that the totalPayoutAssetAmount is no more than 1 wei less than the depositAssetAmount
    //             lte(differenceAsset, 1, "sumDepositApprovedShares - totalPayoutAssetAmount difference is greater than 1");
    //         }
    //     }
    // }

    /// @dev Property: The sum of eligible user claim payout asset amounts for an epoch is <= the approved asset epochRedeemAmounts[..].approvedAssetAmount
    /// @dev Property: The sum of eligible user claim payment share amounts for an epoch is <= than the revoked share epochRedeemAmounts[..].pendingAssetAmount
    /// @dev This doesn't sum over previous epochs because it can be assumed that it'll be called by the fuzzer for each current epoch
    function property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount() public statelessTest {
        address[] memory _actors = _getActors();

        // loop over all created pools
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
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

    /// @dev Property: The amount of holdings of an asset for a pool-shareClas pair in Holdings MUST always be equal to the balance of the escrow for said pool-shareClass for the respective token
    // TODO: verify if this should be applied to the vaults side instead
    // function property_holdings_balance_equals_escrow_balance() public statelessTest {
    //     address[] memory _actors = _getActors();

    //     for (uint256 i = 0; i < createdPools.length; i++) {
    //         PoolId poolId = createdPools[i];
    //         uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
    //         // skip the first share class because it's never assigned
    //         for (uint32 j = 1; j < shareClassCount; j++) {
    //             ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
    //             AssetId assetId = hubRegistry.currency(poolId);

    //             (uint128 holdingAssetAmount,,,) = holdings.holding(poolId, scId, assetId);
                
    //             address pendingShareClassEscrow = hub.escrow(poolId, scId, EscrowId.PendingShareClass);
    //             address shareClassEscrow = hub.escrow(poolId, scId, EscrowId.ShareClass);
    //             uint256 pendingShareClassEscrowBalance = assetRegistry.balanceOf(pendingShareClassEscrow, assetId.raw());
    //             uint256 shareClassEscrowBalance = assetRegistry.balanceOf(shareClassEscrow, assetId.raw());
                
    //             eq(holdingAssetAmount, pendingShareClassEscrowBalance + shareClassEscrowBalance, "holding != escrow balance");
    //         }
    //     }
    // }

    /// @dev Property: The amount of tokens existing in the AssetRegistry MUST always be <= the balance of the associated token in the escrow
    // TODO: confirm if this is correct because it seems like AssetRegistry would never be receiving tokens in the first place
    // TODO: verify if this should be applied to the vaults side instead
    // function property_assetRegistry_balance_leq_escrow_balance() public stateless {
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
    // }

    // === OPTIMIZATION TESTS === // 

    /// @dev Optimzation test to check if the difference between totalAssets and actualAssets is greater than 1 share
    function optimize_totalAssets_solvency() public view returns (int256) {
        uint256 totalAssets = vault.totalAssets();
        uint256 actualAssets = MockERC20(vault.asset()).balanceOf(address(globalEscrow));
        uint256 difference = totalAssets - actualAssets;

        uint256 differenceInShares = vault.convertToShares(difference);

        if (differenceInShares > (10 ** token.decimals()) - 1) {
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
        uint256 SYSTEM_ADDRESSES_LENGTH = 8;

        systemAddresses = new address[](SYSTEM_ADDRESSES_LENGTH);
        
        // NOTE: Skipping escrow which can have non-zero bal
        systemAddresses[0] = address(vaultFactory);
        systemAddresses[1] = address(tokenFactory);
        systemAddresses[2] = address(asyncRequestManager);
        systemAddresses[3] = address(poolManager);
        systemAddresses[4] = address(vault);
        systemAddresses[5] = address(vault.asset());
        systemAddresses[6] = address(token);
        systemAddresses[7] = address(fullRestrictions);

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
