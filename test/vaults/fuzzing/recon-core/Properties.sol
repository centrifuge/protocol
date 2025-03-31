// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Asserts} from "@chimera/Asserts.sol";
import {console2} from "forge-std/console2.sol";

import {BeforeAfter} from "./BeforeAfter.sol";
import {ERC7540CentrifugeProperties} from "./ERC7540CentrifugeProperties.sol";

abstract contract Properties is BeforeAfter, Asserts, ERC7540CentrifugeProperties {
    event DebugWithString(string, uint256);
    event DebugNumber(uint256);

    // == SENTINEL == //
    /// Sentinel properties are used to flag that coverage was reached
    // These can be useful during development, but may also be kept at latest stages
    // They indicate that salient state transitions have happened, which can be helpful at all stages of development

    /// @dev This Property demonstrates that the current actor can reach a non-zero balance
    // This helps get coverage in other areas
    // NOTE: Canary for checking actor balance
    function invariant_sentinel_tranche_balance() trancheTokenIsSet public {
        if (!RECON_USE_SENTINEL_TESTS) {
            return; // Skip if setting is off
        }
        // Dig until we get non-zero tranche balance
        // Afaict this will never work
        eq(trancheToken.balanceOf(_getActor()), 0, "trancheToken.balanceOf(actor)");
    }

    // == GLOBAL == //
    // Sum of tranche tokens received on `deposit` and `mint` <= sum of fulfilledDepositRequest.shares
    function invariant_global_1() trancheTokenIsSet public {
        // Mint and Deposit
        lte(sumOfClaimedDeposits[address(trancheToken)], sumOfFullfilledDeposits[address(trancheToken)], "sumOfClaimedDeposits not <= sumOfFullfilledDeposits");
    }

    // Sum of underlying assets received on `redeem` and `withdraw` <= sum of underlying assets received on `fulfillRedeemRequest`
    function invariant_global_2() trancheTokenIsSet public {
        // Redeem and Withdraw
        // investmentManager_handleExecutedCollectRedeem
        lte(sumOfClaimedRedemptions[address(token)], mintedByCurrencyPayout[address(token)], "sumOfClaimedRedemptions !<= mintedByCurrencyPayout");
    }

    function invariant_global_2_inductive() trancheTokenIsSet public {
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
    function invariant_global_3() trancheTokenIsSet public {
        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as trancheToken cannot overflow due to other
        // functions permanently reverting
        uint256 ghostTotalSupply;
        uint256 totalSupply = trancheToken.totalSupply() - totalSupplyAtFork;
        unchecked {
            // NOTE: Includes `trancheMints` which are arbitrary mints
            ghostTotalSupply = trancheMints[address(trancheToken)] + executedInvestments[address(trancheToken)]
                + incomingTransfers[address(trancheToken)] - outGoingTransfers[address(trancheToken)]
                - executedRedemptions[address(trancheToken)];
        }
        eq(totalSupply, ghostTotalSupply, "totalSupply != ghostTotalSupply");
    }

    function invariant_global_4() trancheTokenIsSet public {
        address[] memory systemAddresses = _getSystemAddresses();
        uint256 SYSTEM_ADDRESSES_LENGTH = systemAddresses.length;

        // NOTE: Skipping root and gateway when not gov fuzzing since we mocked them
        for (uint256 i; i < SYSTEM_ADDRESSES_LENGTH; i++) {
            emit DebugNumber(i); // Number to index
            eq(token.balanceOf(systemAddresses[i]), 0, "token.balanceOf(systemAddresses[i]) > 0");
        }
    }

    // Sum of assets received on `claimCancelDepositRequest`<= sum of fulfillCancelDepositRequest.assets
    function invariant_global_5() trancheTokenIsSet public {
        // claimCancelDepositRequest
        // investmentManager_fulfillCancelDepositRequest
        lte(sumOfClaimedDepositCancelations[address(token)], cancelDepositCurrencyPayout[address(token)], "sumOfClaimedDepositCancelations !<= cancelDepositCurrencyPayout");
    }

    // Inductive implementation of invariant_global_5
    function invariant_global_5_inductive() trancheTokenIsSet public {
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

    // Sum of tranche tokens received on `claimCancelRedeemRequest`<= sum of
    // fulfillCancelRedeemRequest.shares
    function invariant_global_6() trancheTokenIsSet public {
        // claimCancelRedeemRequest
        lte(sumOfClaimedRedeemCancelations[address(trancheToken)], cancelRedeemTrancheTokenPayout[address(trancheToken)], "sumOfClaimedRedeemCancelations !<= cancelRedeemTrancheTokenPayout");
    }

    // Inductive implementation of invariant_global_6
    function invariant_global_6_inductive() trancheTokenIsSet public {
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

    // == TRANCHE TOKENS == //
    // TT-1
    // On the function handler, both transfer, transferFrom, perhaps even mint

    // TODO: Targets / Tranches
    /// @notice Sum of balances equals total supply
    function invariant_tt_2() trancheTokenIsSet public {
        address[] memory actors = _getActors();

        uint256 acc;
        for (uint256 i; i < actors.length; i++) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo tranche
            try trancheToken.balanceOf(actors[i]) returns (uint256 bal) {
                acc += bal;
            } catch {}
        }

        // NOTE: This ensures that supply doesn't overflow

        lte(acc, trancheToken.totalSupply(), "sum of user balances > trancheToken.totalSupply()");
    }

    function invariant_IM_1() public {
        if (address(investmentManager) == address(0)) {
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

    function invariant_IM_2() public {
        if (address(investmentManager) == address(0)) {
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
    function invariant_E_1() trancheTokenIsSet public {
        if (address(escrow) == address(0)) {
            return;
        }

        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as assets cannot overflow due to other
        // functions permanently reverting
        
        uint256 ghostBalOfEscrow;
        uint256 balOfEscrow = token.balanceOf(address(escrow)) - tokenBalanceOfEscrowAtFork; // The balance of tokens in Escrow is sum of deposit requests plus transfers in minus transfers out
        unchecked {
            // Deposit Requests + Transfers In
            /// @audit Minted by Asset Payouts by Investors
            (
                ghostBalOfEscrow = mintedByCurrencyPayout[address(token)] + sumOfDepositRequests[address(token)]
                    + sumOfTransfersIn[address(token)]
                // Minus Claimed Redemptions and TransfersOut
                - sumOfClaimedRedemptions[address(token)] - sumOfClaimedDepositCancelations[address(token)]
                    - sumOfTransfersOut[address(token)]
            );
        }
        eq(balOfEscrow, ghostBalOfEscrow, "balOfEscrow != ghostBalOfEscrow");
    }

    // Escrow
    /**
     * The balance of tranche tokens in Escrow
     *     is sum of all fulfilled deposits
     *     minus sum of all claimed deposits
     *     plus sum of all redeem requests
     *     minus sum of claimed
     *
     *     NOTE: Ignores donations
     */
    function invariant_E_2() trancheTokenIsSet public {
        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as trancheToken cannot overflow due to other
        // functions permanently reverting
        uint256 ghostBalanceOfEscrow;
        uint256 balanceOfEscrow = trancheToken.balanceOf(address(escrow)) - trancheTokenBalanceOfEscrowAtFork;
        
        unchecked {
            ghostBalanceOfEscrow = (
                    sumOfFullfilledDeposits[address(trancheToken)] + sumOfRedeemRequests[address(trancheToken)]
                    - sumOfClaimedDeposits[address(trancheToken)] - sumOfClaimedRedeemCancelations[address(trancheToken)]
                    - sumOfClaimedRequests[address(trancheToken)]
                );
        }
        eq(balanceOfEscrow, ghostBalanceOfEscrow, "balanceOfEscrow != ghostBalanceOfEscrow");
    }

    // TODO: Multi Assets -> Iterate over all existing combinations

    function invariant_E_3() public {
        if (address(vault) == address(0)) {
            return;
        }

        // if (_getActor() != address(this)) {
        //     return; // Canary for actor swaps
        // }

        uint256 balOfEscrow = token.balanceOf(address(escrow));

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

    function invariant_E_4() public {
        if (address(vault) == address(0)) {
            return;
        }

        // if (_getActor() != address(this)) {
        //     return; // Canary for actor swaps
        // }

        uint256 balOfEscrow = trancheToken.balanceOf(address(escrow));
        emit DebugWithString("balOfEscrow", balOfEscrow);

        // Use acc to get maxMint for each actor
        address[] memory actors = _getActors();
        
        uint256 acc;
        for (uint256 i; i < actors.length; i++) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo tranche
            try vault.maxMint(actors[i]) returns (uint256 amt) {
                emit DebugWithString("maxMint", amt);
                acc += amt;
            } catch {}
        }

        emit DebugWithString("acc - balOfEscrow", balOfEscrow < acc ? acc - balOfEscrow : 0);
        lte(acc, balOfEscrow, "account balance > balOfEscrow");
    }

    // == UTILITY == //

    /// @dev Lists out all system addresses, used to check that no dust is left behind
    /// NOTE: A more advanced dust check would have 100% of actors withdraw, to ensure that the sum of operations is
    /// sound
    function _getSystemAddresses() internal returns (address[] memory) {
        uint256 SYSTEM_ADDRESSES_LENGTH = GOV_FUZZING ? 10 : 8;

        address[] memory systemAddresses = new address[](SYSTEM_ADDRESSES_LENGTH);
        
        // NOTE: Skipping escrow which can have non-zero bal
        systemAddresses[0] = address(vaultFactory);
        systemAddresses[1] = address(trancheFactory);
        systemAddresses[2] = address(investmentManager);
        systemAddresses[3] = address(poolManager);
        systemAddresses[4] = address(vault);
        systemAddresses[5] = address(token);
        systemAddresses[6] = address(trancheToken);
        systemAddresses[7] = address(restrictionManager);

        if (GOV_FUZZING) {
            systemAddresses[8] = address(gateway);
            systemAddresses[9] = address(root);
        }
        
    }

    /// @dev Can we donate to this address?
    /// We explicitly preventing donations since we check for exact balances
    function _canDonate(address to) internal returns (bool) {
        if (to == address(escrow)) {
            return false;
        }

        return true;
    }

    /// @dev utility to ensure the target is not in the system addresses
    function _isInSystemAddress(address x) internal returns (bool) {
        address[] memory systemAddresses = _getSystemAddresses();
        uint256 SYSTEM_ADDRESSES_LENGTH = systemAddresses.length;

        for (uint256 i; i < SYSTEM_ADDRESSES_LENGTH; i++) {
            if (systemAddresses[i] == x) return true;
        }

        return false;
    }

    /// NOTE: Example of checked overflow, unused as we have changed tracking of Tranche tokens to be based on Global_3
    function _decreaseTotalTrancheSent(address tranche, uint256 amt) internal {
        uint256 cachedTotal = totalTrancheSent[tranche];
        unchecked {
            totalTrancheSent[tranche] -= amt;
        }

        // Check for overflow here
        gte(cachedTotal, totalTrancheSent[tranche], " _decreaseTotalTrancheSent Overflow");
    }
}
