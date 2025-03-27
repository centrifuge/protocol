// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {FullDeployer, PoolsDeployer, VaultsDeployer} from "script/FullDeployer.s.sol";

import {LocalhostAdapter} from "test/integration/adapters/LocalhostAdapter.sol";

// Script to deploy CP and CP with an Localhost Adapter.
contract LocalhostDeployer is FullDeployer {
    function run() public {
        uint16 centrifugeChainId = uint16(vm.envUint("CENTRIFUGE_CHAIN_ID"));

        vm.startBroadcast();

        deployFull(centrifugeChainId, ISafe(vm.envAddress("ADMIN")));
        saveDeploymentOutput();

        LocalhostAdapter adapter = new LocalhostAdapter(gateway, address(this));
        wire(centrifugeChainId, adapter);

        vm.stopBroadcast();
    }
}
