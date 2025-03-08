// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {TargetFunctions} from "test/recon-core/TargetFunctions.sol";
import {CryticAsserts} from "@chimera/CryticAsserts.sol";

// echidna . --contract CryticCoreTester --config echidna.yaml
// medusa fuzz --config medusa-core.json
contract CryticCoreTester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
    }
}
