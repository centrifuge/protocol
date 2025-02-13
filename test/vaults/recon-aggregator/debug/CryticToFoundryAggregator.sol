// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {TargetFunctions} from "../TargetFunctions.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

contract CryticToFoundryAggregator is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }
}
