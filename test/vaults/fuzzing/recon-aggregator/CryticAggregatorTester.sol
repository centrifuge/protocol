// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {CryticAsserts} from "@chimera/CryticAsserts.sol";
import {TargetFunctions} from "test/vaults/fuzzing/recon-aggregator/TargetFunctions.sol";

// echidna . --contract CryticAggregatorTester --config echidna.yaml
// medusa fuzz
contract CryticAggregatorTester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
    }
}
