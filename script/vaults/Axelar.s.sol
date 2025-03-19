// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AxelarAdapter} from "src/common/AxelarAdapter.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {VaultsDeployer} from "script/vaults/Deployer.s.sol";

// Script to deploy Vaults with an Axelar Adapter.
contract AxelarScript is VaultsDeployer {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        deployVaults(ISafe(vm.envAddress("ADMIN")), msg.sender);

        AxelarAdapter adapter = new AxelarAdapter(
            gateway, address(vm.envAddress("AXELAR_GATEWAY")), address(vm.envAddress("AXELAR_GAS_SERVICE"))
        );
        wire(adapter);

        removeDeployerAccess(address(adapter), msg.sender);

        vm.stopBroadcast();
    }
}
