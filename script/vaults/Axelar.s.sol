// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {AxelarAdapter} from "src/gateway/adapters/axelar/Adapter.sol";
import {Deployer} from "script/Deployer.sol";

// Script to deploy Liquidity Pools with an Axelar Adapter.
contract AxelarScript is Deployer {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        adminSafe = vm.envAddress("ADMIN");

        deploy(msg.sender);
        AxelarAdapter adapter = new AxelarAdapter(
            address(gateway), address(vm.envAddress("AXELAR_GATEWAY")), address(vm.envAddress("AXELAR_GAS_SERVICE"))
        );
        wire(address(adapter));

        removeDeployerAccess(address(adapter), msg.sender);

        vm.stopBroadcast();
    }
}
