// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TargetFunctions} from "./TargetFunctions.sol";

import {d18} from "../../../src/misc/types/D18.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {IHub} from "../../../src/core/hub/interfaces/IHub.sol";

import {IReserveInstantPolicy} from "../../../src/vaults/policies/interfaces/IVaultPlugins.sol";
import {IBasinLiquidityRoute} from "../../../src/vaults/liquidity/interfaces/IBasinLiquidityRoute.sol";
import {IVaultLiquidityRoute} from "../../../src/vaults/liquidity/interfaces/IVaultLiquidityRoute.sol";

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IShareTokenRegistrar} from "../../../src/token/interfaces/IShareTokenRegistrar.sol";

/// @notice The Foundry entrypoint of the suite: every handler, the property check and the reproducers.
/// @dev    A failed check inside a handler is recorded rather than reverted, because Foundry discards a
///         reverting handler call (`fail_on_revert = false`) together with whatever it found; `assertProperties`
///         then asserts nothing was recorded. Echidna and Medusa run the same handlers through
///         `CryticE2ETester`, where a failed check is an `assert(false)`. The stateful invariant itself lives in
///         `StatefulInvariant`, so the reachability contracts that inherit this one do not each rerun it.
contract CryticToFoundry is Test, TargetFunctions {
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

    //----------------------------------------------------------------------------------------------
    // Non-vacuity
    //----------------------------------------------------------------------------------------------

    /// @dev Every property is trivially true of a protocol nothing happened to. This drives each flow once
    ///      and asserts it went through, so a setup change that turns an action into a revert fails here
    ///      rather than leaving the suite green and empty.
    /// @dev The handlers the first suite lacked: lapsed members and sponsors, a long horizon, the investor
    ///      router, the hub policy, retirement and a sponsored position on the route.
    function testTheGapHandlersAreReachable() public {
        hub_lapseMember(0, 3 hours, false);
        hub_lapseMember(0, 0, true);
        hub_setSponsors(0, 1, true);
        hub_setSponsors(1, 0, false);

        router_cycle(2, 500 * ONE_ASSET, false, false);
        hub_fulfill(0, 0, true);
        router_cycle(2, 0, false, true);
        assertGt(ok["router_request"], 0, "unreachable: router_request");
        assertGt(ok["router_claim"], 0, "unreachable: router_claim");

        flow_manyWindows(1, 1, 16, false);
        assertGt(ok["flow_manyWindows"], 0, "unreachable: flow_manyWindows");

        // A stranger cannot credit another controller on a vault with both lanes; the sponsor `hub_setSponsors`
        // just allowed on vaults[2] can
        (bool strangerOk,) = _requestDeposit(_actor(0), _actor(2), 2, 10 * ONE_ASSET);
        assertFalse(strangerOk, "a stranger credited a controller on a vault with both lanes");
        (bool sponsoredOk,) = _requestDeposit(_actor(1), _actor(2), 2, 10 * ONE_ASSET);
        assertTrue(sponsoredOk, "an allowed sponsor could not credit a controller");
        _assertNoFailures();

        // An evicted-but-unsettled per-period position on an async-only vault still needs a fold once it settles
        flow_evictedNeedsFoldRequest(2, 3);
        assertGt(ok["flow_evictedNeedsFoldRequest"], 0, "unreachable: flow_evictedNeedsFoldRequest");
        _assertNoFailures();
        // flow_evictedNeedsFoldRequest warps past several windows; re-notify so later handlers see a fresh price
        oracle_refresh();

        // Eight windows fill the controller's slot and spill into the first overflow slot
        flow_manyWindows(0, 1, 16, false);
        assertGe(ghost_deepestHorizon, 7, "the horizon never reached its overflow slot");

        // A vault retired after its claims were earned still pays them while it keeps the role
        vault_requestDeposit(3, 3, 0, 100 * ONE_ASSET);
        hub_fulfill(0, 0, true);
        hub_setVaultLink(0, false);
        vault_claimMax(3, 0, true);
        hub_setVaultManager(0, false);
        vault_claimMax(3, 0, true);
        hub_setVaultManager(0, true);
        hub_setVaultLink(0, true);
        assertGt(ok["hub_setVaultLink"], 0, "unreachable: hub_setVaultLink");
        assertGt(ok["hub_setVaultManager"], 0, "unreachable: hub_setVaultManager");

        flow_routeExit(1, 5_000 * ONE_ASSET);
        flow_basinDrawAndRepay(1, ONE_ASSET);
        balanceSheet_deposit(0, false, 5_000 * ONE_ASSET);
        bsm_investInUnderlying(5_000 * ONE_ASSET);
        route_pushClaim(type(uint256).max);
        hub_setObserver(true);
        hub_setExtraGas(100_000);
        router_deposit(0, 1, 100 * ONE_ASSET);
        router_batch(3, 50 * ONE_ASSET);
        hub_setObserver(false);
        escrow_coverAndClaim(0, 0, false);
        hub_installPolicy();
        // Under the standard policy an in-policy fill still goes through
        uint256 filled = ok["hub_fulfill"];
        vault_requestDeposit(2, 2, 0, 100 * ONE_ASSET);
        hub_fulfill(0, 0, true);
        assertGt(ok["hub_fulfill"], filled, "a fill under the standard policy was refused");
        assertGt(ok["hub_installPolicy"], 0, "unreachable: hub_installPolicy");
        assertGt(ok["hub_lapseMember"], 0, "unreachable: hub_lapseMember");
        assertGt(ok["hub_setSponsors"], 0, "unreachable: hub_setSponsors");
        oracle_pauseDirect(0);
        oracle_pauseDirect(1);

        string[8] memory composed = [
            "flow_routeExit",
            "flow_basinDrawAndRepay",
            "route_pushClaim",
            "hub_setObserver",
            "oracle_pauseDirect",
            "router_deposit",
            "router_batch",
            "hub_setExtraGas"
        ];
        for (uint256 i; i < composed.length; i++) {
            assertGt(ok[bytes32(bytes(composed[i]))], 0, string.concat("unreachable: ", composed[i]));
        }
    }

    /// @dev The four vault paths no other handler reached, each driven once with its check: a duplicated route refused
    ///      by name, `flushRequest` on every request policy, a request paid from the subsidy, and a basin repayment
    ///      the route cannot book.
    function testTheVaultGapPathsExecute() public {
        route_setDuplicateRoute(0);
        route_setDuplicateRoute(1);
        route_setDuplicateRoute(2);
        assertEq(reverted["route_setDuplicateRoute"], 3, "unreachable: route_setDuplicateRoute");

        // Every vault kind has an open bucket: the non-batching ones flushed theirs as it opened, the windows did not
        for (uint256 v; v < 5; v++) {
            vault_requestDeposit(0, 0, v, 100 * ONE_ASSET);
        }
        for (uint256 v; v < 5; v++) {
            vault_flushAnyKind(v, 0);
        }
        assertEq(reverted["vault_flushAnyKind"], 5, "a flush of a fresh bucket went through");
        vm.warp(block.timestamp + 60 days);
        vault_flushAnyKind(1, 0);
        vault_flushAnyKind(4, 0);
        assertEq(ok["vault_flushAnyKind"], 2, "a closed window was not flushed");

        vm.expectCall(
            address(subsidyManager), abi.encodeCall(subsidyManager.withdrawAll, (poolE, address(vaultRouter)))
        );
        request_paidFromSubsidy(0, 100 * ONE_ASSET, 1e15, true);
        request_paidFromSubsidy(1, 100 * ONE_ASSET, 0, false);
        assertEq(ok["request_paidFromSubsidy"], 2, "unreachable: request_paidFromSubsidy");
        assertEq(address(refundEscrowFactory.get(poolE)).balance, 1e15, "the subsidy was not kept whole");

        vault_requestDeposit(0, 0, 0, 1_000 * ONE_ASSET);
        hub_fulfill(0, 0, true);
        vault_claimMax(0, 0, true);
        vault_instantDeposit(0, false, 2_000 * ONE_ASSET, false);
        vault_instantDeposit(1, true, 1_000 * ONE_ASSET, false);
        oracle_refresh();
        basin_repayUnbooked(0, ONE_ASSET);
        assertEq(ok["basin_repayUnbooked"], 1, "unreachable: basin_repayUnbooked");
        _assertNoFailures();
        property_basinDebtIsBooked();
    }

    /// @dev The adversary's pool is set up as the isolation handlers assume (its manager manages D alone, nobody
    ///      who acts on pool A holds a role on B or D, D holds real deposits), and every isolation handler runs
    ///      across every payload variant, victim and caller, refused every time and leaving every pool as it was.
    function testThePoolIsolationSetupIsAdversarial() public view {
        assertTrue(hubRegistry.manager(poolD, MALLORY), "D's manager is not a hub manager of D");
        assertTrue(spokeRegistry.manager(poolD, MALLORY), "D's manager is not a spoke manager of D");
        assertFalse(hubRegistry.manager(poolD, FM), "FM manages D");
        assertFalse(hubRegistry.manager(poolB, FM), "FM manages B");
        assertFalse(spokeRegistry.manager(poolB, BSM), "the BSM manages B");
        assertFalse(spokeRegistry.manager(poolD, BSM), "the BSM manages D");
        assertGt(usdc.balanceOf(address(_escrow(poolD))), 0, "pool D holds no assets");
        assertGt(shareD.totalSupply(), 0, "pool D has no shares");
        assertGt(holdings.value(poolD, scD, usdcId), 0, "pool D's holding is worth nothing");
    }

    function testFuzzThePoolIsolationManagerHandlersAreReachable(uint256 victim) public {
        for (uint256 variant; variant < 11; variant++) {
            isolation_dManagerCall(variant, victim);
            isolation_aManagerCall(variant, victim);
        }
        assertProperties();
    }

    function testThePoolIsolationManagerHandlersRefuse() public {
        isolation_dManagerCall(0, 0);
        isolation_aManagerCall(0, 0);
        assertGt(reverted[bytes32("isolation_dManagerCall")], 0, "never refused: isolation_dManagerCall");
        assertGt(reverted[bytes32("isolation_aManagerCall")], 0, "never refused: isolation_aManagerCall");
    }

    function testThePoolIsolationHubHandlersAreReachable() public {
        for (uint256 variant; variant < 17; variant++) {
            for (uint256 pool; pool < 4; pool++) {
                for (uint256 caller; caller < 3; caller++) {
                    isolation_hubCross(caller, pool, variant);
                }
            }
        }
        assertGt(reverted[bytes32("isolation_hubCross")], 0, "never refused: isolation_hubCross");
        assertProperties();
    }

    function testThePoolIsolationSettleHandlersAreReachable() public {
        for (uint256 side; side < 4; side++) {
            for (uint256 victim; victim < 5; victim++) {
                isolation_settleCross(side, victim, victim, ONE_ASSET, victim % 2 == 0);
            }
        }
        assertGt(reverted[bytes32("isolation_settleCross")], 0, "never refused: isolation_settleCross");
        assertProperties();
    }

    function testThePoolIsolationLinkHandlersAreReachable() public {
        for (uint256 mode; mode < 4; mode++) {
            for (uint256 victim; victim < 9; victim++) {
                isolation_linkCross(mode, victim);
            }
        }
        assertGt(reverted[bytes32("isolation_linkCross")], 0, "never refused: isolation_linkCross");
        assertProperties();
    }

    function testThePoolIsolationSpokeHandlersAreReachable() public {
        for (uint256 caller; caller < 12; caller++) {
            for (uint256 pool; pool < 4; pool++) {
                for (uint256 op; op < 15; op++) {
                    isolation_spokeCross(caller, pool, pool + 1, op, op + 1);
                    isolation_spokeCross(caller, pool, pool, op, op + 1);
                }
            }
        }

        assertGt(reverted[bytes32("isolation_spokeCross")], 0, "never refused: isolation_spokeCross");
        assertProperties();
    }

    /// @dev The refusals are the intended ones: a payload under pool D's id naming another pool's vault is
    ///      `WrongPool` at each singleton that keys by vault, and naming another pool's share class fails to
    ///      resolve in D.
    function testPoolDCannotConfigureAnotherPoolsVault() public {
        address victim = address(vaults[2]);
        bytes[3] memory payloads = [
            abi.encode(
                IReserveInstantPolicy.ConfigKind.Terms,
                victim,
                abi.encode(MALLORY, 9000, 9000, true, false, false, type(uint128).max)
            ),
            abi.encode(IVaultLiquidityRoute.ConfigKind.Consent, victim, abi.encode(address(vaultD), true)),
            abi.encode(victim, type(uint128).max)
        ];
        address[3] memory targets = [address(reserveInstantPolicy), address(vaultRoute), address(basinRoute)];
        bytes4[3] memory errors = [
            IReserveInstantPolicy.WrongPool.selector,
            IVaultLiquidityRoute.WrongPool.selector,
            IBasinLiquidityRoute.WrongPool.selector
        ];
        for (uint256 i; i < targets.length; i++) {
            vm.prank(MALLORY);
            vm.expectRevert(errors[i]);
            hub.managerCall(poolD, CENTRIFUGE_ID, bytes32(bytes20(targets[i])), payloads[i], 0, 0, REFUND);
        }
        // Naming pool A's share class in a hook call or a registrar call under D's id
        vm.prank(MALLORY);
        vm.expectRevert(IShareTokenRegistrar.NotRegistrar.selector);
        hub.managerCall(
            poolD,
            CENTRIFUGE_ID,
            bytes32(bytes20(address(shareTokenRegistrar))),
            abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.UpdateWard), scA, MALLORY, true),
            0,
            0,
            REFUND
        );
        // Pool A's manager is no manager of D
        vm.prank(FM);
        vm.expectRevert(IHub.NotManager.selector);
        hub.updateHubManager(poolD, FM, true);
    }

    /// @dev A shared redeem window's fills credit no more assets than their price allows.
    function testFuzzSharedRedeemWindowCreditsWithinItsPrice(uint256 amountSeed, uint256 fillSeed, uint256 price)
        public
    {
        for (uint256 i; i < 3; i++) {
            vault_requestDeposit(i, i, 0, 1_000 * ONE_ASSET);
        }
        hub_fulfill(0, 0, true);
        for (uint256 i; i < 3; i++) {
            vault_claimMax(i, 0, true);
        }
        hub_updateSharePrice(price, 2);
        flow_sharedWindow(amountSeed, fillSeed, false);
    }

    /// @dev The conservation handlers run their checks: a cycle with a part fill and a cancelled rest, one with
    ///      a price move between its fills, a deposit and a redemption, and a claim split in two.
    function testTheConservationHandlersAreReachable() public {
        flow_conserved(0, 0, 400 * ONE_ASSET, 3, true);
        flow_conserved(1, 0, 2 * ONE_SHARE, 1, false);
        flow_conserved(2, 1, 300 * ONE_ASSET, 4, true);
        flow_conservedAcrossPrice(0, 0, 400 * ONE_ASSET, 3, true, 2e18);
        flow_conservedAcrossPrice(1, 0, 2 * ONE_SHARE, 4, false, 7e17);
        assertEq(ok["flow_conserved"], 3, "unreachable: flow_conserved");
        assertEq(ok["flow_conservedAcrossPrice"], 2, "unreachable: flow_conservedAcrossPrice");

        // A price that divides nothing evenly, so the split claims round
        hub_updateSharePrice(1_370_000_000_000_000_007, 2);
        vault_requestDeposit(0, 0, 0, 900 * ONE_ASSET + 7);
        hub_fulfill(0, 0, true);
        vault_splitClaim(0, 0, 100 * ONE_ASSET + 3, 200 * ONE_ASSET + 1, 0);
        vault_splitClaim(0, 0, 3 * ONE_SHARE, 5 * ONE_SHARE, 2);
        assertEq(ok["vault_splitClaim"], 2, "unreachable: vault_splitClaim");
        assertProperties();
    }

    function testTheFlowsAreReachable() public {
        // The instant lane, before the other flows have filled its escrow to the policy's cap
        vault_instantRoundTrip(0, false, 100 * ONE_ASSET);

        // Per-request vault: deposit round trip, then redeem round trip
        vault_requestDeposit(0, 0, 0, 1_000 * ONE_ASSET);
        hub_fulfill(0, 0, true);
        // A claimant's previews are the claim, on both entries of each side
        vault_previewIsTheClaim(0, 0, 100 * ONE_ASSET, 0);
        vault_previewIsTheClaim(0, 0, 100 * ONE_SHARE, 2);
        vault_operatorClaim(0, 0, ONE_ASSET, true);
        vault_claimMax(0, 0, true);
        vault_requestRedeem(0, 0, 0, shareA.balanceOf(actors[0]) / 2);
        hub_fulfill(1, 0, true);
        vault_previewIsTheClaim(0, 0, 10 * ONE_ASSET, 1);
        vault_previewIsTheClaim(0, 0, 10 * ONE_SHARE, 3);
        vault_claimMax(0, 0, false);

        // Per-period vault: two contributors share a window, flushed after it closes, settled in two parts
        vault_requestDeposit(1, 1, 1, 500 * ONE_ASSET);
        vault_requestDeposit(2, 2, 1, 300 * ONE_ASSET);
        hub_warp(2 hours);
        vault_flush(2);
        hub_fulfill(2, 400 * ONE_ASSET, false);
        hub_fulfill(2, 0, true);
        vault_claimDeposit(1, 1, type(uint256).max, true);
        vault_claimDeposit(2, 1, type(uint256).max, false);

        // Instant lanes, the second drawing on the basin once its escrow is empty
        vault_instantDeposit(0, false, 2_000 * ONE_ASSET, false);
        vault_instantRedeem(0, false, ONE_SHARE, false);
        vault_instantDeposit(1, true, 1_000 * ONE_ASSET, false);
        balanceSheet_withdraw(0, false, uint128(spoke.availableBalanceOf(poolA, scA, address(usdc), 0)));
        vault_instantRedeem(1, true, ONE_ASSET, true);
        bsm_repayBasin(type(uint128).max);

        // The fund of funds: pool A's USDC into pool C, then an instant exit paid by the route
        balanceSheet_deposit(0, false, 5_000 * ONE_ASSET);
        bsm_investInUnderlying(5_000 * ONE_ASSET);
        balanceSheet_withdraw(0, false, uint128(spoke.availableBalanceOf(poolA, scA, address(usdc), 0)));
        vault_instantRedeem(0, false, ONE_ASSET, true);

        // A request, a transfer its recipient agreed to, then a cancel by the manager
        vault_requestDeposit(2, 2, 0, 700 * ONE_ASSET);
        vault_transferRequest(reqs.length - 1, 2, 0);
        hub_cancel(reqs.length - 1, 0, true);

        // Two requests, then folding the one a claim does not
        vault_requestDeposit(2, 2, 0, 10 * ONE_ASSET);
        vault_requestDeposit(2, 2, 0, 10 * ONE_ASSET);
        vault_foldRequest(reqs.length - 1);

        // Manager and keeper operations
        hub_setFee(100, false);
        hub_updateSharePrice(2e18, 2);
        hub_updateHoldingValue(9e17, 2);
        hub_updateJournal(0, 1, ONE_SHARE, ONE_SHARE, 2);
        balanceSheet_reserve(0, ONE_ASSET, false);
        balanceSheet_unreserve(0, 5e5);
        balanceSheet_withdrawReserved(0, 5e5);
        balanceSheet_noteDeposit(0, ONE_ASSET, 2);
        balanceSheet_issue(0, ONE_SHARE, true, 2);
        balanceSheet_withdrawShares(0, ONE_SHARE);
        balanceSheet_revoke(0, ONE_SHARE);
        balanceSheet_submitQueuedAssets(0, false);
        balanceSheet_submitQueuedAssets(0, true);
        balanceSheet_submitQueuedShares(0);
        hub_updateSpokeManager(true);
        balanceSheet_deposit(6, false, 0);
        hub_updateSpokeManager(false);

        // Restrictions
        token_transfer(0, 1, 1e15);
        hub_freeze(1);
        token_transfer(1, 0, 1);
        hub_unfreeze();
        hub_updateMember(0, true);
        token_transfer(0, 5, 1);

        // Whole lifecycles, a shared per-period window folded per contributor, and a cancelled request's refund
        flow_deposit(0, 0, 1_000 * ONE_ASSET, 1);
        flow_redeem(0, 0, ONE_SHARE, 1);
        flow_cancel(1, 0, 500 * ONE_ASSET, 1, true);
        flow_sharedWindow(7, 2, true);

        // The oracle: a pause round trip, the instant lane refusing a paused price, staleness and skew
        oracle_pauseRoundTrip(0, 100 * ONE_ASSET, 1);
        oracle_setPaused(0);
        vault_instantDeposit(0, false, ONE_ASSET, false);
        oracle_setPaused(1);
        oracle_skew(13 hours, true);
        oracle_stale(1);
        oracle_refresh();

        // The instant policy and the routes: re-terming a lane, gating it, and the underlying's consent
        policy_configure(0, 25, 1, 5, false);
        policy_allow(0, 0, true, true);
        poolC_updateSharePrice(2e18, 2);
        poolC_configure(25, 1, 5, false);
        poolC_updateSharePrice(1e18, 2);
        route_consent(false);
        route_consent(true);
        route_setRoutes(false);
        route_setRoutes(true);

        // Standards: conversions and request ids, strangers and operators, and a call at each reported maximum
        vault_conversionsIgnoreTheCaller(0, 0, ONE_ASSET);
        vault_requestIdsAreTheirs(0, 0, 5);
        vault_requestRedeemBeyondBalance(0, 0, 1);
        vault_strangerCannotClaimFor(0, 0, ONE_ASSET, 0);
        vault_strangerCannotRequestFor(0, 0, ONE_ASSET, 0);
        vault_setOperator(0, 0, address(0x777), true);
        vault_instantDeposit(0, false, 50 * ONE_ASSET, false);
        vault_maxIgnoresBalance(0, 1, false);
        vault_maxExecutes(0, false, 0);
        vault_maxExecutes(0, false, 2);
        vault_maxExecutes(0, false, 1);
        vault_maxExecutes(0, false, 3);

        bytes32[58] memory actions = [
            bytes32("vault_requestDeposit"),
            "vault_requestRedeem",
            "vault_claimMaxDeposit",
            "vault_claimMaxRedeem",
            "vault_claimDeposit",
            "vault_flush",
            "vault_instantDeposit",
            "vault_instantRedeem",
            "vault_transferRequest",
            "vault_foldRequest",
            "hub_fulfill",
            "hub_cancel",
            "hub_warp",
            "hub_setFee",
            "hub_updateSharePrice",
            "hub_updateHoldingValue",
            "hub_updateJournal",
            "hub_freeze",
            "hub_unfreeze",
            "hub_updateMember",
            "hub_updateSpokeManager",
            "balanceSheet_deposit",
            "balanceSheet_withdraw",
            "balanceSheet_reserve",
            "balanceSheet_unreserve",
            "balanceSheet_withdrawReserved",
            "balanceSheet_issue",
            "balanceSheet_submitQueuedShares",
            "bsm_investInUnderlying",
            "token_transfer",
            "flow_deposit",
            "flow_redeem",
            "flow_cancel",
            "flow_sharedWindow",
            "vault_fold",
            "oracle_setPaused",
            "oracle_stale",
            "oracle_skew",
            "oracle_refresh",
            "oracle_pauseRoundTrip",
            "instant_refusedOnInvalidPrice",
            "vault_instantRoundTrip",
            "vault_previewIsTheClaim",
            "policy_configure",
            "poolC_updateSharePrice",
            "poolC_configure",
            "policy_allow",
            "route_consent",
            "route_setRoutes",
            "vault_conversionsIgnoreTheCaller",
            "vault_maxExecutes",
            "vault_maxIgnoresBalance",
            "vault_requestIdsAreTheirs",
            "vault_requestRedeemBeyondBalance",
            "vault_strangerCannotClaimFor",
            "vault_strangerCannotRequestFor",
            "vault_setOperator",
            "vault_operatorClaim"
        ];
        for (uint256 i; i < actions.length; i++) {
            assertGt(ok[actions[i]], 0, string(abi.encodePacked("unreachable: ", actions[i])));
        }
        assertEq(reverted["hub_fulfill"], 0, "a scripted fulfillment reverted");
        assertGt(ok["async_onInvalidPrice"], 0, "no async cycle ran on a paused oracle");
        assertGt(reverted["token_transfer"], 0, "the frozen sender's transfer went through");
        assertGt(basinRoute.receivable(address(vaults[3])) + usdc.balanceOf(LP), 0, "the basin was never drawn");

        assertProperties();
    }

    /// @dev The Recon campaign's falsification of `vault_maxExecutes`, replayed as Echidna ran it.
    function testReconMaxExecutesExactRepro() public {
        vm.stopPrank();
        vm.prank(address(0x20000));
        balanceSheet_reserve(258942393969780000000000000, 235849838, false);
        vm.roll(block.number + 112);
        vm.warp(block.timestamp + 2842);
        vm.stopPrank();
        vm.prank(address(0x30000));
        vault_maxExecutes(124318505322767, false, 36);
        vm.roll(block.number + 126);
        vm.warp(block.timestamp + 2383);
        vm.stopPrank();
        property_vaultIdentityAndInterfaces();
        vm.roll(block.number + 5);
        vm.warp(block.timestamp + 2289);
        vm.stopPrank();
        vm.prank(address(0x20000));
        hub_warp(53227813207275591951785990540870154863466292007352974381066120761659928340670);
        vm.roll(block.number + 36);
        vm.warp(block.timestamp + 159);
        vm.stopPrank();
        vm.prank(address(0x20000));
        flow_deposit(
            91634933183716991573029750243642538209187019841245316906802074661744006772642,
            299200028134,
            30375859873484129265947808822238521368542309045957733745340991269666743595093,
            5325227639644303126311028339915567727308683148160591741311770362826165840537
        );
        vm.roll(block.number + 153);
        vm.warp(block.timestamp + 1168);
        vm.stopPrank();
        property_conversionsAreConsistent();
        vm.roll(block.number + 210);
        vm.warp(block.timestamp + 1138);
        vm.stopPrank();
        property_shareTokenSupplyConsistency();
        vm.roll(block.number + 165);
        vm.warp(block.timestamp + 1052);
        vm.stopPrank();
        vm.prank(address(0x20000));
        flow_sharedWindow(
            113014966499399420413843710417744144770750179498775290702142242398399937257108,
            27308519948205086893095489268259456417235607373669539739413467032437663442452,
            true
        );
        vm.roll(block.number + 279);
        vm.warp(block.timestamp + 1396);
        vm.stopPrank();
        vm.prank(address(0x30000));
        vault_fold(
            81908738107439281445473807725829369737297251472404201916334722240555839906895,
            43733175019322275285651502981797972840709482727836881839035898911216292055328
        );
        vm.roll(block.number + 163);
        vm.warp(block.timestamp + 1500);
        vm.stopPrank();
        vm.prank(address(0x20000));
        vault_maxIgnoresBalance(
            69638086982382994895225474944781075865483552785481074989726459095840825077725, 419323910203505, false
        );
        vm.roll(block.number + 212);
        vm.warp(block.timestamp + 3536);
        vm.stopPrank();
        vm.prank(address(0x20000));
        hub_updateSpokeManager(true);
        vm.roll(block.number + 38);
        vm.warp(block.timestamp + 2426);
        vm.stopPrank();
        property_deficitCountMatchesHoldings();
        vm.roll(block.number + 88);
        vm.warp(block.timestamp + 1813);
        vm.stopPrank();
        vm.prank(address(0x10000));
        vault_foldRequest(35215599424603468607094429137905989083964909169049263021921051620222791951965);
        vm.roll(block.number + 36);
        vm.warp(block.timestamp + 1891);
        vm.stopPrank();
        property_previewsRoundAgainstTheCaller();
        vm.roll(block.number + 109);
        vm.warp(block.timestamp + 512);
        vm.stopPrank();
        vm.prank(address(0x30000));
        bsm_repayBasin(100569587980470446177478694592810266780);
        vm.roll(block.number + 38);
        vm.warp(block.timestamp + 1168);
        vm.stopPrank();
        vm.prank(address(0x10000));
        vault_strangerCannotRequestFor(
            1263127299608586163731878,
            37575403080858915442534453689635630507843401062675157286743763613517050448944,
            205304908854788,
            2
        );
        vm.roll(block.number + 126);
        vm.warp(block.timestamp + 1052);
        vm.stopPrank();
        vm.prank(address(0x20000));
        flow_deposit(
            55094072223362614455684345450023183208332520247384708726869394328606872015428,
            79637245123340875543449744741233127931092805388462545592420613698380248671997,
            38168516663637751981941985380479210595642771126357196909608214478153645860366,
            59590813935111748731983007596752251030958101427423983857174061939984998358254
        );
        vm.roll(block.number + 182);
        vm.warp(block.timestamp + 1450);
        vm.stopPrank();
        vm.prank(address(0x10000));
        hub_updateHoldingValue(1019372305616755919669139300295473986423885, 2);
        vm.roll(block.number + 203);
        vm.warp(block.timestamp + 3351);
        vm.stopPrank();
        vm.prank(address(0x30000));
        balanceSheet_withdraw(72091643633, false, 237936614275520999899584791520076240355);
        vm.roll(block.number + 131);
        vm.warp(block.timestamp + 2529);
        vm.stopPrank();
        vm.prank(address(0x20000));
        hub_updateSpokeManager(true);
        vm.roll(block.number + 138);
        vm.warp(block.timestamp + 2891);
        vm.stopPrank();
        property_pendingTotalsMatchTheRequests();
        vm.roll(block.number + 274);
        vm.warp(block.timestamp + 2891);
        vm.stopPrank();
        vm.prank(address(0x30000));
        vault_requestRedeemBeyondBalance(
            625758989716141000000000000,
            14038376210371279761448040818312969625235372310831834891490161178031515695843,
            51275737000726623133453055937416881520391397132207093134072055341878465916312
        );
        vm.roll(block.number + 81);
        vm.warp(block.timestamp + 2383);
        vm.stopPrank();
        property_pendingDepositsStayReservedPerRequest();
        vm.roll(block.number + 3);
        vm.warp(block.timestamp + 4);
        vm.stopPrank();
        vm.prank(address(0x10000));
        vault_claimMax(98132143623149198325774103338616711457975317289123533327515439505098456170498, 794, true);
        vm.roll(block.number + 193);
        vm.warp(block.timestamp + 1793);
        vm.stopPrank();
        vm.prank(address(0x10000));
        vault_transferRequest(
            115792089237316195423570985008687907853269984665640564039457584007913129639932,
            56598286824150610452077452337497537535826418516774452896527656056554070259973,
            95979677782756846632785402214872918559008662804712961715059156023725045978311
        );
        vm.roll(block.number + 279);
        vm.warp(block.timestamp + 140);
        vm.stopPrank();
        vm.prank(address(0x20000));
        vault_fold(
            17806052987756796666094838267326571187075378622913877780746336212787343064128,
            52222068614216926550561841483443118457856342321016801340647814655784438121199
        );
        vm.roll(block.number + 150);
        vm.warp(block.timestamp + 452);
        vm.stopPrank();
        vm.prank(address(0x10000));
        policy_configure(
            10353790403705291836149074040791083030710082012029997929236894104538142594352,
            288,
            115792089237316195423570985008687907853269984665640564039457584007913129639933,
            910,
            false
        );
        vm.roll(block.number + 231);
        vm.warp(block.timestamp + 363);
        vm.stopPrank();
        property_sum_of_possible_account_balances_leq_escrow();
        vm.roll(block.number + 132);
        vm.warp(block.timestamp + 2590);
        vm.stopPrank();
        vm.prank(address(0x30000));
        hub_unfreeze();
        vm.roll(block.number + 273);
        vm.warp(block.timestamp + 668);
        vm.stopPrank();
        vm.prank(address(0x10000));
        vault_strangerCannotClaimFor(
            62584996491393600926425246721230857343877402223745023268679104476198479553248,
            781979785870,
            175866337843919,
            255
        );
        vm.roll(block.number + 260);
        vm.warp(block.timestamp + 1661);
        vm.stopPrank();
        vm.prank(address(0x20000));
        vault_requestIdsAreTheirs(
            17074184871337243073191727760620471070603801721467512878148940200505309513643,
            115792089237316195423570985008687907853269984665640564039457584007913129639931,
            41
        );
        vm.roll(block.number + 66);
        vm.warp(block.timestamp + 415);
        vm.stopPrank();
        _checkDeltas();
        vm.roll(block.number + 170);
        vm.warp(block.timestamp + 329);
        vm.stopPrank();
        property_actor_pending_and_queued_deposits();
        vm.roll(block.number + 259);
        vm.warp(block.timestamp + 2359);
        vm.stopPrank();
        vm.prank(address(0x30000));
        basin_advertise(1202306771732882561);
        vm.roll(block.number + 127);
        vm.warp(block.timestamp + 2887);
        vm.stopPrank();
        vm.prank(address(0x20000));
        balanceSheet_revoke(
            3189361440096483645441690323842791612548652309190453466847538379970104101217,
            28994387792344984440181534854529361274
        );
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 1945);
        vm.stopPrank();
        property_deficitCountMatchesHoldings();
        vm.roll(block.number + 87);
        vm.warp(block.timestamp + 1791);
        vm.stopPrank();
        vm.prank(address(0x30000));
        vault_claimRedeem(
            398458949275705963278692519,
            111776582316222049790364420957246304615351263205544638596877022886670256588202,
            55135060223848823021623033079406042846287105658972123780472534066056404842700,
            true
        );
        vm.roll(block.number + 30);
        vm.warp(block.timestamp + 724);
        vm.stopPrank();
        vm.prank(address(0x10000));
        hub_updateHoldingValue(154977471332154, 2);
        vm.roll(block.number + 96);
        vm.warp(block.timestamp + 505);
        vm.stopPrank();
        property_accounting_and_holdings_soundness();
        vm.roll(block.number + 124);
        vm.warp(block.timestamp + 1634);
        vm.stopPrank();
        vm.prank(address(0x20000));
        oracle_stale(99085201243601190509346463520507157094043248013946256417037134051130800267472);
        vm.roll(block.number + 247);
        vm.warp(block.timestamp + 2515);
        vm.stopPrank();
        vm.prank(address(0x20000));
        balanceSheet_withdraw(1924264810921548956032354485, false, 251628961839411663932213939554431635985);
        vm.roll(block.number + 169);
        vm.warp(block.timestamp + 2009);
        vm.stopPrank();
        property_assetQueueCounterConsistency();
        vm.roll(block.number + 169);
        vm.warp(block.timestamp + 2201);
        vm.stopPrank();
        property_invalidPriceClosesInstantLane();
        vm.roll(block.number + 241);
        vm.warp(block.timestamp + 431);
        vm.stopPrank();
        vm.prank(address(0x30000));
        policy_configure(614094439305, 41454, 736990840235, 47465094964178280181874193, false);
        vm.roll(block.number + 164);
        vm.warp(block.timestamp + 1671);
        vm.stopPrank();
        property_oracleVerdict();
        vm.roll(block.number + 139);
        vm.warp(block.timestamp + 3339);
        vm.stopPrank();
        vm.prank(address(0x30000));
        vault_requestIdsAreTheirs(23408223021125, 274, 632812408690076);
        vm.roll(block.number + 23);
        vm.warp(block.timestamp + 2520);
        vm.stopPrank();
        property_assetCounterBounds();
        vm.roll(block.number + 188);
        vm.warp(block.timestamp + 748);
        vm.stopPrank();
        property_accounting_and_holdings_soundness();
        vm.roll(block.number + 109);
        vm.warp(block.timestamp + 2763);
        vm.stopPrank();
        vm.prank(address(0x20000));
        balanceSheet_revoke(54219431085863228837252809, 146806272648101539349655758662177835402);
        vm.roll(block.number + 190);
        vm.warp(block.timestamp + 2942);
        vm.stopPrank();
        vm.prank(address(0x30000));
        vault_claimMax(
            4786352967996376341395101266342996508938700949554756146719582148833308301077,
            87499501823259985834453190934556754115550527267990580910618106042154068700664,
            true
        );
        vm.roll(block.number + 257);
        vm.warp(block.timestamp + 1638);
        vm.stopPrank();
        vm.prank(address(0x10000));
        doomsday_accountValue(3436381219);
        vm.roll(block.number + 32);
        vm.warp(block.timestamp + 2653);
        vm.stopPrank();
        vm.prank(address(0x30000));
        vault_operatorClaim(
            1704870444119, 483, 24608820453567068844507598187850034364450333818943128373808112084559027469258, true
        );
        vm.roll(block.number + 71);
        vm.warp(block.timestamp + 50);
        vm.stopPrank();
        property_cancelled_and_processed_redemptions_soundness();
        vm.roll(block.number + 35);
        vm.warp(block.timestamp + 2269);
        vm.stopPrank();
        property_accounting_books_balance();
        vm.roll(block.number + 253);
        vm.warp(block.timestamp + 234);
        vm.stopPrank();
        vm.prank(address(0x30000));
        oracle_refresh();
        vm.roll(block.number + 64);
        vm.warp(block.timestamp + 832);
        vm.stopPrank();
        vm.prank(address(0x10000));
        vault_maxExecutes(372, false, 157);
        vm.roll(block.number + 233);
        vm.warp(block.timestamp + 2738);
        vm.stopPrank();
        vm.prank(address(0x30000));
        balanceSheet_submitQueuedShares(4883467858668000000000000);
        vm.roll(block.number + 121);
        vm.warp(block.timestamp + 2589);
        vm.stopPrank();
        vm.prank(address(0x10000));
        vault_maxExecutes(372, false, 157);
        _assertNoFailures();
    }

    /// @dev A second report of the same refusal: a holder of shares worth just over one asset unit, reached by a transfer.
    function testMaxRedeemOfAHolderJustOverOneUnitRepro() public {
        hub_updateSharePrice(1371682344634180582338797432305037402217451939544, 2);
        flow_deposit(0, 3004613592477140927522004, 575840436212104754941133, 1);
        token_transferFrom(0, 14378727541271630598466808157300617925712228080332598358409261, 252030310830);
        vault_maxExecutes(601993569108152222296098727305678710299, false, 1);
        _assertNoFailures();
    }

    /// @dev The Recon fuzzer's falsification of `vault_overMaxRefused`: the holder's whole balance is worth `maxWithdraw`, so the share past a rounded-down `maxRedeem` pays no more than the capacity and is served.
    function testReconRedeemOnePastRoundedMaxRepro() public {
        hub_updateSharePrice(0x0087efdce51c9e5085303aae203c459d014bcf859a, 0x1);
        hub_updateHoldingValue(0x0, 0x1);
        router_deposit(
            0x9bbfd2954929be9daedfcbe196e7146e9bebdcffbe2833c7156f,
            0x4773269c34cbad0510ff44d1,
            0x17c6d08f1102efc2e16069c43727c1a4c692008dec04336972f68a33
        );
        vault_overMaxRefused(0x0, true, 0x1);
        _assertNoFailures();
    }

    /// @dev The first reproducer's controller, lapsed with a refund: claiming exactly what `maxMint` offers goes
    ///      through, and every property still holds after it.
    function testALapsedControllerClaimsWhatMaxOffers() public {
        oracle_pauseRoundTrip(0x62300f14712a800572ee067ee3cc17681d12, 0x0, 0x11d5160);
        vault_requestRedeem(0x0, 0x6c9de7aa31ca482443789d745cdbdb8b6dea, 0x0, 0x3156aaedde3fb600fd9c423db19966fb18e);
        hub_lapseMember(0x7f1d6513e0a293aad1a, 0x220b388d559fd019b0cef894248d3834c955d66974c2a76e58447a353f4, false);
        hub_cancel(0x2778ae0ab207c7d99609b7d5aa830bd, 0x00278b6daaecf009032523ffa336aa4991eebdfcf0, false);
        vm.warp(block.timestamp + 40);
        vm.roll(block.number + 0);
        property_maxMatchesClaimable();
        vault_lapsedClaimsWhatMaxOffers(0, 0, true);
        _assertNoFailures();
        assertProperties();
        assertTrue(ok["vault_lapsedClaimsWhatMaxOffers"] != 0, "the claim never ran");
    }

    /// @dev The Recon fuzzer's falsification of `property_maxMatchesClaimable`: a lapsed controller with a fill and a refund has `maxMint` of the refund alone.
    function testReconLapsedControllerRefundOnlyMaxRepro() public {
        oracle_pauseRoundTrip(0x62300f14712a800572ee067ee3cc17681d12, 0x0, 0x11d5160);
        vault_requestRedeem(0x0, 0x6c9de7aa31ca482443789d745cdbdb8b6dea, 0x0, 0x3156aaedde3fb600fd9c423db19966fb18e);
        hub_lapseMember(0x7f1d6513e0a293aad1a, 0x220b388d559fd019b0cef894248d3834c955d66974c2a76e58447a353f4, false);
        hub_cancel(0x2778ae0ab207c7d99609b7d5aa830bd, 0x00278b6daaecf009032523ffa336aa4991eebdfcf0, false);
        vm.warp(block.timestamp + 40);
        vm.roll(block.number + 0);
        property_maxMatchesClaimable();
        _assertNoFailures();
    }

    /// @dev The same property, a second sequence (flows over several windows, then a lapse).
    function testReconLapsedControllerRefundOnlyMaxRepro2() public {
        flow_conserved(
            0x3a7ceac,
            0xf7095bc6d95be1338c12a6f4047b7af703fefc75c1278985b78ebd9535,
            0x163c38e1ed277c022b9ae9,
            0x1336d2ec88987d3f4051fe23fd96ca0c0e7b8a947674cc64c4659d66b62db7b,
            true
        );
        flow_manyRequestsAcrossPrice(
            0x5814a9712cd229378a338ead44f5ad66f1c3d9f738557fdaf801a5d2daba,
            0x4d60cdc8cf17d5dd9c8faace269c1252f5fea6d4becb3df5d7978a87c67f,
            0x317e4660fb1d6f9dab2db6f5d3fb0a0edaa03983028b54d255143c8567b05,
            0xa0500a9f51ebb12249e195bdf3dddf672d2be8894382d6aca4b24704e16f43e,
            0xb,
            false
        );
        flow_manyWindows(0x73acc5a, 0x3a95f719f8e57181a08, 0x0, false);
        hub_lapseMember(0x26f, 0x7a9396c34572, false);
        vm.warp(block.timestamp + 34);
        vm.roll(block.number + 0);
        property_maxMatchesClaimable();
        _assertNoFailures();
    }

    /// @dev The Recon campaign's falsification of `vault_maxExecutes` (a reserve, then two calls at the maximum).
    function testReconMaxExecutesRepro() public {
        vm.prank(address(0x20000));
        balanceSheet_reserve(258942393969780000000000000, 235849838, false);
        vm.warp(block.timestamp + 2842);
        vm.prank(address(0x30000));
        vault_maxExecutes(124318505322767, false, 36);
        flow_deposit(
            91634933183716991573029750243642538209187019841245316906802074661744006772642,
            299200028134,
            30375859873484129265947808822238521368542309045957733745340991269666743595093,
            5325227639644303126311028339915567727308683148160591741311770362826165840537
        );
        vm.prank(address(0x10000));
        vault_maxExecutes(372, false, 157);
        vm.prank(address(0x10000));
        vault_maxExecutes(372, false, 157);
        _assertNoFailures();
    }

    /// @dev Shrunk from a campaign: a manager reserving past the escrow's total left the unreserved balance at zero,
    ///      so the assets the route drew in were absorbed by the reservation and a redemption at the reported
    ///      `maxRedeem` reverted. The route's capacity is now net of what is reserved beyond the escrow's total.
    function testAnOverReservedEscrowDoesNotInflateTheRedeemCapacity() public {
        vault_instantDeposit(4703, true, 9511, true);
        balanceSheet_reserve(
            99619417961298436939701859982508842782828409837832440998906649824, 72456620126172978159064395205722099, true
        );
        bsm_investInUnderlying(2000000000000000000);
        flow_redeem(
            277088728648308726869139136685355740273844194605944831128014121,
            11944383139411181530417946648812307575,
            37822716648314727911212633676200850579368283569530863446566101,
            86923278048382
        );
        vault_maxExecutes(13680, false, 37);
        _assertNoFailures();
    }

    /// @dev A manager reserving past the escrow's total holds back a fulfilled redemption's claim, since
    ///      `withdrawReserved` pays only out of the unreserved balance. Shrunk from a campaign; it is why
    ///      `vault_claimMax` asserts liveness only outside over-reservation.
    function testOverReservationHoldsBackRedeemClaims() public {
        vault_requestDeposit(0, 0, 0, 1_000 * ONE_ASSET);
        hub_fulfill(0, 0, true);
        vault_claimMax(0, 0, true);
        vault_requestRedeem(0, 0, 0, shareA.balanceOf(actors[0]) / 2);
        hub_fulfill(1, 0, true);

        balanceSheet_reserve(0, 0, true);
        assertTrue(_overReserved(), "not over-reserved");
        vault_claimMax(0, 0, false);
        assertEq(ok["vault_claimMaxRedeem"], 0, "the claim went through");
        assertEq(reverted["vault_claimMaxRedeem"], 1, "the claim was not attempted");

        balanceSheet_unreserve(0, type(uint128).max);
        vault_claimMax(0, 0, false);
        assertEq(ok["vault_claimMaxRedeem"], 1, "unreserving did not release the claim");
        assertProperties();
    }

    /// @dev Two contributors redeem into one per-period window and a partial fill folds each slice down:
    ///      their pending views then exceed the bucket by a unit, which must not read as a share claim.
    function testSharedRedeemWindowPendingDustIsNotAClaim() public {
        // Amounts of a 6-decimal asset and an 18-decimal share, rescaled to the suite's units
        vault_instantDeposit(0, false, 1_191_204_075 * ONE_ASSET / 1e6, false);
        vault_instantDeposit(1, false, 18_283 * ONE_ASSET, false);
        vault_requestRedeem(0, 0, 1, 37_725_275_122_348_202_705 * ONE_SHARE / 1e18);
        vault_requestRedeem(1, 1, 1, 11_002 * ONE_SHARE / 1e18 + 1);
        hub_warp(2 hours);
        vault_flush(0);
        hub_fulfill(0, 764, false);
        assertEq(ok["vault_requestRedeem"], 2, "both redemptions joined the window");
        assertEq(ok["hub_fulfill"], 1, "the window was part-filled");
        assertProperties();
    }

    //----------------------------------------------------------------------------------------------
    // Assertions
    //----------------------------------------------------------------------------------------------

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

    //----------------------------------------------------------------------------------------------
    // Access control
    //----------------------------------------------------------------------------------------------

    function testStrangerTableMatchesItsCount() public view {
        assertTrue(_entry(ENTRIES - 1, OUTSIDER, 0).target != address(0), "ENTRIES is past the table");
        assertTrue(_entry(ENTRIES, OUTSIDER, 0).target == address(0), "ENTRIES is short of the table");
    }

    /// @dev Every entry point refuses every candidate that lacks its role, with the entry's own error. The
    ///      tester is warded almost everywhere, so this is what shows the refusal comes from the role check and
    ///      not from a bad argument. Split in ranges to keep the memory of the entries it builds bounded.
    function testEveryEntryRefusesTheWrongRole0() public {
        _refuseWrongRole(0, 36);
    }

    function testEveryEntryRefusesTheWrongRole1() public {
        _refuseWrongRole(36, 72);
    }

    function testEveryEntryRefusesTheWrongRole2() public {
        _refuseWrongRole(72, 108);
    }

    function testEveryEntryRefusesTheWrongRole3() public {
        _refuseWrongRole(108, 144);
    }

    function testEveryEntryRefusesTheWrongRole4() public {
        _refuseWrongRole(144, 180);
    }

    function testEveryEntryRefusesTheWrongRole5() public {
        _refuseWrongRole(180, ENTRIES);
    }

    function _refuseWrongRole(uint256 from, uint256 to) internal {
        _prepareStrangers();
        address[] memory candidates = _candidates();
        uint256 refused;
        for (uint256 i = from; i < to; i++) {
            for (uint256 salt; salt < 3; salt++) {
                for (uint256 k; k < candidates.length; k++) {
                    Entry memory e = _entry(i, candidates[k], salt);
                    if (_authorized(e, candidates[k])) continue;
                    vm.prank(candidates[k]);
                    (bool success, bytes memory ret) = e.target.call(e.data);
                    assertFalse(success, e.name);
                    if (e.err != bytes4(0)) assertEq(bytes4(ret), e.err, e.name);
                    refused++;
                }
            }
        }
        assertGt(refused, (to - from) * 50, "too few refusals");
    }

    /// @dev The same calls made by a holder of the role do not hit the role check: they either go through or
    ///      are refused for a state reason, never with the entry's error. Logs the entries a role holder cannot
    ///      run in the initial state, which are the ones whose arguments the refusal test does not vouch for.
    function testEveryEntryRunsForItsRole0() public {
        _runForRole(0, 36);
    }

    function testEveryEntryRunsForItsRole1() public {
        _runForRole(36, 72);
    }

    function testEveryEntryRunsForItsRole2() public {
        _runForRole(72, 108);
    }

    function testEveryEntryRunsForItsRole3() public {
        _runForRole(108, 144);
    }

    function testEveryEntryRunsForItsRole4() public {
        _runForRole(144, 180);
    }

    function testEveryEntryRunsForItsRole5() public {
        _runForRole(180, ENTRIES);
    }

    function _runForRole(uint256 from, uint256 to) internal {
        _prepareStrangers();
        for (uint256 i = from; i < to; i++) {
            Entry memory e = _entry(i, OUTSIDER, 0);
            address holder = _holder(e);
            if (holder == address(0)) continue;
            uint256 snapshot = vm.snapshotState();
            vm.deal(holder, 1 ether);
            vm.prank(holder);
            (bool success, bytes memory ret) = e.target.call(e.data);
            if (!success && e.err != bytes4(0)) {
                assertTrue(bytes4(ret) != e.err, string.concat("role holder refused: ", e.name));
            }
            vm.revertToState(snapshot);
        }
    }

    function _holder(Entry memory e) internal view returns (address) {
        if (e.mask & F != 0) return e.who;
        if (e.mask & S != 0) return BSM;
        if (e.mask & H != 0) return FM;
        if (e.mask & L != 0) return address(vaults[0]);
        if (e.mask & M != 0) return address(basinRoute);
        if (e.mask & P != 0) return FEEDER;
        if (e.mask & W != 0) {
            if (IAuth(e.target).wards(address(this)) == 1) return address(this);
            address[] memory candidates = _candidates();
            for (uint256 k; k < candidates.length; k++) {
                if (IAuth(e.target).wards(candidates[k]) == 1) return candidates[k];
            }
        }
        return address(0);
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    /// @dev Every handler once, then the lifecycle and claim handlers again: Foundry picks uniformly among
    ///      the listed selectors, so a repeat weights the pick. A claim needs a request, a settlement and
    ///      a claim by the same controller to line up, which a uniform pick over 48 handlers rarely does.
    /// @dev Under the hub policy a pause waits for its authorization to age. That wait must not sit between the views
    ///      the round trip compares: a membership lapsing within the hour moves them. Found by the Recon campaign.
    function testPauseRoundTripSurvivesAMembershipLapsingDuringTheWait() public {
        hub_installPolicy();
        hub_lapseMember(1, 30 minutes, false);
        oracle_pauseRoundTrip(1, 100 * ONE_ASSET, 0);
        assertEq(failures.length, 0);
    }

    /// @dev A supply valued past `uint128` makes `totalAssets` revert, which the suite expects rather than reports
    ///      (src/vaults/SPECIFICATION.md): `property_viewsNeverRevert` asserts the revert once the value is clearly out
    ///      of range and an answer while it is in range.
    function testTotalAssetsRevertsOnlyPastUint128() public {
        property_viewsNeverRevert();
        assertTrue(_supplyIsRepresentable(vaults[2]));
        balanceSheet_issue(0, 0, true, 0);
        _pushPrices(poolA, scA, d18(uint128(1e13) * 1e18));
        balanceSheet_issue(0, type(uint128).max, true, 0);
        assertFalse(_supplyIsRepresentable(vaults[2]));
        (bool answered,) = address(vaults[2]).staticcall(abi.encodeCall(vaults[2].totalAssets, ()));
        assertFalse(answered, "the supply is valued past uint128 and totalAssets answered");
        property_viewsNeverRevert();
        assertEq(failures.length, 0);
    }

    /// @dev A cycle on a shared-window vault waits for its window to close, so an investor's membership can lapse
    ///      between its opening check and its claim, which the share hook then refuses. The cycle skips its assertions
    ///      then instead of holding the claim to a payout that cannot happen. Found by the Recon campaign.
    function testAConservedCycleSkipsAClaimTheHookRefusesAfterAMembershipLapses() public {
        uint256 windowVault = 1;

        // A deposit cycle first, so that an investor holds shares to redeem; it must run
        flow_conserved(0, windowVault, 1000 * ONE_ASSET, 0, true);
        assertEq(ok[bytes32("flow_conserved")], 1, "the cycle ran");

        for (uint256 round; round < 3; round++) {
            for (uint256 a; a < 3; a++) {
                hub_lapseMember(a, 1, false);
            }
            if (round == 0) flow_conserved(0, windowVault, 1e9, 0, false);
            else if (round == 1) flow_conserved(0, windowVault, 1000 * ONE_ASSET, 0, true);
            else flow_conservedAcrossPrice(0, windowVault, 1e9, 0, false, 1e18);
        }
        assertEq(failures.length, 0);
    }

    /// @dev Random sequences of the handlers that change what a conserved cycle depends on (memberships, prices, fees,
    ///      time, freezes, the hub policy, other flows), then conserved cycles on every vault: a failed check anywhere in
    ///      a sequence fails the run. Found the lapsed-membership failure of the campaign in 42 runs without its guard.
    function _fuzzW(uint256 seed, uint256 j) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, j)));
    }

    function _fuzzStep(uint256 seed) internal {
        uint256 k = seed % 28;
        uint256 a = _fuzzW(seed, 1);
        uint256 b = _fuzzW(seed, 2);
        uint256 c = _fuzzW(seed, 3);
        uint256 d = _fuzzW(seed, 4);
        bytes memory data;
        if (k == 0 || k == 1) {
            data = abi.encodeWithSelector(this.hub_lapseMember.selector, a, b % 7200, c % 4 == 0);
        } else if (k == 2) {
            data = abi.encodeWithSelector(this.hub_updateSharePrice.selector, a, uint8(b));
        } else if (k == 3) {
            data = abi.encodeWithSelector(this.hub_updateHoldingValue.selector, a, uint8(b));
        } else if (k == 4) {
            data = abi.encodeWithSelector(this.hub_setFee.selector, uint16(a), b % 2 == 0);
        } else if (k == 5) {
            data = abi.encodeWithSelector(this.hub_warp.selector, a);
        } else if (k == 6) {
            data = abi.encodeWithSelector(this.hub_installPolicy.selector);
        } else if (k == 7) {
            data = abi.encodeWithSelector(this.hub_freeze.selector, a);
        } else if (k == 8) {
            data = abi.encodeWithSelector(this.hub_unfreeze.selector);
        } else if (k == 9) {
            data = abi.encodeWithSelector(this.flow_deposit.selector, a, b, c, d);
        } else if (k == 10) {
            data = abi.encodeWithSelector(this.flow_redeem.selector, a, b, c, d);
        } else if (k == 11) {
            data = abi.encodeWithSelector(this.oracle_refresh.selector);
        } else if (k == 12) {
            data = abi.encodeWithSelector(this.balanceSheet_noteDeposit.selector, a, uint128(b), uint8(c));
        } else if (k == 13) {
            data = abi.encodeWithSelector(this.hub_fulfill.selector, a, b, c % 2 == 0);
        } else if (k == 14 || k == 15 || k == 16) {
            data = abi.encodeWithSelector(this.flow_conserved.selector, a, b % 5, c, d, _fuzzW(seed, 5) % 2 == 0);
        } else if (k < 20) {
            data = abi.encodeWithSelector(
                this.flow_conservedAcrossPrice.selector, a, b % 5, c, d, _fuzzW(seed, 5) % 2 == 0, _fuzzW(seed, 6)
            );
        } else {
            data = abi.encodeWithSelector(this.vault_maxExecutes.selector, a, b % 2 == 0, uint8(c));
        }
        vm.roll(block.number + a % 300);
        vm.warp(block.timestamp + b % 3600);
        vm.prank(address(uint160(((c % 3) + 1) * 0x10000)));
        // A step the handlers refuse is fine: they record the failures that matter themselves
        (bool ok,) = address(this).call(data);
        ok;
    }

    function testFuzzConservedCyclesHold(uint256 seed) public {
        for (uint256 i; i < 45; i++) {
            seed = _fuzzW(seed, i);
            _fuzzStep(seed);
            if (failures.length != 0) break;
        }
        if (failures.length != 0) console.log("FAILURE", failures[0]);
        assertEq(failures.length, 0);
    }

    /// @dev A call at a reported maximum goes through at any price and fee the hub can set. The price modes reach
    ///      shares worth a billionth of par and a billion times par, and the fee the whole range the policy accepts.
    function testFuzzMaxExecutesAtExtremePrices(uint256 price, uint8 priceMode, uint16 fee, bool wide, uint256 seed)
        public
    {
        seed %= 2 ** 128;
        hub_updateSharePrice(price, priceMode);
        hub_setFee(fee, wide);
        for (uint256 kind; kind < 8; kind++) {
            vault_maxExecutes(seed, false, uint8(kind));
            vault_maxExecutes(seed, true, uint8(kind));
            vault_maxExecutes(seed ^ 1, false, uint8(kind));
            vault_maxExecutes(seed ^ 2, true, uint8(kind));
        }
        if (failures.length != 0) console.log("FAILURE", failures[0]);
        assertEq(failures.length, 0);
    }

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
        bytes4[20] memory gaps = [
            this.nav_updateAssets.selector,
            this.nav_updateShares.selector,
            this.vault_spenderRequestRedeem.selector,
            this.vault_misfiledRefusesRequests.selector,
            this.vault_rebatedTrade.selector,
            this.donate_andRecover.selector,
            this.route_hostileUnderlying.selector,
            this.bridge_transferShares.selector,
            this.hub_setShareTokenVault.selector,
            this.gas_worstCaseClaim.selector,
            this.atomic_refusedCallback.selector,
            this.atomic_refusedCallback.selector,
            this.route_setDuplicateRoute.selector,
            this.vault_flushAnyKind.selector,
            this.request_paidFromSubsidy.selector,
            this.basin_repayUnbooked.selector,
            this.vault_strangerCannotMoveRequest.selector,
            this.vault_unlinkedRefusesRequests.selector,
            this.flow_claimFoldsTheHorizon.selector,
            this.vault_lapsedClaimsWhatMaxOffers.selector
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

    /// @dev A price of almost zero let `_hugeAssets` credit `uint128.max / 4` assets, which come back as pool C shares
    ///      at par and carried pool A's asset account past `int128.max`.
    function testHugeCreditsAtAPriceOfAlmostZeroKeepTheAccountsInRange() public {
        hub_updateHoldingValue(179036, 0);
        poolC_configure(10341, 14243, 126032, true);
        balanceSheet_noteDeposit(117057001281611122780024, 1889208134028271757155087686233445, 0);
        bsm_investInUnderlying(2569499402149916165622077320);
        balanceSheet_submitQueuedAssets(226716, true);
        _assertNoFailures();
        assertProperties();
    }

    /// @dev A horizon of eight windows standing at rest, some folded and none claimed, is what the overflow slots hold
    ///      between calls; the claim then reads it whole.
    function testAHorizonAtRestIsClaimedInFull() public {
        address holder = _shareHolder(0);
        flow_manyWindows(0, 0x55, 16, true);
        assertGe(ghost_deepestHorizon, 7, "the horizon never reached its overflow slot");
        assertGt(ok["flow_manyWindows"], 0, "unreachable: flow_manyWindows");
        // A keeper folds what is left, each fold finding its window in the stored horizon
        for (uint256 w; w < lastWindowIds.length; w++) {
            if (lastWindowIds[w] == 0 || vaults[LONG_VAULT].contribution(lastWindowIds[w], holder).amount == 0) {
                continue;
            }
            _foldOne(LONG_VAULT, lastWindowIds[w], holder);
        }
        uint256 held = shareA.balanceOf(holder);
        assertTrue(_claimAll(vaults[LONG_VAULT], holder, 0), "a horizon at rest was not claimable");
        assertGt(shareA.balanceOf(holder), held, "no shares reached the holder");
        assertEq(reverted["vault_fold"], 0, "a fold missed its window in the stored horizon");
        _assertNoFailures();
        assertProperties();
    }

    /// @dev A pool C vault the route is told to draw on answers with a revert, a 300 kB payload or the largest number:
    ///      the views keep answering with the honest capacity and an exit the honest liquidity covers goes through.
    function testAHostileUnderlyingCannotBlockTheExit() public {
        vault_requestDeposit(3, 3, 2, 1_000 * ONE_ASSET);
        hub_fulfill(0, 0, true);
        vault_claimMax(3, 2, true);
        // Pool A holds pool C shares, so the route has something to draw on and reads every underlying it is told of
        balanceSheet_noteDeposit(1, 5_000 * ONE_ASSET, 1);
        bsm_investInUnderlying(2_000 * ONE_ASSET);
        assertGt(spoke.availableBalanceOf(poolA, scA, address(shareC), 0), 0, "pool A holds no pool C shares");
        for (uint8 m; m < 3; m++) {
            route_hostileUnderlying(3, 77 + m, m);
        }
        assertEq(ok["route_hostileUnderlying"], 3, "unreachable: route_hostileUnderlying");
        _assertNoFailures();
        assertProperties();
    }

    /// @dev Assets sent straight to each contract that can hold them are recovered whole, and the contract ends where
    ///      it began.
    function testAssetsSentToAContractAreRecoverable() public {
        for (uint256 i; i < 9; i++) {
            donate_andRecover(i, 123 * ONE_ASSET);
        }
        assertGt(ok["donate_andRecover"], 0, "unreachable: donate_andRecover");
        _assertNoFailures();
        assertProperties();
    }

    /// @dev The vault whose policy rebates every trade: a deposit and a redemption each balance to the unit, and the
    ///      rebate source paid something.
    function testARebatedTradeConservesAssets() public {
        uint256 sourceBefore = usdc.balanceOf(REBATER);
        vault_rebatedTrade(0, 1_000 * ONE_ASSET, 0);
        assertEq(ok["vault_rebatedTrade"], 1, "unreachable: a rebated deposit");
        assertLt(usdc.balanceOf(REBATER), sourceBefore, "no rebate was paid");
        vault_rebatedTrade(0, 500 ether, 1);
        assertEq(ok["vault_rebatedTrade"], 2, "unreachable: a rebated redemption");
        _assertNoFailures();
        assertProperties();
    }

    /// @dev A vault the registry files under another share class of its pool refuses requests.
    function testAMisfiledVaultRefusesRequests() public {
        vault_misfiledRefusesRequests(0, 1_000);
        assertEq(ok["vault_misfiledRefusesRequests"], 1, "unreachable: a misfiled vault's refusal");
        _assertNoFailures();
    }

    /// @dev A spender of the owner's allowance cannot request a redemption for the owner on a dual-lane vault.
    function testASpenderCannotCloseTheOwnersInstantLane() public {
        vault_spenderRequestRedeem(1, 0, 2, 10 ether);
        assertEq(ok["vault_spenderRequestRedeem"], 0, "a spender requested on a dual-lane vault");
        _assertNoFailures();
    }

    /// @dev The NAV pool reports through the hub handler, and its NAV, price and sums hold across networks, including a
    ///      network whose liability exceeds its assets.
    function testTheNavPoolSumsSignedNetworks() public {
        nav_updateAssets(0, 1_000, true, false);
        nav_updateShares(1, 1_000 ether, true, true);
        nav_updateAssets(3, 5_000 ether, true, false);
        nav_updateAssets(2, 100, true, false);
        nav_updateShares(0, 10 ether, true, true);
        // A network that reports again replaces its earlier report in the pool's sum
        nav_updateAssets(0, 500, true, true);
        assertEq(ok["nav_updateAssets"], 4, "unreachable: nav_updateAssets");
        assertEq(ok["nav_updateShares"], 2, "unreachable: nav_updateShares");
        (int128 globalNav,) = priceManager.metrics(poolN);
        assertLt(int256(navManager.netAssetValue(poolN, NAV_NET_A)), 0, "no network carried a negative NAV");
        assertTrue(globalNav != 0);
        _assertNoFailures();
        assertProperties();
    }

    function _logStats() internal view {
        console.log("action                           ok  reverted");
        for (uint256 i; i < actionNames.length; i++) {
            console.log(string(abi.encodePacked(actionNames[i])), ok[actionNames[i]], reverted[actionNames[i]]);
        }
    }
}
