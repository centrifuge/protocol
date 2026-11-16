// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Asserts} from "@chimera/Asserts.sol";
import {BeforeAfter} from "../BeforeAfter.sol";

/// @notice The claimable ledger per investor, and what a fill leaves alone.
/// @dev    `property_claimableMatchesOwedLessClaimed` pins each vault's claimable totals, which cannot see value
///         moving between two investors (a fold credited to the wrong controller, a claim that debits the operator).
///         These keep the same ghosts per controller: what the claimable views gained for that controller and what
///         claims paid out of its ledger, whoever the receiver or the caller was. The owed side is measured on its own
///         (each controller's views before and after a call that settles or surfaces), so a call that moved value
///         from one controller to another shows as the per-actor sum drifting from the per-vault ghost
///         (`property_actorGhostsSumToVaultGhosts`); the claimed side is written once for both (`_addClaimed`).
abstract contract ActorClaimProperties is BeforeAfter, Asserts {
    /// @dev Per vault and controller, in the units the views keep: shares on the deposit side, assets on the redeem side.
    mapping(address vault => mapping(address actor => uint256)) internal ghost_actorSharesOwed;
    mapping(address vault => mapping(address actor => uint256)) internal ghost_actorAssetsOwed;
    mapping(address vault => mapping(address actor => uint256)) internal ghost_actorSharesClaimed;
    mapping(address vault => mapping(address actor => uint256)) internal ghost_actorAssetsClaimed;

    /// @dev Each controller's claimable shares and assets must be exactly what settlement made claimable for it less
    ///      what claims paid out of its ledger. Same assumptions as the per-vault equality (no tolerance, ungated):
    ///      a fold credits the slice it is shown and a claim takes the amount it returns, both integers.
    function property_actorClaimableMatchesOwedLessClaimed() public {
        for (uint8 v; v < vaults.length; v++) {
            address vault = address(vaults[v]);
            for (uint256 a; a < actors.length; a++) {
                address actor = actors[a];
                eq(
                    vaults[v].claimableMint(actor) + ghost_actorSharesClaimed[vault][actor],
                    ghost_actorSharesOwed[vault][actor],
                    "an investor's claimable shares != owed - claimed"
                );
                eq(
                    vaults[v].claimableWithdraw(actor) + ghost_actorAssetsClaimed[vault][actor],
                    ghost_actorAssetsOwed[vault][actor],
                    "an investor's claimable assets != owed - claimed"
                );
            }
        }
    }

    /// @dev The per-vault ghosts are the sums of the per-actor ones: a call that lowered one controller's views while
    ///      raising another's leaves the per-vault ghost (a net) short of the per-actor sum (a gross).
    function property_actorGhostsSumToVaultGhosts() public {
        for (uint8 v; v < vaults.length; v++) {
            address vault = address(vaults[v]);
            uint256 sharesOwed;
            uint256 assetsOwed;
            uint256 sharesClaimed;
            uint256 assetsClaimed;
            for (uint256 a; a < actors.length; a++) {
                sharesOwed += ghost_actorSharesOwed[vault][actors[a]];
                assetsOwed += ghost_actorAssetsOwed[vault][actors[a]];
                sharesClaimed += ghost_actorSharesClaimed[vault][actors[a]];
                assetsClaimed += ghost_actorAssetsClaimed[vault][actors[a]];
            }
            eq(sharesOwed, ghost_sharesOwed[vault], "per-actor shares owed != per-vault");
            eq(assetsOwed, ghost_assetsOwed[vault], "per-actor assets owed != per-vault");
            eq(sharesClaimed, ghost_sharesClaimed[vault], "per-actor shares claimed != per-vault");
            eq(assetsClaimed, ghost_assetsClaimed[vault], "per-actor assets claimed != per-vault");
        }
    }

    /// @dev Records what a claim paid out of `controller`'s ledger, whoever called and whoever received it.
    function _addClaimed(address vault, address controller, uint256 shares, uint256 assets) internal {
        ghost_sharesClaimed[vault] += shares;
        ghost_assetsClaimed[vault] += assets;
        ghost_actorSharesClaimed[vault][controller] += shares;
        ghost_actorAssetsClaimed[vault][controller] += assets;
    }

    /// @dev The controllers' own claimable shares (first three) and assets (last three) in one vault.
    function _actorClaimable(uint8 v) internal view returns (uint256[6] memory c) {
        for (uint256 a; a < actors.length; a++) {
            c[a] = vaults[v].claimableMint(actors[a]);
            c[3 + a] = vaults[v].claimableWithdraw(actors[a]);
        }
    }

    /// @dev What each controller's claimable views gained in `v` since `before` (an `_actorClaimable` read), booked as
    ///      owed to that controller. A view that fell is not owed anything: a call that surfaces or settles
    ///      never lowers one, and `strict` makes that a failure where the call is a fill or a cancellation.
    function _noteActorsOwed(uint8 v, uint256[6] memory before, bool strict) internal {
        uint256[6] memory now_ = _actorClaimable(v);
        address vault = address(vaults[v]);
        for (uint256 a; a < actors.length; a++) {
            if (strict) {
                t(now_[a] >= before[a], "a fill or cancellation lowered an investor's claimable shares");
                t(now_[3 + a] >= before[3 + a], "a fill or cancellation lowered an investor's claimable assets");
            }
            ghost_actorSharesOwed[vault][actors[a]] += _floorSub(now_[a], before[a]);
            ghost_actorAssetsOwed[vault][actors[a]] += _floorSub(now_[3 + a], before[3 + a]);
        }
    }

    /// @dev A fill settles at its own price and fee: across a repricing (hub or holding value, pool C's price, time, the
    ///      oracle's staleness, skew or refresh) and across a change of fee, policy terms or oracle pause, nothing any
    ///      controller can already claim in the call's sampled vault moves. Run only after an operation that is not itself a settlement or a
    ///      claim (see `OpType.PRICE` and `OpType.TERMS`).
    function _checkClaimsFixed() internal override {
        t(
            _claimsFingerprint(sampledVault) == _claimsBefore,
            "a repricing or a terms change moved what an investor can claim"
        );
    }
}
