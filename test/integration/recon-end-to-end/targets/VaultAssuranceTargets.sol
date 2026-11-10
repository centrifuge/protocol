// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StandardsTargets} from "./StandardsTargets.sol";

import {IERC20} from "../../../../src/misc/interfaces/IERC20.sol";

import {IAsyncVault, IVaultErrors} from "../../../../src/vaults/interfaces/IAsyncVault.sol";
import {IReserveInstantPolicy} from "../../../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";

/// @notice What the standards ask of a vault that no single call exposes: the `max*` views related to the previews
///         and to each other in every state, the lanes that must read zero when shut, the instant lane's exact legs
///         for a receiver that is not the caller, a claim that must leave the ledger exactly as it paid, operators
///         and allowance holders acting for owners that are neither, and a donation that must change nothing a vault
///         quotes. A hybrid vault is held to ERC-4626 on its instant side and to ERC-7540 on its async side: the
///         4626 rounding rules are asked of the two instant vaults only, and a preview that must revert only of the
///         vaults with no instant lane.
abstract contract VaultAssuranceTargets is StandardsTargets {
    //----------------------------------------------------------------------------------------------
    // max* in every state
    //----------------------------------------------------------------------------------------------

    /// @dev ERC-4626: a reported maximum is something that can be done, in every state and not only where
    ///      `vault_maxExecutes` is drawn with the actor, vault, fee and balance that expose it. For an account on the
    ///      instant lane of a vault that is open to it, on a valid price: a `maxDeposit` mints something, a `maxMint`
    ///      is quoted and costs no more than `maxDeposit` offers, and a `maxWithdraw` is quoted at no more shares
    ///      than the holder has and no more than the whole holding redeems for. `maxRedeem` itself is
    ///      `property_maxRedeemIsRedeemable`, which this relates to `maxWithdraw`.
    function property_maxViewsAreExecutable() public {
        if (!_oracleValid()) return;
        for (uint256 v = 2; v < 4; v++) {
            IAsyncVault vault = vaults[v];
            for (uint256 i; i < actors.length; i++) {
                address actor = actors[i];
                if (frozen[actor] || !_healthy(vault, actor)) continue;
                if (!_inAsync(vault, actor, true)) _depositSideIsExecutable(vault, actor);
                if (!_inAsync(vault, actor, false)) _redeemSideIsExecutable(vault, actor);
            }
        }
    }

    function _depositSideIsExecutable(IAsyncVault vault, address actor) internal {
        uint256 deposit = vault.maxDeposit(actor);
        uint256 mint = vault.maxMint(actor);
        if (deposit != 0) {
            (bool ok, uint256 shares) = _asQuote(vault, actor, vault.previewDeposit.selector, deposit);
            t(ok && shares != 0, "maxDeposit offered assets whose preview mints nothing");
        }
        if (mint != 0) {
            t(deposit != 0, "maxMint offered shares while maxDeposit offered no assets");
            (bool ok, uint256 cost) = _asQuote(vault, actor, vault.previewMint.selector, mint);
            t(ok, "maxMint offered shares whose preview refused");
            lte(cost, deposit, "maxMint costs more than maxDeposit offers");
        }
    }

    function _redeemSideIsExecutable(IAsyncVault vault, address actor) internal {
        uint256 withdraw = vault.maxWithdraw(actor);
        uint256 redeem = vault.maxRedeem(actor);
        uint256 held = shareA.balanceOf(actor);
        if (redeem != 0) {
            t(withdraw != 0, "maxRedeem offered shares while maxWithdraw offered no assets");
            (bool ok, uint256 payout) = _asQuote(vault, actor, vault.previewRedeem.selector, redeem);
            t(ok, "maxRedeem offered shares whose preview refused");
            lte(payout, withdraw, "maxRedeem pays more than maxWithdraw offers");
        }
        if (withdraw != 0) {
            (bool ok, uint256 burned) = _asQuote(vault, actor, vault.previewWithdraw.selector, withdraw);
            t(ok && burned != 0, "maxWithdraw offered assets whose preview burns nothing");
            lte(burned, held, "maxWithdraw burns more shares than the holder has");
            (bool okAll, uint256 whole) = _asQuote(vault, actor, vault.previewRedeem.selector, held);
            t(okAll, "previewRedeem refused the whole holding");
            lte(withdraw, whole, "maxWithdraw offers more than the whole holding redeems for");
        }
    }

    /// @dev A view as `who`, for the views that read the caller.
    function _asQuote(IAsyncVault vault, address who, bytes4 selector, uint256 amount)
        internal
        returns (bool, uint256)
    {
        vm.prank(who);
        return _staticQuote(address(vault), selector, amount);
    }

    /// @dev ERC-4626: a lane that is shut offers nothing. A frozen account is offered nothing on any vault, an async
    ///      claim included, since every claim passes the hook. On the instant lane of a vault, for an account with
    ///      nothing claimable or pending on that side: no `max*` on an unlinked vault, none for a lapsed member, none
    ///      for deposits against a closed reserve, none for redemptions with the lane closed, gated against the
    ///      account, or with no shares to redeem. A vault with no instant lane offers none at all.
    function property_maxIsZeroWhenTheLaneIsShut() public {
        for (uint256 v; v < vaults.length; v++) {
            IAsyncVault vault = vaults[v];
            bool instant = address(vault.instantPolicy()) == address(reserveInstantPolicy);
            (,,, bool redeemEnabled,, bool gatedRedeem, uint128 maxReserve) =
                reserveInstantPolicy.config(address(vault));
            for (uint256 i; i < actors.length; i++) {
                address actor = actors[i];
                bool depositShut = frozen[actor] || !_isMember(actor) || vaultUnlinked[address(vault)] || !instant
                    || (maxReserve == 0);
                bool redeemShut = frozen[actor] || !_isMember(actor) || vaultUnlinked[address(vault)] || !instant
                    || !redeemEnabled
                    || (gatedRedeem
                        && !reserveInstantPolicy.isAllowed(
                            address(vault), IReserveInstantPolicy.ConfigKind.Redeemer, actor
                        )) || shareA.balanceOf(actor) == 0;
                if (frozen[actor]) {
                    // Frozen: shut in whatever mode, a claim included
                    eq(
                        _maxSum(vault, actor, true) + _maxSum(vault, actor, false),
                        0,
                        "a frozen account was offered max"
                    );
                    continue;
                }
                if (depositShut && !_inAsync(vault, actor, true)) {
                    eq(_maxSum(vault, actor, true), 0, "a shut deposit lane offered a maximum");
                }
                if (redeemShut && !_inAsync(vault, actor, false)) {
                    eq(_maxSum(vault, actor, false), 0, "a shut redeem lane offered a maximum");
                }
            }
        }
    }

    function _maxSum(IAsyncVault vault, address actor, bool isDeposit) internal view returns (uint256) {
        return
            isDeposit
                ? vault.maxDeposit(actor) + vault.maxMint(actor)
                : vault.maxWithdraw(actor) + vault.maxRedeem(actor);
    }

    function _isMember(address who) internal view returns (bool member) {
        (member,) = fullRestrictions.isMember(address(shareA), who);
    }

    //----------------------------------------------------------------------------------------------
    // Previews by lane
    //----------------------------------------------------------------------------------------------

    /// @dev ERC-7540 against ERC-4626 on a hybrid: a vault with no instant lane has no previews, all four revert for an
    ///      account with nothing to claim, and a vault with one answers them on a valid price, at the smallest and a
    ///      common amount in each unit, which a spurious revert would hide from the rounding checks that skip it.
    function property_previewsFollowTheLane() public {
        for (uint256 v; v < vaults.length; v++) {
            IAsyncVault vault = vaults[v];
            bool instant = address(vault.instantPolicy()) != address(0);
            if (!instant) {
                _previewsRefuse(vault);
                continue;
            }
            if (!_oracleValid()) continue;
            uint256[2] memory assets = [uint256(1), 1e6];
            uint256[2] memory shares = [uint256(1), 1e18];
            for (uint256 i; i < 2; i++) {
                (bool okD,) = _probe(vault, vault.previewDeposit.selector, assets[i]);
                (bool okW,) = _probe(vault, vault.previewWithdraw.selector, assets[i]);
                (bool okM,) = _probe(vault, vault.previewMint.selector, shares[i]);
                (bool okR,) = _probe(vault, vault.previewRedeem.selector, shares[i]);
                t(okD && okW && okM && okR, "an instant vault's preview refused on a valid price");
            }
        }
    }

    function _previewsRefuse(IAsyncVault vault) internal {
        bytes4[4] memory previews = [
            vault.previewDeposit.selector,
            vault.previewMint.selector,
            vault.previewWithdraw.selector,
            vault.previewRedeem.selector
        ];
        for (uint256 i; i < previews.length; i++) {
            (bool ok,) = _probe(vault, previews[i], 1e6);
            t(!ok, "a vault with no instant lane answered a preview");
        }
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7575 share side
    //----------------------------------------------------------------------------------------------

    /// @dev The share token answers ERC-165 for ERC-7575 and rejects the invalid id, its `vault(asset)` pointer is
    ///      unset or one of the pool's vaults for this asset (the pointer follows `SetVault`, not the link, so it may
    ///      name an unlinked one), and a vault is linked in the registry exactly as the pool left it.
    function property_shareTokenIdentity() public {
        t(shareA.supportsInterface(0x01ffc9a7), "the share token does not support ERC-165");
        t(!shareA.supportsInterface(0xffffffff), "the share token accepted the invalid ERC-165 id");
        t(shareA.supportsInterface(0xf815c03d), "the share token does not advertise ERC-7575");

        address pointed = shareA.vault(address(usdc));
        bool known = pointed == address(0);
        for (uint256 v; v < vaults.length; v++) {
            IAsyncVault vault = vaults[v];
            if (address(vault) == pointed) known = true;
            eq(
                uint256(spokeRegistry.vaultDetails(address(vault)).isLinked ? 1 : 0),
                vaultUnlinked[address(vault)] ? 0 : 1,
                "a vault's link in the registry is not what the pool left it"
            );
        }
        t(known, "the share token's vault for the asset is not one of the pool's");
        if (pointed != address(0)) {
            eq(uint256(uint160(IAsyncVault(pointed).share())), uint256(uint160(address(shareA))), "pointed share moved");
            eq(uint256(uint160(IAsyncVault(pointed).asset())), uint256(uint160(address(usdc))), "pointed asset moved");
        }
    }

    //----------------------------------------------------------------------------------------------
    // Over the maximum, and at zero
    //----------------------------------------------------------------------------------------------

    /// @dev ERC-4626: a call past the maximum reverts, and where the maximum is zero the lane refuses the smallest
    ///      call. On an instant vault, for an account whose 2-argument call would take the instant lane (nothing
    ///      claimable or pending on the side), whatever the account's state, since a call that goes through where
    ///      the view reported nothing, or above what it reported, is the mirror of the bug a `max*` that is too high
    ///      is. `kind` picks deposit, mint, withdraw or redeem. A redemption's cap is on the assets, so one share past
    ///      `maxRedeem` can floor to the same payout (`SPECIFICATION.md` marks it `n`): it is pushed past by two
    ///      assets' worth of shares. A redemption at zero is tried by assets only, since `redeem(1)` pays nothing.
    function vault_overMaxRefused(uint256 actorSeed, bool basinVault, uint8 kind) public updateGhosts(OpType.USER) {
        IAsyncVault vault = vaults[basinVault ? 3 : 2];
        bool isDeposit = kind % 2 == 0;
        bool flag = kind / 2 % 2 == 1;
        address actor = _instantActor(actorSeed, vault, isDeposit);
        if (_inAsync(vault, actor, isDeposit)) return;

        uint256 max = isDeposit
            ? (flag ? vault.maxMint(actor) : vault.maxDeposit(actor))
            : (flag ? vault.maxWithdraw(actor) : vault.maxRedeem(actor));
        if (max >= type(uint64).max) return;

        uint256 amount = 1;
        if (max != 0) amount = !isDeposit && !flag ? _pastRedeemMax(vault, actor, max) : max + 1;
        else if (!isDeposit && !flag) return;
        // A redemption that pays no more than `maxWithdraw` is within the cap, however many shares it burns: a holder
        // whose whole balance is worth the capacity is served one share past a rounded-down `maxRedeem`
        if (!isDeposit && !flag) {
            try vault.previewRedeem(amount) returns (uint256 payout) {
                if (payout <= vault.maxWithdraw(actor)) return;
            } catch {}
        }
        if (isDeposit) {
            // Whatever the account holds, the call must not be refused for the want of it
            usdc.mint(actor, 2 * vault.maxDeposit(actor) + amount + 1e9);
            vm.prank(actor);
            usdc.approve(address(vault), type(uint256).max);
        }
        (bool success,) = _callAs(actor, address(vault), _instantCall(actor, amount, flag, isDeposit));
        if (isDeposit) {
            vm.prank(actor);
            usdc.approve(address(vault), 0);
        }
        t(
            !success,
            max != 0
                ? "an instant call above the maximum went through"
                : "an instant call at a zero maximum went through"
        );
        _ok("vault_overMaxRefused");
    }

    /// @dev Shares that pay out more than `maxWithdraw`: `maxRedeem` rounds the capacity down to a share, so the share
    ///      just past it can pay exactly the capacity, which the lane serves. A share worth many assets needs the
    ///      conversion of the capacity itself, not of two assets.
    function _pastRedeemMax(IAsyncVault vault, address actor, uint256 maxShares) internal view returns (uint256) {
        uint256 byAssets = vault.convertToShares(vault.maxWithdraw(actor) + 2) + 1;
        uint256 byShares = maxShares + vault.convertToShares(2) + 1;
        return byAssets > byShares ? byAssets : byShares;
    }

    //----------------------------------------------------------------------------------------------
    // The instant lane for a receiver
    //----------------------------------------------------------------------------------------------

    /// @dev ERC-4626 on the instant lane with a receiver that may be another account: each leg moves exactly what the
    ///      call says. A deposit takes `assets` from the caller and returns the shares the receiver got, a mint
    ///      returns the assets the caller paid, a withdraw pays the receiver exactly `assets` and returns the shares
    ///      burned from the caller, a redeem burns exactly `shares` and returns what the receiver was paid; the
    ///      caller's other balance and the receiver's other balance are unchanged, the preview holds as it does for
    ///      the caller, and a receiver the hook refuses or for whom `maxDeposit` is zero was not served. Under the
    ///      reserve policy only, which never rebates. `kind` picks deposit, mint, withdraw or redeem.
    function vault_instantTradeFor(uint256 actorSeed, uint256 receiverSeed, bool basinVault, uint256 amount, uint8 kind)
        public
        updateGhosts(OpType.USER)
    {
        Trade memory tr;
        tr.vault = vaults[basinVault ? 3 : 2];
        tr.isDeposit = kind % 2 == 0;
        tr.flag = kind / 2 % 2 == 1;
        tr.actor = _instantActor(actorSeed, tr.vault, tr.isDeposit);
        tr.receiver = _receiver(receiverSeed);
        if (frozen[tr.actor] || !_oracleValid() || !_healthy(tr.vault, tr.actor)) return;
        if (_inAsync(tr.vault, tr.actor, tr.isDeposit)) return;
        if (address(tr.vault.instantPolicy()) != address(reserveInstantPolicy)) return;

        uint256 max = tr.isDeposit
            ? (tr.flag ? tr.vault.maxMint(tr.actor) : tr.vault.maxDeposit(tr.actor))
            : (tr.flag ? tr.vault.maxWithdraw(tr.actor) : tr.vault.maxRedeem(tr.actor));
        if (max == 0) return;
        tr.amount = between(amount, 1, max);
        bool quoted;
        (quoted, tr.quote) = _asQuote(tr.vault, tr.actor, _previewSelector(tr.vault, tr.isDeposit, tr.flag), tr.amount);
        t(quoted, "a preview refused an amount within the maximum");
        _trade(tr);
    }

    struct Trade {
        IAsyncVault vault;
        address actor;
        address receiver;
        bool isDeposit;
        bool flag;
        uint256 amount;
        uint256 quote;
        uint256[4] before;
    }

    function _trade(Trade memory tr) internal {
        if (tr.isDeposit) {
            uint256 cost = tr.flag ? tr.quote : tr.amount;
            if (cost > usdc.balanceOf(tr.actor)) usdc.mint(tr.actor, cost - usdc.balanceOf(tr.actor));
            vm.prank(tr.actor);
            usdc.approve(address(tr.vault), type(uint256).max);
        }
        tr.before = _balances(tr.actor, tr.receiver);
        FeeProbe memory probe = _feeBegin(tr.vault, tr.actor, tr.receiver);
        bool receiverOpen = !tr.isDeposit || _maxDepositOf(tr.vault, tr.receiver) != 0;
        (bool success, bytes memory ret) =
            _callAs(tr.actor, address(tr.vault), _tradeCall(tr.receiver, tr.amount, tr.flag, tr.isDeposit));
        if (tr.isDeposit) {
            vm.prank(tr.actor);
            usdc.approve(address(tr.vault), 0);
        }
        if (!success) {
            t(_mayRefuse(tr, receiverOpen), "the instant lane refused a trade within the maximum and its quote");
            return _reverted("vault_instantTradeFor");
        }

        t(
            !frozen[tr.actor] && !frozen[tr.receiver] && _isMember(tr.receiver),
            "the instant lane served a receiver the hook refuses"
        );
        t(receiverOpen, "a deposit went through for a receiver whose maxDeposit was zero");
        _legs(tr, abi.decode(ret, (uint256)));
        _feeEnd(probe, tr.vault, tr.actor, tr.receiver, tr.amount, tr.flag, tr.isDeposit);
        _ok("vault_instantTradeFor");
    }

    /// @dev What may turn away a trade the caller's maximum and quote allow: a receiver the hook refuses or with no
    ///      room (`maxDeposit`) for the cost, a caller the lane's gate leaves out, or an amount in whose quote nothing is
    ///      left, which the fee or the rounding takes (`ExceedsDepositLimits` / `ExceedsRedeemLimits`). Beyond these
    ///      the caller's maximum and the call read the same capacity, so a refusal is a bug.
    function _mayRefuse(Trade memory tr, bool receiverOpen) internal view returns (bool) {
        if (frozen[tr.receiver] || !_isMember(tr.receiver) || !receiverOpen) return true;
        if (_gatedOut(tr)) return true;
        if (!tr.flag && tr.quote == 0) return true;
        if (tr.isDeposit && tr.receiver != tr.actor) {
            return _maxDepositOf(tr.vault, tr.receiver) < (tr.flag ? tr.quote : tr.amount);
        }
        return false;
    }

    /// @dev The lane is gated and the caller is not on it: the gate answers to the caller, which `max*` does not know.
    function _gatedOut(Trade memory tr) internal view returns (bool) {
        (,,,, bool gatedDeposit, bool gatedRedeem,) = reserveInstantPolicy.config(address(tr.vault));
        return tr.isDeposit
            ? gatedDeposit
                && !reserveInstantPolicy.isAllowed(
                    address(tr.vault), IReserveInstantPolicy.ConfigKind.Depositor, tr.actor
                )
            : gatedRedeem
                && !reserveInstantPolicy.isAllowed(
                    address(tr.vault), IReserveInstantPolicy.ConfigKind.Redeemer, tr.actor
                );
    }

    /// @dev What the receiver's own `maxDeposit` says, as read when it is not itself mid-claim: a receiver with a claim
    ///      reads its claim there, which routing, keyed to the caller, does not look at.
    function _maxDepositOf(IAsyncVault vault, address receiver) internal view returns (uint256) {
        return _inAsync(vault, receiver, true) ? 1 : vault.maxDeposit(receiver);
    }

    /// @dev The USDC and shares of the caller and of the receiver: caller assets, caller shares, receiver assets,
    ///      receiver shares.
    function _balances(address actor, address receiver) internal view returns (uint256[4] memory b) {
        b = [usdc.balanceOf(actor), shareA.balanceOf(actor), usdc.balanceOf(receiver), shareA.balanceOf(receiver)];
    }

    function _legs(Trade memory tr, uint256 returned) internal {
        uint256[4] memory b = tr.before;
        uint256[4] memory a = _balances(tr.actor, tr.receiver);
        bool same = tr.actor == tr.receiver;
        if (tr.isDeposit) {
            // The caller pays in assets and never in shares; the receiver gains the shares and no assets
            eq(b[0], a[0] + (tr.flag ? returned : tr.amount), "an instant deposit did not take exactly the assets");
            eq(a[3], b[3] + (tr.flag ? tr.amount : returned), "the receiver did not get exactly the shares minted");
            if (!same) {
                eq(a[1], b[1], "an instant deposit moved the caller's shares");
                eq(a[2], b[2], "an instant deposit moved the receiver's assets");
            }
            if (tr.flag) lte(returned, tr.quote, "previewMint quoted fewer assets than mint took");
            else gte(returned, tr.quote, "previewDeposit quoted more shares than deposit minted");
        } else {
            eq(b[1], a[1] + (tr.flag ? returned : tr.amount), "an instant redemption did not burn exactly the shares");
            eq(a[2], b[2] + (tr.flag ? tr.amount : returned), "the receiver was not paid exactly the payout");
            if (!same) {
                eq(a[0], b[0], "an instant redemption moved the caller's assets");
                eq(a[3], b[3], "an instant redemption moved the receiver's shares");
            }
            if (tr.flag) lte(returned, tr.quote, "previewWithdraw quoted fewer shares than withdraw burned");
            else gte(returned, tr.quote, "previewRedeem quoted more assets than redeem paid");
        }
    }

    function _previewSelector(IAsyncVault vault, bool isDeposit, bool flag) internal pure returns (bytes4) {
        if (isDeposit) return flag ? vault.previewMint.selector : vault.previewDeposit.selector;
        return flag ? vault.previewWithdraw.selector : vault.previewRedeem.selector;
    }

    /// @dev The 2-argument call of the lane, for any receiver: deposit, mint, withdraw or redeem.
    function _tradeCall(address receiver, uint256 amount, bool flag, bool isDeposit)
        internal
        pure
        returns (bytes memory)
    {
        if (isDeposit) {
            return flag
                ? abi.encodeWithSignature("mint(uint256,address)", amount, receiver)
                : abi.encodeWithSignature("deposit(uint256,address)", amount, receiver);
        }
        return flag
            ? abi.encodeWithSignature("withdraw(uint256,address)", amount, receiver)
            : abi.encodeWithSignature("redeem(uint256,address)", amount, receiver);
    }

    /// @dev An investor or the outsider, the accounts the hook can be asked about.
    function _receiver(uint256 seed) internal view returns (address) {
        uint256 i = seed % (actors.length + 1);
        return i == actors.length ? OUTSIDER : actors[i];
    }

    //----------------------------------------------------------------------------------------------
    // Async claims in the converted unit
    //----------------------------------------------------------------------------------------------

    /// @dev ERC-7540 prop 9 in the units `vault_claimMax` leaves out: a controller with a fulfilled position that the
    ///      hook lets claim can claim all of `maxDeposit` as assets and all of `maxRedeem` as shares, the async twin
    ///      of the `maxRedeem` that paid nothing.
    function vault_claimMaxConverted(uint256 actorSeed, uint256 vaultSeed, bool isDeposit)
        public
        updateGhosts(OpType.USER)
    {
        (IAsyncVault vault, address actor, uint256 max) = _findClaim(actorSeed, vaultSeed, isDeposit, !isDeposit);
        if (max == 0) return;
        if (isDeposit) _claimDeposit(vault, actor, max, false, true);
        else _claimRedeem(vault, actor, max, true, true);
    }

    //----------------------------------------------------------------------------------------------
    // Operators and allowance holders
    //----------------------------------------------------------------------------------------------

    /// @dev ERC-7540: an operator requests for an owner with the owner's assets or shares, crediting a controller that
    ///      is a third account. The owner pays and the operator does not, an operator needs no share allowance and
    ///      leaves it alone, and the request is tracked like any other. A request the vault refuses is counted.
    function vault_operatorRequests(
        uint256 ownerSeed,
        uint256 operatorSeed,
        uint256 controllerSeed,
        uint256 vaultSeed,
        uint256 amount,
        bool isDeposit
    ) public updateGhosts(OpType.USER) {
        OperatorRequest memory r;
        r.v = _vaultIndex(vaultSeed);
        r.vault = vaults[r.v];
        r.owner = isDeposit ? _actor(ownerSeed) : _liquidHolder(ownerSeed);
        r.operator = _actor(operatorSeed);
        r.controller = _unfrozen(controllerSeed);
        r.isDeposit = isDeposit;
        if (r.operator == r.owner || vaultUnlinked[address(r.vault)]) return;
        r.ownerBefore = isDeposit ? usdc.balanceOf(r.owner) : shareA.balanceOf(r.owner);
        if (r.ownerBefore == 0) return;
        r.amount = between(amount, 1, r.ownerBefore);
        r.allowanceBefore = shareA.allowance(r.owner, r.operator);
        r.operatorAssets = usdc.balanceOf(r.operator);
        r.operatorShares = shareA.balanceOf(r.operator);

        (bool success, bytes memory ret) = _requestAsOperator(r);
        if (!success) return _reverted("vault_operatorRequests");
        _noteSurfaced(r.v, r.fold);
        _onRequest(r.v, abi.decode(ret, (uint256)), r.controller, isDeposit, r.amount);
        eq(
            r.ownerBefore,
            (isDeposit ? usdc.balanceOf(r.owner) : shareA.balanceOf(r.owner)) + r.amount,
            "an operator's request did not take exactly the amount from the owner"
        );
        eq(usdc.balanceOf(r.operator), r.operatorAssets, "an operator's request moved its assets");
        eq(shareA.balanceOf(r.operator), r.operatorShares, "an operator's request moved its shares");
        eq(shareA.allowance(r.owner, r.operator), r.allowanceBefore, "an operator's request spent a share allowance");
        t(!frozen[r.controller] && (isDeposit || !frozen[r.owner]), "a frozen party requested through an operator");
        _ok("vault_operatorRequests");
    }

    struct OperatorRequest {
        IAsyncVault vault;
        address owner;
        address operator;
        address controller;
        uint8 v;
        bool isDeposit;
        uint256 amount;
        uint256 ownerBefore;
        uint256 allowanceBefore;
        uint256 operatorAssets;
        uint256 operatorShares;
        uint256[10] fold;
    }

    /// @dev The owner makes the caller an operator for the call only and, for assets, approves the vault for them.
    function _requestAsOperator(OperatorRequest memory r) internal returns (bool success, bytes memory ret) {
        bool wasOperator = r.vault.isOperator(r.owner, r.operator);
        vm.prank(r.owner);
        r.vault.setOperator(r.operator, true);
        if (r.isDeposit) {
            vm.prank(r.owner);
            usdc.approve(address(r.vault), r.amount);
        }
        r.fold = _beforeFold(r.v);
        (success, ret) = _callAs(
            r.operator,
            address(r.vault),
            r.isDeposit
                ? abi.encodeCall(r.vault.requestDeposit, (r.amount, r.controller, r.owner))
                : abi.encodeCall(r.vault.requestRedeem, (r.amount, r.controller, r.owner))
        );
        vm.prank(r.owner);
        r.vault.setOperator(r.operator, wasOperator);
        if (r.isDeposit) {
            vm.prank(r.owner);
            usdc.approve(address(r.vault), 0);
        }
    }

    /// @dev ERC-20 allowance on `requestRedeem`, the one place the vault honours it (ERC-4626's allowance flow for
    ///      `withdraw` and `redeem` is declined, `SPECIFICATION.md`): a spender that is no operator redeems an owner's
    ///      shares up to its allowance, spending exactly that much unless the allowance is unlimited, and is refused
    ///      above it. The controller is the owner, on a vault without an instant lane, where no sponsor rule applies.
    function vault_allowanceRequestRedeem(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 vaultSeed,
        uint256 allowance,
        uint256 amount
    ) public updateGhosts(OpType.USER) {
        address owner = _liquidHolder(ownerSeed);
        address spender = _actor(spenderSeed);
        uint8 v = _vaultIndex(vaultSeed);
        // A vault with both lanes refuses such a spender as no sponsor, which `vault_spenderRequestRedeem` covers
        if (address(vaults[v].instantPolicy()) != address(0)) return;
        if (spender == owner || vaults[v].isOperator(owner, spender) || vaultUnlinked[address(vaults[v])]) return;
        if (frozen[owner] || !_healthy(vaults[v], owner) || shareA.balanceOf(owner) == 0) return;
        uint256 balance = shareA.balanceOf(owner);
        _spend(owner, spender, v, between(allowance, 1, balance), between(amount, 1, balance));
    }

    function _spend(address owner, address spender, uint8 v, uint256 allowance, uint256 amount) internal {
        uint256 prior = shareA.allowance(owner, spender);
        vm.prank(owner);
        shareA.approve(spender, allowance);
        uint256[10] memory fold = _beforeFold(v);
        (bool success, bytes memory ret) =
            _callAs(spender, address(vaults[v]), abi.encodeCall(vaults[v].requestRedeem, (amount, owner, owner)));
        uint256 left = shareA.allowance(owner, spender);
        vm.prank(owner);
        shareA.approve(spender, prior);

        if (amount > allowance) {
            t(!success, "a spender redeemed past its allowance");
            if (!success) t(bytes4(ret) == IERC20.InsufficientAllowance.selector, "refused for another reason");
            return _ok("vault_allowanceRequestRedeem");
        }
        if (!success) return _reverted("vault_allowanceRequestRedeem");
        _noteSurfaced(v, fold);
        _onRequest(v, abi.decode(ret, (uint256)), owner, false, amount);
        eq(left + amount, allowance, "a spender's request did not spend exactly the shares it redeemed");
        _ok("vault_allowanceRequestRedeem");
    }

    /// @dev ERC-7540: an operator claims for a controller to any receiver, and the receiver gets the payout while the
    ///      controller's balances stay. The ledger shrinks by what was paid and the claim is counted for the receiver.
    ///      `kind` picks deposit, mint, withdraw or redeem. A claim the hook refuses for that receiver is counted.
    function vault_operatorClaimsForOthers(
        uint256 ownerSeed,
        uint256 operatorSeed,
        uint256 receiverSeed,
        uint256 vaultSeed,
        uint256 amount,
        uint8 kind
    ) public updateGhosts(OpType.USER) {
        OperatorClaim memory c;
        c.k = kind % 4;
        uint256 max;
        (c.vault, c.owner, max) = _findClaim(ownerSeed, vaultSeed, c.k < 2, c.k % 2 == 1);
        if (max == 0) return;
        c.operator = _actor(operatorSeed);
        c.receiver = _receiver(receiverSeed);
        if (c.operator == c.owner || c.receiver == c.owner) return;
        c.amount = between(amount, 1, max);
        _claimAsOperator(c);
    }

    struct OperatorClaim {
        IAsyncVault vault;
        address owner;
        address operator;
        address receiver;
        uint8 k;
        uint256 amount;
    }

    function _claimAsOperator(OperatorClaim memory c) internal {
        bool wasOperator = c.vault.isOperator(c.owner, c.operator);
        vm.prank(c.owner);
        c.vault.setOperator(c.operator, true);
        uint256[4] memory before = _balances(c.owner, c.receiver);
        uint256[2] memory ledger = _ledger(c.vault, c.owner, c.k < 2);
        (bool success, bytes memory ret) =
            _callAs(c.operator, address(c.vault), _claimCall(c.k, c.amount, c.receiver, c.owner));
        vm.prank(c.owner);
        c.vault.setOperator(c.operator, wasOperator);
        if (!success) return _reverted("vault_operatorClaimsForOthers");

        // What was paid, in both units: what the claim was made in is its amount, the other is what it returned
        uint256 returned = abi.decode(ret, (uint256));
        uint256 shares = c.k % 2 == 1 ? c.amount : returned;
        uint256 assets = c.k % 2 == 1 ? returned : c.amount;
        if (c.k < 2) {
            eq(shareA.balanceOf(c.receiver), before[3] + shares, "the receiver did not get the claimed shares");
            _addClaimed(address(c.vault), c.owner, shares, 0);
        } else {
            eq(usdc.balanceOf(c.receiver), before[2] + assets, "the receiver was not paid the claimed assets");
            _addClaimed(address(c.vault), c.owner, 0, assets);
        }
        eq(usdc.balanceOf(c.owner), before[0], "an operator's claim moved the controller's assets");
        eq(shareA.balanceOf(c.owner), before[1], "an operator's claim moved the controller's shares");
        _ledgerMoved(c.vault, c.owner, ledger, c.k < 2, shares, assets);
        _ok("vault_operatorClaimsForOthers");
    }

    /// @dev One of the four 3-argument claims: deposit, mint, withdraw or redeem for `controller`.
    function _claimCall(uint8 k, uint256 amount, address receiver, address controller)
        internal
        pure
        returns (bytes memory)
    {
        if (k == 0) {
            return abi.encodeWithSignature("deposit(uint256,address,address)", amount, receiver, controller);
        }
        if (k == 1) return abi.encodeWithSignature("mint(uint256,address,address)", amount, receiver, controller);
        if (k == 2) return abi.encodeWithSignature("withdraw(uint256,address,address)", amount, receiver, controller);
        return abi.encodeWithSignature("redeem(uint256,address,address)", amount, receiver, controller);
    }

    /// @dev ERC-7540, and the instant lane's rule that an operator never reaches it: an operator of a controller with
    ///      nothing claimable on a side is refused on that side's 3-argument calls, with the limit that says there is
    ///      nothing to claim, so an operator can never spend the controller's assets or shares on an instant trade.
    ///      `kind` picks deposit, mint, withdraw or redeem.
    function vault_operatorCannotTrade(
        uint256 ownerSeed,
        uint256 operatorSeed,
        uint256 vaultSeed,
        uint256 amount,
        uint8 kind
    ) public updateGhosts(OpType.USER) {
        uint8 k = kind % 4;
        IAsyncVault vault = vaults[_vaultIndex(vaultSeed)];
        address owner = _actor(ownerSeed);
        address operator = _actor(operatorSeed);
        if (operator == owner) return;
        // Nothing claimable on the side, whatever its pending or the instant lane's capacity
        uint256[2] memory ledger = _ledger(vault, owner, k < 2);
        if (ledger[0] != 0 || ledger[1] != 0) return;
        _tryToTradeAsOperator(vault, owner, operator, k, between(amount, 1, 1e12));
    }

    function _tryToTradeAsOperator(IAsyncVault vault, address owner, address operator, uint8 k, uint256 amount)
        internal
    {
        bool wasOperator = vault.isOperator(owner, operator);
        vm.prank(owner);
        vault.setOperator(operator, true);
        if (k < 2) {
            // The owner has paid the way for a purchase, so only the vault's routing keeps it from one
            if (usdc.balanceOf(owner) < amount) usdc.mint(owner, amount - usdc.balanceOf(owner));
            vm.prank(owner);
            usdc.approve(address(vault), amount);
        }
        (bool success, bytes memory ret) = _callAs(operator, address(vault), _claimCall(k, amount, operator, owner));
        vm.prank(owner);
        vault.setOperator(operator, wasOperator);
        if (k < 2) {
            vm.prank(owner);
            usdc.approve(address(vault), 0);
        }

        t(!success, "an operator traded for an owner with nothing to claim");
        t(
            bytes4(ret)
                == (k < 2 ? IVaultErrors.ExceedsDepositLimits.selector : IVaultErrors.ExceedsRedeemLimits.selector),
            "an operator was refused for another reason than nothing to claim"
        );
        _ok("vault_operatorCannotTrade");
    }

    //----------------------------------------------------------------------------------------------
    // Donation
    //----------------------------------------------------------------------------------------------

    /// @dev A direct transfer of assets to the pool's escrow, which the accounting never sees: nothing a vault quotes
    ///      or offers moves, since conversions are priced by the oracle and capacities read the accounted balance, not
    ///      the token's. The escrow's balance may then exceed its holding by what was donated
    ///      (`property_escrowBalanceMatchesHoldingTotal`).
    function vault_donate(uint256 amountSeed) public updateGhosts(OpType.USER) {
        bytes32 before = _quoteDigest();
        uint256 amount = between(amountSeed, 1, 1_000e6);
        usdc.mint(address(_escrow(poolA)), amount);
        ghost_donatedToEscrow += amount;
        t(_quoteDigest() == before, "a donation to the escrow changed what a vault quotes or offers");
        _ok("vault_donate");
    }

    /// @dev Everything an integrator reads off every vault, hashed, so a change in any is one comparison.
    function _quoteDigest() internal returns (bytes32 digest) {
        bytes4[4] memory maxes = [
            vaults[0].maxDeposit.selector,
            vaults[0].maxMint.selector,
            vaults[0].maxWithdraw.selector,
            vaults[0].maxRedeem.selector
        ];
        bytes4[4] memory previews = [
            vaults[0].previewDeposit.selector,
            vaults[0].previewMint.selector,
            vaults[0].previewWithdraw.selector,
            vaults[0].previewRedeem.selector
        ];
        for (uint256 v; v < vaults.length; v++) {
            address vault = address(vaults[v]);
            digest = keccak256(abi.encode(digest, vaults[v].totalAssets(), vaults[v].pricePerShare()));
            digest = keccak256(abi.encode(digest, vaults[v].convertToShares(1e6), vaults[v].convertToAssets(1e18)));
            for (uint256 a; a < actors.length; a++) {
                for (uint256 i; i < 4; i++) {
                    (bool ok, uint256 value) = _staticQuote(vault, maxes[i], uint256(uint160(actors[a])));
                    digest = keccak256(abi.encode(digest, ok, value));
                }
            }
            for (uint256 i; i < 4; i++) {
                (bool ok, uint256 value) = _probe(vaults[v], previews[i], i % 2 == 0 ? 1e6 : 1e18);
                digest = keccak256(abi.encode(digest, ok, value));
            }
        }
    }
}
