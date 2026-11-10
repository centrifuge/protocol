// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CryticToFoundry} from "./CryticToFoundry.sol";

/// @dev Drives the share custody and instant-fee properties through states that exercise them and asserts they hold,
///      so a src mutation can be shown to fail each alone.
contract CustodyReachability is CryticToFoundry {
    function _custody() internal {
        _assertNoFailures();
        property_shareCustodyEquality();
        _assertNoFailures();
    }

    function testCustody_holdsThroughTheLifecycle() public {
        _custody();

        // A deposit and a part-filled one in a shared-window vault: unclaimed and unsurfaced entitlements
        vault_requestDeposit(0, 0, 0, 500 * ONE_ASSET);
        vault_requestDeposit(1, 1, 1, 300 * ONE_ASSET);
        _custody();
        hub_fulfill(0, 0, true);
        _custody();
        hub_fulfill(1, 100 * ONE_ASSET, false);
        _custody();
        assertGt(shareA.balanceOf(address(_escrow(poolA))), 0, "unreachable: shares in the escrow");

        // A part claim, then a redemption requested, part filled and the rest cancelled into a refund
        vault_claimMax(0, 0, true);
        _custody();
        vault_requestRedeem(0, 0, 0, shareA.balanceOf(actors[0]) / 2);
        _custody();
        hub_fulfill(0, 0, false);
        _custody();
        hub_cancel(0, 0, true);
        _custody();
        vault_claimMax(0, 0, false);
        vault_claimMax(0, 0, true);
        _custody();
        assertGt(ok["hub_fulfill"], 0, "unreachable: hub_fulfill");
        assertGt(ok["vault_requestRedeem"], 0, "unreachable: vault_requestRedeem");
        assertGt(ok["hub_cancel"], 0, "unreachable: hub_cancel");
    }

    /// @dev Claims and fills run on a vault whose lane pays a fee recipient, which none of them may pay.
    function testFee_noPayoutOutsideTheInstantActions() public {
        vault_instantDeposit(0, false, 300 * ONE_ASSET, false);
        vault_requestDeposit(0, 0, 0, 500 * ONE_ASSET);
        hub_fulfill(0, 0, true);
        vault_claimMax(0, 0, true);
        vault_requestRedeem(0, 0, 0, shareA.balanceOf(actors[0]) / 2);
        hub_fulfill(0, 0, true);
        vault_claimMax(0, 0, false);
        assertGt(ok["vault_claimMaxRedeem"], 0, "unreachable: vault_claimMaxRedeem");
        assertGt(ghost_feeQuoted, 0, "no fee was quoted");
        _assertNoFailures();
        property_feeRecipientReceivedTheQuotedFees();
        _assertNoFailures();
    }

    function testFee_instantActionsPayTheQuotedFee() public {
        // The first vault pays a fee to a recipient, the second retains it in the escrow
        vault_instantDeposit(0, false, 300 * ONE_ASSET, false);
        vault_instantDeposit(1, false, 40 * ONE_ASSET, true);
        vault_instantDeposit(0, true, 300 * ONE_ASSET, false);
        vault_instantRedeem(0, false, 2 * ONE_SHARE, false);
        vault_instantRedeem(1, false, ONE_ASSET, true);
        vault_instantRedeem(0, true, ONE_SHARE, false);
        vault_instantTradeFor(0, 1, false, 50 * ONE_ASSET, 0);
        vault_instantTradeFor(0, 1, false, 5 * ONE_SHARE, 1);
        vault_instantTradeFor(0, 2, false, ONE_SHARE, 2);
        vault_instantTradeFor(0, 1, false, ONE_ASSET, 3);
        vault_instantTradeFor(0, 1, true, 50 * ONE_ASSET, 0);

        assertGt(ok["vault_instantDeposit"], 2, "unreachable: vault_instantDeposit");
        assertGt(ok["vault_instantRedeem"], 2, "unreachable: vault_instantRedeem");
        assertGt(ok["vault_instantTradeFor"], 3, "unreachable: vault_instantTradeFor");
        assertGt(ghost_feeQuoted, 0, "no fee was quoted");
        _assertNoFailures();
        property_feeRecipientReceivedTheQuotedFees();
        _assertNoFailures();
    }
}
