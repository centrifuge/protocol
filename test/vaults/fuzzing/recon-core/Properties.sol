// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Asserts} from "@chimera/Asserts.sol";
import {Setup} from "./Setup.sol";
import {AsyncVaultCentrifugeProperties} from "./AsyncVaultCentrifugeProperties.sol";

abstract contract Properties is Setup, Asserts, AsyncVaultCentrifugeProperties {
    // == SENTINEL == //
    /// Sentinel properties are used to flag that coverage was reached
    // These can be useful during development, but may also be kept at latest stages
    // They indicate that salient state transitions have happened, which can be helpful at all stages of development

    /// @dev This Property demonstrates that the current actor can reach a non-zero balance
    // This helps get coverage in other areas
    function invariant_sentinel_tranche_balance() public view returns (bool) {
        if (!RECON_USE_SENTINEL_TESTS) {
            return true; // Skip if setting is off
        }

        if (address(trancheToken) == address(0)) {
            return true; // Skip
        }
        // Dig until we get non-zero tranche balance
        // Afaict this will never work
        return trancheToken.balanceOf(actor) == 0;
    }

    // == GLOBAL == //
    event DebugNumber(uint256);

    // Sum of tranche tokens received on `deposit` and `mint` <= sum of fulfilledDepositRequest.shares
    function invariant_global_1() public view returns (bool) {
        if (address(trancheToken) == address(0)) {
            return true; // Skip
        }

        // Mint and Deposit
        return sumOfClaimedDeposits[address(trancheToken)]
        // asyncRequests_fulfilledDepositRequest
        <= sumOfFullfilledDeposits[address(trancheToken)];
    }

    function invariant_global_2() public view returns (bool) {
        if (address(token) == address(0)) {
            return true; // Skip
        }

        // Redeem and Withdraw
        return sumOfClaimedRedemptions[address(token)]
        // asyncRequests_handleExecutedCollectRedeem
        <= mintedByCurrencyPayout[address(token)];
    }

    function invariant_global_3() public view returns (bool) {
        if (address(trancheToken) == address(0)) {
            return true; // Skip
        }

        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as trancheToken cannot overflow due to other
        // functions permanently reverting
        unchecked {
            return trancheToken.totalSupply()
            // NOTE: Includes `trancheMints` which are arbitrary mints
            == trancheMints[address(trancheToken)] + executedInvestments[address(trancheToken)]
                + incomingTransfers[address(trancheToken)] - outGoingTransfers[address(trancheToken)]
                - executedRedemptions[address(trancheToken)];
        }
    }

    /// @dev Lists out all system addresses, used to check that no dust is left behind
    /// NOTE: A more advanced dust check would have 100% of actors withdraw, to ensure that the sum of operations is
    /// sound
    function _getSystemAddresses() internal view returns (address[] memory) {
        uint256 SYSTEM_ADDRESSES_LENGTH = 9;

        address[] memory systemAddresses = new address[](SYSTEM_ADDRESSES_LENGTH);
        systemAddresses[0] = address(vaultFactory);
        systemAddresses[1] = address(trancheFactory);

        // NOTE: Skipping escrow which instead can have non-zero bal

        systemAddresses[2] = address(asyncRequests);
        systemAddresses[3] = address(poolManager);
        systemAddresses[4] = address(vault);
        systemAddresses[5] = address(token);
        systemAddresses[6] = address(trancheToken);
        systemAddresses[7] = address(restrictionManager);

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

    function invariant_global_4() public returns (bool) {
        if (address(token) == address(0)) {
            return true; // Skip
        }

        address[] memory systemAddresses = _getSystemAddresses();
        uint256 SYSTEM_ADDRESSES_LENGTH = systemAddresses.length;

        // NOTE: Skipping root and gateway since we mocked them
        for (uint256 i; i < SYSTEM_ADDRESSES_LENGTH; i++) {
            if (token.balanceOf(systemAddresses[i]) > 0) {
                emit DebugNumber(i); // Number to index
                return false; // NOTE: We do not have donation functions so this is true unless something is off
            }
        }

        return true;
    }

    // Sum of assets received on `claimCancelDepositRequest`<= sum of fulfillCancelDepositRequest.assets
    function invariant_global_5() public view returns (bool) {
        if (address(token) == address(0)) {
            return true; // Skip
        }

        // claimCancelDepositRequest
        return sumOfClaimedDepositCancelations[address(token)]
        // asyncRequests_fulfillCancelDepositRequest
        <= cancelDepositCurrencyPayout[address(token)];
    }

    // Sum of tranche tokens received on `claimCancelRedeemRequest`<= sum of
    // fulfillCancelRedeemRequest.shares
    function invariant_global_6() public view returns (bool) {
        if (address(trancheToken) == address(0)) {
            return true; // Skip
        }

        // claimCancelRedeemRequest
        return sumOfClaimedRedeemCancelations[address(trancheToken)]
        // asyncRequests_fulfillCancelRedeemRequest
        <= cancelRedeemTrancheTokenPayout[address(trancheToken)];
    }

    // == TRANCHE TOKENS == //
    // TT-1
    // On the function handler, both transfer, transferFrom, perhaps even mint

    // TODO: Actors
    // TODO: Targets / Tranches
    /// @notice Sum of balances equals total supply
    function invariant_tt_2() public view returns (bool) {
        if (address(trancheToken) == address(0)) {
            return true; // Skip
        }
        uint256 ACTORS_LENGTH = 1;
        address[] memory actors = new address[](ACTORS_LENGTH);
        actors[0] = address(this);

        uint256 acc;

        for (uint256 i; i < ACTORS_LENGTH; ++i) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo tranche
            try trancheToken.balanceOf(actors[i]) returns (uint256 bal) {
                acc += bal;
            } catch {}
        }

        // NOTE: This ensures that supply doesn't overflow
        return acc <= trancheToken.totalSupply();
    }

    function invariant_IM_1() public view returns (bool) {
        if (address(asyncRequests) == address(0)) {
            return true;
        }
        if (address(vault) == address(0)) {
            return true;
        }
        if (actor != address(this)) {
            return true; // Canary for actor swaps
        }

        // Get actor data

        {
            (uint256 depositPrice,) = _getDepositAndRedeemPrice();

            // NOTE: Specification | Obv this breaks when you switch pools etc..
            // NOTE: Should reset
            // OR: Separate the check per actor | tranche instead of being so simple
            if (depositPrice > _investorsGlobals[actor].maxDepositPrice) {
                return false;
            }

            if (depositPrice < _investorsGlobals[actor].minDepositPrice) {
                return false;
            }
        }

        return true;
    }

    function invariant_IM_2() public view returns (bool) {
        if (address(asyncRequests) == address(0)) {
            return true;
        }
        if (address(vault) == address(0)) {
            return true;
        }
        if (actor != address(this)) {
            return true; // Canary for actor swaps
        }

        // Get actor data

        {
            (, uint256 redeemPrice) = _getDepositAndRedeemPrice();

            if (redeemPrice > _investorsGlobals[actor].maxRedeemPrice) {
                return false;
            }

            if (redeemPrice < _investorsGlobals[actor].minRedeemPrice) {
                return false;
            }
        }

        return true;
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
    function invariant_E_1() public view returns (bool) {
        if (address(escrow) == address(0)) {
            return true;
        }
        if (address(token) == address(0)) {
            return true;
        }

        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as assets cannot overflow due to other
        // functions permanently reverting
        unchecked {
            // The balance of tokens in Escrow is sum of deposit requests plus transfers in minus transfers out
            return token.balanceOf(address(escrow))
            // Deposit Requests + Transfers In
            /// @audit Minted by Asset Payouts by Investors
            == (
                mintedByCurrencyPayout[address(token)] + sumOfDepositRequests[address(token)]
                    + sumOfTransfersIn[address(token)]
                // Minus Claimed Redemptions and TransfersOut
                - sumOfClaimedRedemptions[address(token)] - sumOfClaimedDepositCancelations[address(token)]
                    - sumOfTransfersOut[address(token)]
            );
        }
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
    function invariant_E_2() public view returns (bool) {
        if (address(trancheToken) == address(0)) {
            return true;
        }

        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as trancheToken cannot overflow due to other
        // functions permanently reverting
        unchecked {
            return trancheToken.balanceOf(address(escrow))
                == (
                    sumOfFullfilledDeposits[address(trancheToken)] + sumOfRedeemRequests[address(trancheToken)]
                        - sumOfClaimedDeposits[address(trancheToken)] - sumOfClaimedRedeemCancelations[address(trancheToken)]
                        - sumOfClaimedRequests[address(trancheToken)]
                );
        }
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

    // TODO: Multi Actor -> Swap actors memory to actors storage
    // TODO: Multi Assets -> Iterate over all existing combinations
    // TODO: Broken? Why
    event DebugWithString(string, uint256);

    function invariant_E_3() public returns (bool) {
        if (address(vault) == address(0)) {
            return true;
        }

        if (actor != address(this)) {
            return true; // Canary for actor swaps
        }

        uint256 balOfEscrow = token.balanceOf(address(escrow));

        // Use acc to get maxWithdraw for each actor
        uint256 ACTORS_LENGTH = 1;
        address[] memory actors = new address[](ACTORS_LENGTH);
        actors[0] = address(this);

        uint256 acc;

        for (uint256 i; i < ACTORS_LENGTH; ++i) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo tranche
            try vault.maxWithdraw(actors[i]) returns (uint256 amt) {
                emit DebugWithString("maxWithdraw", amt);
                acc += amt;
            } catch {}
        }

        return acc <= balOfEscrow; // Ensure bal of escrow is sufficient to fulfill requests
    }

    function invariant_E_4() public returns (bool) {
        if (address(vault) == address(0)) {
            return true;
        }

        if (actor != address(this)) {
            return true; // Canary for actor swaps
        }

        uint256 balOfEscrow = trancheToken.balanceOf(address(escrow));
        emit DebugWithString("balOfEscrow", balOfEscrow);

        // Use acc to get maxMint for each actor
        uint256 ACTORS_LENGTH = 1;
        address[] memory actors = new address[](ACTORS_LENGTH);
        actors[0] = address(this);

        uint256 acc;

        for (uint256 i; i < ACTORS_LENGTH; ++i) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo tranche
            try vault.maxMint(actors[i]) returns (uint256 amt) {
                emit DebugWithString("maxMint", amt);
                acc += amt;
            } catch {}
        }

        emit DebugWithString("acc - balOfEscrow", balOfEscrow < acc ? acc - balOfEscrow : 0);
        return acc <= balOfEscrow; // Ensure bal of escrow is sufficient to fulfill requests
    }
}
