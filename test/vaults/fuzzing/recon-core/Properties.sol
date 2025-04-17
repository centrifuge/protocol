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
    function invariant_sentinel_token_balance() public view returns (bool) {
        if (!RECON_USE_SENTINEL_TESTS) {
            return true; // Skip if setting is off
        }

        if (address(token) == address(0)) {
            return true; // Skip
        }
        // Dig until we get non-zero share class balance
        // Afaict this will never work
        return token.balanceOf(actor) == 0;
    }

    // == GLOBAL == //
    event DebugNumber(uint256);

    // Sum of share class tokens received on `deposit` and `mint` <= sum of fulfilledDepositRequest.shares
    function invariant_global_1() public view returns (bool) {
        if (address(token) == address(0)) {
            return true; // Skip
        }

        // Mint and Deposit
        return sumOfClaimedDeposits[address(token)]
        // asyncRequests_fulfilledDepositRequest
        <= sumOfFullfilledDeposits[address(token)];
    }

    function invariant_global_2() public view returns (bool) {
        if (address(assetErc20) == address(0)) {
            return true; // Skip
        }

        // Redeem and Withdraw
        return sumOfClaimedRedemptions[address(assetErc20)]
        // asyncRequests_handleExecutedCollectRedeem
        <= mintedByCurrencyPayout[address(assetErc20)];
    }

    function invariant_global_3() public view returns (bool) {
        if (address(token) == address(0)) {
            return true; // Skip
        }

        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as token cannot overflow due to other
        // functions permanently reverting
        unchecked {
            return token.totalSupply()
            // NOTE: Includes `shareMints` which are arbitrary mints
            == shareMints[address(token)] + executedInvestments[address(token)] + incomingTransfers[address(token)]
                - outGoingTransfers[address(token)] - executedRedemptions[address(token)];
        }
    }

    /// @dev Lists out all system addresses, used to check that no dust is left behind
    /// NOTE: A more advanced dust check would have 100% of actors withdraw, to ensure that the sum of operations is
    /// sound
    function _getSystemAddresses() internal view returns (address[] memory) {
        uint256 SYSTEM_ADDRESSES_LENGTH = 9;

        address[] memory systemAddresses = new address[](SYSTEM_ADDRESSES_LENGTH);
        systemAddresses[0] = address(vaultFactory);
        systemAddresses[1] = address(tokenFactory);

        // NOTE: Skipping escrow which instead can have non-zero bal

        systemAddresses[2] = address(asyncRequests);
        systemAddresses[3] = address(poolManager);
        systemAddresses[4] = address(vault);
        systemAddresses[5] = address(assetErc20);
        systemAddresses[6] = address(token);
        systemAddresses[7] = address(restrictedTransfers);

        return systemAddresses;
    }

    /// @dev Can we donate to this address?
    /// We explicitly preventing donations since we check for exact balances
    function _canDonate(address to) internal view returns (bool) {
        if (to == poolEscrowFactory.escrow(poolId)) {
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
        if (address(assetErc20) == address(0)) {
            return true; // Skip
        }

        address[] memory systemAddresses = _getSystemAddresses();
        uint256 SYSTEM_ADDRESSES_LENGTH = systemAddresses.length;

        // NOTE: Skipping root and gateway since we mocked them
        for (uint256 i; i < SYSTEM_ADDRESSES_LENGTH; i++) {
            if (assetErc20.balanceOf(systemAddresses[i]) > 0) {
                emit DebugNumber(i); // Number to index
                return false; // NOTE: We do not have donation functions so this is true unless something is off
            }
        }

        return true;
    }

    // Sum of assets received on `claimCancelDepositRequest`<= sum of fulfillCancelDepositRequest.assets
    function invariant_global_5() public view returns (bool) {
        if (address(assetErc20) == address(0)) {
            return true; // Skip
        }

        // claimCancelDepositRequest
        return sumOfClaimedDepositCancelations[address(assetErc20)]
        // asyncRequests_fulfillCancelDepositRequest
        <= cancelDepositCurrencyPayout[address(assetErc20)];
    }

    // Sum of share class tokens received on `claimCancelRedeemRequest`<= sum of
    // fulfillCancelRedeemRequest.shares
    function invariant_global_6() public view returns (bool) {
        if (address(token) == address(0)) {
            return true; // Skip
        }

        // claimCancelRedeemRequest
        return sumOfClaimedRedeemCancelations[address(token)]
        // asyncRequests_fulfillCancelRedeemRequest
        <= cancelRedeemShareTokenPayout[address(token)];
    }

    // == SHARE CLASS TOKENS == //
    // TT-1
    // On the function handler, both transfer, transferFrom, perhaps even mint

    // TODO: Actors
    // TODO: Targets / Shares
    /// @notice Sum of balances equals total supply
    function invariant_tt_2() public view returns (bool) {
        if (address(token) == address(0)) {
            return true; // Skip
        }
        uint256 ACTORS_LENGTH = 1;
        address[] memory actors = new address[](ACTORS_LENGTH);
        actors[0] = address(this);

        uint256 acc;

        for (uint256 i; i < ACTORS_LENGTH; ++i) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo share class
            try token.balanceOf(actors[i]) returns (uint256 bal) {
                acc += bal;
            } catch {}
        }

        // NOTE: This ensures that supply doesn't overflow
        return acc <= token.totalSupply();
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
            // OR: Separate the check per actor | share class instead of being so simple
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
        if (poolEscrowFactory.escrow(poolId) == address(0)) {
            return true;
        }
        if (address(assetErc20) == address(0)) {
            return true;
        }

        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as assets cannot overflow due to other
        // functions permanently reverting
        unchecked {
            // The balance of tokens in Escrow is sum of deposit requests plus transfers in minus transfers out
            return assetErc20.balanceOf(poolEscrowFactory.escrow(poolId))
            // Deposit Requests + Transfers In
            /// @audit Minted by Asset Payouts by Investors
            == (
                mintedByCurrencyPayout[address(assetErc20)] + sumOfDepositRequests[address(assetErc20)]
                    + sumOfTransfersIn[address(assetErc20)]
                // Minus Claimed Redemptions and TransfersOut
                - sumOfClaimedRedemptions[address(assetErc20)] - sumOfClaimedDepositCancelations[address(assetErc20)]
                    - sumOfTransfersOut[address(assetErc20)]
            );
        }
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
    function invariant_E_2() public view returns (bool) {
        if (address(token) == address(0)) {
            return true;
        }

        // NOTE: By removing checked the math can overflow, then underflow back, resulting in correct calculations
        // NOTE: Overflow should always result back to a rational value as token cannot overflow due to other
        // functions permanently reverting
        unchecked {
            return token.balanceOf(poolEscrowFactory.escrow(poolId))
                == (
                    sumOfFullfilledDeposits[address(token)] + sumOfRedeemRequests[address(token)]
                        - sumOfClaimedDeposits[address(token)] - sumOfClaimedRedeemCancelations[address(token)]
                        - sumOfClaimedRequests[address(token)]
                );
        }
    }

    /// NOTE: Example of checked overflow, unused as we have changed tracking of Share tokens to be based on Global_3
    function _decreaseTotalShareSent(address assetErc20, uint256 amt) internal {
        uint256 cachedTotal = totalShareSent[assetErc20];
        unchecked {
            totalShareSent[assetErc20] -= amt;
        }

        // Check for overflow here
        gte(cachedTotal, totalShareSent[assetErc20], " _decreaseTotalShareSent Overflow");
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

        uint256 balOfEscrow = assetErc20.balanceOf(poolEscrowFactory.escrow(poolId));

        // Use acc to get maxWithdraw for each actor
        uint256 ACTORS_LENGTH = 1;
        address[] memory actors = new address[](ACTORS_LENGTH);
        actors[0] = address(this);

        uint256 acc;

        for (uint256 i; i < ACTORS_LENGTH; ++i) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo share class
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

        uint256 balOfEscrow = token.balanceOf(poolEscrowFactory.escrow(poolId));
        emit DebugWithString("balOfEscrow", balOfEscrow);

        // Use acc to get maxMint for each actor
        uint256 ACTORS_LENGTH = 1;
        address[] memory actors = new address[](ACTORS_LENGTH);
        actors[0] = address(this);

        uint256 acc;

        for (uint256 i; i < ACTORS_LENGTH; ++i) {
            // NOTE: Accounts for scenario in which we didn't deploy the demo share class
            try vault.maxMint(actors[i]) returns (uint256 amt) {
                emit DebugWithString("maxMint", amt);
                acc += amt;
            } catch {}
        }

        emit DebugWithString("acc - balOfEscrow", balOfEscrow < acc ? acc - balOfEscrow : 0);
        return acc <= balOfEscrow; // Ensure bal of escrow is sufficient to fulfill requests
    }
}
