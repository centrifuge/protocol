// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CryticToFoundry} from "./CryticToFoundry.sol";

import {console} from "forge-std/console.sol";

/// @dev Drives the exit rescue with state it can act on and asserts it ran to its checks, so a setup change that
///      turns it into a silent skip fails here, and a src mutation can be shown to fail it.
contract ExitReachability is CryticToFoundry {
    uint256 internal worstGas;
    uint256 internal rescues;
    uint256 internal completedRescues;
    uint256 internal filledOrders;
    uint256 internal cancelledOrders;
    uint256 internal exitedPositions;
    uint256 internal instantExits;

    /// @dev Open orders on every vault and both sides, a queued window, a partial fill, then the rescue: it settles and
    ///      claims everyone, leaves nothing behind, and the handler itself leaves no trace.
    function testExit_everyoneLeaves() public {
        // Shares to redeem with
        for (uint256 a; a < 3; a++) {
            flow_deposit(a, a % 2, 2_000 * ONE_ASSET, a);
        }
        for (uint256 v; v < 3; v++) {
            vault_requestDeposit(v, v, v, (100 + v) * ONE_ASSET);
            vault_requestRedeem(v, v, v, 10 * ONE_SHARE);
        }
        hub_fulfill(0, 40 * ONE_ASSET, false);
        _assertNoFailures();

        // The handler is stateless: it reverts with its marker and leaves what it ran in untouched
        uint256 escrowBefore = shareA.balanceOf(address(_escrow(poolA)));
        uint256 assetsBefore = usdc.balanceOf(actors[0]);
        uint256 timeBefore = block.timestamp;
        try this.exit_everyoneCanLeave(3) {
            if (failures.length != 0) console.log("FAILURE", failures[0]);
            assertTrue(false, "the handler did not revert");
        } catch (bytes memory err) {
            assertEq(bytes4(err), ExitRehearsalEnded.selector, "the handler reverted with another error");
        }
        assertEq(shareA.balanceOf(address(_escrow(poolA))), escrowBefore, "the handler left shares behind");
        assertEq(usdc.balanceOf(actors[0]), assetsBefore, "the handler left assets behind");
        assertEq(block.timestamp, timeBefore, "the handler left time moved");
        _assertNoFailures();

        uint256 g0 = gasleft();
        Rescue memory s = _everyoneCanLeave(3);
        console.log("rescue gas", g0 - gasleft());
        console.log("incomplete", s.incomplete ? 1 : 0);
        _assertNoFailures();
        assertTrue(s.completed, "the rescue did not reach the end state");
        assertGt(s.filled, 0, "the rescue filled nothing");
        assertGt(s.exits, 0, "the rescue claimed nothing");
        for (uint256 a; a < actors.length; a++) {
            for (uint256 v; v < vaults.length; v++) {
                assertEq(vaults[v].claimableMint(actors[a]), 0, "shares left to claim");
                assertEq(vaults[v].claimableWithdraw(actors[a]), 0, "assets left to claim");
                assertEq(vaults[v].pendingDepositRequest(0, actors[a]), 0, "a deposit left pending");
                assertEq(vaults[v].pendingRedeemRequest(0, actors[a]), 0, "a redemption left pending");
            }
        }
        assertProperties();
    }

    /// @dev An order the hub refuses to fill is cancelled: at a fee past the one the hub takes the fill at 99.99%,
    ///      a dust deposit converts to nothing.
    function testExit_cancelsWhatCannotBeFilled() public {
        hub_setFee(uint16(9_999), true);
        vault_requestDeposit(0, 0, 0, 2 * DUST_ASSETS);
        vault_requestDeposit(1, 1, 0, 5 * ONE_ASSET);
        Rescue memory s = _everyoneCanLeave(0);
        _assertNoFailures();
        assertGt(s.cancelled, 0, "no order was cancelled");
        assertTrue(s.completed, "the rescue did not reach the end state");
        assertProperties();
    }

    /// @dev Random sequences of the handlers that open orders, settle them part way, lapse and freeze investors,
    ///      move prices, fees and time, retire vaults and over-reserve the escrow, then the rescue: a failed check
    ///      anywhere fails the run, and the gas of the rescue is measured on the states this reaches.
    function testFuzzEveryoneCanExit(uint256 seed) public {
        for (uint256 i; i < 28; i++) {
            seed = _fuzzW(seed, i);
            _exitStep(seed);
            if (failures.length != 0) break;
        }
        if (failures.length == 0) _exitRescue(seed);
        if (failures.length != 0) console.log("FAILURE", failures[0]);
        assertEq(failures.length, 0);
    }

    /// @dev The rescue on a state a fuzz sequence reached, run as the internal function so its outcome can be read
    ///      (the external handler would revert it away); the marker and the statelessness are tested above.
    function _exitRescue(uint256 seed) internal {
        uint256 g = gasleft();
        Rescue memory s = _everyoneCanLeave(seed);
        uint256 used = g - gasleft();
        if (used > worstGas) worstGas = used;
        console.log("RESCUE done/filled/cancelled/exits", s.completed ? 1 : 0, s.filled, s.cancelled);
        console.log("RESCUE exits/instant/gas", s.exits, s.instantExits, used);
        // The role hook's per-request onRoles dispatch adds a few thousand gas each; the ceiling carries that margin.
        assertLt(used, 12_500_000, "the exit rescue spent more gas than a call may");
    }

    function testExit_gasOfTheWorstCase() public {
        // Every actor in every vault with an open order of each side, nothing settled
        for (uint256 a; a < 3; a++) {
            flow_deposit(a, 0, 5_000 * ONE_ASSET, a);
        }
        for (uint256 round; round < 3; round++) {
            for (uint256 v; v < 5; v++) {
                for (uint256 a; a < 3; a++) {
                    vault_requestDeposit(a, a, v, (10 + round) * ONE_ASSET);
                    vault_requestRedeem(a, a, v, (round + 1) * ONE_SHARE);
                }
            }
            hub_warp(1 hours);
        }
        uint256 g = gasleft();
        Rescue memory s = _everyoneCanLeave(1);
        console.log("worst-case rescue gas", g - gasleft());
        console.log("filled cancelled exits", s.filled, s.cancelled, s.exits);
        console.log("incomplete", s.incomplete ? 1 : 0, "reqs", reqs.length);
        _assertNoFailures();
        assertLt(g - gasleft(), 12_500_000, "the exit rescue spent more gas than a call may");
    }

    /// @dev One handler call drawn from the handlers that decide what a rescue meets. Requests are the most common, so
    ///      orders are usually open; the rest move what makes a rescue skip or settle differently.
    function _exitStep(uint256 seed) internal {
        uint256 k = seed % 40;
        uint256 a = _fuzzW(seed, 1);
        uint256 b = _fuzzW(seed, 2);
        uint256 c = _fuzzW(seed, 3);
        uint256 d = _fuzzW(seed, 4);
        bytes memory data;
        if (k < 8) {
            data = abi.encodeWithSelector(this.vault_requestDeposit.selector, a, b, c, d);
        } else if (k < 14) {
            data = abi.encodeWithSelector(this.vault_requestRedeem.selector, a, b, c, d);
        } else if (k == 14 || k == 15) {
            data = abi.encodeWithSelector(this.hub_fulfill.selector, a, b, c % 2 == 0);
        } else if (k == 16) {
            data = abi.encodeWithSelector(this.hub_cancel.selector, a, b, c % 2 == 0);
        } else if (k == 17) {
            data = abi.encodeWithSelector(this.vault_flush.selector, a);
        } else if (k == 18) {
            data = abi.encodeWithSelector(this.vault_fold.selector, a, b);
        } else if (k == 19) {
            data = abi.encodeWithSelector(this.vault_claimMax.selector, a, b, c % 2 == 0);
        } else if (k == 20) {
            data = abi.encodeWithSelector(this.vault_claimRedeem.selector, a, b, c, d % 2 == 0);
        } else if (k == 21) {
            data = abi.encodeWithSelector(this.vault_claimDeposit.selector, a, b, c, d % 2 == 0);
        } else if (k == 22) {
            data = abi.encodeWithSelector(this.vault_instantDeposit.selector, a, b % 2 == 0, c, d % 2 == 0);
        } else if (k == 23) {
            data = abi.encodeWithSelector(this.vault_instantRedeem.selector, a, b % 2 == 0, c, d % 2 == 0);
        } else if (k == 24) {
            data = abi.encodeWithSelector(this.flow_deposit.selector, a, b, c, d);
        } else if (k == 25) {
            data = abi.encodeWithSelector(this.flow_redeem.selector, a, b, c, d);
        } else if (k == 26) {
            data = abi.encodeWithSelector(this.hub_lapseMember.selector, a, b % 7200, c % 4 == 0);
        } else if (k == 27) {
            data = abi.encodeWithSelector(this.hub_freeze.selector, a);
        } else if (k == 28) {
            data = abi.encodeWithSelector(this.hub_unfreeze.selector);
        } else if (k == 29) {
            data = abi.encodeWithSelector(this.hub_updateSharePrice.selector, a, uint8(b));
        } else if (k == 30) {
            data = abi.encodeWithSelector(this.hub_setFee.selector, uint16(a), b % 2 == 0);
        } else if (k == 31) {
            data = abi.encodeWithSelector(this.hub_warp.selector, a);
        } else if (k == 32) {
            data = abi.encodeWithSelector(this.hub_installPolicy.selector);
        } else if (k == 33) {
            data = abi.encodeWithSelector(this.balanceSheet_reserve.selector, a, uint128(b), c % 2 == 0);
        } else if (k == 34) {
            data = abi.encodeWithSelector(this.balanceSheet_withdraw.selector, a, c % 8 == 0, uint128(b));
        } else if (k == 35) {
            data = abi.encodeWithSelector(this.hub_setVaultLink.selector, a, c % 3 != 0);
        } else if (k == 36) {
            data = abi.encodeWithSelector(this.hub_setVaultManager.selector, a, c % 3 != 0);
        } else if (k == 37) {
            data = abi.encodeWithSelector(this.oracle_refresh.selector);
        } else if (k == 38) {
            data = abi.encodeWithSelector(this.oracle_stale.selector, a);
        } else {
            data = abi.encodeWithSelector(this.flow_sharedWindow.selector, a, b, c % 2 == 0);
        }
        vm.roll(block.number + a % 300);
        vm.warp(block.timestamp + b % 3600);
        vm.prank(address(uint160(((c % 3) + 1) * 0x10000)));
        (bool success,) = address(this).call(data);
        success;
    }
}
