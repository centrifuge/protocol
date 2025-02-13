// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TargetFunctions} from "test/vaults/recon-core/TargetFunctions.sol";
import {CryticAsserts} from "@chimera/CryticAsserts.sol";

// echidna . --contract CryticTester --config echidna.yaml
// medusa fuzz
contract CryticTester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
    }
}
