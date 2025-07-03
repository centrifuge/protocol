// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {CryticAsserts} from "@chimera/CryticAsserts.sol";

import {TargetFunctions} from "./TargetFunctions.sol";

// echidna . --contract CryticE2ETester --config echidna.yaml --format text --workers 16 --test-limit 100000000
// medusa fuzz --config medusa.json
contract CryticE2ETester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
    }
}
