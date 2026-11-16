// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FoundryHarness} from "./FoundryHarness.sol";

/// @dev Drives pool P's handlers through every answer the strict policy gives (in policy, held, blocked outright),
///      so a policy that classifies a call another way fails here alone.
contract StrictPolicyReachability is FoundryHarness {
    function _holds() internal {
        _assertNoFailures();
        property_strictPolicyAnchorsOnExecutedMoves();
        _assertNoFailures();
    }

    function testRestriction_onlyACanonicalFreezeIsInPolicy() public {
        for (uint256 kind; kind < 5; kind++) {
            strict_updateRestriction(kind, 0, false);
            strict_updateRestriction(kind, 0, true);
        }
        _holds();
        // The freeze twice, and the unfreeze and the membership once authorized
        assertGe(ok["strict_updateRestriction"], 4, "unreachable: a restriction update sent");
        // The four kinds out of policy, sent without an authorization
        assertGe(reverted["strict_updateRestriction"], 4, "unreachable: a restriction update held");
    }

    function testAccounting_belongsToTheNavManager() public {
        for (uint256 which; which < 8; which++) {
            strict_accounting(which);
        }
        _holds();
        assertEq(ok["strict_accounting"], 8, "unreachable: strict_accounting");
    }

    function testSharePrice_onlyABoundedMoveIsInPolicy() public {
        // The first update under the policy is unguarded, even past the absolute bound
        strict_updateSharePrice(2 * STRICT_MAX_PRICE_DELTA, 1, true, false);
        assertEq(ok["strict_priceInPolicy"], 1, "unreachable: the first update");
        assertEq(ghostStrictPriceAnchor, block.timestamp, "the first update did not anchor");

        // In the block of the last move any move waits, and a re-commit does not
        strict_updateSharePrice(1, 1, true, false);
        assertEq(reverted["strict_updateSharePrice"], 1, "unreachable: a move in the same block");
        strict_updateSharePrice(0, 0, true, false);
        assertEq(ok["strict_priceInPolicy"], 2, "unreachable: a re-commit");

        // An hour on, a move under both bounds is in policy, and a re-commit after it leaves the baseline
        vm.warp(block.timestamp + 1 hours);
        strict_updateSharePrice(STRICT_MAX_PRICE_DELTA / 10, 1, false, false);
        assertEq(ok["strict_priceInPolicy"], 3, "unreachable: a bounded move");
        uint64 anchor = ghostStrictPriceAnchor;
        vm.warp(block.timestamp + 3 hours);
        strict_updateSharePrice(0, 0, true, false);
        assertEq(ghostStrictPriceAnchor, anchor, "a re-commit moved the baseline");
        _holds();

        // Three hours after the last move the rate bound admits a move at the absolute bound, which still waits,
        // and goes through once authorized
        strict_updateSharePrice(STRICT_MAX_PRICE_DELTA, 1, true, false);
        assertEq(reverted["strict_updateSharePrice"], 2, "unreachable: a move at the absolute bound");
        strict_updateSharePrice(STRICT_MAX_PRICE_DELTA, 1, true, true);
        assertEq(ok["strict_priceAuthorized"], 1, "unreachable: an authorized move");

        // Ten minutes on, a move under the absolute bound but faster than the rate waits
        vm.warp(block.timestamp + 10 minutes);
        strict_updateSharePrice(STRICT_MAX_PRICE_DELTA / 2, 1, false, false);
        assertEq(reverted["strict_updateSharePrice"], 3, "unreachable: a move over the rate");
        _holds();
    }
}
