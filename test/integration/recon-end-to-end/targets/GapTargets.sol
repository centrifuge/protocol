// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FlowTargets} from "./FlowTargets.sol";

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {MockAdapter} from "../../../core/mocks/MockAdapter.sol";

import {RequestId} from "../../../../src/core/types/RequestId.sol";
import {IAdapter} from "../../../../src/core/messaging/interfaces/IAdapter.sol";
import {VaultUpdateKind} from "../../../../src/core/messaging/libraries/MessageLib.sol";
import {IMessageHandler} from "../../../../src/core/messaging/interfaces/IMessageHandler.sol";

import {UpdateRestrictionMessageLib} from "../../../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {OrderBookAction} from "../../../../src/vaults/hub/interfaces/IOrderBook.sol";
import {VaultRequestIdLib} from "../../../../src/vaults/libraries/VaultRequestIdLib.sol";
import {IAsyncVault, IVaultErrors} from "../../../../src/vaults/interfaces/IAsyncVault.sol";
import {IReserveInstantPolicy} from "../../../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";
import {IShareTokenRegistrar} from "../../../../src/token/interfaces/IShareTokenRegistrar.sol";

/// @dev What the first suite left unreached: members that lapse and sponsors, horizons long enough to spill
///      the claim ledger, a hub policy, the investor router, vaults retired mid-flight, and a position on the route.
abstract contract GapTargets is FlowTargets {
    /// @dev `ISpokeRegistry.NotBridger`: what a share transfer by a holder without the role is refused as.
    bytes4 internal constant NOT_BRIDGER = bytes4(keccak256("NotBridger()"));
    /// @dev `ISpoke.BridgeNotAllowed`: the share hook's refusal of a transfer to the target network.
    bytes4 internal constant BRIDGE_NOT_ALLOWED = bytes4(keccak256("BridgeNotAllowed()"));

    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    uint8 internal constant LONG_VAULT = 4;

    /// @dev The recording adapter pool A uses towards `REMOTE_ID`, set up on the first bridge.
    MockAdapter internal remoteAdapter;

    //----------------------------------------------------------------------------------------------
    // Members and sponsors
    //----------------------------------------------------------------------------------------------

    /// @dev Any actor's membership is set to lapse within hours, or never. The first suite only ever lapsed the
    ///      outsider, so a controller whose membership ended while it held a claim was unreachable.
    function hub_lapseMember(uint256 actorSeed, uint256 duration, bool forever) public updateGhosts(OpType.MANAGER) {
        address actor = _actor(actorSeed);
        uint64 validUntil = forever ? type(uint64).max : uint64(block.timestamp + between(duration, 0, 6 hours));
        _updateRestriction(
            poolA,
            scA,
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: actor.toBytes32(), validUntil: validUntil
            }).serialize()
        );
        _ok("hub_lapseMember");
    }

    /// @dev Allows or removes a sponsor of one of the vaults with an instant lane, through the instant policy's
    ///      trusted call, so a request funded by someone the controller did not choose meets the check.
    function hub_setSponsors(uint256 vaultSeed, uint256 actorSeed, bool value) public updateGhosts(OpType.MANAGER) {
        IAsyncVault vault = vaults[2 + vaultSeed % 2];
        _managerCall(
            poolA,
            address(reserveInstantPolicy),
            abi.encode(IReserveInstantPolicy.ConfigKind.Sponsor, address(vault), abi.encode(_actor(actorSeed), value))
        );
        ghostSponsor[address(vault)][_actor(actorSeed)] = value;
        _ok("hub_setSponsors");
    }

    /// @dev Points the share token's ERC-7575 vault for USDC at one of the pool's vaults, or clears it, through the
    ///      registrar's call, so `property_shareTokenIdentity` meets a pointer that is set. The registrar takes a
    ///      vault the registry links and refuses one it does not, which leaves the pointer where it was.
    function hub_setShareTokenVault(uint256 vaultSeed, bool clear) public updateGhosts(OpType.MANAGER) {
        IAsyncVault vault = vaults[_vaultIndex(vaultSeed)];
        address before = shareA.vault(address(usdc));
        _managerCall(
            poolA,
            address(shareTokenRegistrar),
            abi.encode(
                uint8(IShareTokenRegistrar.RegistrarCall.SetVault),
                scA.raw(),
                usdcId.raw(),
                clear ? address(0) : address(vault)
            )
        );
        address expected =
            clear ? address(0) : spokeRegistry.vaultDetails(address(vault)).isLinked ? address(vault) : before;
        eq(
            uint256(uint160(shareA.vault(address(usdc)))),
            uint256(uint160(expected)),
            "the share token's vault is not the one the registrar was told to set"
        );
        _ok("hub_setShareTokenVault");
    }

    //----------------------------------------------------------------------------------------------
    // Bridging
    //----------------------------------------------------------------------------------------------

    /// @dev A holder sends shares to another network. Only a bridger may: without the role the call is refused as
    ///      `NotBridger`, and the share hook refuses a target network it has not made a member (`BridgeNotAllowed`).
    ///      Otherwise the shares leave the holder and the supply, and the hub moves that much issuance from this
    ///      network to the target. The share queue is flushed first, so the hub's issuance here covers what leaves.
    ///      The role is withdrawn again, so it never leaks into another handler.
    function bridge_transferShares(uint256 actorSeed, uint128 amount, bool grant, bool open)
        public
        updateGhosts(OpType.USER)
    {
        address actor = _liquidHolder(actorSeed);
        uint256 balance = shareA.balanceOf(actor);
        (bool member,) = fullRestrictions.isMember(address(shareA), actor);
        if (balance == 0 || frozen[actor] || !member) return;
        amount = uint128(between(amount, 1, balance));
        _openRemoteNetwork();
        spokeRegistry.updateBridger(poolA, actor, grant);
        _updateRestriction(
            poolA,
            scA,
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: address(uint160(REMOTE_ID)).toBytes32(),
                validUntil: open ? type(uint64).max : uint64(block.timestamp)
            }).serialize()
        );
        _flushShareQueue();
        // A closed network's membership ends with this second
        if (!open) vm.warp(block.timestamp + 1);

        uint256[4] memory before = [
            balance,
            shareA.totalSupply(),
            shareClassManager.issuance(poolA, scA, CENTRIFUGE_ID),
            shareClassManager.issuance(poolA, scA, REMOTE_ID)
        ];
        vm.deal(actor, 1 ether);
        vm.prank(actor);
        shareA.approve(address(spoke), amount);
        vm.prank(actor);
        (bool success, bytes memory ret) = address(spoke).call{value: 0.1 ether}(
            abi.encodeWithSignature(
                "crosschainTransferShares(uint16,uint64,bytes16,bytes32,uint128,uint128)",
                REMOTE_ID,
                poolA,
                scA,
                actor.toBytes32(),
                amount,
                uint128(0)
            )
        );
        spokeRegistry.updateBridger(poolA, actor, false);
        vm.prank(actor);
        shareA.approve(address(spoke), 0);

        if (!success) {
            bytes4 expected = !grant ? NOT_BRIDGER : BRIDGE_NOT_ALLOWED;
            t(!grant || !open ? bytes4(ret) == expected : false, "a bridge by a bridger to an open network was refused");
            return _reverted("bridge_transferShares");
        }
        t(grant && open, "shares were bridged without the bridger role or to a closed network");
        eq(shareA.balanceOf(actor), before[0] - amount, "the bridged shares did not leave the holder");
        eq(shareA.totalSupply(), before[1] - amount, "the bridged shares were not burnt");
        eq(
            uint256(shareClassManager.issuance(poolA, scA, CENTRIFUGE_ID)),
            before[2] - amount,
            "the hub kept the bridged issuance on this network"
        );
        eq(
            uint256(shareClassManager.issuance(poolA, scA, REMOTE_ID)),
            before[3] + amount,
            "the hub did not move the bridged issuance to the target"
        );
        _ok("bridge_transferShares");
    }

    /// @dev The balance-sheet manager flushes pool A's share queue, counted like the handler that does it.
    function _flushShareQueue() internal {
        (bool flushed,) =
            _callAs(BSM, address(spoke), abi.encodeCall(spoke.submitQueuedShares, (poolA, scA, 0, REFUND)));
        if (flushed) ghost_shareQueueFlushes++;
    }

    /// @dev The suite has one network, so a message to `REMOTE_ID` has nowhere to go: this gives pool A a recording
    ///      adapter for it, once, so the hub's forward of a bridged transfer is accepted and not refused for want of one.
    function _openRemoteNetwork() internal {
        if (address(remoteAdapter) != address(0)) return;
        remoteAdapter = new MockAdapter(REMOTE_ID, IMessageHandler(address(multiAdapter)));
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = remoteAdapter;
        multiAdapter.setAdapters(REMOTE_ID, poolA, adapters, 1, 1);
    }

    //----------------------------------------------------------------------------------------------
    // Long horizon
    //----------------------------------------------------------------------------------------------

    /// @dev The requests of the last `flow_manyWindows`, for a test to look at what became of them.
    uint96[] internal lastWindowIds;

    /// @dev Several windows of the long-horizon per-period vault, each settled, then folded and claimed: a
    ///      horizon past the first slots reaches the overflow slot of its folds. With `leaveAtRest` the horizon is
    ///      left standing instead, with only the windows a bit of `fillSeed` picks folded and nothing claimed, so
    ///      what is stored in the overflow slots is read later, by whatever handler or property comes next.
    function flow_manyWindows(uint256 amountSeed, uint256 fillSeed, uint8 windows, bool leaveAtRest)
        public
        updateGhosts(OpType.MANAGER)
    {
        IAsyncVault vault = vaults[LONG_VAULT];
        // Each window costs a settlement, a fold and a claim, so most runs stay shallow and one in sixteen goes on
        // to the overflow slots
        windows = windows % 16 == 0 ? uint8(between(windows, 8, 10)) : uint8(between(windows, 2, 3));
        bool completed = true;
        uint96[] memory ids = new uint96[](windows);
        address actor = _shareHolder(amountSeed);
        if (frozen[actor]) return;
        for (uint256 w; w < windows; w++) {
            uint256 balance = usdc.balanceOf(actor);
            if (balance < _dust(true)) break;
            uint256 amount = between(uint256(keccak256(abi.encode(amountSeed, w))), _dust(true), balance);
            (bool requested, uint256 requestId) = _requestDeposit(actor, actor, LONG_VAULT, amount);
            if (!requested) continue;
            ids[w] = uint96(requestId);
            completed = _settle(Req(LONG_VAULT, requestId, true), fillSeed + w) && completed;
        }
        uint256 open;
        for (uint256 w; w < windows; w++) {
            if (ids[w] != 0 && vault.contribution(ids[w], actor).amount != 0) open++;
        }
        if (open > ghost_deepestHorizon) ghost_deepestHorizon = open;
        lastWindowIds = ids;
        for (uint256 w; w < windows; w++) {
            if (ids[w] == 0 || vault.contribution(ids[w], actor).amount == 0) continue;
            if (leaveAtRest && (fillSeed >> w) & 1 == 0) continue;
            _foldOne(LONG_VAULT, ids[w], actor);
        }
        if (!leaveAtRest) completed = _claimAll(vault, actor, fillSeed) && completed;
        _flowEnd("flow_manyWindows", completed);
    }

    /// @dev On an async-only vault nothing routes on a pending position, so eviction from the horizon is only a
    ///      view-visibility gap, not a loss: a position evicted while still unsettled, once it settles, needs a
    ///      `foldRequest` before a claim sees it, exactly as an un-evicted position needs none. Opens one more
    ///      window than the long horizon holds, settles only the evicted (oldest) one, and checks it is invisible
    ///      to the claimable views until folded, then visible after.
    function flow_evictedNeedsFoldRequest(uint256 amountSeed, uint256 fillSeed) public updateGhosts(OpType.MANAGER) {
        IAsyncVault vault = vaults[LONG_VAULT];
        uint256 horizon = vault.foldHorizon();
        address actor = _shareHolder(amountSeed);
        if (frozen[actor]) return;

        uint256 windows = horizon + 1;
        uint256[] memory requestIds = new uint256[](windows);
        for (uint256 w; w < windows; w++) {
            uint256 balance = usdc.balanceOf(actor);
            if (balance < _dust(true)) return;
            vm.warp(block.timestamp + PERIOD);
            uint256 amount = between(uint256(keccak256(abi.encode(amountSeed, w))), _dust(true), balance);
            (bool requested, uint256 requestId) = _requestDeposit(actor, actor, LONG_VAULT, amount);
            if (!requested) return;
            requestIds[w] = requestId;
        }

        // The oldest window is the one the horizon made way for; it still has its contribution, just no
        // longer auto-folded.
        uint96 evictedId = uint96(requestIds[0]);
        if (vault.contribution(evictedId, actor).amount == 0) return;

        // What the actor can already claim from earlier positions is not the evicted one's
        uint256 claimableBefore = vault.claimableMint(actor);
        uint256 maxBefore = vault.maxMint(actor);
        if (!_settle(Req(LONG_VAULT, requestIds[0], true), fillSeed)) return;
        t(
            vault.claimableMint(actor) == claimableBefore && vault.maxMint(actor) == maxBefore,
            "a settled evicted position was claimable before foldRequest"
        );

        _foldOne(LONG_VAULT, evictedId, actor);
        t(vault.claimableMint(actor) > claimableBefore, "a settled evicted position stayed hidden after foldRequest");
        _flowEnd("flow_evictedNeedsFoldRequest", _claimAll(vault, actor, fillSeed));
    }

    //----------------------------------------------------------------------------------------------
    // Hub policy
    //----------------------------------------------------------------------------------------------

    /// @dev Installs the standard policy for the pool, once: from then on manager calls are classified as
    ///      immediate, delayed or refused, so the fee manager's in-policy check and the delays are live.
    function hub_installPolicy() public updateGhosts(OpType.TERMS) {
        if (address(hub.policy(poolA)) == address(hubPolicy)) return;
        _fm();
        hub.setPolicy(poolA, hubPolicy);
        hubPolicyInstalled = true;
        _ok("hub_installPolicy");
    }

    //----------------------------------------------------------------------------------------------
    // Investor router
    //----------------------------------------------------------------------------------------------

    /// @dev The investor router relays a request and the claim of it, once the investor made it an operator.
    function router_cycle(uint256 actorSeed, uint256 amount, bool redeem, bool claim) public updateGhosts(OpType.USER) {
        IAsyncVault vault = vaults[0];
        address actor = _actor(actorSeed);
        if (frozen[actor]) return;
        vm.prank(actor);
        vault.setOperator(address(investorRouter), true);
        if (claim) {
            bytes memory data = abi.encodeCall(
                redeem ? investorRouter.claimRedeem : investorRouter.claimDeposit, (vault, actor, actor)
            );
            uint256 sharesBefore = shareA.balanceOf(actor);
            uint256 assetsBefore = usdc.balanceOf(actor);
            (bool claimed,) = _callAs(actor, address(investorRouter), data);
            if (claimed) _countClaimed(address(vault), actor, sharesBefore, assetsBefore);
            return claimed ? _ok("router_claim") : _reverted("router_claim");
        }
        uint256 balance = redeem ? shareA.balanceOf(actor) : usdc.balanceOf(actor);
        if (balance == 0) return;
        amount = between(amount, 1, balance);
        uint128[64] memory held = _held(vault, actor);
        vm.prank(actor);
        usdc.approve(address(vault), amount);
        uint256[10] memory fold = _beforeFold(0);
        (bool success,) = _callAs(
            actor,
            address(investorRouter),
            abi.encodeCall(
                redeem ? investorRouter.requestRedeem : investorRouter.requestDeposit, (vault, amount, actor, actor)
            )
        );
        if (!success) return _reverted("router_request");
        _noteSurfaced(0, fold);
        _trackGrowth(vault, actor, held, !redeem);
        _ok("router_request");
    }

    //----------------------------------------------------------------------------------------------
    // Retirement
    //----------------------------------------------------------------------------------------------

    /// @dev Links or unlinks a vault. An unlinked vault refuses new requests, flushes and callbacks, but claims
    ///      already earned must still pay while its manager role holds.
    function hub_setVaultLink(uint256 vaultSeed, bool linked) public updateGhosts(OpType.MANAGER) {
        _setVaultLink(vaults[_vaultIndex(vaultSeed)], linked);
        _ok("hub_setVaultLink");
    }

    function _setVaultLink(IAsyncVault vault, bool linked) internal {
        VaultUpdateKind kind = linked ? VaultUpdateKind.Link : VaultUpdateKind.Unlink;
        _authorize(
            poolA,
            abi.encodeCall(hub.updateVault, (poolA, scA, usdcId, address(vault).toBytes32(), kind, "", 0, REFUND))
        );
        _fm();
        hub.updateVault(poolA, scA, usdcId, address(vault).toBytes32(), kind, "", 0, REFUND);
        vaultUnlinked[address(vault)] = !linked;
    }

    /// @dev An unlinked vault refuses new requests: both request entrypoints revert as `VaultNotLinked`, for a
    ///      requester that could otherwise pay or redeem. A linked vault is unlinked for the calls and linked again.
    function vault_unlinkedRefusesRequests(uint256 vaultSeed, uint256 actorSeed, uint256 amount)
        public
        updateGhosts(OpType.MANAGER)
    {
        IAsyncVault vault = vaults[_vaultIndex(vaultSeed)];
        bool wasLinked = !vaultUnlinked[address(vault)];
        if (wasLinked) _setVaultLink(vault, false);

        address depositor = _actor(actorSeed);
        amount = between(amount, 1, 1e12);
        usdc.mint(depositor, amount);
        vm.prank(depositor);
        usdc.approve(address(vault), amount);
        (bool deposited, bytes memory depositRet) =
            _callAs(depositor, address(vault), abi.encodeCall(vault.requestDeposit, (amount, depositor, depositor)));
        t(!deposited, "a request deposit went through an unlinked vault");
        t(bytes4(depositRet) == IVaultErrors.VaultNotLinked.selector, "an unlinked vault refused for another reason");

        _redeemRefusedWhenUnlinked(vault, actorSeed, amount);

        if (wasLinked) _setVaultLink(vault, true);
        _ok("vault_unlinkedRefusesRequests");
    }

    function _redeemRefusedWhenUnlinked(IAsyncVault vault, uint256 actorSeed, uint256 amount) internal {
        address holder = _liquidHolder(actorSeed);
        uint256 shares = shareA.balanceOf(holder);
        if (shares == 0) return;

        uint256 asked = between(amount, 1, shares);
        (bool redeemed, bytes memory ret) =
            _callAs(holder, address(vault), abi.encodeCall(vault.requestRedeem, (asked, holder, holder)));
        t(!redeemed, "a request redeem went through an unlinked vault");
        t(bytes4(ret) == IVaultErrors.VaultNotLinked.selector, "an unlinked vault refused for another reason");
    }

    /// @dev A vault the registry holds as linked under another share class of its pool is not linked as far as the
    ///      vault is concerned: it refuses requests and offers no capacity, since it is not the position it was built for.
    function vault_misfiledRefusesRequests(uint256 actorSeed, uint256 amount) public updateGhosts(OpType.USER) {
        address actor = _actor(actorSeed);
        amount = between(amount, 1, 1e12);
        usdc.mint(actor, amount);
        vm.prank(actor);
        usdc.approve(address(misfiledVault), amount);
        (bool deposited, bytes memory ret) =
            _callAs(actor, address(misfiledVault), abi.encodeCall(misfiledVault.requestDeposit, (amount, actor, actor)));
        t(!deposited, "a vault registered under another share class took a request");
        t(bytes4(ret) == IVaultErrors.VaultNotLinked.selector, "a misfiled vault refused for another reason");
        eq(misfiledVault.maxDeposit(actor), 0, "a misfiled vault offered deposit capacity");
        _ok("vault_misfiledRefusesRequests");
    }

    /// @dev A spender of an owner's share allowance is not the owner: it cannot use the owner's standing as a
    ///      sponsor, nor close the owner's instant lane by requesting a redemption for the owner as controller. On a
    ///      vault with both lanes only the owner or its operator may, whoever else holds the allowance.
    function vault_spenderRequestRedeem(uint256 spenderSeed, uint256 ownerSeed, uint256 vaultSeed, uint256 shares)
        public
        updateGhosts(OpType.USER)
    {
        address owner = _liquidHolder(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 held = shareA.balanceOf(owner);
        if (spender == owner || held == 0 || frozen[owner]) return;
        uint8 v = _vaultIndex(vaultSeed);
        IAsyncVault vault = vaults[v];
        shares = between(shares, 1, held);

        vm.prank(owner);
        shareA.approve(spender, shares);
        (bool success, bytes memory ret) =
            _callAs(spender, address(vault), abi.encodeCall(vault.requestRedeem, (shares, owner, owner)));
        vm.prank(owner);
        shareA.approve(spender, 0);

        bool mayAct = vault.isOperator(owner, spender) || address(vault.instantPolicy()) == address(0);
        if (success) {
            t(mayAct, "a spender of the owner's allowance requested a redemption on a dual-lane vault");
            _onRequest(v, abi.decode(ret, (uint256)), owner, false, shares);
            _ok("vault_spenderRequestRedeem");
        } else {
            _reverted("vault_spenderRequestRedeem");
        }
    }

    /// @dev Withdraws or restores a vault's manager role, which its claims pay through.
    function hub_setVaultManager(uint256 vaultSeed, bool canManage) public updateGhosts(OpType.MANAGER) {
        IAsyncVault vault = vaults[_vaultIndex(vaultSeed)];
        _updateManager(poolA, address(vault), canManage);
        vaultRevoked[address(vault)] = !canManage;
        _ok("hub_setVaultManager");
    }

    //----------------------------------------------------------------------------------------------
    // Liveness after over-reservation
    //----------------------------------------------------------------------------------------------

    /// @dev A payout releases only what the escrow holds unreserved, so while it is over-reserved a claim may
    ///      wait and the liveness check stands down. The manager funds the shortfall, and from then on the
    ///      claim at the full `maxWithdraw` must go through: the check the over-reserved state otherwise skips.
    function escrow_coverAndClaim(uint256 actorSeed, uint256 vaultSeed, bool byShares)
        public
        updateGhosts(OpType.MANAGER)
    {
        (uint128 total, uint128 reserved) = _escrow(poolA).holding(scA, address(usdc), 0);
        if (reserved > total) {
            uint128 shortfall = reserved - total;
            usdc.mint(BSM, shortfall);
            vm.prank(BSM);
            usdc.approve(address(spoke), shortfall);
            vm.prank(BSM);
            spoke.deposit(poolA, scA, address(usdc), 0, shortfall);
        }
        (IAsyncVault vault, address actor, uint256 max) = _findClaim(actorSeed, vaultSeed, false, byShares);
        if (max == 0) return;
        bool paid = _claimRedeem(vault, actor, max, byShares, true);
        paid ? _ok("escrow_coverAndClaim") : _reverted("escrow_coverAndClaim");
    }

    //----------------------------------------------------------------------------------------------
    // Liquidity routes, composed so one call reaches what a random walk rarely strings together
    //----------------------------------------------------------------------------------------------

    /// @dev The fund-of-funds exit in one call: idle USDC goes into pool C, the escrow is drained, and an instant
    ///      redemption on the top vault is paid by the route, which redeems the pool C shares it holds.
    function flow_routeExit(uint256 seed, uint128 amount) public updateGhosts(OpType.USER) {
        IAsyncVault top = vaults[2];
        if (!_oracleValid()) return;
        address actor = _shareHolder(seed);
        if (frozen[actor] || !_healthy(top, actor) || _inAsync(top, actor, false)) return;

        amount = uint128(between(amount, 2 * ONE_ASSET, 10_000 * ONE_ASSET));
        usdc.mint(BSM, amount);
        vm.prank(BSM);
        usdc.approve(address(spoke), amount);
        vm.prank(BSM);
        spoke.deposit(poolA, scA, address(usdc), 0, amount);

        uint128 invest = spoke.availableBalanceOf(poolA, scA, address(usdc), 0);
        uint256 capacity = vaultC.maxDeposit(BSM);
        invest = uint128(_min(invest, capacity));
        if (invest == 0) return;
        vm.prank(BSM);
        spoke.withdraw(poolA, scA, address(usdc), 0, BSM, invest);
        vm.prank(BSM);
        usdc.approve(address(vaultC), invest);
        uint256 held = shareC.balanceOf(BSM);
        vm.prank(BSM);
        try vaultC.deposit(invest, BSM) {
            uint128 shares = uint128(shareC.balanceOf(BSM) - held);
            vm.prank(BSM);
            shareC.approve(address(spoke), shares);
            vm.prank(BSM);
            spoke.deposit(poolA, scA, address(shareC), 0, shares);
        } catch {
            return _reverted("flow_routeExit");
        }

        // Drain what is left, so the exit can only be paid through the route
        uint128 idle = spoke.availableBalanceOf(poolA, scA, address(usdc), 0);
        if (idle != 0) {
            vm.prank(BSM);
            spoke.withdraw(poolA, scA, address(usdc), 0, BSM, idle);
        }
        uint256 capacityOut = top.maxWithdraw(actor);
        if (capacityOut == 0) return _reverted("flow_routeExit");
        t(
            _instant(top, actor, between(seed, ONE_ASSET < capacityOut ? ONE_ASSET : 1, capacityOut), true, false),
            "an exit within the capacity was not paid through the route"
        );
        _ok("flow_routeExit");
    }

    /// @dev What a hostile answer may add to the capacity view's gas: the callee's own cost of producing a 300 kB
    ///      payload (about 200k), and short of what copying it into the caller adds on top (about 430k in all).
    uint256 internal constant HOSTILE_GAS_SLACK = 300_000;

    /// @dev A pool A vault is told to draw on a second pool C vault that answers as its mode says: nothing, a revert, a
    ///      300 kB payload or the largest number. Whatever it says, the views never revert, a revert or a payload
    ///      reads as no capacity (the exit capacity is what the honest liquidity gives), and an exit the honest
    ///      liquidity covers goes through: a refusal under a hostile mode is retried with the underlying silent,
    ///      and only a refusal that goes away with it is a block. The mode is silent again afterwards.
    function route_hostileUnderlying(uint256 actorSeed, uint256 amountSeed, uint8 mode)
        public
        updateGhosts(OpType.USER)
    {
        IAsyncVault top = hostileTop;
        if (!_oracleValid()) return;
        address actor = _liquidHolder(actorSeed);
        if (frozen[actor] || !_healthy(top, actor) || _inAsync(top, actor, false)) return;

        hostileUnderlying.setMode(0);
        uint256 gasBefore = gasleft();
        uint256 honest = top.maxWithdraw(actor);
        uint256 honestGas = gasBefore - gasleft();
        if (honest == 0) return;

        mode = 1 + mode % 3;
        hostileUnderlying.setMode(mode);
        gasBefore = gasleft();
        (bool viewed, bytes memory ret) = address(top).staticcall(abi.encodeCall(top.maxWithdraw, (actor)));
        // A payload is read one word of, so a 300 kB answer costs the caller what answering does and no more
        lte(
            gasBefore - gasleft(),
            honestGas + HOSTILE_GAS_SLACK,
            "a hostile underlying made the capacity view cost more"
        );
        t(viewed, "a hostile underlying made maxWithdraw revert");
        if (viewed && mode != 3) {
            eq(abi.decode(ret, (uint256)), honest, "a reverting or oversized quote changed the exit capacity");
        }

        uint256 amount = between(amountSeed, 1, honest);
        if (!_instant(top, actor, amount, true, false)) {
            hostileUnderlying.setMode(0);
            t(
                !_instant(top, actor, amount, true, false),
                "a hostile underlying blocked an exit the honest liquidity covers"
            );
        }
        hostileUnderlying.setMode(0);
        _ok("route_hostileUnderlying");
    }

    /// @dev Assets sent straight to a contract that can hold them are not lost: Root (or, where it is not a ward, the
    ///      tester) recovers them, and the contract ends exactly where it began. The contracts are the vaults, the
    ///      investor router, the pool's escrow, the two liquidity routes and the core contracts that are recoverable.
    function donate_andRecover(uint256 targetSeed, uint128 amount) public updateGhosts(OpType.USER) {
        address[9] memory targets = [
            address(vaults[0]),
            address(vaults[2]),
            address(vaults[3]),
            address(investorRouter),
            address(_escrow(poolA)),
            address(vaultRoute),
            address(basinRoute),
            address(spoke),
            address(hub)
        ];
        address target = targets[targetSeed % targets.length];
        address who = IAuth(target).wards(address(root)) == 1
            ? address(root)
            : IAuth(target).wards(address(this)) == 1 ? address(this) : address(0);
        if (who == address(0)) return;

        amount = uint128(between(amount, 1, 1_000 * ONE_ASSET));
        address receiver = OUTSIDER;
        uint256 held = usdc.balanceOf(target);
        uint256 received = usdc.balanceOf(receiver);
        usdc.mint(address(this), amount);
        usdc.transfer(target, amount);
        eq(usdc.balanceOf(target), held + amount, "a donation did not reach the contract");

        (bool recovered,) = _callAs(
            who,
            target,
            abi.encodeWithSignature("recoverTokens(address,address,uint256)", address(usdc), receiver, amount)
        );
        t(recovered, "assets sent to a contract could not be recovered");
        if (!recovered) return;
        eq(usdc.balanceOf(receiver), received + amount, "the recovery did not pay the receiver the donation");
        eq(usdc.balanceOf(target), held, "the recovery left the contract's balance changed");
        _ok("donate_andRecover");
    }

    /// @dev An instant trade on the vault whose policy rebates every trade, paid by a source that approved the vault.
    ///      Nothing is created or lost: on a deposit the escrow takes in what the caller and the rebate source paid,
    ///      and on a redemption the receiver gets what the escrow and the rebate source gave up, which is the
    ///      payout the call returned. A vault that took the rebate out of the escrow as well as from the source
    ///      would pay it twice.
    function vault_rebatedTrade(uint256 actorSeed, uint256 amount, uint8 kind) public updateGhosts(OpType.USER) {
        address actor = _liquidHolder(actorSeed);
        (bool member,) = fullRestrictions.isMember(address(shareA), actor);
        if (frozen[actor] || !member || !_oracleValid()) return;

        uint256 actorBefore = usdc.balanceOf(actor);
        uint256 sourceBefore = usdc.balanceOf(REBATER);
        uint256 escrowBefore = usdc.balanceOf(address(_escrow(poolA)));
        bool success;
        bytes memory ret;
        if (kind % 2 == 0) {
            uint256 room = rebateVault.maxDeposit(actor);
            uint256 assets = room < actorBefore ? room : actorBefore;
            if (assets == 0) return;
            assets = between(amount, 1, assets);
            vm.prank(actor);
            usdc.approve(address(rebateVault), assets);
            (success, ret) = _callAs(
                actor, address(rebateVault), abi.encodeWithSignature("deposit(uint256,address)", assets, actor)
            );
            vm.prank(actor);
            usdc.approve(address(rebateVault), 0);
            if (!success) return _reverted("vault_rebatedTrade");
            eq(
                usdc.balanceOf(address(_escrow(poolA))) - escrowBefore,
                (actorBefore - usdc.balanceOf(actor)) + (sourceBefore - usdc.balanceOf(REBATER)),
                "an instant deposit's escrow intake is not what the caller and the rebate source paid"
            );
        } else {
            uint256 held = shareA.balanceOf(actor);
            uint256 room = rebateVault.maxRedeem(actor);
            uint256 shares = room < held ? room : held;
            if (shares == 0) return;
            shares = between(amount, 1, shares);
            (success, ret) =
                _callAs(actor, address(rebateVault), abi.encodeWithSignature("redeem(uint256,address)", shares, actor));
            if (!success) return _reverted("vault_rebatedTrade");
            uint256 gained = usdc.balanceOf(actor) - actorBefore;
            eq(gained, abi.decode(ret, (uint256)), "an instant redemption paid other than the payout it returned");
            eq(
                gained,
                (escrowBefore - usdc.balanceOf(address(_escrow(poolA)))) + (sourceBefore - usdc.balanceOf(REBATER)),
                "an instant redemption's payout is not what the escrow and the rebate source gave up"
            );
        }
        _ok("vault_rebatedTrade");
    }

    /// @dev The basin draw and its repayment: the escrow is drained, an instant redemption on the basin vault draws on
    ///      the venue, and the manager repays what the route booked, which reopens the credit line.
    function flow_basinDrawAndRepay(uint256 seed, uint128 amount) public updateGhosts(OpType.USER) {
        IAsyncVault vault = vaults[3];
        if (!_oracleValid()) return;
        address actor = _shareHolder(seed);
        if (frozen[actor] || !_healthy(vault, actor) || _inAsync(vault, actor, false)) return;

        uint128 idle = spoke.availableBalanceOf(poolA, scA, address(usdc), 0);
        if (idle != 0) {
            vm.prank(BSM);
            spoke.withdraw(poolA, scA, address(usdc), 0, BSM, idle);
        }
        uint256 capacity = vault.maxWithdraw(actor);
        if (capacity == 0) return _reverted("flow_basinDrawAndRepay");
        amount = uint128(between(amount, 1, capacity));
        if (!_instant(vault, actor, amount, true, false)) return _reverted("flow_basinDrawAndRepay");

        uint256 receivable = basinRoute.receivable(address(vault));
        if (receivable != 0) {
            usdc.mint(BSM, receivable);
            vm.prank(BSM);
            usdc.approve(address(basinRoute), receivable);
            vm.prank(BSM);
            basinRoute.repay(address(vault), uint128(receivable));
        }
        _ok("flow_basinDrawAndRepay");
    }

    /// @dev A redemption the underlying settles in the route's favour: the route never requests, so a sponsor pool C
    ///      allowed on its vault funds one with pool A's pool C shares and the route as controller, and the underlying
    ///      pool fills it. The route's draws on pool C then claim it until it is spent.
    function route_pushClaim(uint256 amountSeed) public updateGhosts(OpType.MANAGER) {
        uint128 held = spoke.availableBalanceOf(poolA, scA, address(shareC), 0);
        if (held == 0) return;
        _managerCall(
            poolC,
            address(reserveInstantPolicy),
            abi.encode(IReserveInstantPolicy.ConfigKind.Sponsor, address(vaultC), abi.encode(BSM, true))
        );
        // A fill that converts to no assets is refused, so the request stays above that dust
        uint128 shares = uint128(between(amountSeed, held < DUST_SHARES ? held : DUST_SHARES, held));
        vm.prank(BSM);
        spoke.withdraw(poolA, scA, address(shareC), 0, BSM, shares);
        vm.prank(BSM);
        (bool requested, bytes memory ret) =
            address(vaultC).call(abi.encodeCall(vaultC.requestRedeem, (shares, address(vaultRoute), BSM)));
        if (!requested) return _reverted("route_pushClaim");
        uint256 requestId = abi.decode(ret, (uint256));
        _fm();
        try feeRequestManager.fulfill(poolC, scC, usdcId, RequestId.wrap(requestId), false, shares, 0, REFUND) {
            _ok("route_pushClaim");
        } catch {
            _reverted("route_pushClaim");
        }
    }

    /// @dev ERC-7540: what `maxMint` or `maxRedeem` offers a controller is claimable now. A controller whose membership
    ///      lapsed, but who is not frozen, is offered the refund alone, and claiming exactly that must go through
    ///      and pay what the ledger keeps. The first vault and lapsed controller from the seeds with such an offer.
    function vault_lapsedClaimsWhatMaxOffers(uint256 actorSeed, uint256 vaultSeed, bool isDeposit)
        public
        updateGhosts(OpType.USER)
    {
        if (_overReserved()) return;
        for (uint256 v; v < vaults.length; v++) {
            IAsyncVault vault = vaults[_vaultIndex(vaultSeed + v)];
            for (uint256 a; a < actors.length; a++) {
                address actor = _actor(actorSeed + a);
                if (frozen[actor] || _claimOpen(vault, actor)) continue;
                uint256 max = isDeposit ? vault.maxMint(actor) : vault.maxRedeem(actor);
                if (max == 0 || (isDeposit ? vault.claimableMint(actor) : vault.claimableWithdraw(actor)) == 0) {
                    continue;
                }
                uint256 before = isDeposit ? shareA.balanceOf(actor) : usdc.balanceOf(actor);
                _feeNoInstantInCall = true;
                (bool success,) = _boundedCall(
                    actor,
                    address(vault),
                    isDeposit
                        ? abi.encodeWithSignature("mint(uint256,address,address)", max, actor, actor)
                        : abi.encodeWithSignature("redeem(uint256,address,address)", max, actor, actor),
                    "a refund-only claim cost more gas than the ceiling"
                );
                t(success, "a lapsed controller could not claim what max offered");
                if (success) {
                    uint256 afterBal = isDeposit ? shareA.balanceOf(actor) : usdc.balanceOf(actor);
                    t(afterBal >= before, "a refund-only claim lowered the balance");
                    _addClaimed(
                        address(vault), actor, isDeposit ? afterBal - before : 0, isDeposit ? 0 : afterBal - before
                    );
                    _ok("vault_lapsedClaimsWhatMaxOffers");
                }
                return;
            }
        }
    }

    //----------------------------------------------------------------------------------------------
    // Observer, direct pause, extra gas
    //----------------------------------------------------------------------------------------------

    /// @dev Replaces the pool's hub-side request observer with a counting one, or with none: the slot the stranded
    ///      deposit recovery goes through.
    function hub_setObserver(bool installed) public updateGhosts(OpType.MANAGER) {
        _managerCall(
            poolA,
            address(orderBook),
            abi.encode(uint8(OrderBookAction.SetObserver), installed ? address(requestObserver) : address(0))
        );
        _ok("hub_setObserver");
    }

    /// @dev A spoke manager can pause the oracle at once, without the hub; anyone else is refused.
    function oracle_pauseDirect(uint256 callerSeed) public updateGhosts(OpType.MANAGER) {
        address caller = callerSeed % 3 == 0 ? OUTSIDER : callerSeed % 3 == 1 ? BSM : AUX_MANAGER;
        bool manager = spokeRegistry.manager(poolA, caller);
        (bool success,) = _callAs(caller, address(spokeOracle), abi.encodeCall(spokeOracle.pause, (poolA)));
        t(success == manager, "the oracle was paused by a non-manager or refused its manager");
        if (success) _ok("oracle_pauseDirect");
    }

    /// @dev Sets the gas the pool funds for the observer the request message runs.
    function hub_setExtraGas(uint128 gas) public updateGhosts(OpType.MANAGER) {
        _managerCall(poolA, address(vaultRouter), abi.encode(uint128(between(gas, 0, 5_000_000))));
        _ok("hub_setExtraGas");
    }

    //----------------------------------------------------------------------------------------------
    // Investor router: the instant deposit, a batch and the permit
    //----------------------------------------------------------------------------------------------

    /// @dev A deposit through the router on an instant vault: the router pays from the investor and the vault credits
    ///      the receiver, whom the hook checks for the investor, not the router.
    function router_deposit(uint256 actorSeed, uint256 receiverSeed, uint256 amount) public updateGhosts(OpType.USER) {
        IAsyncVault vault = vaults[2];
        address actor = _actor(actorSeed);
        address receiver = _actor(receiverSeed);
        uint256 balance = usdc.balanceOf(actor);
        if (frozen[actor] || balance == 0 || !_oracleValid() || _inAsync(vault, actor, true)) return;
        amount = between(amount, 1, balance);
        vm.prank(actor);
        usdc.approve(address(investorRouter), amount);
        (bool success,) = _callAs(
            actor, address(investorRouter), abi.encodeCall(investorRouter.deposit, (vault, amount, receiver, actor))
        );
        if (success) {
            t(!frozen[actor] && !frozen[receiver], "the router deposited for a frozen account");
            _ok("router_deposit");
        } else {
            _reverted("router_deposit");
        }
    }

    /// @dev Two requests in one multicall, then a permit that is allowed to fail.
    function router_batch(uint256 actorSeed, uint256 amount) public updateGhosts(OpType.USER) {
        IAsyncVault vault = vaults[0];
        address actor = _actor(actorSeed);
        uint256 balance = usdc.balanceOf(actor);
        if (frozen[actor] || balance < 2) return;
        amount = between(amount, 1, balance / 2);
        vm.prank(actor);
        vault.setOperator(address(investorRouter), true);
        vm.prank(actor);
        usdc.approve(address(vault), 2 * amount);
        uint128[64] memory held = _held(vault, actor);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(investorRouter.requestDeposit, (vault, amount, actor, actor));
        calls[1] = abi.encodeCall(investorRouter.requestDeposit, (vault, amount, actor, actor));
        calls[2] = abi.encodeCall(investorRouter.permit, (address(usdc), address(vault), amount, 0, 0, 0, 0));
        uint256[10] memory fold = _beforeFold(0);
        (bool success,) = _callAs(actor, address(investorRouter), abi.encodeCall(investorRouter.multicall, (calls)));
        if (!success) return _reverted("router_batch");
        _noteSurfaced(0, fold);
        _trackGrowth(vault, actor, held, true);
        _ok("router_batch");
    }

    /// @dev What the controller holds in each of the first 64 local ids, before a request the router relays.
    function _held(IAsyncVault vault, address actor) internal view returns (uint128[64] memory held) {
        for (uint96 id = 1; id <= 64; id++) {
            held[id - 1] = vault.contribution(id, actor).amount;
        }
    }

    /// @dev The router answers no request id, so what it requested is found by what the controller's contributions
    ///      grew by, and recorded as the vault's own handlers record theirs.
    function _trackGrowth(IAsyncVault vault, address actor, uint128[64] memory held, bool isDeposit) internal {
        for (uint96 id = 1; id <= 64; id++) {
            uint128 grew = vault.contribution(id, actor).amount - held[id - 1];
            if (grew != 0) {
                _onRequest(0, RequestId.unwrap(VaultRequestIdLib.from(address(vault), id)), actor, isDeposit, grew);
            }
        }
    }
}
