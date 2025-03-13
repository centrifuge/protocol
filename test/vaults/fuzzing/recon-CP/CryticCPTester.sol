// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {CryticAsserts} from "@chimera/CryticAsserts.sol";

import {TargetFunctions} from "./TargetFunctions.sol";

// echidna . --contract CryticCPTester --config echidna-cp.yaml --format text --workers 16 --test-limit 1000000
// medusa fuzz --config medusa-cp.json
contract CryticCPTester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
    }
}