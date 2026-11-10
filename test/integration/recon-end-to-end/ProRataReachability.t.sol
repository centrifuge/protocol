// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CryticToFoundry} from "./CryticToFoundry.sol";

import {console} from "forge-std/console.sol";

/// @dev Drives the shared-window pro-rata flows with state they can act on and asserts they ran to their checks in each
///      of the two window vaults and on both sides, so a setup change that turns them into silent reverts fails here,
///      and a src mutation can be shown to fail them.
contract ProRataReachability is CryticToFoundry {
    function testProRata_depositVault1() public {
        _reach(0, 1);
    }

    function testProRata_depositVault4() public {
        _reach(0, 4);
    }

    function testProRata_redeemVault1() public {
        _reach(1, 1);
    }

    function testProRata_redeemVault4() public {
        _reach(1, 4);
    }

    /// @dev One side in one window vault, with and without price moves, over seeds that reach every settlement mode and
    ///      amount shape; a redemption starts from a deposit round filled in full, so the contributors hold shares.
    function _reach(uint256 side, uint256 vault) internal {
        uint256 v = vault == 1 ? 0 : 1;
        uint256 constant_;
        uint256 moving;
        for (uint256 s; s < 12; s++) {
            uint256 seed = uint256(keccak256(abi.encode(s, v, side)));
            if (side == 1) flow_sharedProRata(s, v, seed, seed - seed % 4, true);
            uint256 before = ok["flow_sharedProRata"];
            flow_sharedProRata(s, v, seed, seed + s, side == 0);
            constant_ += ok["flow_sharedProRata"] - before;
            if (side == 1) flow_sharedProRata(s, v, seed, seed - seed % 4, true);
            before = ok["flow_sharedProRataAcrossPrice"];
            flow_sharedProRataAcrossPrice(s, v, seed + 1, seed + s, side == 0);
            moving += ok["flow_sharedProRataAcrossPrice"] - before;
        }
        console.log("ok constant / moving", constant_, moving);
        assertGt(constant_, 0, "unreachable: flow_sharedProRata");
        assertGt(moving, 0, "unreachable: flow_sharedProRataAcrossPrice");
        _assertNoFailures();
        assertProperties();
    }

    function testFuzzProRata(uint256 a, uint256 b, uint256 c, uint256 d, bool dep, bool moves) public {
        if (moves) flow_sharedProRataAcrossPrice(a, b, c, d, dep);
        else flow_sharedProRata(a, b, c, d, dep);
        _assertNoFailures();
        assertProperties();
    }
}
