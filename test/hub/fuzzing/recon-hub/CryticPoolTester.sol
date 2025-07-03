// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {CryticAsserts} from "@chimera/CryticAsserts.sol";

import {TargetFunctions} from "./TargetFunctions.sol";

// echidna . --contract CryticPoolTester --config echidna.yaml --format text --workers 16 --test-limit 100000000
// medusa fuzz
contract CryticPoolTester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
    }
}
