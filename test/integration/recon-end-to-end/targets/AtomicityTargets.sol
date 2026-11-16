// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MultiRequestTargets} from "./MultiRequestTargets.sol";

import {AccountId} from "../../../../src/core/types/AccountId.sol";
import {RequestId} from "../../../../src/core/types/RequestId.sol";
import {IEscrow} from "../../../../src/core/spoke/interfaces/IEscrow.sol";

import {RequestCallbackMessageLib} from "../../../../src/vaults/messaging/libraries/RequestCallbackMessageLib.sol";

import {BucketReference} from "../../../vaults/BucketReference.sol";

import {OrderBookAction} from "../../../../src/vaults/hub/interfaces/IOrderBook.sol";
import {VaultRequestIdLib} from "../../../../src/vaults/libraries/VaultRequestIdLib.sol";
import {IAsyncVault, REASON_REDEEM} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";

/// @notice A hub callback or a request that cannot be applied leaves nothing behind, so a retry meets exactly the state
///         that was there before.
/// @dev    Under Foundry a failed call is atomic by itself; the property is for code that catches and carries on, or
///         that writes state before a call it then swallows, and is held by what a refusal leaves of the pool's
///         observable state (`_atomicFingerprint`). Every case is one the stack must refuse, so a call that goes
///         through is a failure of its own, and a refusal is then compared against the state before it. The cases:
///           - a fill or a cancellation larger than the order, a request id no order was ever opened for, and a
///             redemption fill the escrow's cash cannot cover (the callback reverts, retryable once it is refunded);
///           - the router applying a callback whose last leg the vault refuses, after the legs before it released a
///             reservation, minted or burnt shares, or reserved a payout in the same call;
///           - a stranger calling the vault's callbacks or the router's;
///           - a request whose flush the hub-side observer refuses, after the vault took the assets or shares and
///             booked the request.
///         The stack catches no revert on these paths (the settlement and request observers are called plainly, and
///         the gateway's catch applies only to messages from another network), so a trace left behind is a catch added.
abstract contract AtomicityTargets is MultiRequestTargets {
    uint256 internal constant ATOMIC_KINDS = 7;
    /// @dev The requests the fingerprint reads, so its cost stays flat as the fuzzer opens more.
    uint256 internal constant FINGERPRINT_REQUESTS = 24;

    function atomic_refusedCallback(uint256 reqSeed, uint256 kindSeed, uint256 amountSeed)
        public
        updateGhosts(OpType.MANAGER)
    {
        uint256 kind = kindSeed % ATOMIC_KINDS;
        if (kind == 0) _atomicOverFill(reqSeed, amountSeed);
        else if (kind == 1) _atomicOverCancel(reqSeed, amountSeed);
        else if (kind == 2) _atomicUnknownRequest(reqSeed, amountSeed);
        else if (kind == 3) _atomicUncoveredPayout(reqSeed, amountSeed);
        else if (kind == 4) _atomicRouterLeg(reqSeed, amountSeed);
        else if (kind == 5) _atomicStranger(reqSeed, amountSeed);
        else _atomicRefusedFlush(reqSeed, amountSeed);
    }

    //----------------------------------------------------------------------------------------------
    // Cases
    //----------------------------------------------------------------------------------------------

    function _atomicOverFill(uint256 reqSeed, uint256 amountSeed) internal {
        (Req memory r, uint128 outstanding) = _pickOrder(reqSeed, false);
        if (outstanding == 0) return;
        bytes32 before = _atomicFingerprint();
        bool success = _fulfill(r, outstanding + 1 + uint128(amountSeed % 1e9));
        _atomicRefused("atomic_overFill", before, success);
    }

    function _atomicOverCancel(uint256 reqSeed, uint256 amountSeed) internal {
        (Req memory r, uint128 outstanding) = _pickOrder(reqSeed, false);
        if (outstanding == 0) return;
        bytes32 before = _atomicFingerprint();
        bool success = _cancel(r, outstanding + 1 + uint128(amountSeed % 1e9));
        _atomicRefused("atomic_overCancel", before, success);
    }

    /// @dev An id in a range the vault's counter never reaches.
    function _atomicUnknownRequest(uint256 reqSeed, uint256 amountSeed) internal {
        uint8 v = uint8(reqSeed % vaults.length);
        uint256 id = VaultRequestIdLib.from(address(vaults[v]), uint96((1 << 40) + amountSeed % 1e6)).raw();
        Req memory r = Req(v, id, amountSeed / 1e6 % 2 == 0);
        bytes32 before = _atomicFingerprint();
        bool success = amountSeed / 2e6 % 2 == 0 ? _fulfill(r, _dust(r.isDeposit)) : _cancel(r, 1);
        _atomicRefused("atomic_unknownRequest", before, success);
    }

    /// @dev A redemption whose payout the escrow's unreserved cash does not cover, which the vault refuses until the
    ///      pool refunds the escrow. The margin keeps a conversion that differs by a unit out of it.
    function _atomicUncoveredPayout(uint256 reqSeed, uint256 amountSeed) internal {
        if (!_pricesLive()) return;
        IEscrow escrow = _escrow(poolA);
        (uint128 total,) = escrow.holding(scA, address(usdc), 0);
        for (uint256 i; i < reqs.length; i++) {
            Req memory r = reqs[(reqSeed + i) % reqs.length];
            uint128 outstanding = _outstanding(r);
            if (r.isDeposit || outstanding < _dust(false)) continue;
            uint128 fill = uint128(between(amountSeed, _dust(false), outstanding));
            uint128 owed = uint128(escrow.reservedBy(scA, address(vaults[r.vault]), REASON_REDEEM, address(usdc), 0));
            if (total + 2 >= owed + _fillOutput(false, fill)) continue;
            bytes32 before = _atomicFingerprint();
            bool success = _fulfill(r, fill);
            return _atomicRefused("atomic_uncoveredPayout", before, success);
        }
    }

    /// @dev The router applies a callback to a vault leg by leg. One that settles more than the bucket holds is
    ///      refused at its last leg, after the first ones released, minted, burnt or reserved: none of it may stay.
    function _atomicRouterLeg(uint256 reqSeed, uint256 amountSeed) internal {
        if (reqs.length == 0) return;
        Req memory r = reqs[reqSeed % reqs.length];
        uint128 over =
            BucketReference.outstanding(vaults[r.vault].bucket(uint96(r.requestId))) + 1 + uint128(amountSeed % 1e12);
        bytes memory payload = _overSettled(r, over, 1 + uint128(amountSeed / 1e12 % 1e12), amountSeed / 1e24 % 2 == 0);
        bytes32 before = _atomicFingerprint();
        (bool success,) = _callAs(
            address(spokeHandler),
            address(vaultRouter),
            abi.encodeCall(vaultRouter.callback, (poolA, scA, usdcId, payload))
        );
        _atomicRefused("atomic_routerLeg", before, success);
    }

    function _overSettled(Req memory r, uint128 over, uint128 other, bool settles)
        internal
        pure
        returns (bytes memory)
    {
        uint128 net = other < over ? other : over;
        if (r.isDeposit) {
            return settles
                ? RequestCallbackMessageLib.serialize(
                    RequestCallbackMessageLib.SettledDeposit(RequestId.wrap(r.requestId), over, other)
                )
                : RequestCallbackMessageLib.serialize(
                    RequestCallbackMessageLib.CancelledDeposit(RequestId.wrap(r.requestId), over, net)
                );
        }
        return settles
            ? RequestCallbackMessageLib.serialize(
                RequestCallbackMessageLib.SettledRedeem(RequestId.wrap(r.requestId), other, over)
            )
            : RequestCallbackMessageLib.serialize(
                RequestCallbackMessageLib.CancelledRedeem(RequestId.wrap(r.requestId), over, net)
            );
    }

    /// @dev One of the vault's seven callbacks, or the router's, from an account that is not the request manager.
    function _atomicStranger(uint256 reqSeed, uint256 amountSeed) internal {
        Req memory r = reqs.length == 0 ? Req(0, 1, true) : reqs[reqSeed % reqs.length];
        address vault = address(vaults[r.vault]);
        address caller = amountSeed % 2 == 0 ? OUTSIDER : actors[amountSeed / 2 % actors.length];
        uint96 localId = uint96(r.requestId);
        uint128 amount = uint128(1 + amountSeed / 4 % 1e9);
        uint256 shape = amountSeed / 1e9 % 8;
        bytes memory data = shape == 0
            ? abi.encodeWithSignature("approveDeposits(uint96,uint128)", localId, amount)
            : shape == 1
                ? abi.encodeWithSignature("issueShares(uint96,uint128)", localId, amount)
                : shape == 2
                    ? abi.encodeWithSignature("fulfillDepositRequest(uint96,uint128,uint128)", localId, amount, amount)
                    : shape == 3
                        ? abi.encodeWithSignature("cancelDeposit(uint96,uint128,uint128)", localId, amount, amount)
                        : shape == 4
                            ? abi.encodeWithSignature("revokeShares(uint96,uint128,uint128)", localId, amount, amount)
                            : shape == 5
                                ? abi.encodeWithSignature(
                                    "fulfillRedeemRequest(uint96,uint128,uint128)", localId, amount, amount
                                )
                                : shape == 6
                                    ? abi.encodeWithSignature(
                                        "cancelRedeem(uint96,uint128,uint128)", localId, amount, amount
                                    )
                                    : abi.encodeCall(
                                        vaultRouter.callback,
                                        (poolA, scA, usdcId, _overSettled(r, amount, amount, true))
                                    );
        address target = shape == 7 ? address(vaultRouter) : vault;
        bytes32 before = _atomicFingerprint();
        (bool success,) = _callAs(caller, target, data);
        _atomicRefused("atomic_stranger", before, success);
    }

    /// @dev The hub-side request observer refuses: the deposit request has taken the investor's assets, escrowed and
    ///      reserved them and booked the request before it flushes, and the flush reaches the observer last. The
    ///      pool's own observer is put back after.
    function _atomicRefusedFlush(uint256 actorSeed, uint256 amountSeed) internal {
        IAsyncVault vault = vaults[0];
        address actor = _unfrozen(actorSeed);
        uint256 balance = usdc.balanceOf(actor);
        if (balance < _dust(true) || !_healthy(vault, actor)) return;
        uint256 amount = between(amountSeed, _dust(true), balance);
        address previous = address(orderBook.observer(poolA));
        vm.prank(actor);
        usdc.approve(address(vault), amount);
        _atomicSetObserver(address(refusingObserver));

        bytes32 before = _atomicFingerprint();
        (bool success,) = _callAs(actor, address(vault), abi.encodeCall(vault.requestDeposit, (amount, actor, actor)));
        _atomicRefused("atomic_refusedFlush", before, success);
        _atomicSetObserver(previous);
    }

    function _atomicSetObserver(address observer) internal {
        _managerCall(poolA, address(orderBook), abi.encode(uint8(OrderBookAction.SetObserver), observer));
    }

    //----------------------------------------------------------------------------------------------
    // Judgement
    //----------------------------------------------------------------------------------------------

    function _atomicRefused(bytes32 action, bytes32 before, bool success) internal {
        t(!success, "a callback or request that cannot be applied went through");
        if (success) return;
        t(_atomicFingerprint() == before, "a refused callback or request left a trace");
        _ok(action);
    }

    /// @dev Every view of pool A a refused call could have half applied, folded into one hash: the escrow's holding,
    ///      balances and reservations, the spoke's queued deltas, the hub's holding and accounts, the supply, and per
    ///      vault and controller the request and claimable ledgers, the investors' balances, and per tracked request
    ///      the bucket, the order, the deposit reservation and each contribution. A view that reverts hashes as such.
    function _atomicFingerprint() internal view returns (bytes32 acc) {
        IEscrow escrow = _escrow(poolA);
        acc = _read(acc, address(escrow), abi.encodeCall(escrow.holding, (scA, address(usdc), 0)));
        acc = _read(acc, address(usdc), abi.encodeCall(usdc.balanceOf, (address(escrow))));
        acc = _read(acc, address(shareA), abi.encodeCall(shareA.balanceOf, (address(escrow))));
        acc = _read(acc, address(shareA), abi.encodeCall(shareA.totalSupply, ()));
        acc = _read(acc, address(snapshotQueue), abi.encodeCall(snapshotQueue.queuedShares, (poolA, scA)));
        acc = _read(acc, address(snapshotQueue), abi.encodeCall(snapshotQueue.queuedAssets, (poolA, scA, usdcId)));
        acc = _read(acc, address(holdings), abi.encodeCall(holdings.amount, (poolA, scA, usdcId)));
        acc = _read(acc, address(holdings), abi.encodeCall(holdings.value, (poolA, scA, usdcId)));
        acc = _read(
            acc, address(shareClassManager), abi.encodeCall(shareClassManager.issuance, (poolA, scA, CENTRIFUGE_ID))
        );
        AccountId[4] memory accts = _accounts();
        for (uint256 i; i < 4; i++) {
            acc = _read(acc, address(accounting), abi.encodeCall(accounting.accounts, (poolA, accts[i])));
        }
        for (uint256 a; a < actors.length; a++) {
            acc = _read(acc, address(usdc), abi.encodeCall(usdc.balanceOf, (actors[a])));
            acc = _read(acc, address(shareA), abi.encodeCall(shareA.balanceOf, (actors[a])));
        }
        for (uint256 v; v < vaults.length; v++) {
            acc = _atomicVault(acc, vaults[v], escrow);
        }
        uint256 n = reqs.length < FINGERPRINT_REQUESTS ? reqs.length : FINGERPRINT_REQUESTS;
        for (uint256 i; i < n; i++) {
            acc = _atomicRequest(acc, reqs[i], escrow);
        }
    }

    function _atomicVault(bytes32 acc, IAsyncVault vault, IEscrow escrow) internal view returns (bytes32) {
        acc = _read(
            acc,
            address(escrow),
            abi.encodeCall(escrow.reservedBy, (scA, address(vault), REASON_REDEEM, address(usdc), 0))
        );
        for (uint256 a; a < actors.length; a++) {
            acc = _read(acc, address(vault), abi.encodeCall(vault.pendingDepositRequest, (0, actors[a])));
            acc = _read(acc, address(vault), abi.encodeCall(vault.pendingRedeemRequest, (0, actors[a])));
            acc = _read(acc, address(vault), abi.encodeCall(vault.claimableDepositRequest, (0, actors[a])));
            acc = _read(acc, address(vault), abi.encodeCall(vault.claimableRedeemRequest, (0, actors[a])));
            acc = _read(acc, address(vault), abi.encodeCall(vault.claimableMint, (actors[a])));
            acc = _read(acc, address(vault), abi.encodeCall(vault.claimableWithdraw, (actors[a])));
        }
        return acc;
    }

    function _atomicRequest(bytes32 acc, Req memory r, IEscrow escrow) internal view returns (bytes32) {
        IAsyncVault vault = vaults[r.vault];
        uint96 localId = uint96(r.requestId);
        acc = _read(acc, address(vault), abi.encodeCall(vault.bucket, (localId)));
        acc = _read(
            acc,
            address(orderBook),
            r.isDeposit
                ? abi.encodeCall(orderBook.depositOrders, (poolA, scA, usdcId, RequestId.wrap(r.requestId)))
                : abi.encodeCall(orderBook.redeemOrders, (poolA, scA, usdcId, RequestId.wrap(r.requestId)))
        );
        acc = _read(
            acc,
            address(escrow),
            abi.encodeCall(escrow.reservedBy, (scA, address(vault), _depositReason(localId), address(usdc), 0))
        );
        for (uint256 a; a < actors.length; a++) {
            acc = _read(acc, address(vault), abi.encodeCall(vault.contribution, (localId, actors[a])));
        }
        return acc;
    }
}
