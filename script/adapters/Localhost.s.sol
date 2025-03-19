// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {FullDeployer, PoolsDeployer, VaultsDeployer} from "script/FullDeployer.s.sol";

import {LocalhostAdapter} from "test/integration/adapters/LocalhostAdapter.sol";

// Script to deploy CP and CP with an Localhost Adapter.
contract LocalhostAdapterScript is FullDeployer {
    function run() public {
        vm.startBroadcast();

        deployFull(ISafe(vm.envAddress("ADMIN")), msg.sender);

        LocalhostAdapter adapter = new LocalhostAdapter(gateway);
        wire(adapter, msg.sender);

        removeFullDeployerAccess(msg.sender);

        vm.stopBroadcast();
    }
}
