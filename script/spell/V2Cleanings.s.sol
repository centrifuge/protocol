// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import {V2CleaningsSpell} from "../../src/spell/V2CleaningsSpell.sol";

contract V2CleaningsDeployer is Script {
    function run() external {
        vm.startBroadcast();

        new V2CleaningsSpell();

        vm.stopBroadcast();
    }
}

contract V2CleaningsExecutor is Script {
    bytes32 constant NEW_VERSION = "v3.1";
    address deployer;

    function run(V2CleaningsSpell spell) external {
        vm.startBroadcast();

        migrate(spell);

        vm.stopBroadcast();
    }

    function migrate(V2CleaningsSpell spell) public {
        vm.label(address(spell), "V2CleaningsSpell");

        spell.cast();
    }
}
