// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CryticToFoundry} from "./CryticToFoundry.sol";

import {console} from "forge-std/console.sol";

/// @dev Drives the order independence flows and the policy swap rescue with state they can act on and asserts they ran
///      to their checks, so a setup change that turns them into silent skips fails here, and a src mutation can be
///      shown to fail them.
contract OrderIndependenceReachability is CryticToFoundry {
    function testOrder_foldClaimDeposit() public {
        _reachFoldClaim(true);
    }

    function testOrder_foldClaimRedeem() public {
        _reachFoldClaim(false);
    }

    function testOrder_flushTimingDeposit() public {
        _reachFlushTiming(true);
    }

    function testOrder_flushTimingRedeem() public {
        _reachFlushTiming(false);
    }

    /// @dev Shares to redeem with.
    function _holders() internal {
        for (uint256 a; a < 3; a++) {
            flow_deposit(a, 0, 2_000 * ONE_ASSET, a);
        }
    }

    function _reachFoldClaim(bool isDeposit) internal {
        if (!isDeposit) _holders();
        uint256 ran;
        for (uint256 s; s < 8; s++) {
            uint256 seed = uint256(keccak256(abi.encode(s, isDeposit)));
            uint256 before = ok["flow_foldClaimOrder"];
            uint256 g = gasleft();
            flow_foldClaimOrder(s, s, seed, seed + s, isDeposit);
            if (g - gasleft() > worstGas) worstGas = g - gasleft();
            ran += ok["flow_foldClaimOrder"] - before;
            _assertNoFailures();
        }
        console.log("ran / worst gas", ran, worstGas);
        assertGt(ran, 0, "unreachable: flow_foldClaimOrder");
        assertLt(worstGas, 12_500_000, "the handler spent more gas than a call may");
        assertProperties();
    }

    function _reachFlushTiming(bool isDeposit) internal {
        if (!isDeposit) _holders();
        uint256 withNext;
        uint256 alone;
        for (uint256 s; s < 12; s++) {
            uint256 seed = uint256(keccak256(abi.encode(s, isDeposit, "flush")));
            uint256 before = ok["flow_flushTimingIndependence"];
            uint256 g = gasleft();
            flow_flushTimingIndependence(s, s, seed, seed, isDeposit);
            if (g - gasleft() > worstGas) worstGas = g - gasleft();
            if (ok["flow_flushTimingIndependence"] > before) {
                if (seed / 11 % 2 == 1) withNext++;
                else alone++;
            }
            _assertNoFailures();
        }
        console.log("with next / alone / worst gas", withNext, alone, worstGas);
        assertGt(withNext, 0, "unreachable: flush timing with a second window");
        assertGt(alone, 0, "unreachable: flush timing with one window");
        assertLt(worstGas, 12_500_000, "the handler spent more gas than a call may");
        assertProperties();
    }

    uint256 internal worstGas;

    /// @dev Open orders on every vault and both sides, a queued window and a part fill, then the pool re-terms its
    ///      policies and the rescue takes everyone out; the handler itself leaves no trace.
    function testExit_afterPolicySwap() public {
        _swapReach(0);
    }

    function testExit_afterFeeSwap() public {
        _swapReach(1);
    }

    function testExit_afterObserverSwap() public {
        _swapReach(2);
    }

    function _swapReach(uint256 kind) internal {
        for (uint256 a; a < 3; a++) {
            flow_deposit(a, a % 2, 2_000 * ONE_ASSET, a);
        }
        for (uint256 v; v < 3; v++) {
            vault_requestDeposit(v, v, v, (100 + v) * ONE_ASSET);
            vault_requestRedeem(v, v, v, 10 * ONE_SHARE);
        }
        hub_fulfill(0, 40 * ONE_ASSET, false);
        _assertNoFailures();

        uint256 escrowBefore = shareA.balanceOf(address(_escrow(poolA)));
        uint256 timeBefore = block.timestamp;
        // Flags 8 close instant redemptions on the first instant vault, a fee moves the fills
        uint256 swap = 16;
        swap = swap | uint256(250) << 16 | uint256(77) << 8;
        assertTrue(swap % 8 == 0 && swap % 5 != 0);
        swap |= kind << 72;
        uint256 g = gasleft();
        try this.exit_afterPolicySwap(3, swap) {
            _assertNoFailures();
            assertTrue(false, "the handler did not revert");
        } catch (bytes memory err) {
            if (failures.length != 0) console.log("FAILURE", failures[0]);
            assertEq(bytes4(err), ExitRehearsalEnded.selector, "the handler reverted with another error");
        }
        console.log("handler gas", g - gasleft());
        assertLt(g - gasleft(), 12_500_000, "the handler spent more gas than a call may");
        assertEq(shareA.balanceOf(address(_escrow(poolA))), escrowBefore, "the handler left shares behind");
        assertEq(block.timestamp, timeBefore, "the handler left time moved");
        _assertNoFailures();

        Rescue memory s = _afterPolicySwap(3, swap);
        console.log("incomplete/blocked/over", s.incomplete ? 1 : 0, s.blocked, _overReserved() ? 1 : 0);
        console.log("filled/cancelled/exits", s.filled, s.cancelled, s.exits);
        _assertNoFailures();
        assertTrue(s.completed, "the rescue did not reach the end state");
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

    function testFuzzOrderIndependence(uint256 a, uint256 b, uint256 c, uint256 d, bool dep, bool flush) public {
        if (!dep) _holders();
        if (flush) flow_flushTimingIndependence(a, b, c, d, dep);
        else flow_foldClaimOrder(a, b, c, d, dep);
        _assertNoFailures();
        assertProperties();
    }

    function testFuzzAfterPolicySwap(uint256 seed, uint256 swap) public {
        for (uint256 a; a < 3; a++) {
            flow_deposit(a, a % 2, 2_000 * ONE_ASSET, a);
        }
        for (uint256 v; v < 4; v++) {
            vault_requestDeposit(v, v, v, (100 + v) * ONE_ASSET);
            vault_requestRedeem(v, v, v, 10 * ONE_SHARE);
        }
        uint256 g = gasleft();
        _afterPolicySwap(seed, swap);
        assertLt(g - gasleft(), 12_500_000, "the handler spent more gas than a call may");
        if (failures.length != 0) console.log("FAILURE", failures[0]);
        assertEq(failures.length, 0);
    }
}
