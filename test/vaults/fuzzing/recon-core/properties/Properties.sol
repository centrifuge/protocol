// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Asserts} from "@chimera/Asserts.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {console2} from "forge-std/console2.sol";

import {BeforeAfter} from "../BeforeAfter.sol";
import {AsyncVaultCentrifugeProperties} from "./AsyncVaultCentrifugeProperties.sol";

abstract contract Properties is BeforeAfter, Asserts, AsyncVaultCentrifugeProperties {
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
        lte(sumOfClaimedRedemptions[address(assetErc20)], mintedByCurrencyPayout[address(assetErc20)], "sumOfClaimedRedemptions[address(assetErc20)] > mintedByCurrencyPayout[address(assetErc20)]");
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
        uint256 totalSupply = token.totalSupply() - totalSupplyAtFork;
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
            if (assetErc20.balanceOf(systemAddresses[i]) > 0) {
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
            // claiming a cancel deposit request means that the escrow token balance decreases
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
            // claiming a cancel redeem request means that the escrow tranche token balance decreases
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
        if (address(asyncRequests) == address(0)) {
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
        if (address(asyncRequests) == address(0)) {
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
        if (address(escrow) == address(0)) {
            return;
        }
        if (address(assetErc20) == address(0)) {
            return;
        }

        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as assets cannot overflow due to other
        // functions permanently reverting
        
        uint256 ghostBalOfEscrow;
        // The balance of tokens in Escrow is sum of deposit requests plus transfers in minus transfers out
        uint256 balOfEscrow = MockERC20(address(vault.asset())).balanceOf(address(escrow)) - tokenBalanceOfEscrowAtFork; // The balance of tokens in Escrow is sum of deposit requests plus transfers in minus transfers out
        unchecked {
            // Deposit Requests + Transfers In
            /// @audit Minted by Asset Payouts by Investors
            ghostBalOfEscrow = (
                mintedByCurrencyPayout[address(assetErc20)] + sumOfDepositRequests[address(assetErc20)]
                    + sumOfTransfersIn[address(assetErc20)]
                // Minus Claimed Redemptions and TransfersOut
                - sumOfClaimedRedemptions[address(assetErc20)] - sumOfClaimedDepositCancelations[address(assetErc20)]
                    - sumOfTransfersOut[address(assetErc20)]
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
        uint256 balanceOfEscrow = token.balanceOf(address(escrow)) - trancheTokenBalanceOfEscrowAtFork;
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

        uint256 balOfEscrow = assetErc20.balanceOf(address(escrow));

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

        uint256 balOfEscrow = token.balanceOf(address(escrow));
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
        uint256 actualAssets = MockERC20(vault.asset()).balanceOf(address(vault));
        
        uint256 difference = totalAssets - actualAssets;
        uint256 differenceInShares = vault.convertToShares(difference);

        // if (differenceInShares > 1e18 - 1) {
        // note: may need to check account for minimal allowable difference in shares
        lte(totalAssets, actualAssets, "totalAssets > actualAssets");
        // }
    }

    /// @dev Optimzation test to check if the difference between totalAssets and actualAssets is greater than 1 share
    function optimize_totalAssets_solvency() public returns (int256) {
        uint256 totalAssets = vault.totalAssets();
        uint256 actualAssets = MockERC20(vault.asset()).balanceOf(address(vault));
        uint256 difference = totalAssets - actualAssets;

        uint256 differenceInShares = vault.convertToShares(difference);

        if (differenceInShares > 1e18 - 1) {
            return int256(difference);
        }

        return 0;
    }
    

    // == UTILITY == //

    /// @dev Lists out all system addresses, used to check that no dust is left behind
    /// NOTE: A more advanced dust check would have 100% of actors withdraw, to ensure that the sum of operations is
    /// sound
    function _getSystemAddresses() internal view returns (address[] memory systemAddresses) {
        uint256 SYSTEM_ADDRESSES_LENGTH = GOV_FUZZING ? 10 : 8;

        systemAddresses = new address[](SYSTEM_ADDRESSES_LENGTH);
        
        // NOTE: Skipping escrow which can have non-zero bal
        systemAddresses[0] = address(vaultFactory);
        systemAddresses[1] = address(tokenFactory);
        systemAddresses[2] = address(asyncRequests);
        systemAddresses[3] = address(poolManager);
        systemAddresses[4] = address(vault);
        systemAddresses[5] = address(vault.asset());
        systemAddresses[6] = address(token);
        systemAddresses[7] = address(restrictedTransfers);

        if (GOV_FUZZING) {
            systemAddresses[8] = address(gateway);
            systemAddresses[9] = address(root);
        }
        
        return systemAddresses;
    }

    /// @dev Can we donate to this address?
    /// We explicitly preventing donations since we check for exact balances
    function _canDonate(address to) internal view returns (bool) {
        if (to == address(escrow)) {
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
    function _decreaseTotalShareSent(address assetErc20, uint256 amt) internal {
        uint256 cachedTotal = totalShareSent[assetErc20];
        unchecked {
            totalShareSent[assetErc20] -= amt;
        }

        // Check for overflow here
        gte(cachedTotal, totalShareSent[assetErc20], " _decreaseTotalShareSent Overflow");
    }
}
