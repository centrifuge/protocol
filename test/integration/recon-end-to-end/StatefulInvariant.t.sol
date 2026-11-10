// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CryticToFoundry} from "./CryticToFoundry.sol";

/// @notice The one stateful invariant over every handler.
/// @dev    Not worth rerunning per reachability contract: they inherit `CryticToFoundry`, not this. Not every
///         property stays broken once broken, so CI checks after every call; the default profile checks every
///         tenth call to keep local runs quick. CI runs 20 deep runs, about 20k calls (~3 min): a full `ci`
///         budget of 100k takes over 14 minutes, which is for the scheduled campaigns rather than every pull
///         request.
/// forge-config: default.invariant.check_interval = 10
/// forge-config: ci.invariant.check_interval = 1
/// forge-config: ci.invariant.runs = 20
/// forge-config: ci.invariant.depth = 1000
contract StatefulInvariant is CryticToFoundry {
    function invariant_properties() public {
        assertProperties();
    }
}
