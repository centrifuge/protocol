// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {CryticAsserts} from "@chimera/CryticAsserts.sol";
import {TargetFunctions} from "test/vaults/fuzzing/recon-aggregator/TargetFunctions.sol";

// echidna . --contract CryticAggregatorForkedTester --config echidna.yaml
// NOTE: Must pass ECHIDNA_RPC_URL and ECHIDNA_RPC_BLOCK params to ENV
contract CryticAggregatorForkedTester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
        setupFork();
    }
}
