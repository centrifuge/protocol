// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {TargetFunctions} from "test/recon-core/TargetFunctions.sol";
import {CryticAsserts} from "@chimera/CryticAsserts.sol";

// echidna . --contract CryticTester --config echidna.yaml
// medusa fuzz
contract CryticTester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
    }
}
