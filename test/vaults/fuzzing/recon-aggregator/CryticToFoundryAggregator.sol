// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {TargetFunctions} from "test/vaults/fuzzing/recon-aggregator/TargetFunctions.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

contract CryticToFoundryAggregator is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }
}
