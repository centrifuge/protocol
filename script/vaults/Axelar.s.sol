// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AxelarAdapter} from "src/common/AxelarAdapter.sol";
import {Deployer} from "script/vaults/Deployer.sol";

// Script to deploy Liquidity Pools with an Axelar Adapter.
contract AxelarScript is Deployer {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        adminSafe = vm.envAddress("ADMIN");

        deploy(msg.sender);
        AxelarAdapter adapter = new AxelarAdapter(
            gateway, address(vm.envAddress("AXELAR_GATEWAY")), address(vm.envAddress("AXELAR_GAS_SERVICE"))
        );
        wire(address(adapter));

        removeDeployerAccess(address(adapter), msg.sender);

        vm.stopBroadcast();
    }
}
