// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CryticToFoundry} from "./CryticToFoundry.sol";

import {d18} from "../../../src/misc/types/D18.sol";

/// @dev Drives every refused case of the callback atomicity handler with orders open on both sides, and asserts each
///      was attempted, refused and left no trace, so a setup change that turns a case into a silent skip fails here,
///      and a src mutation that lets a refused callback half apply can be shown to fail it.
contract AtomicityReachability is CryticToFoundry {
    function _open() internal {
        for (uint256 a; a < 3; a++) {
            flow_deposit(a, 0, 2_000 * ONE_ASSET, a);
        }
        vault_requestDeposit(0, 0, 0, 100 * ONE_ASSET);
        vault_requestDeposit(1, 1, 1, 50 * ONE_ASSET);
        vault_requestRedeem(2, 2, 0, 10 * ONE_SHARE);
        vault_requestRedeem(0, 0, 1, 5 * ONE_SHARE);
        _assertNoFailures();
    }

    function _refused(uint256 kind, uint256 reqSeed, uint256 amountSeed, bytes32 action) internal {
        atomic_refusedCallback(reqSeed, kind, amountSeed);
        _assertNoFailures();
        assertEq(ok[action], 1, "the case was not attempted and refused");
        assertProperties();
    }

    function testAtomic_overFillIsRefusedWithoutATrace() public {
        _open();
        _refused(0, 0, 5, "atomic_overFill");
    }

    function testAtomic_overCancelIsRefusedWithoutATrace() public {
        _open();
        _refused(1, 1, 5, "atomic_overCancel");
    }

    function testAtomic_unknownRequestIsRefusedWithoutATrace() public {
        _open();
        atomic_refusedCallback(0, 2, 3);
        atomic_refusedCallback(1, 2, 2e6 + 1);
        _assertNoFailures();
        assertEq(ok["atomic_unknownRequest"], 2, "the case was not attempted and refused");
    }

    /// @dev The share price rises a hundredfold, so a redemption fill converts to a payout the escrow cannot cover; the vault refuses it and the order stays open.
    function testAtomic_uncoveredPayoutIsRefusedWithoutATrace() public {
        _open();
        vault_requestRedeem(2, 2, 0, 1_500 * ONE_SHARE);
        _pushPrices(poolA, scA, d18(100, 1));
        _refused(3, 0, 1_500 * ONE_SHARE, "atomic_uncoveredPayout");
    }

    function testAtomic_aRouterCallbackWithARefusedLastLegIsRefusedWithoutATrace() public {
        _open();
        for (uint256 i; i < reqs.length; i++) {
            for (uint256 shape; shape < 2; shape++) {
                bytes32 before = _atomicFingerprint();
                atomic_refusedCallback(i, 4, shape * 1e24 + 7);
                assertEq(_atomicFingerprint(), before, "the callback left a trace");
            }
        }
        _assertNoFailures();
        assertGt(ok["atomic_routerLeg"], 0, "the case was not attempted and refused");
    }

    function testAtomic_strangersAreRefusedWithoutATrace() public {
        _open();
        for (uint256 shape; shape < 8; shape++) {
            atomic_refusedCallback(shape, 5, shape * 1e9 + shape);
        }
        _assertNoFailures();
        assertEq(ok["atomic_stranger"], 8, "a stranger's call was not refused");
    }

    function testAtomic_aRequestWhoseFlushIsRefusedLeavesNoTrace() public {
        _open();
        address previous = address(orderBook.observer(poolA));
        _refused(6, 0, 100 * ONE_ASSET, "atomic_refusedFlush");
        assertEq(address(orderBook.observer(poolA)), previous, "the pool's observer was not put back");
    }
}
