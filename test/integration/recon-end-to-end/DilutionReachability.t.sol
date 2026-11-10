// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CryticToFoundry} from "./CryticToFoundry.sol";

/// @dev Drives the instant lanes and the single-vault actions with state the checks can judge, and asserts they ran to
///      their checks, so a setup change that turns them into silent skips fails here, and a src mutation can be shown
///      to fail them.
contract DilutionReachability is CryticToFoundry {
    /// @dev Holders, a share price off par so every conversion rounds, then both instant vaults on both sides and in
    ///      both units, each judged on a bystander's value and on the value the caller takes out.
    function testInstantLaneNonDilution() public {
        _holders();
        for (uint256 i; i < 16; i++) {
            vault_instantDeposit(i, i % 2 == 1, 1_234_567 + i * 7_920, i % 4 >= 2);
            vault_instantRedeem(i, i % 2 == 1, 777_777_777_777_777 + i * 31_337, i % 4 >= 2);
        }
        _assertNoFailures();
        assertGt(ok["vault_instantDeposit"], 4, "unreachable: vault_instantDeposit");
        assertGt(ok["vault_instantRedeem"], 4, "unreachable: vault_instantRedeem");
        assertGt(ghost_dilutionChecks, 8, "the non-dilution check never judged a bystander");
        assertProperties();
    }

    /// @dev Requests, claims and flushes on one vault while the others hold positions of their own.
    function testSiblingIsolation() public {
        for (uint256 v; v < vaults.length; v++) {
            vault_requestDeposit(v, v + 1, v, (100 + v) * ONE_ASSET);
            vault_requestRedeem(v, v + 2, v, ONE_SHARE);
        }
        hub_warp(2 hours);
        hub_fulfill(0, 0, true);
        hub_fulfill(2, 0, true);
        vault_requestDeposit(1, 1, 0, ONE_ASSET);
        vault_requestDeposit(1, 1, 2, ONE_ASSET);
        for (uint256 i; i < 8; i++) {
            vault_flush(i);
            vault_claimDeposit(i, i, type(uint256).max, i % 2 == 0);
            vault_claimRedeem(i, i, type(uint256).max, i % 2 == 0);
            vault_requestDeposit(i, i, i + 1, ONE_ASSET);
            vault_instantDeposit(i, i % 2 == 1, 5_000_001 + i * 8, false);
        }
        _assertNoFailures();
        assertGt(ghost_siblingChecks, 20, "the sibling check never ran");
        assertProperties();
    }

    /// @dev Two per-period vaults with open windows: flushing the window of one leaves the other's window queued.
    function testSiblingWindowsStayQueued() public {
        vault_requestDeposit(0, 1, 1, 100 * ONE_ASSET);
        vault_requestDeposit(1, 2, 4, 100 * ONE_ASSET);
        hub_warp(2 hours);
        assertTrue(_flushFirst(4), "vault 4 had nothing to flush");
        vault_requestDeposit(2, 3, 4, 100 * ONE_ASSET);
        hub_warp(2 hours);
        assertTrue(_flushFirst(1), "vault 1 had nothing to flush");
        _assertNoFailures();
        assertGt(ghost_siblingChecks, 0, "the sibling check never ran");
        assertProperties();
    }

    /// @dev A window of the per-period vault settled and not folded, then a request on the per-request vault, whose
    ///      flush goes through the router every vault shares: the sibling's stored ledger must stay as it was.
    function testSiblingLedgerStaysWhileAnotherVaultRequests() public {
        vault_requestDeposit(0, 0, 1, 100 * ONE_ASSET);
        hub_warp(2 hours);
        assertTrue(_flushFirst(1), "vault 1 had nothing to flush");
        hub_fulfill(0, 0, true);
        assertGt(ok["hub_fulfill"], 0, "unreachable: hub_fulfill");
        assertGt(vaults[1].claimableMint(actors[0]), 0, "the window left nothing claimable");

        uint256 checks = ghost_siblingChecks;
        vault_requestDeposit(1, 1, 0, ONE_ASSET);
        vault_requestDeposit(2, 2, 2, ONE_ASSET);
        assertGt(ghost_siblingChecks, checks, "the sibling check never judged a request");
        _assertNoFailures();
        assertProperties();
    }

    function _flushFirst(uint8 v) internal returns (bool) {
        for (uint256 i; i < reqs.length; i++) {
            if (reqs[i].vault != v || vaults[v].bucket(uint96(reqs[i].requestId)).queued == 0) continue;
            return _flush(reqs[i]);
        }
        return false;
    }

    function _holders() internal {
        for (uint256 a; a < 3; a++) {
            flow_deposit(a, a % 2, 2_000 * ONE_ASSET, a);
        }
        hub_updateSharePrice(1_370_000_001_234_567_891, 2);
    }
}
