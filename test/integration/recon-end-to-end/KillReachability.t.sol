// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CryticToFoundry} from "./CryticToFoundry.sol";

/// @dev Drives the refusal and rounding checks of the vault with state they can act on and asserts they ran to their
///      assertions, so a setup change that turns them into silent returns fails here, and a src mutation can be shown
///      to fail them.
contract KillReachability is CryticToFoundry {
    /// @dev A withdraw claim at an amount the ledger does not divide evenly, after a fill at a price that makes the
    ///      pro-rata inexact.
    function testKill_withdrawClaimRoundsUp() public {
        vault_requestDeposit(0, 0, 0, 1_000 * ONE_ASSET + 7);
        hub_fulfill(0, 0, true);
        vault_claimMax(0, 0, true);
        hub_updateSharePrice(1_370_000_000_000_000_007, 2);
        vault_requestRedeem(0, 0, 0, shareA.balanceOf(actors[0]) / 3 + 1);
        hub_fulfill(1, 0, true);

        address actor = actors[0];
        uint256 shares = vaults[0].claimableRedeemRequest(0, actor);
        uint256 assets = vaults[0].claimableWithdraw(actor);
        uint256 amount = assets / 3 + 1;
        assertTrue(shares * amount % assets != 0, "the claim is exact, so rounding is not reached");
        assertTrue(_claimRedeem(vaults[0], actor, amount, false, false), "the withdraw claim reverted");
        _assertNoFailures();
    }

    function testKill_strangerCannotTransferRequest() public {
        vault_requestDeposit(0, 0, 1, 500 * ONE_ASSET);
        for (uint8 k; k < 12; k += 4) {
            vault_strangerCannotMoveRequest(0, 0, 1, k);
        }
        assertGt(ok["vault_strangerCannotMoveRequest"], 0, "unreachable: vault_strangerCannotMoveRequest");
        _assertNoFailures();
    }

    function testKill_unlinkedRefusesRequests() public {
        vault_requestDeposit(0, 0, 0, 1_000 * ONE_ASSET);
        hub_fulfill(0, 0, true);
        vault_claimMax(0, 0, true);
        for (uint256 v; v < 3; v++) {
            vault_unlinkedRefusesRequests(v, 0, 1e6);
        }
        assertEq(ok["vault_unlinkedRefusesRequests"], 3, "unreachable: vault_unlinkedRefusesRequests");
        assertTrue(!vaultUnlinked[address(vaults[0])], "the vault was left unlinked");
        _assertNoFailures();
    }

    /// @dev Three and four settled positions of one controller in each per-period vault, on both sides, folded by
    ///      nothing but the claim.
    function testKill_claimFoldsTheHorizon() public {
        uint256 reached;
        for (uint256 s; s < 8; s++) {
            uint256 seed = uint256(keccak256(abi.encode(s)));
            uint256 before = ok["flow_claimFoldsTheHorizon"];
            flow_claimFoldsTheHorizon(s, s, seed, seed, uint8(s), s % 4 < 2);
            reached += ok["flow_claimFoldsTheHorizon"] - before;
        }
        assertGt(reached, 2, "unreachable: flow_claimFoldsTheHorizon");
        _assertNoFailures();
    }
}
