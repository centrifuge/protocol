// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {ShareClassManager} from "src/hub/ShareClassManager.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";

/// @dev Wrapper so we can reset the epoch increment for testing
contract ShareClassManagerWrapper is ShareClassManager {
    constructor(IHubRegistry hubRegistry, address deployer) ShareClassManager(hubRegistry, deployer) {
        hubRegistry = hubRegistry;
    }
}
