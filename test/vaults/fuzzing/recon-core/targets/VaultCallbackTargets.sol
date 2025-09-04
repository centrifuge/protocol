/// Callbacks for AsyncVault

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {vm} from "@chimera/Hevm.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {console2} from "forge-std/console2.sol";

// Types
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {D18} from "src/misc/types/D18.sol";
// Src Deps
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {ShareToken} from "src/spoke/ShareToken.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";

import {Properties} from "../properties/Properties.sol";
import {OpType} from "../BeforeAfter.sol";

/// @dev Separate the 5 Callbacks that go from Gateway to AsyncRequests
/**
 */
abstract contract VaultCallbackTargets is BaseTargetFunctions, Properties {
    /// @dev Callback to requestDeposit
    function asyncRequests_fulfillDepositRequest(
        uint128 currencyPayout,
        uint128 tokenPayout,
        uint128 cancelledAssets,
        uint256 investorEntropy,
        D18 pricePoolPerShare
    ) public notGovFuzzing updateGhostsWithType(OpType.ADMIN) {
        address investor = _getRandomActor(investorEntropy);

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
            ) = asyncRequestManager.investments(IBaseVault(address(vault)), investor);

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

        MockERC20(address(token)).mint(address(escrow), tokenPayout);

        asyncRequestManager.revokedShares(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            AssetId.wrap(assetId),
            currencyPayout,
            tokenPayout,
            pricePoolPerShare
        );
        asyncRequestManager.fulfillDepositRequest(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            investor,
            AssetId.wrap(assetId),
            currencyPayout,
            tokenPayout,
            cancelledAssets
        );

        (address asset, uint256 tokenId) = spoke.idToAsset(AssetId.wrap(assetId));
        balanceSheet.noteDeposit(PoolId.wrap(poolId), ShareClassId.wrap(scId), asset, tokenId, currencyPayout);
        // E-2 | Global-1
        sumOfFullfilledDeposits[address(token)] += tokenPayout;

        // Track mint
        executedInvestments[address(token)] += tokenPayout;

        __globals();
    }

    /// @dev Callback to requestRedeem
    function asyncRequests_fulfillRedeemRequest(
        uint128 currencyPayout,
        uint128 tokenPayout,
        uint128 cancelledShares,
        uint256 investorEntropy
    ) public notGovFuzzing updateGhostsWithType(OpType.ADMIN) {
        address investor = _getRandomActor(investorEntropy);

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
            ) = asyncRequestManager.investments(vault, investor);

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
        MockERC20(_getAsset()).mint(address(escrow), currencyPayout);
        mintedByCurrencyPayout[_getAsset()] += currencyPayout;
        // /// @audit We mint payout here which has to be paid by the borrowers
        // // END TODO test_invariant_asyncVault_10_w_recon

        asyncRequestManager.fulfillRedeemRequest(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            investor,
            AssetId.wrap(assetId),
            currencyPayout,
            tokenPayout,
            cancelledShares
        );

        // balanceSheet.noteRevoke(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, tokenPayout);

        sumOfClaimedRequests[address(token)] += tokenPayout;

        // NOTE: Currency moves from escrow to user escrow, we do not track that at this time

        // Track burn
        executedRedemptions[address(token)] += tokenPayout;

        __globals();
    }

    uint256 totalCurrencyPayout;

    /// @dev Callback to `cancelDepositRequest`
    /// @dev NOTE: Share -> decreaseByAmount is linear!
    // function asyncRequests_fulfillCancelDepositRequest(uint128 currencyPayout, uint128 cancelledShares, uint256
    // investorEntropy) public notGovFuzzing updateGhostsWithType(OpType.ADMIN) {
    //     /// === CLAMP `currencyPayout` === ///
    //     address investor = _getRandomActor(investorEntropy);

    //     // Require that the investor has created a deposit request
    //     require(vault.pendingCancelDepositRequest(0, investor));
    //     {
    //         (
    //             /*uint128 maxMint*/
    //             ,
    //             /*uint128 maxWithdraw*/
    //             ,
    //             /*uint256 depositPrice*/
    //             ,
    //             /*uint256 redeemPrice*/
    //             ,
    //             uint128 pendingDepositRequest,
    //             /*uint128 pendingRedeemRequest*/
    //             ,
    //             /*uint128 claimableCancelDepositRequest*/
    //             ,
    //             /*uint128 claimableCancelRedeemRequest*/
    //             ,
    //             /*bool pendingCancelDepositRequest*/
    //             ,
    //             /*bool pendingCancelRedeemRequest*/
    //         ) = asyncRequestManager.investments(vault, investor);

    //         /// @audit DANGEROUS TODO: Clamp so we ensure we never give remaining above what was sent, fully trusted
    //         /// value
    //         // remainingInvestOrder %=
    //         // Need to cap currencyPayout by the amount in the escrow?
    //         // TO ASK Should currency payout be capped to the amount?
    //         if (pendingDepositRequest == 0) {
    //             /// @audit NOTHING REQUESTED = WE STOP
    //             return;
    //         } else {
    //             currencyPayout %= pendingDepositRequest + 1; // Needs to be capped at this value
    //             totalCurrencyPayout += currencyPayout;
    //             /// @audit TODO Remove totalCurrencyPayout
    //         }
    //     }
    //     // Need to cap remainingInvestOrder by the shares?

    //     // TODO: Would they set the order to a higher value?
    //     asyncRequestManager.fulfillCancelDepositRequest(
    //         PoolId.wrap(poolId),
    //         ShareClassId.wrap(scId),
    //         investor,
    //         AssetId.wrap(assetId),
    //         currencyPayout,
    //         currencyPayout,
    //         cancelledShares
    //     );
    //     /// @audit Reduced by: currencyPayout

    //     cancelDepositCurrencyPayout[_getAsset()] += currencyPayout;

    //     __globals();
    // }

    /// @dev Callback to `cancelRedeemRequest`
    /// @dev NOTE: Share -> decreaseByAmount is linear!
    // function asyncRequests_fulfillCancelRedeemRequest(uint128 tokenPayout, uint256 investorEntropy) public
    // notGovFuzzing updateGhostsWithType(OpType.ADMIN) {
    //     // Require that the actor has done the request

    //     /// === CLAMP `tokenPayout` === ///
    //     address investor = _getRandomActor(investorEntropy);
    //     require(vault.pendingCancelRedeemRequest(0, investor));

    //     {
    //         (
    //             /*uint128 maxMint*/
    //             ,
    //             /*uint128 maxWithdraw*/
    //             ,
    //             /*uint256 depositPrice*/
    //             ,
    //             /*uint256 redeemPrice*/
    //             ,
    //             /*uint128 pendingDepositRequest*/
    //             ,
    //             uint128 pendingRedeemRequest,
    //             /*uint128 claimableCancelDepositRequest*/
    //             ,
    //             /*uint128 claimableCancelRedeemRequest*/
    //             ,
    //             /*bool pendingCancelDepositRequest*/
    //             ,
    //             /*bool pendingCancelRedeemRequest*/
    //         ) = asyncRequestManager.investments(vault, investor);

    //         /// @audit DANGEROUS TODO: Clamp so we ensure we never give remaining above what was sent, fully trusted
    //         /// value
    //         // remainingInvestOrder %=
    //         // Need to cap currencyPayout by the amount in the escrow?
    //         // TO ASK Should currency payout be capped to the amount?
    //         if (pendingRedeemRequest == 0) {
    //             /// @audit NOTHING REQUESTED = WE STOP
    //             return;
    //         } else {
    //             tokenPayout %= pendingRedeemRequest + 1; // Needs to be capped at this value
    //         }
    //     }

    //     asyncRequestManager.fulfillCancelRedeemRequest(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor,
    // AssetId.wrap(assetId), tokenPayout);
    //     /// @audit tokenPayout

    //     cancelRedeemShareTokenPayout[address(token)] += tokenPayout;

    //     __globals();
    // }

    // NOTE: TODO: We should remove this and consider a separate test, if we go by the FSM
    // FSM -> depps
    // function asyncRequests_triggerRedeemRequest(uint128 tokenAmount) public {
    //     uint256 balB4 = token.balanceOf(_getActor());

    //     asyncRequests.triggerRedeemRequest(poolId, scId, _getActor(), assetId, tokenAmount);

    //     uint256 balAfter = token.balanceOf(_getActor());

    //     // E-2 /// @audit TODO: Forcefully moves tokens from user to here only if a transfer happened
    //     sumOfRedeemRequests[(address(token))] += balB4 - balAfter;

    //     __globals();
    // }
}
