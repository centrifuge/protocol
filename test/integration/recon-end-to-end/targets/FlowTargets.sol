// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {HubTargets} from "./HubTargets.sol";
import {VaultTargets} from "./VaultTargets.sol";

import {IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";

/// @notice Whole request lifecycles in one call: request, close the window and flush, settle or cancel,
///         then claim. Single-step handlers reach a claim only when a fuzzer happens to line up a request,
///         its settlement and a claim by the same controller on the same vault; these make every call
///         end in one, so claims, folds and refunds are exercised in proportion to the requests made.
/// @dev    Each step goes through the same internals as its single-step handler, so the inline checks and
///         ghost updates are the same, and a full claim after a settlement is asserted to go through.
///         Time only moves to close a per-period window, which moves no price.
abstract contract FlowTargets is VaultTargets, HubTargets {
    uint8 internal constant PER_PERIOD_VAULT = 1;

    /// @dev Deposit request, settled in full or in part, then claimed in full or in part.
    function flow_deposit(uint256 actorSeed, uint256 vaultSeed, uint256 amount, uint256 fillSeed)
        public
        updateGhosts(OpType.MANAGER)
    {
        address actor = _unfrozen(actorSeed);
        uint256 balance = usdc.balanceOf(actor);
        if (balance < _dust(true)) return;
        _flowEnd(
            "flow_deposit",
            _depositCycle(actor, _vaultIndex(vaultSeed), between(amount, _dust(true), balance), fillSeed)
        );
    }

    /// @dev Redeem request, settled in full or in part, then claimed in full or in part.
    function flow_redeem(uint256 actorSeed, uint256 vaultSeed, uint256 shares, uint256 fillSeed)
        public
        updateGhosts(OpType.MANAGER)
    {
        address actor = _liquidHolder(actorSeed);
        uint256 balance = shareA.balanceOf(actor);
        if (frozen[actor] || balance < _dust(false)) return;
        uint8 v = _vaultIndex(vaultSeed);
        (bool requested, uint256 requestId) = _requestRedeem(actor, actor, v, between(shares, _dust(false), balance));
        _flowEnd(
            "flow_redeem",
            requested && _settle(Req(v, requestId, false), fillSeed) && _claimAll(vaults[v], actor, fillSeed)
        );
    }

    /// @dev A request cancelled by the manager, then its refund claimed: a cancelled deposit comes back as
    ///      assets on the redeem side, a cancelled redemption as shares on the deposit side.
    function flow_cancel(uint256 actorSeed, uint256 vaultSeed, uint256 amount, uint256 cancelSeed, bool isDeposit)
        public
        updateGhosts(OpType.MANAGER)
    {
        address actor = isDeposit ? _unfrozen(actorSeed) : _liquidHolder(actorSeed);
        uint256 balance = isDeposit ? usdc.balanceOf(actor) : shareA.balanceOf(actor);
        if (frozen[actor] || balance == 0) return;
        uint8 v = _vaultIndex(vaultSeed);
        (bool requested, uint256 requestId) = isDeposit
            ? _requestDeposit(actor, actor, v, between(amount, 1, balance))
            : _requestRedeem(actor, actor, v, between(amount, 1, balance));
        if (!requested) return _flowEnd("flow_cancel", false);

        Req memory r = Req(v, requestId, isDeposit);
        if (!_flushQueued(r)) return _flowEnd("flow_cancel", false);
        uint128 outstanding = _outstanding(r);
        if (outstanding == 0) return _flowEnd("flow_cancel", false);
        uint128 gross = cancelSeed % 3 == 0 ? uint128(between(cancelSeed, 1, outstanding)) : outstanding;
        _flowEnd("flow_cancel", _cancel(r, gross) && _claimAll(vaults[v], actor, cancelSeed));
    }

    /// @dev Every free actor joins one per-period window, which closes, is flushed and settled in one or
    ///      two parts, then each contributor folds its slice and claims it.
    function flow_sharedWindow(uint256 amountSeed, uint256 fillSeed, bool isDeposit)
        public
        updateGhosts(OpType.MANAGER)
    {
        uint256 windowId;
        for (uint256 i; i < actors.length; i++) {
            address actor = actors[i];
            uint256 balance = isDeposit ? usdc.balanceOf(actor) : shareA.balanceOf(actor);
            if (frozen[actor] || balance < _dust(isDeposit)) continue;
            uint256 amount = between(uint256(keccak256(abi.encode(amountSeed, i))), _dust(isDeposit), balance);
            (bool requested, uint256 requestId) = isDeposit
                ? _requestDeposit(actor, actor, PER_PERIOD_VAULT, amount)
                : _requestRedeem(actor, actor, PER_PERIOD_VAULT, amount);
            if (requested) windowId = requestId;
        }
        if (windowId == 0) return;

        Req memory r = Req(PER_PERIOD_VAULT, windowId, isDeposit);
        uint96 localId = uint96(windowId);
        bool settled = _settle(r, fillSeed);
        if (settled && fillSeed % 2 == 0 && _outstanding(r) >= _dust(isDeposit)) _fulfill(r, _outstanding(r));

        IAsyncVault vault = vaults[PER_PERIOD_VAULT];
        bool claimed = settled;
        for (uint256 i; i < actors.length; i++) {
            if (vault.contribution(localId, actors[i]).amount == 0) continue;
            _foldOne(PER_PERIOD_VAULT, localId, actors[i]);
            if (!frozen[actors[i]]) claimed = _claimAll(vault, actors[i], fillSeed + i) && claimed;
        }
        _flowEnd("flow_sharedWindow", claimed);
    }

    //----------------------------------------------------------------------------------------------
    // Steps
    //----------------------------------------------------------------------------------------------

    function _depositCycle(address actor, uint8 v, uint256 amount, uint256 fillSeed) internal returns (bool) {
        (bool requested, uint256 requestId) = _requestDeposit(actor, actor, v, amount);
        return requested && _settle(Req(v, requestId, true), fillSeed) && _claimAll(vaults[v], actor, fillSeed);
    }

    /// @dev Flushes what is queued, then fills the hub order in full, or in part for one seed in three.
    function _settle(Req memory r, uint256 fillSeed) internal returns (bool) {
        if (!_flushQueued(r)) return false;
        uint128 outstanding = _outstanding(r);
        uint128 dust = _dust(r.isDeposit);
        if (outstanding < dust) return false;
        // A part fill leaves at least the dust, which only a cancellation could otherwise clear
        bool part = fillSeed % 3 == 0 && outstanding >= 2 * dust;
        return _fulfill(r, part ? uint128(between(fillSeed, dust, outstanding - dust)) : outstanding);
    }

    /// @dev A per-period window is closed by moving to the next one; the other policies flush on request.
    function _flushQueued(Req memory r) internal returns (bool) {
        if (vaults[r.vault].bucket(uint96(r.requestId)).queued == 0) return true;
        if (!_isClosed(r)) vm.warp((block.timestamp / PERIOD + 1) * PERIOD);
        return _flush(r);
    }

    /// @dev Claims what the controller's ledger holds on each side: in full, which must go through, or for
    ///      one seed in four a part of it in the other unit.
    function _claimAll(IAsyncVault vault, address actor, uint256 seed) internal returns (bool claimed) {
        uint256 maxMint = vault.claimableMint(actor);
        uint256 maxWithdraw = vault.claimableWithdraw(actor);
        if (maxMint != 0) claimed = _claimSide(vault, actor, maxMint, true, seed);
        if (maxWithdraw != 0) claimed = _claimSide(vault, actor, maxWithdraw, false, seed) || claimed;
    }

    function _claimSide(IAsyncVault vault, address actor, uint256 max, bool isDeposit, uint256 seed)
        internal
        returns (bool)
    {
        uint256 converted = seed % 4 != 0 ? 0 : isDeposit ? vault.maxDeposit(actor) : vault.maxRedeem(actor);
        if (converted == 0) {
            return
                isDeposit ? _claimDeposit(vault, actor, max, true, true) : _claimRedeem(vault, actor, max, false, true);
        }
        uint256 amount = between(seed, 1, converted);
        return
            isDeposit
                ? _claimDeposit(vault, actor, amount, false, false)
                : _claimRedeem(vault, actor, amount, true, false);
    }

    function _foldOne(uint8 v, uint96 localId, address controller) internal {
        uint256[10] memory before = _beforeFold(v);
        uint256 gas0 = gasleft();
        try vaults[v].foldRequest(localId, controller) {
            _boundGas(gas0 - gasleft(), "a fold cost more gas than the ceiling");
            _noteSurfaced(v, before);
            _ok("vault_fold");
        } catch {
            _boundGas(gas0 - gasleft(), "a refused fold cost more gas than the ceiling");
            _reverted("vault_fold");
        }
    }

    /// @dev Counts the flow, and separately those that completed while the oracle refused the price: the
    ///      async lane must not depend on it.
    function _flowEnd(bytes32 action, bool completed) internal {
        if (!completed) return _reverted(action);
        _ok(action);
        if (!_oracleValid()) _ok("async_onInvalidPrice");
    }
}
