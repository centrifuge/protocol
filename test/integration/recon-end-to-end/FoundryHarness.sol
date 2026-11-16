// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TargetFunctions} from "./TargetFunctions.sol";

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

/// @notice The Foundry harness of the suite: the deployment, every handler as the fuzz target, the property check and
///         the assertions. `CryticToFoundry` holds the reproducers and the reachability contracts their own tests;
///         each inherits this alone, so no test runs again under another contract's name.
/// @dev    A failed check inside a handler is recorded rather than reverted, because Foundry discards a
///         reverting handler call (`fail_on_revert = false`) together with whatever it found; `assertProperties`
///         then asserts nothing was recorded. Echidna and Medusa run the same handlers through
///         `CryticE2ETester`, where a failed check is an `assert(false)`. The stateful invariant itself lives in
///         `StatefulInvariant`.
abstract contract FoundryHarness is Test, TargetFunctions {
    string[] internal failures;

    function setUp() public {
        setup();
        vm.deal(address(this), 100 ether);

        targetContract(address(this));
        targetSelector(FuzzSelector({addr: address(this), selectors: _handlers()}));
    }

    /// @dev Every property; the stateful invariant checks it after every call the profile checks.
    function assertProperties() public {
        property_sum_of_balances();
        property_shareTokenSupplyConsistency();
        property_shareTokenCountedInSupply();
        property_system_addresses_never_receive_share_tokens();
        property_everyAssetIsAccountedFor();
        property_escrowBalanceMatchesHoldingTotal();
        property_basinDebtIsBooked();
        property_hubHoldingMatchesEscrowAccounted();
        property_escrowReservedSumConsistency();
        property_accounting_books_balance();
        property_accountTotalsFitInt128();
        property_accounting_and_holdings_soundness();
        property_holdingZeroAmountHasZeroValue();
        property_deficitCountMatchesHoldings();
        property_shareQueueCommutativity();
        property_deltaCheck();
        property_nonceMonotonicity();
        property_assetQueueCounterConsistency();
        property_assetCounterBounds();
        property_authorizationBypass();
        property_authorizationLevel();
        property_authorizationChange();
        property_sum_of_shares_received();
        property_sum_of_assets_received();
        property_cancelled_and_processed_deposits_soundness();
        property_cancelled_and_processed_redemptions_soundness();
        property_actor_pending_and_queued_deposits();
        property_actor_pending_and_queued_redemptions();
        property_orderBookMatchesBuckets();
        property_pendingDepositsStayReservedPerRequest();
        property_pendingTotalsMatchTheRequests();
        property_navPoolSumsTheNetworks();
        property_strictPolicyAnchorsOnExecutedMoves();
        property_poolBIsUntouched();
        property_poolDIsUntouched();
        property_poolDIsConsistent();
        property_viewsNeverRevert();
        property_sum_of_possible_account_balances_leq_escrow();
        property_oracleVerdict();
        property_invalidPriceClosesInstantLane();
        property_vaultIdentityAndInterfaces();
        property_conversionsAreConsistent();
        property_previewsRoundAgainstTheCaller();
        property_noDrawWithoutConsent();
        property_maxViewsAnswerEveryone();
        property_maxRedeemIsRedeemable();
        property_noValueStrandedInEscrow();
        property_foldedNeverExceedsSettled();
        property_maxMatchesClaimable();
        property_hubNonceMatchesSpoke();
        property_maxViewsAreExecutable();
        property_maxIsZeroWhenTheLaneIsShut();
        property_previewsFollowTheLane();
        property_extremeAmountsAreDefined();
        property_shareTokenIdentity();
        property_claimableMatchesOwedLessClaimed();
        property_actorClaimableMatchesOwedLessClaimed();
        property_actorGhostsSumToVaultGhosts();
        property_shareCustodyEquality();
        property_feeRecipientReceivedTheQuotedFees();
        _assertNoFailures();
    }

    function afterInvariant() external view {
        _logStats();
    }

    function gt(uint256 a, uint256 b, string memory reason) internal override {
        if (!(a > b)) _fail(reason, a, b);
    }

    function gte(uint256 a, uint256 b, string memory reason) internal override {
        if (!(a >= b)) _fail(reason, a, b);
    }

    function lt(uint256 a, uint256 b, string memory reason) internal override {
        if (!(a < b)) _fail(reason, a, b);
    }

    function lte(uint256 a, uint256 b, string memory reason) internal override {
        if (!(a <= b)) _fail(reason, a, b);
    }

    function eq(uint256 a, uint256 b, string memory reason) internal override {
        if (a != b) _fail(reason, a, b);
    }

    function t(bool b, string memory reason) internal override {
        if (!b) _fail(reason, 0, 0);
    }

    function between(uint256 value, uint256 low, uint256 high) internal pure override returns (uint256) {
        if (value >= low && value <= high) return value;
        return low + (value % (high - low + 1));
    }

    function between(int256 value, int256 low, int256 high) internal pure override returns (int256) {
        if (value >= low && value <= high) return value;
        int256 range = high - low + 1;
        int256 clamped = (value - low) % range;
        return low + (clamped < 0 ? clamped + range : clamped);
    }

    function precondition(bool p) internal pure override {
        vm.assume(p);
    }

    function _fail(string memory reason, uint256 a, uint256 b) internal {
        failures.push(string(abi.encodePacked(reason, " (", vm.toString(a), ", ", vm.toString(b), ")")));
    }

    function _failureCount() internal view override returns (uint256) {
        return failures.length;
    }

    function _assertNoFailures() internal view {
        if (failures.length != 0) revert(failures[0]);
    }

    /// @dev Every handler once, then the lifecycle and claim handlers again: Foundry picks uniformly among
    ///      the listed selectors, so a repeat weights the pick. A claim needs a request, a settlement and
    ///      a claim by the same controller to line up, which a uniform pick over 48 handlers rarely does.
    function _handlers() internal pure returns (bytes4[] memory selectors) {
        bytes4[84] memory once = [
            this.hub_lapseMember.selector,
            this.hub_setSponsors.selector,
            this.flow_manyWindows.selector,
            this.hub_installPolicy.selector,
            this.router_cycle.selector,
            this.hub_setVaultLink.selector,
            this.hub_setVaultManager.selector,
            this.escrow_coverAndClaim.selector,
            this.flow_routeExit.selector,
            this.flow_basinDrawAndRepay.selector,
            this.route_pushClaim.selector,
            this.hub_setObserver.selector,
            this.oracle_pauseDirect.selector,
            this.hub_setExtraGas.selector,
            this.router_deposit.selector,
            this.router_batch.selector,
            this.vault_requestDeposit.selector,
            this.vault_requestRedeem.selector,
            this.vault_transferRequest.selector,
            this.vault_flush.selector,
            this.vault_fold.selector,
            this.vault_claimDeposit.selector,
            this.vault_claimRedeem.selector,
            this.vault_claimMax.selector,
            this.vault_instantDeposit.selector,
            this.vault_instantRedeem.selector,
            this.vault_instantRoundTrip.selector,
            this.vault_previewIsTheClaim.selector,
            this.policy_configure.selector,
            this.policy_allow.selector,
            this.route_consent.selector,
            this.route_setRoutes.selector,
            this.vault_conversionsIgnoreTheCaller.selector,
            this.vault_maxExecutes.selector,
            this.vault_maxIgnoresBalance.selector,
            this.vault_requestIdsAreTheirs.selector,
            this.vault_requestRedeemBeyondBalance.selector,
            this.vault_strangerCannotClaimFor.selector,
            this.vault_strangerCannotRequestFor.selector,
            this.vault_setOperator.selector,
            this.vault_operatorClaim.selector,
            this.flow_deposit.selector,
            this.flow_redeem.selector,
            this.flow_cancel.selector,
            this.flow_sharedWindow.selector,
            this.hub_fulfill.selector,
            this.hub_cancel.selector,
            this.hub_setFee.selector,
            this.poolC_updateSharePrice.selector,
            this.poolC_configure.selector,
            this.vault_foldRequest.selector,
            this.hub_updateSharePrice.selector,
            this.hub_updateHoldingValue.selector,
            this.hub_warp.selector,
            this.hub_updateJournal.selector,
            this.hub_freeze.selector,
            this.hub_unfreeze.selector,
            this.hub_updateMember.selector,
            this.hub_updateSpokeManager.selector,
            this.oracle_setPaused.selector,
            this.oracle_stale.selector,
            this.oracle_skew.selector,
            this.oracle_refresh.selector,
            this.oracle_pauseRoundTrip.selector,
            this.balanceSheet_deposit.selector,
            this.balanceSheet_noteDeposit.selector,
            this.balanceSheet_withdraw.selector,
            this.balanceSheet_reserve.selector,
            this.balanceSheet_unreserve.selector,
            this.balanceSheet_withdrawReserved.selector,
            this.bs_withdrawVaultReserved.selector,
            this.balanceSheet_issue.selector,
            this.balanceSheet_revoke.selector,
            this.balanceSheet_withdrawShares.selector,
            this.balanceSheet_submitQueuedAssets.selector,
            this.balanceSheet_submitQueuedShares.selector,
            this.bsm_investInUnderlying.selector,
            this.token_transfer.selector,
            this.isolation_dManagerCall.selector,
            this.isolation_aManagerCall.selector,
            this.isolation_hubCross.selector,
            this.isolation_settleCross.selector,
            this.isolation_linkCross.selector,
            this.isolation_spokeCross.selector
        ];
        bytes4[10] memory rest = [
            this.token_transferFrom.selector,
            this.balanceSheet_submitLiability.selector,
            this.bsm_repayBasin.selector,
            this.basin_advertise.selector,
            this.doomsday_accountValue.selector,
            this.exit_everyoneCanLeave.selector,
            this.exit_afterPolicySwap.selector,
            this.flow_foldClaimOrder.selector,
            this.flow_flushTimingIndependence.selector,
            this.stranger_call.selector
        ];
        bytes4[16] memory weighted = [
            this.oracle_refresh.selector,
            this.flow_deposit.selector,
            this.flow_deposit.selector,
            this.flow_redeem.selector,
            this.flow_redeem.selector,
            this.flow_redeem.selector,
            this.flow_cancel.selector,
            this.flow_sharedWindow.selector,
            this.flow_sharedWindow.selector,
            this.vault_claimRedeem.selector,
            this.vault_claimMax.selector,
            this.vault_fold.selector,
            this.vault_instantRedeem.selector,
            this.vault_instantRedeem.selector,
            this.vault_instantRedeem.selector,
            this.vault_instantDeposit.selector
        ];
        bytes4[5] memory conserved = [
            this.flow_conserved.selector,
            this.flow_conserved.selector,
            this.flow_conservedAcrossPrice.selector,
            this.flow_conservedAcrossPrice.selector,
            this.vault_splitClaim.selector
        ];
        bytes4[9] memory assurance = [
            this.vault_overMaxRefused.selector,
            this.vault_instantTradeFor.selector,
            this.vault_claimMaxConverted.selector,
            this.vault_operatorRequests.selector,
            this.vault_allowanceRequestRedeem.selector,
            this.vault_operatorClaimsForOthers.selector,
            this.vault_operatorCannotTrade.selector,
            this.vault_donate.selector,
            this.vault_extremeAmounts.selector
        ];
        bytes4[31] memory gaps = [
            this.subsidy_withdraw.selector,
            this.nav_updateAssets.selector,
            this.nav_updateShares.selector,
            this.strict_updateRestriction.selector,
            this.strict_accounting.selector,
            this.strict_updateSharePrice.selector,
            this.vault_spenderRequestRedeem.selector,
            this.vault_misfiledRefusesRequests.selector,
            this.vault_rebatedTrade.selector,
            this.donate_andRecover.selector,
            this.route_hostileUnderlying.selector,
            this.bridge_transferShares.selector,
            this.router_bridgeShares.selector,
            this.router_nonMemberBridgeRefused.selector,
            this.hub_setShareTokenVault.selector,
            this.gas_worstCaseClaim.selector,
            this.atomic_refusedCallback.selector,
            this.atomic_refusedCallback.selector,
            this.route_setDuplicateRoute.selector,
            this.vault_flushAnyKind.selector,
            this.request_paidFromSubsidy.selector,
            this.basin_repayUnbooked.selector,
            this.basin_setLine.selector,
            this.hook_cappedInstantDeposit.selector,
            this.vault_strangerCannotMoveRequest.selector,
            this.vault_unlinkedRefusesRequests.selector,
            this.flow_claimFoldsTheHorizon.selector,
            this.vault_lapsedClaimsWhatMaxOffers.selector,
            this.flow_evictedNeedsFoldRequest.selector,
            this.flow_giftIntoFullHorizon.selector,
            this.vault_instantWhilePending.selector
        ];
        bytes4[4] memory multi = [
            this.flow_manyRequests.selector,
            this.flow_manyRequests.selector,
            this.flow_manyRequestsAcrossPrice.selector,
            this.flow_manyRequestsAcrossPrice.selector
        ];
        bytes4[4] memory prorata = [
            this.flow_sharedProRata.selector,
            this.flow_sharedProRata.selector,
            this.flow_sharedProRataAcrossPrice.selector,
            this.flow_sharedProRataAcrossPrice.selector
        ];
        selectors = new bytes4[](
            once.length + rest.length + weighted.length + conserved.length + assurance.length + gaps.length
                + multi.length + prorata.length
        );
        uint256 n;
        for (uint256 i; i < gaps.length; i++) {
            selectors[n++] = gaps[i];
        }
        for (uint256 i; i < multi.length; i++) {
            selectors[n++] = multi[i];
        }
        for (uint256 i; i < prorata.length; i++) {
            selectors[n++] = prorata[i];
        }
        for (uint256 i; i < assurance.length; i++) {
            selectors[n++] = assurance[i];
        }
        for (uint256 i; i < once.length; i++) {
            selectors[n++] = once[i];
        }
        for (uint256 i; i < rest.length; i++) {
            selectors[n++] = rest[i];
        }
        for (uint256 i; i < weighted.length; i++) {
            selectors[n++] = weighted[i];
        }
        for (uint256 i; i < conserved.length; i++) {
            selectors[n++] = conserved[i];
        }
    }

    function _logStats() internal view {
        console.log("action                           ok  reverted");
        for (uint256 i; i < actionNames.length; i++) {
            console.log(string(abi.encodePacked(actionNames[i])), ok[actionNames[i]], reverted[actionNames[i]]);
        }
    }

    /// @dev The `j`th word of a seed, for tests that derive several fuzzed values from one.
    function _fuzzW(uint256 seed, uint256 j) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, j)));
    }
}
