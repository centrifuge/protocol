// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {TargetFunctions} from "./TargetFunctions.sol";
import {CryticAsserts} from "@chimera/CryticAsserts.sol";

// echidna . --contract CryticMessagingTester --config echidna-messaging.yaml
contract CryticMessagingTester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
    }
}
