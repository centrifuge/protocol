// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ActorClaimProperties} from "./ActorClaimProperties.sol";

/// @notice The vaults' claimable ledgers against the value flow ghosts, exactly.
/// @dev    `property_sum_of_shares_received` and `property_sum_of_assets_received` bound what claims paid from above
///         (`claimed <= owed`). These pin the other side too: what the investors can still claim is what settlement
///         made claimable less what claims paid, so a ledger that loses a unit, or one a claim does not shrink by what
///         it paid, fails the next time any property runs and not only when a full exit happens to expose it.
///         `ghost_*Owed` is what the claimable views gained (a fill or a cancellation, or a fold or a request
///         surfacing a settled slice), `ghost_*Claimed` what the claimers' balances gained, so the two sides are
///         measured independently of the vault's own ledger arithmetic. Every handler that settles, folds, requests or
///         claims in a pool A vault records its part, the claim handlers also check each claim shrinks the ledger by
///         what it paid (`_ledgerMoved`), so a ledger that drifts breaks this the call it drifts.
abstract contract ClaimLedgerProperties is ActorClaimProperties {
    /// @dev Per vault, over the actors who can hold a ledger: the shares claimable on the deposit side (the filled
    ///      ones and the refunded ones of a cancelled redemption) are exactly the shares owed less the shares paid, and
    ///      the assets claimable on the redeem side (the filled ones and the refunded ones of a cancelled deposit)
    ///      exactly the assets owed less the assets paid. No tolerance: a fold credits the slice it is shown and a
    ///      claim takes the amount it returns from the ledger, both integers, so the pro-rata roundings of the
    ///      conversions move value between the ledger's own counters, never between the ledger and these totals.
    function property_claimableMatchesOwedLessClaimed() public {
        for (uint8 v; v < vaults.length; v++) {
            address vault = address(vaults[v]);
            (uint256 shares, uint256 assets) = _claimable(v);
            eq(shares + ghost_sharesClaimed[vault], ghost_sharesOwed[vault], "claimable shares != owed - claimed");
            eq(assets + ghost_assetsClaimed[vault], ghost_assetsOwed[vault], "claimable assets != owed - claimed");
        }
    }

    /// @dev Counts what a claim made through a path that does not measure it itself paid to `who`: the shares and
    ///      assets its balances gained since `sharesBefore` and `assetsBefore`. `who` is the controller whose ledger the
    ///      claim drew on, and the receiver.
    function _countClaimed(address vault, address who, uint256 sharesBefore, uint256 assetsBefore) internal {
        _addClaimed(
            vault, who, _floorSub(shareA.balanceOf(who), sharesBefore), _floorSub(usdc.balanceOf(who), assetsBefore)
        );
    }
}
