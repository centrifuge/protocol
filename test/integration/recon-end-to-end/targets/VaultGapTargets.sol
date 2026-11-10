// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GapTargets} from "./GapTargets.sol";

import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {RequestId} from "../../../../src/core/types/RequestId.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";

import {VaultRequestIdLib} from "../../../../src/vaults/libraries/VaultRequestIdLib.sol";
import {IRequestPolicy} from "../../../../src/vaults/policies/interfaces/IVaultPlugins.sol";
import {IAsyncVault, IVaultErrors, Bucket} from "../../../../src/vaults/interfaces/IAsyncVault.sol";
import {IVaultLiquidityRoute} from "../../../../src/vaults/liquidity/interfaces/IVaultLiquidityRoute.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";

/// @notice Handlers for code paths the other targets never reach: a duplicated route, `flushRequest` on every kind
///         of request policy, a request paid from the pool's subsidy, and a basin repayment the route cannot book.
/// @dev    Each handler asserts the one thing that makes the path a test: the exact revert, the exact balance, or the
///         exact ledger. Every check is gated on the state under which it must hold.
abstract contract VaultGapTargets is GapTargets {
    using CastLib for *;
    using VaultRequestIdLib for address;

    //----------------------------------------------------------------------------------------------
    // Duplicate routes
    //----------------------------------------------------------------------------------------------

    /// @dev The top pool routes to the same underlying vault more than once. Consent is given (the config is otherwise
    ///      sound), so the duplicate check is the one that refuses it, with `DuplicateRoute` and nothing stored.
    ///      Without consent the first entry fails `NotConsented` before any duplicate is looked for.
    function route_setDuplicateRoute(uint8 copies) public updateGhosts(OpType.MANAGER) {
        address top = address(vaults[2]);
        if (!vaultRoute.isConsented(address(vaultC), top) || !spokeRegistry.isLinked(address(vaultC))) return;

        // Two to four copies, so the duplicate sits at every position the loop compares
        address[] memory underlying = new address[](2 + copies % 3);
        for (uint256 i; i < underlying.length; i++) {
            underlying[i] = address(vaultC);
        }
        bytes memory payload = abi.encode(IVaultLiquidityRoute.ConfigKind.Routes, top, abi.encode(underlying));
        bytes32 routesBefore = keccak256(abi.encode(vaultRoute.routes(top)));

        _authorizeManagerCall(poolA, address(vaultRoute), payload);
        _fm();
        (bool success, bytes memory ret) = address(hub)
            .call(
                abi.encodeCall(
                    hub.managerCall, (poolA, CENTRIFUGE_ID, address(vaultRoute).toBytes32(), payload, 0, 0, REFUND)
                )
            );

        // The hub's own refusal (the pool's policy, or a lapsed authorization) is not an answer about the route
        if (bytes4(ret) == IHubRegistry.Unauthorized.selector) return _reverted("route_setDuplicateRoute");
        t(!success, "a route to the same vault twice was accepted");
        t(bytes4(ret) == IVaultLiquidityRoute.DuplicateRoute.selector, "a duplicated route failed with another error");
        t(keccak256(abi.encode(vaultRoute.routes(top))) == routesBefore, "a refused routes config changed the routes");
        _reverted("route_setDuplicateRoute");
    }

    //----------------------------------------------------------------------------------------------
    // Flush on every request policy
    //----------------------------------------------------------------------------------------------

    /// @dev The observer's count before a flush, in storage to keep the handler's stack within its limit.
    uint256 internal observerMark;

    /// @dev A stranger asks one vault to flush one of its buckets, whatever the policy. The permissionless call either
    ///      sends the queue (the bucket is flushed, the queue is empty and the hub's order grew by exactly the queue),
    ///      or refuses with the policy's own gate (`BucketStillOpen`) or the empty queue (`NoQueuedRequest`). A
    ///      non-batching policy has no gate, and flushes its bucket as it opens, so for it the answer is always an
    ///      empty queue; that is the `isClosed` of the per-request and per-investor policies.
    function vault_flushAnyKind(uint256 vaultSeed, uint256 reqSeed) public updateGhosts(OpType.USER) {
        uint8 v = _vaultIndex(vaultSeed);
        Req memory r;
        bool found;
        for (uint256 i; i < reqs.length; i++) {
            r = reqs[(reqSeed + i) % reqs.length];
            if (r.vault == v) {
                found = true;
                break;
            }
        }
        if (!found) return;

        IAsyncVault vault = vaults[v];
        uint96 localId = uint96(r.requestId);
        IRequestPolicy policy = IRequestPolicy(address(vault.requestPolicy()));
        uint128 queued = vault.bucket(localId).queued;
        bool open = policy.isClosed(address(vault), vault.keyOf(localId));
        uint128 outstanding = _outstandingOf(address(vault), localId, r.isDeposit);
        if (address(policy) == address(perRequestPolicy) || address(policy) == address(perInvestorPolicy)) {
            t(open, "a non-batching policy gated a flush");
        }

        observerMark = requestObserver.calls();
        (bool success, bytes memory ret) =
            _callAs(OUTSIDER, address(vault), abi.encodeCall(vault.flushRequest, (localId)));

        if (success) {
            t(open && queued != 0, "a flush went through without an open queue");
            // The request message reaches the pool's observer once when it is the counting one, and no other
            eq(
                requestObserver.calls() - observerMark,
                address(orderBook.observer(poolA)) == address(requestObserver) ? 1 : 0,
                "the request observer was not told of a flush exactly once"
            );
            Bucket memory b = vault.bucket(localId);
            t(b.flushed, "a flushed bucket is not marked flushed");
            eq(uint256(vault.bucket(localId).queued), 0, "a flush left a queue behind");
            eq(
                uint256(_outstandingOf(address(vault), localId, r.isDeposit)) - outstanding,
                uint256(queued),
                "the hub's order did not grow by the flushed queue"
            );
            return _ok("vault_flushAnyKind");
        }

        bytes4 reason = bytes4(ret);
        if (!open) {
            t(reason == IVaultErrors.BucketStillOpen.selector, "a closed gate refused with another error");
        } else if (queued == 0) {
            t(reason == IVaultErrors.NoQueuedRequest.selector, "an empty queue refused with another error");
        } else {
            // A queue behind an open gate is sent unless the vault was retired
            t(vaultRevoked[address(vault)] || vaultUnlinked[address(vault)], "an open queue was not flushed");
        }
        _reverted("vault_flushAnyKind");
    }

    function _outstandingOf(address vault, uint96 localId, bool isDeposit) internal view returns (uint128) {
        RequestId rid = vault.from(localId);
        return
            isDeposit
                ? orderBook.depositOrders(poolA, scA, usdcId, rid)
                : orderBook.redeemOrders(poolA, scA, usdcId, rid);
    }

    //----------------------------------------------------------------------------------------------
    // Request paid from the subsidy
    //----------------------------------------------------------------------------------------------

    /// @dev Pool E's asset is registered under another network's id, so the router pays the request's message out of
    ///      the pool's subsidy: it withdraws the whole subsidy, sends it with the message and names the pool's refund
    ///      escrow as the refund. The pool is on this network, so the message is delivered in place for nothing and
    ///      the whole payment comes back. An optional subsidy is deposited first (anyone may), so both the funded and
    ///      the empty escrow are drawn. The request has to go through, the order lands at the hub, the subsidy is
    ///      whole afterwards (it paid the message's cost, which is nothing here) and nothing is left in the router.
    function request_paidFromSubsidy(uint256 actorSeed, uint128 amount, uint128 subsidy, bool fund)
        public
        updateGhosts(OpType.USER)
    {
        address actor = _actor(actorSeed);
        uint256 balance = usdcE.balanceOf(actor);
        if (balance == 0) return;
        amount = uint128(between(amount, 1, balance));

        if (fund) {
            uint256 value = between(subsidy, 1, 1 ether);
            vm.deal(address(this), address(this).balance + value);
            subsidyManager.deposit{value: value}(poolE);
        }
        address escrow = address(refundEscrowFactory.get(poolE));
        uint256 escrowBefore = escrow.balance;
        uint256 routerBefore = address(vaultRouter).balance;
        uint256 refundBefore = REFUND.balance;

        vm.prank(actor);
        usdcE.approve(address(vaultE), amount);
        vm.prank(actor);
        try vaultE.requestDeposit(amount, actor, actor) returns (uint256 requestId) {
            eq(
                uint256(orderBook.depositOrders(poolE, scE, usdcEId, RequestId.wrap(requestId))),
                uint256(amount),
                "the request did not reach the hub"
            );
            eq(escrow.balance, escrowBefore, "the subsidy was not made whole after the message");
            eq(address(vaultRouter).balance, routerBefore, "the router kept part of the subsidy");
            eq(REFUND.balance, refundBefore, "the subsidy's refund went to another address");
            _ok("request_paidFromSubsidy");
        } catch {
            t(false, "the request paid from the subsidy was refused");
        }
    }

    //----------------------------------------------------------------------------------------------
    // Basin repayment the route cannot book
    //----------------------------------------------------------------------------------------------

    /// @dev The route has lost its minting right, so `repay` cannot burn the liability it booked at the draw: the
    ///      provider is paid in full, the receivable falls, and the booked liability stays as it was, for the pool to
    ///      clear. That is the `: 0` side of the booking, and the cleanup is the pool clearing it (a manager takes the
    ///      liability out and burns it under a minting right granted for the purpose), which restores the books
    ///      `property_basinDebtIsBooked` reads.
    function basin_repayUnbooked(uint256 seed, uint128 amount) public updateGhosts(OpType.USER) {
        IAsyncVault vault = vaults[3];
        if (!spokeRegistry.manager(poolA, BSM)) return;
        if (basinRoute.receivable(address(vault)) == 0 && !_drawBasin(seed, amount)) {
            return _reverted("basin_repayUnbooked");
        }
        uint128 owed = basinRoute.receivable(address(vault));
        if (owed == 0) return;
        uint128 assets = uint128(between(amount, 1, owed));
        uint256 liabilityId = _basinLiabilityTokenId();

        _setBasinMinter(address(basinRoute), false);
        (uint128 bookedBefore,) = _escrow(poolA).holding(scA, address(accountingToken), liabilityId);
        usdc.mint(BSM, assets);
        vm.prank(BSM);
        usdc.approve(address(basinRoute), assets);
        uint256 providerBefore = usdc.balanceOf(LP);
        uint256 bsmBefore = usdc.balanceOf(BSM);

        vm.prank(BSM);
        try basinRoute.repay(address(vault), assets) {
            eq(usdc.balanceOf(LP) - providerBefore, uint256(assets), "the provider was not paid in full");
            eq(bsmBefore - usdc.balanceOf(BSM), uint256(assets), "the repayer paid another amount");
            eq(basinRoute.receivable(address(vault)), uint256(owed - assets), "the receivable fell by another amount");
            (uint128 bookedAfter,) = _escrow(poolA).holding(scA, address(accountingToken), liabilityId);
            eq(uint256(bookedAfter), uint256(bookedBefore), "an unbookable repayment moved the booked liability");
            _clearLiability(liabilityId, assets);
            _ok("basin_repayUnbooked");
        } catch {
            t(false, "a repayment the route cannot book was refused");
        }
        _setBasinMinter(address(basinRoute), true);
    }

    /// @dev The pool clears a liability left booked: a manager takes it out of the escrow and burns it.
    function _clearLiability(uint256 liabilityId, uint128 assets) internal {
        _setBasinMinter(BSM, true);
        vm.prank(BSM);
        spoke.withdraw(poolA, scA, address(accountingToken), liabilityId, BSM, assets);
        vm.prank(BSM);
        accountingToken.burn(BSM, liabilityId, assets, scA);
        _setBasinMinter(BSM, false);
    }

    function _setBasinMinter(address who, bool canMint) internal {
        _managerCall(poolA, address(accountingToken), abi.encode(who.toBytes32(), canMint));
    }

    /// @dev The draw of `flow_basinDrawAndRepay`: the escrow is drained and an instant redemption on the basin vault
    ///      pulls from the venue, which books the receivable.
    function _drawBasin(uint256 seed, uint128 amount) internal returns (bool) {
        IAsyncVault vault = vaults[3];
        if (!_oracleValid()) return false;
        address actor = _shareHolder(seed);
        if (frozen[actor] || !_healthy(vault, actor) || _inAsync(vault, actor, false)) return false;

        uint128 idle = spoke.availableBalanceOf(poolA, scA, address(usdc), 0);
        if (idle != 0) {
            vm.prank(BSM);
            spoke.withdraw(poolA, scA, address(usdc), 0, BSM, idle);
        }
        uint256 capacity = vault.maxWithdraw(actor);
        if (capacity == 0) return false;
        return _instant(vault, actor, between(amount, 1, capacity), true, false);
    }
}
