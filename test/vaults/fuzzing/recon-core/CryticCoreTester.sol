// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TargetFunctions} from "./TargetFunctions.sol";
import {CryticAsserts} from "@chimera/CryticAsserts.sol";

// echidna . --contract CryticCoreTester --config echidna.yaml
// medusa fuzz
contract CryticCoreTester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
    }
}
