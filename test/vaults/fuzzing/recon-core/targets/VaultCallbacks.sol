/// Callbacks for AsyncVault

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Properties} from "../Properties.sol";
import {vm} from "@chimera/Hevm.sol";

// Src Deps | For cycling of values
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {CentrifugeToken} from "src/vaults/token/ShareToken.sol";
import {RestrictedTransfers} from "src/hooks/RestrictedTransfers.sol";

/// @dev Separate the 5 Callbacks that go from Gateway to AsyncRequests
/**
 */
abstract contract VaultCallbacks is BaseTargetFunctions, Properties {
    /// @dev Callback to requestDeposit
    function asyncRequests_fulfillDepositRequest(
        uint128 currencyPayout,
        uint128 tokenPayout,
        uint128 /*decreaseByAmount*/
    ) public {
        /// === CLAMP `currencyPayout` === ///
        {
            (
                /*uint128 maxMint*/
                ,
                /*uint128 maxWithdraw*/
                ,
                /*uint256 depositPrice*/
                ,
                /*uint256 redeemPrice*/
                ,
                uint128 pendingDepositRequest,
                /*uint128 pendingRedeemRequest*/
                ,
                /*uint128 claimableCancelDepositRequest*/
                ,
                /*uint128 claimableCancelRedeemRequest*/
                ,
                /*bool pendingCancelDepositRequest*/
                ,
                /*bool pendingCancelRedeemRequest*/
            ) = asyncRequests.investments(address(vault), address(actor));

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

        asyncRequests.fulfillDepositRequest(poolId, scId, actor, assetId, currencyPayout, tokenPayout);

        // E-2 | Global-1
        sumOfFullfilledDeposits[address(token)] += tokenPayout;

        // Track mint
        executedInvestments[address(token)] += tokenPayout;

        __globals();
    }

    /// @dev Callback to requestRedeem
    function asyncRequests_fulfillRedeemRequest(uint128 currencyPayout, uint128 tokenPayout) public {
        /// === CLAMP `tokenPayout` === ///
        {
            (
                /*uint128 maxMint*/
                ,
                /*uint128 maxWithdraw*/
                ,
                /*uint256 depositPrice*/
                ,
                /*uint256 redeemPrice*/
                ,
                /*uint128 pendingDepositRequest*/
                ,
                uint128 pendingRedeemRequest,
                /*uint128 claimableCancelDepositRequest*/
                ,
                /*uint128 claimableCancelRedeemRequest*/
                ,
                /*bool pendingCancelDepositRequest*/
                ,
                /*bool pendingCancelRedeemRequest*/
            ) = asyncRequests.investments(address(vault), address(actor));

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
                tokenPayout %= pendingRedeemRequest; // Needs to be capped at this value
                    // remainingRedeemOrder = pendingRedeemRequest - tokenPayout; /// @audit Replaced by
                    // decreaseByAmount
            }
        }

        // TODO: Re check
        // // TODO: test_invariant_asyncVault_10_w_recon
        assetErc20.mint(address(escrow), currencyPayout);
        mintedByCurrencyPayout[address(assetErc20)] += currencyPayout;
        // /// @audit We mint payout here which has to be paid by the borrowers
        // // END TODO test_invariant_asyncVault_10_w_recon

        asyncRequests.fulfillRedeemRequest(poolId, scId, actor, assetId, currencyPayout, tokenPayout);

        sumOfClaimedRequests[address(token)] += tokenPayout;

        // NOTE: Currency moves from escrow to user escrow, we do not track that at this time

        // Track burn
        executedRedemptions[address(token)] += tokenPayout;

        __globals();
    }

    uint256 totalCurrencyPayout;

    /// @dev Callback to `cancelDepositRequest`
    /// @dev NOTE: Share -> decreaseByAmount is linear!
    function asyncRequests_fulfillCancelDepositRequest(uint128 currencyPayout) public {
        /// === CLAMP `currencyPayout` === ///
        // Require that the actor has done the request
        require(vault.pendingCancelDepositRequest(0, actor));
        {
            (
                /*uint128 maxMint*/
                ,
                /*uint128 maxWithdraw*/
                ,
                /*uint256 depositPrice*/
                ,
                /*uint256 redeemPrice*/
                ,
                uint128 pendingDepositRequest,
                /*uint128 pendingRedeemRequest*/
                ,
                /*uint128 claimableCancelDepositRequest*/
                ,
                /*uint128 claimableCancelRedeemRequest*/
                ,
                /*bool pendingCancelDepositRequest*/
                ,
                /*bool pendingCancelRedeemRequest*/
            ) = asyncRequests.investments(address(vault), address(actor));

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
        asyncRequests.fulfillCancelDepositRequest(poolId, scId, actor, assetId, currencyPayout, currencyPayout);
        /// @audit Reduced by: currencyPayout

        cancelDepositCurrencyPayout[address(assetErc20)] += currencyPayout;

        __globals();
    }

    /// @dev Callback to `cancelRedeemRequest`
    /// @dev NOTE: Share -> decreaseByAmount is linear!
    function asyncRequests_fulfillCancelRedeemRequest(uint128 tokenPayout) public {
        // Require that the actor has done the request

        /// === CLAMP `tokenPayout` === ///
        require(vault.pendingCancelRedeemRequest(0, actor));

        {
            (
                /*uint128 maxMint*/
                ,
                /*uint128 maxWithdraw*/
                ,
                /*uint256 depositPrice*/
                ,
                /*uint256 redeemPrice*/
                ,
                /*uint128 pendingDepositRequest*/
                ,
                uint128 pendingRedeemRequest,
                /*uint128 claimableCancelDepositRequest*/
                ,
                /*uint128 claimableCancelRedeemRequest*/
                ,
                /*bool pendingCancelDepositRequest*/
                ,
                /*bool pendingCancelRedeemRequest*/
            ) = asyncRequests.investments(address(vault), address(actor));

            /// @audit DANGEROUS TODO: Clamp so we ensure we never give remaining above what was sent, fully trusted
            /// value
            // remainingInvestOrder %=
            // Need to cap currencyPayout by the amount in the escrow?
            // TO ASK Should currency payout be capped to the amount?
            if (pendingRedeemRequest == 0) {
                /// @audit NOTHING REQUESTED = WE STOP
                return;
            } else {
                tokenPayout %= pendingRedeemRequest + 1; // Needs to be capped at this value
            }
        }

        asyncRequests.fulfillCancelRedeemRequest(poolId, scId, actor, assetId, tokenPayout);
        /// @audit tokenPayout

        cancelRedeemShareTokenPayout[address(token)] += tokenPayout;

        __globals();
    }

    // NOTE: TODO: We should remove this and consider a separate test, if we go by the FSM
    // FSM -> depps
    // function asyncRequests_triggerRedeemRequest(uint128 tokenAmount) public {
    //     uint256 balB4 = token.balanceOf(actor);

    //     asyncRequests.triggerRedeemRequest(poolId, scId, actor, assetId, tokenAmount);

    //     uint256 balAfter = token.balanceOf(actor);

    //     // E-2 /// @audit TODO: Forcefully moves tokens from user to here only if a transfer happened
    //     sumOfRedeemRequests[(address(token))] += balB4 - balAfter;

    //     __globals();
    // }
}
