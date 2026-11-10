// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TargetFunctions} from "./TargetFunctions.sol";

import {CryticAsserts} from "@chimera/CryticAsserts.sol";

// echidna . --contract CryticE2ETester --config echidna.yaml
// medusa fuzz --config medusa.json
contract CryticE2ETester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
    }
}
