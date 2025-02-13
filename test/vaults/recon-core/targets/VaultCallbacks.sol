/// Callbacks for ERC7540Vault

// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Properties} from "../Properties.sol";
import {vm} from "@chimera/Hevm.sol";

// Src Deps | For cycling of values
import {ERC7540Vault} from "src/ERC7540Vault.sol";
import {ERC20} from "src/token/ERC20.sol";
import {Tranche} from "src/token/Tranche.sol";
import {RestrictionManager} from "src/token/RestrictionManager.sol";

/// @dev Separate the 5 Callbacks that go from Gateway to InvestmentManager
/**
 */
abstract contract VaultCallbacks is BaseTargetFunctions, Properties {
    /// @dev Callback to requestDeposit
    function investmentManager_fulfillDepositRequest(
        uint128 currencyPayout,
        uint128 trancheTokenPayout,
        uint128 decreaseByAmount
    ) public {
        /// === CLAMP `currencyPayout` === ///
        {
            (
                uint128 maxMint,
                uint128 maxWithdraw,
                uint256 depositPrice,
                uint256 redeemPrice,
                uint128 pendingDepositRequest,
                uint128 pendingRedeemRequest,
                uint128 claimableCancelDepositRequest,
                uint128 claimableCancelRedeemRequest,
                bool pendingCancelDepositRequest,
                bool pendingCancelRedeemRequest
            ) = investmentManager.investments(address(vault), address(actor));

            /// @audit DANGEROUS TODO: Clamp so we ensure we never give remaining above what was sent, fully trusted
            /// value
            // remainingInvestOrder %=
            // Need to cap currencyPayout by the amount in the escrow?
            // TO ASK Should currency payout be capped to the amount?
            if (pendingDepositRequest == 0) {
                /// @audit NOTHING REQUESTED = WE STOP
                return;
            } else {
                // TODO(@hieronx): revisit clamps here
                currencyPayout %= pendingDepositRequest; // Needs to be capped at this value
            }
        }

        investmentManager.fulfillDepositRequest(
            poolId, trancheId, actor, currencyId, currencyPayout, trancheTokenPayout
        );

        // E-2 | Global-1
        sumOfFullfilledDeposits[address(trancheToken)] += trancheTokenPayout;

        // Track mint
        executedInvestments[address(trancheToken)] += trancheTokenPayout;

        __globals();
    }

    /// @dev Callback to requestRedeem
    function investmentManager_fulfillRedeemRequest(uint128 currencyPayout, uint128 trancheTokenPayout) public {
        /// === CLAMP `trancheTokenPayout` === ///
        {
            (
                uint128 maxMint,
                uint128 maxWithdraw,
                uint256 depositPrice,
                uint256 redeemPrice,
                uint128 pendingDepositRequest,
                uint128 pendingRedeemRequest,
                uint128 claimableCancelDepositRequest,
                uint128 claimableCancelRedeemRequest,
                bool pendingCancelDepositRequest,
                bool pendingCancelRedeemRequest
            ) = investmentManager.investments(address(vault), address(actor));

            /// @audit DANGEROUS TODO: Clamp so we ensure we never give remaining above what was sent, fully trusted
            /// value
            // remainingInvestOrder %=
            // Need to cap currencyPayout by the amount in the escrow?
            // TO ASK Should currency payout be capped to the amount?
            if (pendingRedeemRequest == 0) {
                /// @audit NOTHING REQUESTED = WE STOP
                return;
            } else {
                // TODO(@hieronx): revisit clamps here
                trancheTokenPayout %= pendingRedeemRequest; // Needs to be capped at this value
                    // remainingRedeemOrder = pendingRedeemRequest - trancheTokenPayout; /// @audit Replaced by
                    // decreaseByAmount
            }
        }

        // TODO: Re check
        // // TODO: test_invariant_erc7540_10_w_recon
        token.mint(address(escrow), currencyPayout);
        mintedByCurrencyPayout[address(token)] += currencyPayout;
        // /// @audit We mint payout here which has to be paid by the borrowers
        // // END TODO test_invariant_erc7540_10_w_recon

        investmentManager.fulfillRedeemRequest(poolId, trancheId, actor, currencyId, currencyPayout, trancheTokenPayout);

        sumOfClaimedRequests[address(trancheToken)] += trancheTokenPayout;

        // NOTE: Currency moves from escrow to user escrow, we do not track that at this time

        // Track burn
        executedRedemptions[address(trancheToken)] += trancheTokenPayout;

        __globals();
    }

    uint256 totalCurrencyPayout;

    /// @dev Callback to `cancelDepositRequest`
    /// @dev NOTE: Tranche -> decreaseByAmount is linear!
    function investmentManager_fulfillCancelDepositRequest(uint128 currencyPayout) public {
        /// === CLAMP `currencyPayout` === ///
        // Require that the actor has done the request
        require(vault.pendingCancelDepositRequest(0, actor));
        {
            (
                uint128 maxMint,
                uint128 maxWithdraw,
                uint256 depositPrice,
                uint256 redeemPrice,
                uint128 pendingDepositRequest,
                uint128 pendingRedeemRequest,
                uint128 claimableCancelDepositRequest,
                uint128 claimableCancelRedeemRequest,
                bool pendingCancelDepositRequest,
                bool pendingCancelRedeemRequest
            ) = investmentManager.investments(address(vault), address(actor));

            /// @audit DANGEROUS TODO: Clamp so we ensure we never give remaining above what was sent, fully trusted
            /// value
            // remainingInvestOrder %=
            // Need to cap currencyPayout by the amount in the escrow?
            // TO ASK Should currency payout be capped to the amount?
            if (pendingDepositRequest == 0) {
                /// @audit NOTHING REQUESTED = WE STOP
                return;
            } else {
                currencyPayout %= pendingDepositRequest + 1; // Needs to be capped at this value
                totalCurrencyPayout += currencyPayout;
                /// @audit TODO Remove totalCurrencyPayout
            }
        }
        // Need to cap remainingInvestOrder by the shares?

        // TODO: Would they set the order to a higher value?
        investmentManager.fulfillCancelDepositRequest(
            poolId, trancheId, actor, currencyId, currencyPayout, currencyPayout
        );
        /// @audit Reduced by: currencyPayout

        cancelDepositCurrencyPayout[address(token)] += currencyPayout;

        __globals();
    }

    /// @dev Callback to `cancelRedeemRequest`
    /// @dev NOTE: Tranche -> decreaseByAmount is linear!
    function investmentManager_fulfillCancelRedeemRequest(uint128 trancheTokenPayout) public {
        // Require that the actor has done the request

        /// === CLAMP `trancheTokenPayout` === ///
        require(vault.pendingCancelRedeemRequest(0, actor));

        {
            (
                uint128 maxMint,
                uint128 maxWithdraw,
                uint256 depositPrice,
                uint256 redeemPrice,
                uint128 pendingDepositRequest,
                uint128 pendingRedeemRequest,
                uint128 claimableCancelDepositRequest,
                uint128 claimableCancelRedeemRequest,
                bool pendingCancelDepositRequest,
                bool pendingCancelRedeemRequest
            ) = investmentManager.investments(address(vault), address(actor));

            /// @audit DANGEROUS TODO: Clamp so we ensure we never give remaining above what was sent, fully trusted
            /// value
            // remainingInvestOrder %=
            // Need to cap currencyPayout by the amount in the escrow?
            // TO ASK Should currency payout be capped to the amount?
            if (pendingRedeemRequest == 0) {
                /// @audit NOTHING REQUESTED = WE STOP
                return;
            } else {
                trancheTokenPayout %= pendingRedeemRequest + 1; // Needs to be capped at this value
            }
        }

        investmentManager.fulfillCancelRedeemRequest(poolId, trancheId, actor, currencyId, trancheTokenPayout);
        /// @audit trancheTokenPayout

        cancelRedeemTrancheTokenPayout[address(trancheToken)] += trancheTokenPayout;

        __globals();
    }

    // NOTE: TODO: We should remove this and consider a separate test, if we go by the FSM
    // FSM -> depps
    // function investmentManager_triggerRedeemRequest(uint128 trancheTokenAmount) public {
    //     uint256 balB4 = trancheToken.balanceOf(actor);

    //     investmentManager.triggerRedeemRequest(poolId, trancheId, actor, currencyId, trancheTokenAmount);

    //     uint256 balAfter = trancheToken.balanceOf(actor);

    //     // E-2 /// @audit TODO: Forcefully moves tokens from user to here only if a transfer happened
    //     sumOfRedeemRequests[(address(trancheToken))] += balB4 - balAfter;

    //     __globals();
    // }
}
