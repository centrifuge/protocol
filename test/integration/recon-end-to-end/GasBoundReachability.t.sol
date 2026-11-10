// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CryticToFoundry} from "./CryticToFoundry.sol";

import {console} from "forge-std/console.sol";

/// @dev Drives the gas bound with the longest history the horizon allows and asserts the claims, folds and flushes it
///      measured stayed under the ceiling, so a setup change that turns the handler into a silent skip fails here,
///      and a src mutation that makes a claim scale with history can be shown to fail it.
contract GasBoundReachability is CryticToFoundry {
    uint256 internal constant HORIZON = 8;

    /// @dev Every actor holds shares, so the redeem side has a history too.
    function _hold() internal {
        for (uint256 a; a < 3; a++) {
            flow_deposit(a, 0, 2_000 * ONE_ASSET, a);
        }
    }

    /// @dev Every actor holds shares, then the subject joins `horizon + 2` windows on both sides of the long-horizon
    ///      vault, all settled, the evicted ones folded by a keeper, the rest by each controller's claim. The history
    ///      is built in the same transaction, so what the claims cost here is the warm cost.
    function testGas_worstCaseClaimStaysUnderTheCeiling() public {
        _hold();
        uint256 g0 = gasleft();
        uint256 windows = _worstCase(7, 0, 2);
        console.log("history and claims gas", g0 - gasleft());
        console.log("windows", windows);
        console.log("worst warm call gas", ghost_worstClaimGas);
        _assertNoFailures();
        assertEq(windows, HORIZON + 2, "the history did not reach the horizon and its overflow");
        assertEq(ok["gas_worstCaseClaim"], 1, "the claims did not run");
        assertGt(ghost_worstClaimGas, 200_000, "no call folded a horizon");
        assertLe(ghost_worstClaimGas, CLAIM_GAS_CEILING, "a call cost more than the ceiling");
        assertProperties();
    }

    /// @dev The same history with its claims made one call at a time. Under `--isolate` each call is a transaction of
    ///      its own, so the figure is the cold one a keeper or an investor pays (about 0.5M for the subject's first
    ///      claim); without it the test passes on the warm figure, which is the lower bound it asserts.
    function testGas_claimsAfterTheHistoryStayUnderTheCeiling() public {
        _hold();
        (Windows memory deposits, Windows memory redeems) = _buildHistory(7, 2);
        ghost_worstClaimGas = 0;
        _keep(deposits, redeems, 0);
        console.log("worst call gas after the history", ghost_worstClaimGas);
        _assertNoFailures();
        assertGt(ghost_worstClaimGas, 250_000, "no call folded a horizon");
        assertLe(ghost_worstClaimGas, CLAIM_GAS_CEILING, "a call cost more than the ceiling");
    }
}
