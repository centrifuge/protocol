// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CryticToFoundry} from "./CryticToFoundry.sol";

import {console} from "forge-std/console.sol";

/// @dev Drives the multi-request flows with state they can act on and asserts they ran to their checks, so a setup
///      change that turns them into silent reverts fails here, and a src mutation can be shown to fail them.
contract MultiRequestReachability is CryticToFoundry {
    uint256 internal worstGas;

    /// @dev Every vault, side and settlement mode: a deposit and a redemption in each of the three vaults, with and
    ///      without price moves.
    function testMultiRequest_reachable() public {
        for (uint256 side; side < 2; side++) {
            for (uint256 v; v < 3; v++) {
                for (uint256 s; s < 6; s++) {
                    uint256 seed = s * 7919 + v * 31 + side;
                    uint256 g = gasleft();
                    flow_manyRequests(s, v, seed, seed, uint8(s), side == 0);
                    worstGas = _larger(worstGas, g - gasleft());
                    g = gasleft();
                    flow_manyRequestsAcrossPrice(s, v, seed, seed, uint8(s), side == 0);
                    worstGas = _larger(worstGas, g - gasleft());
                }
            }
        }
        console.log("worst gas of one call", worstGas);
        console.log("ok", ok["flow_manyRequests"], ok["flow_manyRequestsAcrossPrice"], ok["flow_manyRequests_operator"]);
        assertGt(ok["flow_manyRequests"], 10, "unreachable: flow_manyRequests");
        assertGt(ok["flow_manyRequestsAcrossPrice"], 10, "unreachable: flow_manyRequestsAcrossPrice");
        assertGt(ok["flow_manyRequests_operator"], 0, "unreachable: an operator part");
        _assertNoFailures();
        assertProperties();
    }

    function testFuzzMultiRequest(uint256 a, uint256 b, uint256 c, uint256 d, uint8 n, bool dep, bool moves) public {
        if (moves) flow_manyRequestsAcrossPrice(a, b, c, d, n, dep);
        else flow_manyRequests(a, b, c, d, n, dep);
        _assertNoFailures();
        assertProperties();
    }

    /// @dev The global ledger equality on a claim no handler measures itself (the router's): shows
    ///      `property_claimableMatchesOwedLessClaimed` fails alone when a claim leaves the ledger a unit off.
    function testClaimLedgerEqualityAfterRouterClaim() public {
        router_cycle(2, 500 * ONE_ASSET, false, false);
        hub_fulfill(0, 0, true);
        router_cycle(2, 0, false, true);
        assertGt(ok["router_claim"], 0, "unreachable: router_claim");
        _assertNoFailures();
        property_claimableMatchesOwedLessClaimed();
        assertProperties();
    }

    /// @dev The shared-window vaults alone (folds by a keeper or by the claim): what a mutation of the lazy fold's credit
    ///      is shown against, since the per-request vault's eager fold is also read by the fill check.
    function testMultiRequest_sharedWindowVaults() public {
        for (uint256 s; s < 4; s++) {
            flow_manyRequests(s, 1, s + 11, s + 5, uint8(s), true);
            flow_manyRequestsAcrossPrice(s, 4, s + 13, s + 7, uint8(s), true);
        }
        assertGt(ok["flow_manyRequests"], 0, "unreachable: flow_manyRequests on a shared window");
        _assertNoFailures();
    }
}
