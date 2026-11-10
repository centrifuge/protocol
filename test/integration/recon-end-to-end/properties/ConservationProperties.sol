// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import {IEscrow} from "../../../../src/core/spoke/interfaces/IEscrow.sol";

import {BucketReference} from "../../../vaults/BucketReference.sol";

import {IAsyncVault, Bucket, Contribution, REASON_REDEEM} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {Asserts} from "@chimera/Asserts.sol";
import {BeforeAfter} from "../BeforeAfter.sol";

/// @notice Two-sided conservation: what the standing properties bound from above, bounded from below as well, so a
///         credit that is too small and value stranded in the escrow fail as loudly as a credit that is too large.
/// @dev    The rounding tolerance is the documented one and nothing more: a settled bucket's floor-rounded slices leave
///         at most one unit per contributor but one (`2` here, three investors) of dust in the escrow, once per
///         settlement (`ghost_settlements`).
abstract contract ConservationProperties is BeforeAfter, Asserts {
    /// @dev Fills and cancellations the manager applied: each can leave floor-rounding dust in the escrow.
    uint256 internal ghost_settlements;

    /// @dev The buckets whose first settlement left them standing, which is every shared one: a sole owner's bucket is
    ///      retired by the eager fold inside its fill, and reads as empty. Only a standing bucket can strand dust, and
    ///      at most one unit per contributor but one in all, however many fills it takes.
    uint256 internal ghost_standingBuckets;

    /// @dev What a bucket's pro-rata floors may strand, per settlement.
    function _dustPerSettlement() internal view returns (uint256) {
        return actors.length - 1;
    }

    /// @dev `a - b` that records a violation instead of reverting when `a < b`: a subtraction that underflows inside
    ///      a handler reverts the whole call, which hides exactly the state that broke the rule (Medusa and Echidna
    ///      in assertion mode both ignore the revert).
    function _nonNegativeDelta(uint256 a, uint256 b, string memory reason) internal returns (uint256) {
        t(a >= b, reason);
        return a > b ? a - b : 0;
    }

    //----------------------------------------------------------------------------------------------
    // Stranded value
    //----------------------------------------------------------------------------------------------

    /// @dev What pool A's escrow holds of its own shares, what is owed against them (claimable ledgers, pending
    ///      redemptions, the balance-sheet manager's float) and the most that could be owed but not yet counted: the
    ///      settled slices a fold has not surfaced, which the claimable views leave out outside a controller's horizon.
    function _shareBacking() internal view returns (uint256 held, uint256 owed, uint256 unfolded) {
        held = shareA.balanceOf(address(_escrow(poolA)));
        owed = ghost_bsmEscrowShares;
        for (uint8 v; v < vaults.length; v++) {
            (uint256 claimable,) = _claimable(v);
            (uint256 slices,) = _unfoldedBound(v);
            owed += claimable;
            unfolded += slices;
        }
        for (uint256 i; i < reqs.length; i++) {
            if (reqs[i].isDeposit) continue;
            owed += BucketReference.outstanding(vaults[reqs[i].vault].bucket(uint96(reqs[i].requestId)));
        }
    }

    /// @dev The redeem payouts reserved under the vaults' redeem reason, what is owed against them, and the settled
    ///      slices not yet surfaced.
    function _payoutBacking() internal view returns (uint256 reserved, uint256 owed, uint256 unfolded) {
        IEscrow escrow = _escrow(poolA);
        for (uint8 v; v < vaults.length; v++) {
            reserved += escrow.reservedBy(scA, address(vaults[v]), REASON_REDEEM, address(usdc), 0);
            (, uint256 claimable) = _claimable(v);
            (, uint256 slices) = _unfoldedBound(v);
            owed += claimable;
            unfolded += slices;
        }
    }

    /// @dev The escrow keeps no more of the vaults' shares and payouts than it owes. `property_sum_of_possible_...`
    ///      bounds this from below (everything owed is backed); this bounds it from above: what the escrow holds beyond
    ///      what is owed is at most the slices a fold has yet to surface plus the rounding dust of the settlements, so
    ///      a credit that comes out too small, or a fill that issues more than it credits, strands value and fails
    ///      here. The unfolded bound counts a settled slice inside a controller's horizon twice (the views already
    ///      carry it), which only loosens the bound.
    function property_noValueStrandedInEscrow() public {
        uint256 dust = ghost_settlements * _dustPerSettlement();
        (uint256 held, uint256 owed, uint256 unfolded) = _shareBacking();
        lte(_floorSub(held, owed), unfolded + dust, "shares stranded in the escrow beyond rounding dust");
        (uint256 reserved, uint256 payouts, uint256 unfoldedPayouts) = _payoutBacking();
        lte(_floorSub(reserved, payouts), unfoldedPayouts + dust, "payouts stranded in the reservation beyond dust");
    }

    /// @dev Vaults SPEC row 387, no under-fold: a contributor's folded snapshot never exceeds the slice settled for
    ///      it, in any bucket, so no fold ever has to credit a negative amount. Derived from the bucket and the
    ///      contribution alone, not from the views, and the reason `_unfoldedBound` can floor at zero.
    function property_foldedNeverExceedsSettled() public {
        for (uint256 i; i < reqs.length; i++) {
            uint96 localId = uint96(reqs[i].requestId);
            IAsyncVault vault = vaults[reqs[i].vault];
            Bucket memory b = vault.bucket(localId);
            if (b.total == 0) continue;
            for (uint256 a; a < actors.length; a++) {
                Contribution memory c = vault.contribution(localId, actors[a]);
                if (c.amount == 0) continue;
                lte(
                    c.foldedCancelledNet,
                    MathLib.mulDiv(b.cancelledNet, c.amount, b.total),
                    "folded cancelled net above the settled slice"
                );
                lte(
                    b.isDeposit ? c.foldedShares : c.foldedAssets,
                    MathLib.mulDiv(b.isDeposit ? b.fulfilledShares : b.fulfilledAssets, c.amount, b.total),
                    "folded fill above the settled slice"
                );
            }
        }
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7540
    //----------------------------------------------------------------------------------------------

    /// @dev ERC-7540 on a controller with a position to claim: `maxDeposit` and `maxMint` report exactly what
    ///      `claimableDepositRequest` and the ledger's shares hold, and `maxWithdraw` and `maxRedeem` the redeem
    ///      side's. Where the share hook refuses the fill, the figure is what is still claimable, the refund alone or
    ///      nothing, so at most the total. A healthy, unfrozen controller is never refused, so
    ///      for it the figures are equal. Not asserted for a controller with nothing claimable: its figures are then
    ///      the instant lane's capacity.
    function property_maxMatchesClaimable() public {
        for (uint8 v; v < vaults.length; v++) {
            IAsyncVault vault = vaults[v];
            for (uint256 a; a < actors.length; a++) {
                address actor = actors[a];
                bool open = !frozen[actor] && _claimOpen(vault, actor);
                uint256 shares = vault.claimableMint(actor);
                if (shares != 0) {
                    _matches(vault.maxMint(actor), shares, open, "maxMint != the claimable shares");
                    _matches(
                        vault.maxDeposit(actor),
                        vault.claimableDepositRequest(0, actor),
                        open,
                        "maxDeposit != claimableDepositRequest"
                    );
                }
                uint256 assets = vault.claimableWithdraw(actor);
                if (assets != 0) {
                    _matches(vault.maxWithdraw(actor), assets, open, "maxWithdraw != the claimable assets");
                    _matches(
                        vault.maxRedeem(actor),
                        vault.claimableRedeemRequest(0, actor),
                        open,
                        "maxRedeem != claimableRedeemRequest"
                    );
                }
            }
        }
    }

    function _matches(uint256 max, uint256 claimable, bool open, string memory reason) internal {
        if (open) eq(max, claimable, reason);
        else t(max <= claimable, reason);
    }

    //----------------------------------------------------------------------------------------------
    // Hub
    //----------------------------------------------------------------------------------------------

    /// @dev Vaults/hub SPECIFICATION, snapshot nonce: the hub consumes one nonce per accepted update, and hub and spoke
    ///      share a chain here, so its nonce is the spoke queue's, whichever flushes ran.
    function property_hubNonceMatchesSpoke() public {
        (, uint64 hubNonce) = holdings.snapshot(poolA, scA, CENTRIFUGE_ID);
        (,,, uint64 spokeNonce) = snapshotQueue.queuedShares(poolA, scA);
        eq(hubNonce, spokeNonce, "hub snapshot nonce != spoke queue nonce");
    }

    //----------------------------------------------------------------------------------------------
    // Bystanders
    //----------------------------------------------------------------------------------------------

    /// @dev What the accounts outside a vault operation hold, pool A's shares and USDC: the other investors, the
    ///      managers, the outsider, the fee recipient, the venue and its provider, and the other pools' escrows. No vault
    ///      operation may move them. USDC the route may carry off (the instant vaults) is left to the caller to skip.
    function _bystanders(address party) internal view returns (uint256 sharesHeld, uint256 usdcHeld) {
        address[7] memory others = [BSM, OUTSIDER, AUX_MANAGER, FEE_RECIPIENT, LP, address(basin), INVESTOR_B];
        for (uint256 i; i < actors.length; i++) {
            if (actors[i] == party) continue;
            sharesHeld += shareA.balanceOf(actors[i]);
            usdcHeld += usdc.balanceOf(actors[i]);
        }
        for (uint256 i; i < others.length; i++) {
            sharesHeld += shareA.balanceOf(others[i]);
            usdcHeld += usdc.balanceOf(others[i]);
        }
        usdcHeld += usdc.balanceOf(address(_escrow(poolB))) + usdc.balanceOf(address(_escrow(poolC)));
    }
}
