// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";
import {IRequestPolicy, IReserveInstantPolicy} from "../../../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

/// @notice Investor and keeper actions on pool A's vaults.
/// @dev    Inputs are clamped to what the state can take (shares held, claimable amounts, closed windows,
///         instant capacity), so a run spends its calls on the flows rather than on reverts it already
///         knows about. One call in `UNCLAMPED` keeps the raw input, so the edges stay reachable.
abstract contract VaultTargets is BaseTargetFunctions, Properties {
    uint256 internal constant UNCLAMPED = 8;

    //----------------------------------------------------------------------------------------------
    // Requests
    //----------------------------------------------------------------------------------------------

    /// @dev Whether `caller` may credit `controller` with `owner`'s assets or shares on vault `v`: the controller or its
    ///      operator always may; otherwise only a vault with an instant lane asks, and then the owner has to be a
    ///      sponsor the handlers made (`ghostSponsor`, not the policy's list) and the caller the owner or its operator.
    function _expectedCredit(uint8 v, address caller, address owner, address controller) internal view returns (bool) {
        IAsyncVault vault = vaults[v];
        if (caller == controller || vault.isOperator(controller, caller)) return true;
        if (address(vault.instantPolicy()) == address(0)) return true;
        return (caller == owner || vault.isOperator(owner, caller)) && ghostSponsor[address(vault)][owner];
    }

    /// @dev The controller may differ from the owner, which a vault with an instant lane refuses unless the owner
    ///      acts for the controller or is a sponsor of that vault's instant policy. Without one, anyone may, as in v1.
    function vault_requestDeposit(uint256 ownerSeed, uint256 controllerSeed, uint256 vaultSeed, uint256 amount)
        public
        updateGhosts(OpType.USER)
    {
        address owner = _actor(ownerSeed);
        uint256 balance = usdc.balanceOf(owner);
        if (balance == 0) return;
        _requestDeposit(owner, _actor(controllerSeed), _vaultIndex(vaultSeed), between(amount, 1, balance));
    }

    /// @dev The owner is a share holder that is not frozen, unless the call is unclamped.
    function vault_requestRedeem(uint256 ownerSeed, uint256 controllerSeed, uint256 vaultSeed, uint256 shares)
        public
        updateGhosts(OpType.USER)
    {
        bool clamped = shares % UNCLAMPED != 0;
        address owner = clamped ? _liquidHolder(ownerSeed) : _shareHolder(ownerSeed);
        address controller = clamped ? _unfrozen(controllerSeed) : _actor(controllerSeed);
        uint256 balance = shareA.balanceOf(owner);
        if (balance == 0) return;
        _requestRedeem(owner, controller, _vaultIndex(vaultSeed), between(shares, 1, balance));
    }

    function _requestDeposit(address owner, address controller, uint8 v, uint256 amount)
        internal
        siblingsUntouched(vaults[v])
        returns (bool success, uint256 requestId)
    {
        IAsyncVault vault = vaults[v];
        vm.prank(owner);
        usdc.approve(address(vault), amount);
        uint256[10] memory before = _beforeFold(v);
        vm.prank(owner);
        try vault.requestDeposit(amount, controller, owner) returns (uint256 id) {
            _noteSurfaced(v, before);
            _onRequest(v, id, controller, true, amount);
            t(!frozen[controller], "a deposit request credited a frozen controller");
            t(
                _expectedCredit(v, owner, owner, controller),
                "a deposit request credited a controller the policy forbids"
            );
            _ok("vault_requestDeposit");
            return (true, id);
        } catch {
            _reverted("vault_requestDeposit");
        }
    }

    function _requestRedeem(address owner, address controller, uint8 v, uint256 shares)
        internal
        siblingsUntouched(vaults[v])
        returns (bool success, uint256 requestId)
    {
        uint256[10] memory before = _beforeFold(v);
        vm.prank(owner);
        try vaults[v].requestRedeem(shares, controller, owner) returns (uint256 id) {
            _noteSurfaced(v, before);
            _onRequest(v, id, controller, false, shares);
            t(!frozen[owner] && !frozen[controller], "a frozen party requested a redemption");
            t(_expectedCredit(v, owner, owner, controller), "a redeem request credited a controller the policy forbids");
            _ok("vault_requestRedeem");
            return (true, id);
        } catch {
            _reverted("vault_requestRedeem");
        }
    }

    function _onRequest(uint8 v, uint256 requestId, address, bool isDeposit, uint256 amount) internal {
        _track(v, requestId, isDeposit);
        ghost_requested[address(vaults[v])][isDeposit] += amount;
    }

    /// @dev A keeper folding every actor's slice of one request: what makes positions outside a horizon claimable.
    function vault_foldRequest(uint256 reqSeed) public updateGhosts(OpType.USER) {
        if (reqs.length == 0) return;
        Req memory r = reqs[reqSeed % reqs.length];
        uint256[10] memory before = _beforeFold(r.vault);
        for (uint256 a; a < actors.length; a++) {
            if (vaults[r.vault].contribution(uint96(r.requestId), actors[a]).amount == 0) continue;
            uint256 gas0 = gasleft();
            vaults[r.vault].foldRequest(uint96(r.requestId), actors[a]);
            _boundGas(gas0 - gasleft(), "a keeper's fold cost more gas than the ceiling");
        }
        _noteSurfaced(r.vault, before);
        _ok("vault_foldRequest");
    }

    /// @dev A settled slice outside a controller's horizon enters the claimable views only when it is
    ///      folded, or when the position enters the horizon, so what that surfaces is owed too.
    ///      What surfaces is bounded independently by the settled-but-unfolded slices before the call, so
    ///      a fold that over-credits fails here rather than being counted as owed.
    function _noteSurfaced(uint8 v, uint256[10] memory before) internal {
        (uint256 sharesAfter, uint256 assetsAfter) = _claimable(v);
        address vault = address(vaults[v]);
        if (sharesAfter > before[0]) {
            lte(sharesAfter - before[0], before[2], "a fold credited more shares than settled");
            ghost_sharesOwed[vault] += sharesAfter - before[0];
        }
        if (assetsAfter > before[1]) {
            lte(assetsAfter - before[1], before[3], "a fold credited more assets than settled");
            ghost_assetsOwed[vault] += assetsAfter - before[1];
        }
        uint256[6] memory actorsBefore;
        for (uint256 i; i < 6; i++) {
            actorsBefore[i] = before[4 + i];
        }
        _noteActorsOwed(v, actorsBefore, false);
    }

    /// @dev The views and the independent bound, before a call that may fold.
    function _beforeFold(uint8 v) internal view returns (uint256[10] memory before) {
        (before[0], before[1]) = _claimable(v);
        (before[2], before[3]) = _unfoldedBound(v);
        uint256[6] memory c = _actorClaimable(v);
        for (uint256 i; i < 6; i++) {
            before[4 + i] = c[i];
        }
    }

    /// @dev ERC-8161: moves the caller's stake in a pending request to another controller.
    function vault_transferRequest(uint256 reqSeed, uint256 fromSeed, uint256 toSeed) public updateGhosts(OpType.USER) {
        if (reqs.length == 0) return;
        Req memory r = reqs[reqSeed % reqs.length];
        IAsyncVault vault = vaults[r.vault];
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to || vault.contribution(uint96(r.requestId), from).amount == 0) return;

        bytes memory data = r.isDeposit
            ? abi.encodeCall(vault.transferDepositRequest, (r.requestId, from, to))
            : abi.encodeCall(vault.transferRedeemRequest, (r.requestId, from, to));
        uint256[10] memory before = _beforeFold(r.vault);
        // The merge sums two contributions, so the recipient's slice is one floor of the sum rather than the
        // sum of two floors, which can exceed what the bound counted by one unit per side.
        before[2] += 1;
        before[3] += 1;
        // On a vault with an instant lane the recipient has to agree, here by making the sender its operator for the
        // call; half the calls skip it, which such a vault refuses unless the sender is a sponsor.
        bool agreed = (toSeed >> 8) % 2 == 0;
        if (agreed) _callAs(to, address(vault), abi.encodeCall(vault.setOperator, (from, true)));
        (bool success, bytes memory err) = _callAs(from, address(vault), data);
        // Read before revoking: the operator approval that made the transfer agreed-to would otherwise read as
        // revoked by the time the check runs.
        bool expectedCredit =
            agreed || address(vault.instantPolicy()) == address(0) || ghostSponsor[address(vault)][from];
        if (agreed) _callAs(to, address(vault), abi.encodeCall(vault.setOperator, (from, false)));
        if (success) {
            _noteSurfaced(r.vault, before);
            t(!frozen[from] && !frozen[to], "a frozen party moved a pending position");
            t(expectedCredit, "a transfer credited a controller the policy forbids");
            _ok("vault_transferRequest");
        } else {
            // Refused with a reason, never a panic or an empty revert, which would be a transfer that broke
            t(err.length >= 4 && bytes4(err) != PANIC, "a transfer reverted without a reason or with a panic");
            _reverted("vault_transferRequest");
        }
    }

    /// @dev Pushes a closed per-period window to the hub; anyone may. Clamped calls only pick a bucket
    ///      its policy would let go, unclamped ones also try a window that is still open.
    function vault_flush(uint256 reqSeed) public updateGhosts(OpType.USER) {
        bool clamped = reqSeed % UNCLAMPED != 0;
        for (uint256 i; i < reqs.length; i++) {
            Req memory r = reqs[(reqSeed + i) % reqs.length];
            if (vaults[r.vault].bucket(uint96(r.requestId)).queued == 0) continue;
            if (clamped && !_isClosed(r)) continue;
            _flush(r);
            return;
        }
    }

    function _isClosed(Req memory r) internal view returns (bool) {
        IAsyncVault vault = vaults[r.vault];
        return IRequestPolicy(address(vault.requestPolicy())).isClosed(address(vault), vault.keyOf(uint96(r.requestId)));
    }

    function _flush(Req memory r) internal siblingsUntouched(vaults[r.vault]) returns (bool success) {
        uint256 gas0 = gasleft();
        try vaults[r.vault].flushRequest(uint96(r.requestId)) {
            _boundGas(gas0 - gasleft(), "a flush cost more gas than the ceiling");
            _ok("vault_flush");
            return true;
        } catch {
            _boundGas(gas0 - gasleft(), "a refused flush cost more gas than the ceiling");
            _reverted("vault_flush");
        }
    }

    /// @dev Folds a stake with a settlement it has not taken in yet, or, unclamped, any open stake.
    function vault_fold(uint256 reqSeed, uint256 actorSeed) public updateGhosts(OpType.USER) {
        if (reqs.length == 0) return;
        bool clamped = actorSeed % UNCLAMPED != 0;
        for (uint256 i; i < reqs.length; i++) {
            Req memory r = reqs[(reqSeed + i) % reqs.length];
            for (uint256 a; a < actors.length; a++) {
                address controller = _actor(actorSeed + a);
                if (!_canFold(r, controller, clamped)) continue;
                uint256[10] memory before = _beforeFold(r.vault);
                uint256 gas0 = gasleft();
                try vaults[r.vault].foldRequest(uint96(r.requestId), controller) {
                    _boundGas(gas0 - gasleft(), "a fold cost more gas than the ceiling");
                    _noteSurfaced(r.vault, before);
                    _ok("vault_fold");
                } catch {
                    _boundGas(gas0 - gasleft(), "a refused fold cost more gas than the ceiling");
                    _reverted("vault_fold");
                }
                return;
            }
        }
    }

    function _canFold(Req memory r, address controller, bool unfoldedOnly) internal view returns (bool) {
        IAsyncVault vault = vaults[r.vault];
        uint96 localId = uint96(r.requestId);
        uint128 amount = vault.contribution(localId, controller).amount;
        if (amount == 0) return false;
        return
            !unfoldedOnly
                || vault.contribution(localId, controller).foldedSettlements != vault.bucket(localId).settlements;
    }

    //----------------------------------------------------------------------------------------------
    // Async claims (3-arg, never instant)
    //----------------------------------------------------------------------------------------------

    /// @dev Clamped calls look for a controller with something to claim, across the vaults; unclamped
    ///      ones claim past the maximum, which must revert.
    function vault_claimDeposit(uint256 actorSeed, uint256 vaultSeed, uint256 amount, bool byShares)
        public
        updateGhosts(OpType.USER)
    {
        (IAsyncVault vault, address actor, uint256 max) = _findClaim(actorSeed, vaultSeed, true, byShares);
        if (max == 0) return;
        if (amount % UNCLAMPED == 0) return _claimPastMax(vault, actor, max, true, byShares);
        _claimDeposit(vault, actor, between(amount, 1, max), byShares, false);
    }

    function vault_claimRedeem(uint256 actorSeed, uint256 vaultSeed, uint256 amount, bool byShares)
        public
        updateGhosts(OpType.USER)
    {
        (IAsyncVault vault, address actor, uint256 max) = _findClaim(actorSeed, vaultSeed, false, byShares);
        if (max == 0) return;
        if (amount % UNCLAMPED == 0) return _claimPastMax(vault, actor, max, false, byShares);
        _claimRedeem(vault, actor, between(amount, 1, max), byShares, false);
    }

    /// @dev Full-exit liveness: a controller with a fulfilled position can always claim all of it.
    function vault_claimMax(uint256 actorSeed, uint256 vaultSeed, bool isDeposit) public updateGhosts(OpType.USER) {
        (IAsyncVault vault, address actor, uint256 max) = _findClaim(actorSeed, vaultSeed, isDeposit, isDeposit);
        if (max == 0) return;
        if (isDeposit) _claimDeposit(vault, actor, max, true, true);
        else _claimRedeem(vault, actor, max, false, true);
    }

    /// @dev The first vault and controller from the seeds with something claimable on that side, and its
    ///      maximum in the unit the claim is made in.
    function _findClaim(uint256 actorSeed, uint256 vaultSeed, bool isDeposit, bool byShares)
        internal
        view
        returns (IAsyncVault vault, address actor, uint256 max)
    {
        for (uint256 v; v < vaults.length; v++) {
            vault = vaults[_vaultIndex(vaultSeed + v)];
            for (uint256 a; a < actors.length; a++) {
                actor = _actor(actorSeed + a);
                max = _claimMax(vault, actor, isDeposit, byShares);
                if (max != 0) return (vault, actor, max);
            }
        }
    }

    function _claimMax(IAsyncVault vault, address actor, bool isDeposit, bool byShares)
        internal
        view
        returns (uint256)
    {
        if (isDeposit) {
            if (vault.claimableDepositRequest(0, actor) == 0) return 0;
            return byShares ? vault.maxMint(actor) : vault.maxDeposit(actor);
        }
        if (vault.claimableRedeemRequest(0, actor) == 0) return 0;
        return byShares ? vault.maxRedeem(actor) : vault.maxWithdraw(actor);
    }

    /// @dev A claim one unit past the maximum. In the unit the ledger keeps (shares on the deposit side,
    ///      assets on the redeem side) it must revert; in the converted unit rounding may still fit it.
    function _claimPastMax(IAsyncVault vault, address actor, uint256 max, bool isDeposit, bool byShares) internal {
        bytes memory data = isDeposit
            ? byShares
                ? abi.encodeWithSignature("mint(uint256,address,address)", max + 1, actor, actor)
                : abi.encodeWithSignature("deposit(uint256,address,address)", max + 1, actor, actor)
            : byShares
                ? abi.encodeWithSignature("redeem(uint256,address,address)", max + 1, actor, actor)
                : abi.encodeWithSignature("withdraw(uint256,address,address)", max + 1, actor, actor);
        uint256 sharesBefore = shareA.balanceOf(actor);
        uint256 assetsBefore = usdc.balanceOf(actor);
        (bool success,) = _callAs(actor, address(vault), data);
        if (!success) return _reverted("vault_claimPastMax");
        t(isDeposit != byShares, "a claim past the maximum went through");
        uint256 sharesGained =
            _nonNegativeDelta(shareA.balanceOf(actor), sharesBefore, "a claim past the maximum took shares");
        uint256 assetsGained =
            _nonNegativeDelta(usdc.balanceOf(actor), assetsBefore, "a claim past the maximum took assets");
        _addClaimed(address(vault), actor, sharesGained, assetsGained);
        _ok("vault_claimPastMax");
    }

    /// @dev A manager reserving past the escrow's total (legal: reserving ahead of arrival) leaves no
    ///      unreserved balance, and `withdrawReserved` releases a claim only out of that, so payouts wait
    ///      for the manager to fund the escrow or unreserve. Liveness is asserted outside that state.
    function _overReserved() internal view returns (bool) {
        (uint128 total, uint128 reserved) = _escrow(poolA).holding(scA, address(usdc), 0);
        return reserved > total;
    }

    function _claimDeposit(IAsyncVault vault, address actor, uint256 amount, bool byShares, bool mustSucceed)
        internal
        siblingsUntouched(vault)
        returns (bool)
    {
        return _claimDepositOf(vault, actor, amount, byShares, mustSucceed);
    }

    function _claimDepositOf(IAsyncVault vault, address actor, uint256 amount, bool byShares, bool mustSucceed)
        internal
        returns (bool success)
    {
        _feeNoInstantInCall = true;
        uint256[3] memory before =
            [shareA.balanceOf(address(_escrow(poolA))), shareA.balanceOf(actor), vault.maxMint(actor)];
        uint256[2] memory ledger = _ledger(vault, actor, true);
        mustSucceed = mustSucceed && _claimOpen(vault, actor);
        bytes memory data = byShares
            ? abi.encodeWithSignature("mint(uint256,address,address)", amount, actor, actor)
            : abi.encodeWithSignature("deposit(uint256,address,address)", amount, actor, actor);
        bytes memory ret;
        (success, ret) = _boundedCall(actor, address(vault), data, "a deposit claim cost more gas than the ceiling");
        if (success) {
            uint256 received =
                _nonNegativeDelta(shareA.balanceOf(actor), before[1], "a deposit claim lowered the shares held");
            uint256 released = _nonNegativeDelta(
                before[0], shareA.balanceOf(address(_escrow(poolA))), "a deposit claim grew the escrow's shares"
            );
            eq(received, released, "claimed shares not from the escrow");
            _ledgerMoved(vault, actor, ledger, true, received, byShares ? abi.decode(ret, (uint256)) : amount);
            lte(received, before[2], "claim paid more shares than maxMint");
            _addClaimed(address(vault), actor, received, 0);
            t(!frozen[actor], "a frozen controller claimed shares");
            _ok(mustSucceed ? bytes32("vault_claimMaxDeposit") : bytes32("vault_claimDeposit"));
        } else {
            t(!mustSucceed, "claiming the full maxMint reverted");
            _reverted(mustSucceed ? bytes32("vault_claimMaxDeposit") : bytes32("vault_claimDeposit"));
        }
    }

    function _claimRedeem(IAsyncVault vault, address actor, uint256 amount, bool byShares, bool isMax)
        internal
        siblingsUntouched(vault)
        returns (bool)
    {
        return _claimRedeemOf(vault, actor, amount, byShares, isMax);
    }

    function _claimRedeemOf(IAsyncVault vault, address actor, uint256 amount, bool byShares, bool isMax)
        internal
        returns (bool success)
    {
        _feeNoInstantInCall = true;
        uint256 actorBefore = usdc.balanceOf(actor);
        uint256 maxWithdraw = vault.maxWithdraw(actor);
        uint256[2] memory ledger = _ledger(vault, actor, false);
        // Payouts wait for funds the escrow holds unreserved, and for the role the vault pays through
        bool mustSucceed = isMax && _claimOpen(vault, actor) && !_overReserved();
        expectedBurn = byShares ? 0 : _withdrawBurn(vault, actor, ledger, amount);
        bytes memory data = byShares
            ? abi.encodeWithSignature("redeem(uint256,address,address)", amount, actor, actor)
            : abi.encodeWithSignature("withdraw(uint256,address,address)", amount, actor, actor);
        bytes memory ret;
        (success, ret) = _boundedCall(actor, address(vault), data, "a redeem claim cost more gas than the ceiling");
        if (success) {
            uint256 received =
                _nonNegativeDelta(usdc.balanceOf(actor), actorBefore, "a redeem claim lowered the assets held");
            lte(received, maxWithdraw, "claim paid more assets than maxWithdraw");
            _ledgerMoved(vault, actor, ledger, false, byShares ? amount : abi.decode(ret, (uint256)), received);
            if (!byShares && expectedBurn != type(uint256).max) {
                eq(abi.decode(ret, (uint256)), expectedBurn, "a withdraw claim burned other than the rounded-up shares");
            }
            _addClaimed(address(vault), actor, 0, received);
            t(!frozen[actor], "a frozen controller claimed a redemption");
            _ok(isMax ? bytes32("vault_claimMaxRedeem") : bytes32("vault_claimRedeem"));
        } else {
            t(!mustSucceed, "claiming the full maxWithdraw reverted");
            _reverted(isMax ? bytes32("vault_claimMaxRedeem") : bytes32("vault_claimRedeem"));
        }
    }

    /// @dev What the withdraw claim in flight must burn, kept here to spare the claim's stack.
    uint256 internal expectedBurn;

    /// @dev The shares a withdraw claim of `amount` burns, from the ledger before it: the refunded assets are taken
    ///      first and carry no shares, the rest burns the redeem shares pro-rata, rounded up. The refund split is not
    ///      in the views, so it is read from storage. A ledger the views count more of than storage holds (a
    ///      settlement the claim has yet to fold in) cannot be split, and answers `type(uint256).max`.
    function _withdrawBurn(IAsyncVault vault, address owner, uint256[2] memory ledger, uint256 amount)
        internal
        returns (uint256)
    {
        bytes32 base = keccak256(abi.encode(owner, INVESTMENTS_SLOT));
        uint256 paid = uint256(vm.load(address(vault), bytes32(uint256(base) + 1)));
        uint256 refunds = uint256(vm.load(address(vault), bytes32(uint256(base) + 2)));
        uint256 filled = uint128(paid);
        uint256 refund = refunds >> 128;
        if (filled + refund != ledger[0] || paid >> 128 != ledger[1]) return type(uint256).max;

        uint256 priced = amount - _min(amount, refund);
        if (priced == 0) return 0;
        if (filled == 0) return type(uint256).max;
        return (ledger[1] * priced + filled - 1) / filled;
    }

    /// @dev The claimable ledger of a controller on one side: the assets and the shares.
    function _ledger(IAsyncVault vault, address owner, bool isDeposit) internal view returns (uint256[2] memory l) {
        l = isDeposit
            ? [vault.claimableDepositRequest(0, owner), vault.claimableMint(owner)]
            : [vault.claimableWithdraw(owner), vault.claimableRedeemRequest(0, owner)];
    }

    /// @dev A claim shrinks the controller's ledger by exactly what it paid, in both units: a ledger that shrank by
    ///      more than it paid is a loss no total `claimed <= owed` can see.
    function _ledgerMoved(
        IAsyncVault vault,
        address owner,
        uint256[2] memory before,
        bool isDeposit,
        uint256 shares,
        uint256 assets
    ) internal {
        uint256[2] memory now_ = _ledger(vault, owner, isDeposit);
        eq(before[0], now_[0] + assets, "a claim did not shrink the claimable assets by what it paid");
        eq(before[1], now_[1] + shares, "a claim did not shrink the claimable shares by what it paid");
    }

    /// @dev A claimant's previews are the claim: for an account with something to claim, `preview*` quotes what the
    ///      2-argument call then pays, in the unit it returns. `kind` picks the function: deposit, mint, redeem or
    ///      withdraw.
    function vault_previewIsTheClaim(uint256 actorSeed, uint256 vaultSeed, uint256 amount, uint8 kind)
        public
        updateGhosts(OpType.USER)
    {
        bool isDeposit = kind % 2 == 0;
        bool byShares = kind / 2 % 2 == 1;
        (IAsyncVault vault, address actor, uint256 max) = _findClaim(actorSeed, vaultSeed, isDeposit, byShares);
        if (max == 0) return;
        amount = between(amount, 1, max);

        bytes4 previewSelector = isDeposit
            ? (byShares ? vault.previewMint.selector : vault.previewDeposit.selector)
            : (byShares ? vault.previewRedeem.selector : vault.previewWithdraw.selector);
        vm.prank(actor);
        (bool quoted, uint256 quote) = _staticQuote(address(vault), previewSelector, amount);

        bytes memory data = isDeposit
            ? abi.encodeWithSignature(byShares ? "mint(uint256,address)" : "deposit(uint256,address)", amount, actor)
            : abi.encodeWithSignature(byShares ? "redeem(uint256,address)" : "withdraw(uint256,address)", amount, actor);
        uint256 sharesBefore = shareA.balanceOf(actor);
        uint256 assetsBefore = usdc.balanceOf(actor);
        (bool success, bytes memory ret) = _callAs(actor, address(vault), data);
        if (!success) return _reverted("vault_previewIsTheClaim");

        t(quoted, "a claimant's preview refused a claim that went through");
        eq(abi.decode(ret, (uint256)), quote, "a claimant's preview differed from the claim");
        _countClaimed(address(vault), actor, sharesBefore, assetsBefore);
        _ok("vault_previewIsTheClaim");
    }

    //----------------------------------------------------------------------------------------------
    // Instant lanes (2-arg, on the two instant vaults)
    //----------------------------------------------------------------------------------------------

    /// @dev While the oracle refuses the price the capacity reads zero, so the call is made anyway with
    ///      a raw amount and must revert.
    function vault_instantDeposit(uint256 actorSeed, bool basinVault, uint256 amount, bool byShares)
        public
        updateGhosts(OpType.USER)
    {
        IAsyncVault vault = vaults[basinVault ? 3 : 2];
        address actor = amount % UNCLAMPED != 0 ? _instantActor(actorSeed, vault, true) : _actor(actorSeed);
        if (_inAsync(vault, actor, true)) return;
        uint256 balance = usdc.balanceOf(actor);
        if (balance == 0) return;
        if (!_oracleValid()) return _instantOnInvalidPrice(vault, actor, between(amount, 1, balance), byShares, true);
        uint256 capacity = vault.maxDeposit(actor);
        if (capacity == 0) return;
        amount = between(amount, 1, capacity < balance ? capacity : balance);
        if (byShares) amount = vault.convertToShares(amount) / 2;
        if (amount == 0) return;
        _instant(vault, actor, amount, byShares, true);
    }

    /// @dev Clamped to what the investor holds as well as the lane's capacity, which is set by the escrow
    ///      and the route rather than the investor's balance.
    function vault_instantRedeem(uint256 actorSeed, bool basinVault, uint256 amount, bool byAssets)
        public
        updateGhosts(OpType.USER)
    {
        bool clamped = amount % UNCLAMPED != 0;
        IAsyncVault vault = vaults[basinVault ? 3 : 2];
        address actor = clamped ? _instantActor(actorSeed, vault, false) : _shareHolder(actorSeed);
        if (_inAsync(vault, actor, false)) return;
        uint256 balance = shareA.balanceOf(actor);
        if (!_oracleValid()) {
            if (balance == 0) return;
            return _instantOnInvalidPrice(vault, actor, between(amount, 1, balance), byAssets, false);
        }
        uint256 capacity = byAssets ? vault.maxWithdraw(actor) : vault.maxRedeem(actor);
        if (clamped) capacity = _min(capacity, byAssets ? vault.previewRedeem(balance) : balance);
        if (capacity == 0) return;
        // Clamped calls stay above an amount that converts to nothing on the other side
        uint256 floor = clamped ? _min(capacity, byAssets ? DUST_ASSETS : DUST_SHARES) : 1;
        _instant(vault, actor, between(amount, floor, capacity), byAssets, false);
    }

    function _instant(IAsyncVault vault, address actor, uint256 amount, bool flag, bool isDeposit)
        internal
        siblingsUntouched(vault)
        returns (bool)
    {
        return _instantTrade(vault, actor, amount, flag, isDeposit);
    }

    function _instantTrade(IAsyncVault vault, address actor, uint256 amount, bool flag, bool isDeposit)
        internal
        returns (bool success)
    {
        Bystander memory bystander = _bystander(vault, actor);
        if (isDeposit) {
            vm.prank(actor);
            usdc.approve(address(vault), type(uint256).max);
        }
        uint256 sharesBefore = shareA.balanceOf(actor);
        uint256 assetsBefore = usdc.balanceOf(actor);
        (bool quoted, uint256 quote) = _quote(vault, actor, amount, flag, isDeposit);
        FeeProbe memory probe = _feeBegin(vault, actor, actor);
        (success,) = _callAs(actor, address(vault), _instantCall(actor, amount, flag, isDeposit));
        if (isDeposit) {
            vm.prank(actor);
            usdc.approve(address(vault), 0);
        }
        bytes32 action = isDeposit ? bytes32("vault_instantDeposit") : bytes32("vault_instantRedeem");
        if (!success) {
            _reverted(action);
            return false;
        }
        t(!frozen[actor], "a frozen investor used an instant lane");
        _checkLane(vault, actor, isDeposit);
        _feeEnd(probe, vault, actor, actor, amount, flag, isDeposit);
        _checkNonDilution(vault, bystander, actor, sharesBefore, assetsBefore, isDeposit);
        if (quoted) _checkQuote(quote, actor, sharesBefore, assetsBefore, flag, isDeposit);
        _ok(action);
    }

    /// @dev What the policy let through must be what it is configured to let through: a closed lane serves nobody,
    ///      and a gated one only the accounts on its list. The gate is the caller's, never the receiver's.
    function _checkLane(IAsyncVault vault, address actor, bool isDeposit) internal {
        (,,, bool redeemEnabled, bool gatedDeposit, bool gatedRedeem, uint128 maxReserve) =
            reserveInstantPolicy.config(address(vault));
        if (isDeposit) {
            t(maxReserve != 0, "an instant deposit went through a lane with no reserve");
            t(
                !gatedDeposit
                    || reserveInstantPolicy.isAllowed(
                        address(vault), IReserveInstantPolicy.ConfigKind.Depositor, actor
                    ),
                "a gated lane took a deposit"
            );
        } else {
            t(redeemEnabled, "an instant redemption went through a closed lane");
            t(
                !gatedRedeem
                    || reserveInstantPolicy.isAllowed(address(vault), IReserveInstantPolicy.ConfigKind.Redeemer, actor),
                "a gated lane paid a redemption"
            );
        }
    }

    /// @dev The preview matching an instant call, taken from the investor and again from a stranger, which
    ///      must agree: a preview that varied with the caller could not be quoted to one. Skipped where the
    ///      preview refuses, which `property_viewsNeverRevert` and the capacity reads cover.
    function _quote(IAsyncVault vault, address actor, uint256 amount, bool flag, bool isDeposit)
        internal
        returns (bool quoted, uint256 quote)
    {
        bytes4 selector = isDeposit
            ? (flag ? vault.previewMint.selector : vault.previewDeposit.selector)
            : (flag ? vault.previewWithdraw.selector : vault.previewRedeem.selector);
        bool okOwn;
        bool okOther;
        uint256 other;
        vm.prank(actor);
        (okOwn, quote) = _staticQuote(address(vault), selector, amount);
        vm.prank(address(uint160(actor) + 0x400000));
        (okOther, other) = _staticQuote(address(vault), selector, amount);
        if (okOwn != okOther) t(false, "a preview refused for one caller and not another");
        else if (okOwn) eq(quote, other, "a preview depended on the caller");
        return (okOwn && okOther, quote);
    }

    function _staticQuote(address vault, bytes4 selector, uint256 amount) internal view returns (bool, uint256) {
        (bool success, bytes memory ret) = vault.staticcall(abi.encodeWithSelector(selector, amount));
        return (success && ret.length == 32, success && ret.length == 32 ? abi.decode(ret, (uint256)) : 0);
    }

    /// @dev ERC-4626: a preview is as close as possible to the real figure and never better for the caller.
    ///      `flag` is `byShares` on the deposit side (mint: the quote bounds the assets paid) and `byAssets`
    ///      on the redeem side (withdraw: the quote bounds the shares burned).
    function _checkQuote(
        uint256 quote,
        address actor,
        uint256 sharesBefore,
        uint256 assetsBefore,
        bool flag,
        bool isDeposit
    ) internal {
        uint256 sharesAfter = shareA.balanceOf(actor);
        uint256 assetsAfter = usdc.balanceOf(actor);
        // What the caller gave up floors at zero when the call paid it instead: a payment above the quote's
        // ceiling is a violation, a payment to the caller is not. What the caller received floors at zero when it
        // lost instead, which is below any quote, so the lower bounds still fail.
        if (isDeposit) {
            if (flag) {
                lte(_floorSub(assetsBefore, assetsAfter), quote, "previewMint quoted fewer assets than mint took");
            } else {
                gte(
                    _floorSub(sharesAfter, sharesBefore), quote, "previewDeposit quoted more shares than deposit minted"
                );
            }
        } else {
            if (flag) {
                lte(
                    _floorSub(sharesBefore, sharesAfter),
                    quote,
                    "previewWithdraw quoted fewer shares than withdraw burned"
                );
            } else {
                gte(_floorSub(assetsAfter, assetsBefore), quote, "previewRedeem quoted more assets than redeem paid");
            }
        }
    }

    /// @dev Round trip on an instant lane: what `deposit` mints, `redeem` cannot turn back into more than
    ///      was put in, whatever the oracle price and the fees. It runs in one call, so the price cannot move
    ///      between the legs, and an unclamped amount is not tried since the lane's capacity may refuse it.
    function vault_instantRoundTrip(uint256 actorSeed, bool basinVault, uint256 amount)
        public
        updateGhosts(OpType.USER)
    {
        IAsyncVault vault = vaults[basinVault ? 3 : 2];
        address actor = _instantActor(actorSeed, vault, true);
        if (_inAsync(vault, actor, true) || _inAsync(vault, actor, false) || !_oracleValid()) return;
        uint256 balance = usdc.balanceOf(actor);
        uint256 capacity = vault.maxDeposit(actor);
        if (balance == 0 || capacity == 0) return;
        uint256 assets = between(amount, 1, capacity < balance ? capacity : balance);

        uint256 sharesBefore = shareA.balanceOf(actor);
        uint256 assetsBefore = usdc.balanceOf(actor);
        if (!_instant(vault, actor, assets, false, true)) return;
        uint256 shares = shareA.balanceOf(actor) - sharesBefore;
        if (shares == 0 || vault.maxRedeem(actor) < shares) return;
        if (!_instant(vault, actor, shares, false, false)) return;

        lte(usdc.balanceOf(actor), assetsBefore, "an instant round trip paid out more than it took in");
        _ok("vault_instantRoundTrip");
    }

    /// @dev `flag` is `byShares` on the deposit side and `byAssets` on the redeem side.
    function _instantCall(address actor, uint256 amount, bool flag, bool isDeposit)
        internal
        pure
        returns (bytes memory)
    {
        if (isDeposit) {
            return flag
                ? abi.encodeWithSignature("mint(uint256,address)", amount, actor)
                : abi.encodeWithSignature("deposit(uint256,address)", amount, actor);
        }
        return flag
            ? abi.encodeWithSignature("withdraw(uint256,address)", amount, actor)
            : abi.encodeWithSignature("redeem(uint256,address)", amount, actor);
    }

    function _instantOnInvalidPrice(IAsyncVault vault, address actor, uint256 amount, bool flag, bool isDeposit)
        internal
    {
        if (isDeposit) {
            vm.prank(actor);
            usdc.approve(address(vault), type(uint256).max);
        }
        (bool success,) = _callAs(actor, address(vault), _instantCall(actor, amount, flag, isDeposit));
        if (isDeposit) {
            vm.prank(actor);
            usdc.approve(address(vault), 0);
        }
        t(!success, "an instant lane traded on an invalid price");
        _ok("instant_refusedOnInvalidPrice");
    }

    /// @dev The first actor from `seed` the lane would serve on that side: not frozen, holding what it
    ///      would pay in, and with nothing pending or claimable, which would make the 2-arg call a claim.
    function _instantActor(uint256 seed, IAsyncVault vault, bool isDeposit) internal view returns (address) {
        for (uint256 i; i < actors.length; i++) {
            address a = _actor(seed + i);
            uint256 balance = isDeposit ? usdc.balanceOf(a) : shareA.balanceOf(a);
            if (!frozen[a] && balance != 0 && !_inAsync(vault, a, isDeposit)) return a;
        }
        return _actor(seed);
    }

    /// @dev The 2-arg entrypoints claim instead while anything is pending or claimable; those claims are
    ///      driven through the 3-arg handlers so their payouts are counted. Read off the ledger rather than
    ///      `claimable*Request`, which prices a cancellation's refund at a settlement price it may not have.
    function _inAsync(IAsyncVault vault, address actor, bool isDeposit) internal view returns (bool) {
        return isDeposit
            ? vault.claimableMint(actor) != 0 || vault.pendingDepositRequest(0, actor) != 0
            : vault.claimableWithdraw(actor) != 0 || vault.pendingRedeemRequest(0, actor) != 0;
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    /// @dev The first actor from `seed` holding shares it may move, or the seeded actor if none does.
    function _liquidHolder(uint256 seed) internal view returns (address) {
        for (uint256 i; i < actors.length; i++) {
            address a = actors[(seed + i) % actors.length];
            if (!frozen[a] && shareA.balanceOf(a) != 0) return a;
        }
        return _actor(seed);
    }

    /// @dev The first actor from `seed` that is not frozen; at most one is.
    function _unfrozen(uint256 seed) internal view returns (address) {
        address a = _actor(seed);
        return frozen[a] ? _actor(seed + 1) : a;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
