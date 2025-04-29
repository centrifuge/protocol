// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Asserts} from "@chimera/Asserts.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {console2} from "forge-std/console2.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {D18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {PoolEscrow} from "src/vaults/Escrow.sol";

import {BeforeAfter} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {AsyncVaultCentrifugeProperties} from "test/integration/recon-end-to-end/properties/AsyncVaultCentrifugeProperties.sol";

abstract contract Properties is BeforeAfter, Asserts, AsyncVaultCentrifugeProperties {
    using CastLib for *;
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

    // == GLOBAL == //

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
