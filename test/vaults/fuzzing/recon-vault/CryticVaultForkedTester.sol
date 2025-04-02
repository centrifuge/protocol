// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {CryticAsserts} from "@chimera/CryticAsserts.sol";
import {TargetFunctions} from "./TargetFunctions.sol";
// ECHIDNA_RPC_URL=$(grep ECHIDNA_RPC_URL .env | cut -d'=' -f2) ECHIDNA_RPC_BLOCK=$(grep ECHIDNA_RPC_BLOCK .env | cut -d'=' -f2) echidna . --contract CryticVaultForkedTester --config echidna.yaml
// NOTE: Must pass ECHIDNA_RPC_URL and ECHIDNA_RPC_BLOCK params to ENV
contract CryticVaultForkedTester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
        setupFork();
    }
}
