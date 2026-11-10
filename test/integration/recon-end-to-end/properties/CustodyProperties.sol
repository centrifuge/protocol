// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ConservationProperties} from "./ConservationProperties.sol";

import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import {BucketReference} from "../../../vaults/BucketReference.sol";

import {IAsyncVault, Bucket, Contribution} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {vm} from "@chimera/Hevm.sol";

/// @notice Share custody: the shares pool A's escrow holds are the shares it owes, to the unit, up to the rounding
///         dust of the buckets that settled and still stand.
/// @dev    Owed across every vault of the share class: what each controller's ledger holds in shares (the stored
///         counters, read raw, so the claimable views' partial reading of the unfolded slices plays no part), every
///         settled slice a fold has not credited yet, exactly as the vault computes it from the bucket and the
///         contribution, the redeem shares requested and neither revoked nor refunded (queued ones included, since a
///         request moves its shares into the escrow before it is flushed), and the balance-sheet manager's float. An
///         instant deposit mints to its receiver and an instant redemption burns what it pulled, so neither rests in
///         the escrow.
///
///         Equality is exact until a shared bucket settles. A bucket's fills are issued whole while its contributors
///         are credited the floor of their pro-rata slices of the cumulative total, so the escrow keeps the
///         difference, which is below one unit per contributor but one however many fills the bucket takes. A
///         contributor's slice is not recorded once its fold completes (the contribution is deleted and the bucket
///         keeps only its totals), so the dust a bucket has left is not derivable from the vault's views. The bound
///         is therefore that per-bucket worst case for every bucket that settled and was left standing
///         (`ghost_standingBuckets`), which a sole owner's bucket, retired by its own fill, never adds to.
abstract contract CustodyProperties is ConservationProperties {
    function property_shareCustodyEquality() public {
        (uint256 held, uint256 owed) = _shareCustody();
        gte(held, owed, "the escrow holds fewer shares than are owed against it");
        lte(
            _floorSub(held, owed),
            ghost_standingBuckets * _dustPerSettlement(),
            "the escrow holds shares beyond the rounding dust of the buckets that settled"
        );
        if (ghost_standingBuckets == 0) {
            eq(held, owed, "shares in the escrow != shares owed before a shared bucket settled");
        }
    }

    /// @dev What the escrow holds of pool A's shares and what is owed against them.
    function _shareCustody() internal returns (uint256 held, uint256 owed) {
        held = shareA.balanceOf(address(_escrow(poolA)));
        owed = ghost_bsmEscrowShares;
        for (uint256 v; v < vaults.length; v++) {
            for (uint256 a; a < actors.length; a++) {
                bytes32 base = keccak256(abi.encode(actors[a], INVESTMENTS_SLOT));
                // depositShares is the low half of the first slot, refundShares the low half of the third
                owed += uint128(uint256(vm.load(address(vaults[v]), base)));
                owed += uint128(uint256(vm.load(address(vaults[v]), bytes32(uint256(base) + 2))));
            }
        }
        for (uint256 i; i < reqs.length; i++) {
            uint96 localId = uint96(reqs[i].requestId);
            IAsyncVault vault = vaults[reqs[i].vault];
            Bucket memory b = vault.bucket(localId);
            if (b.total == 0) continue;
            if (!b.isDeposit) owed += BucketReference.outstanding(b);
            for (uint256 a; a < actors.length; a++) {
                Contribution memory c = vault.contribution(localId, actors[a]);
                if (c.amount == 0) continue;
                owed += _unfoldedShares(b, c);
            }
        }
    }

    /// @dev The shares a fold of this contribution would make claimable: the settled slice of a deposit's issued
    ///      shares, or of a redemption's refund, less what was folded.
    function _unfoldedShares(Bucket memory b, Contribution memory c) internal pure returns (uint256) {
        if (b.isDeposit) {
            return _floorSub(MathLib.mulDiv(b.fulfilledShares, c.amount, b.total), c.foldedShares);
        }
        return _floorSub(MathLib.mulDiv(b.cancelledNet, c.amount, b.total), c.foldedCancelledNet);
    }
}
