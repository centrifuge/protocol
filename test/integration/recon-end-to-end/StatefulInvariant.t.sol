// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FoundryHarness} from "./FoundryHarness.sol";

/// @notice The one stateful invariant over every handler.
/// @dev    Not worth rerunning per reachability contract: they inherit `FoundryHarness`, not this. Not every
///         property stays broken once broken, so the `ci` profile checks after every call; the default profile
///         checks every tenth call to keep local runs quick. The `ci` profile runs 20 deep runs, about 20k calls,
///         which takes over an hour on a CI runner, so the CI test job leaves it out: the Recon campaigns fuzz the
///         same handlers and properties.
/// forge-config: default.invariant.check_interval = 10
/// forge-config: ci.invariant.check_interval = 1
/// forge-config: ci.invariant.runs = 20
/// forge-config: ci.invariant.depth = 1000
contract StatefulInvariant is FoundryHarness {
    function invariant_properties() public {
        assertProperties();
    }
}
