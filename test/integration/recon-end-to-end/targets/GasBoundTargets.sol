// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GapTargets} from "./GapTargets.sol";
import {ExitTargets} from "./ExitTargets.sol";

import {RequestId} from "../../../../src/core/types/RequestId.sol";

import {RequestCallbackMessageLib} from "../../../../src/vaults/messaging/libraries/RequestCallbackMessageLib.sol";

import {IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";
import {VaultRequestIdLib} from "../../../../src/vaults/libraries/VaultRequestIdLib.sol";

import {vm} from "@chimera/Hevm.sol";

/// @notice The longest history the horizon allows, built in one call and then folded, flushed and claimed under the
///         gas ceiling.
/// @dev    The single-step handlers measure every claim the fuzzer reaches (`_boundGas`), but a sequence of random
///         calls seldom stacks a full horizon of settled windows. This one does: the investors join each of up to
///         `horizon + 2` consecutive windows of the long-horizon per-period vault on both sides, so the oldest two are
///         evicted from every controller's horizon and wait for a keeper, the hub settles them all, a keeper folds
///         the evicted windows and each controller claims the rest.
///
///         A stateless doomsday handler, like `exit_everyoneCanLeave`: it calls the vault directly, with none of the
///         handlers' ghost bookkeeping (whose views cost millions once many windows are open, and which a history this
///         size would drift), and reverts with its marker at the end, so nothing it did persists. A failed check is
///         recorded when the call returns instead of reverting, for Foundry (see `exit_everyoneCanLeave`).
///         The history is built inside the call that claims, so its slots are warm; the ceiling's margin over the
///         measured worst case (see `GasBoundProperties`) covers the cold-storage difference.
abstract contract GasBoundTargets is GapTargets, ExitTargets {
    error GasRehearsalEnded();

    /// @dev The windows that stay open on top of the horizon, so the oldest are evicted from it.
    uint256 internal constant EXTRA_WINDOWS = 2;
    /// @dev Gas the history may spend opening windows. A full-size one needs about 6.4M, and an Echidna transaction
    ///      (12.5M) must still settle and claim it.
    uint256 internal constant HISTORY_BUDGET = 6_500_000;
    /// @dev Gas the claims need, which no fill past this point may eat into.
    uint256 internal constant CLAIM_RESERVE = 2_500_000;
    /// @dev The windows every investor joins; after them only one investor, the one whose claims are the deepest,
    ///      keeps requesting, so the history is as long as the horizon allows within the budget.
    uint256 internal constant SHARED_WINDOWS = 2;

    /// @dev The requests of one side, oldest first, in memory to stay clear of the stack limit.
    struct Windows {
        uint96[16] ids;
        uint256 count;
    }

    function gas_worstCaseClaim(uint256 amountSeed, uint256 fillSeed, uint8 extra) public {
        siblingBudget = 0;
        uint256 failuresBefore = _failureCount();
        uint256 timeBefore = block.timestamp;
        _worstCase(amountSeed, fillSeed, extra);
        if (_failureCount() != failuresBefore) return;
        vm.warp(timeBefore);
        revert GasRehearsalEnded();
    }

    function _worstCase(uint256 amountSeed, uint256 fillSeed, uint8 extra) internal returns (uint256 windows) {
        Windows memory deposits;
        Windows memory redeems;
        (deposits, redeems) = _buildHistory(amountSeed, extra);
        _keep(deposits, redeems, fillSeed);
        return deposits.count;
    }

    /// @dev Opens the windows, closes the last, settles every window and has a keeper fold the evicted ones.
    function _buildHistory(uint256 amountSeed, uint8 extra)
        internal
        returns (Windows memory deposits, Windows memory redeems)
    {
        IAsyncVault vault = vaults[LONG_VAULT];
        uint256 horizon = vault.foldHorizon();
        uint256 windows = horizon + between(extra, 0, EXTRA_WINDOWS);

        uint256 gas0 = gasleft();
        for (uint256 w; w < windows && gas0 - gasleft() < HISTORY_BUDGET; w++) {
            vm.warp((block.timestamp / PERIOD + 1) * PERIOD);
            _openWindow(deposits, redeems, w, amountSeed);
        }
        vm.warp((block.timestamp / PERIOD + 1) * PERIOD);
        _flushWindows(deposits);
        _flushWindows(redeems);
        _fillWindows(deposits, true);
        _fillWindows(redeems, false);
    }

    /// @dev What a keeper and the investors do with the history: fold what the horizon evicted, then claim.
    function _keep(Windows memory deposits, Windows memory redeems, uint256 fillSeed) internal {
        uint256 horizon = vaults[LONG_VAULT].foldHorizon();
        _foldEvicted(deposits, horizon);
        _foldEvicted(redeems, horizon);
        for (uint256 a; a < actors.length; a++) {
            _claimBoth(a, fillSeed);
        }
        _ok("gas_worstCaseClaim");
    }

    /// @dev The investors join the first windows; the one the seed picks joins every window on both sides, with
    ///      whatever it holds.
    function _openWindow(Windows memory deposits, Windows memory redeems, uint256 w, uint256 amountSeed) internal {
        IAsyncVault vault = vaults[LONG_VAULT];
        for (uint256 a; a < actors.length; a++) {
            address actor = actors[a];
            if (frozen[actor] || !_healthy(vault, actor)) continue;
            if (w >= SHARED_WINDOWS && a != amountSeed % actors.length) continue;
            uint256 seed = uint256(keccak256(abi.encode(amountSeed, w, a)));
            uint256 assets = usdc.balanceOf(actor);
            if (assets >= _dust(true)) {
                uint256 amount = between(seed, _dust(true), _min(assets, 100 * uint256(ONE_ASSET)));
                vm.prank(actor);
                usdc.approve(address(vault), amount);
                vm.prank(actor);
                try vault.requestDeposit(amount, actor, actor) returns (uint256 id) {
                    _record(deposits, id);
                } catch {}
            }
            uint256 shares = shareA.balanceOf(actor);
            if (shares >= _dust(false)) {
                uint256 amount = between(seed / 3, _dust(false), _min(shares, 10 * uint256(ONE_SHARE)));
                vm.prank(actor);
                try vault.requestRedeem(amount, actor, actor) returns (uint256 id) {
                    _record(redeems, id);
                } catch {}
            }
        }
    }

    function _record(Windows memory side, uint256 requestId) internal pure {
        if (side.count != 0 && side.ids[side.count - 1] == uint96(requestId)) return;
        side.ids[side.count++] = uint96(requestId);
    }

    /// @dev Sends each closed window to the hub, anyone may.
    function _flushWindows(Windows memory side) internal {
        for (uint256 i; i < side.count; i++) {
            if (vaults[LONG_VAULT].bucket(side.ids[i]).queued == 0) continue;
            _boundedCall(
                OUTSIDER,
                address(vaults[LONG_VAULT]),
                abi.encodeCall(vaults[LONG_VAULT].flushRequest, (side.ids[i])),
                "a flush cost more gas than the ceiling"
            );
        }
    }

    /// @dev Each window settled in full at par, as the router applies the hub's callback to the vault: the hub's own
    ///      legs (the order book, the message) cost the same whatever the history is, and this keeps a full-size
    ///      history within an Echidna transaction. A callback the vault refuses leaves its window open.
    function _fillWindows(Windows memory side, bool isDeposit) internal {
        for (uint256 i; i < side.count; i++) {
            if (gasleft() < CLAIM_RESERVE) return;
            RequestId requestId = VaultRequestIdLib.from(address(vaults[LONG_VAULT]), side.ids[i]);
            uint128 outstanding = _outstanding(Req(LONG_VAULT, requestId.raw(), isDeposit));
            if (outstanding < _dust(isDeposit)) continue;
            uint128 other =
                uint128(isDeposit ? outstanding * ONE_SHARE / ONE_ASSET : outstanding * ONE_ASSET / ONE_SHARE);
            bytes memory payload = isDeposit
                ? RequestCallbackMessageLib.serialize(
                    RequestCallbackMessageLib.SettledDeposit(requestId, outstanding, other)
                )
                : RequestCallbackMessageLib.serialize(
                    RequestCallbackMessageLib.SettledRedeem(requestId, other, outstanding)
                );
            _callAs(
                address(spokeHandler),
                address(vaultRouter),
                abi.encodeCall(vaultRouter.callback, (poolA, scA, usdcId, payload))
            );
        }
    }

    /// @dev A keeper folds the windows the horizon evicted, for every contributor that is still in them.
    function _foldEvicted(Windows memory side, uint256 horizon) internal {
        if (side.count <= horizon) return;
        IAsyncVault vault = vaults[LONG_VAULT];
        for (uint256 i; i < side.count - horizon; i++) {
            for (uint256 a; a < actors.length; a++) {
                if (vault.contribution(side.ids[i], actors[a]).amount == 0) continue;
                _boundedCall(
                    OUTSIDER,
                    address(vault),
                    abi.encodeCall(vault.foldRequest, (side.ids[i], actors[a])),
                    "a keeper's fold cost more gas than the ceiling"
                );
            }
        }
    }

    /// @dev The controller claims what it can on both sides, through the entrypoints the seed picks.
    function _claimBoth(uint256 a, uint256 seed) internal {
        IAsyncVault vault = vaults[LONG_VAULT];
        address actor = actors[a];
        if (frozen[actor] || !_healthy(vault, actor)) return;
        bool byAssets = (seed + a) % 2 == 0;
        uint256 shares = byAssets ? vault.maxDeposit(actor) : vault.maxMint(actor);
        if (shares != 0) {
            _boundedCall(
                actor,
                address(vault),
                abi.encodeWithSignature(
                    byAssets ? "deposit(uint256,address,address)" : "mint(uint256,address,address)",
                    shares,
                    actor,
                    actor
                ),
                "a deposit claim cost more gas than the ceiling"
            );
        }
        uint256 assets = byAssets ? vault.maxWithdraw(actor) : vault.maxRedeem(actor);
        if (assets != 0) {
            _boundedCall(
                actor,
                address(vault),
                abi.encodeWithSignature(
                    byAssets ? "withdraw(uint256,address,address)" : "redeem(uint256,address,address)",
                    assets,
                    actor,
                    actor
                ),
                "a redeem claim cost more gas than the ceiling"
            );
        }
    }
}
