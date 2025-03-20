// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AxelarAdapter} from "src/common/AxelarAdapter.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {FullDeployer, PoolsDeployer, VaultsDeployer} from "script/FullDeployer.s.sol";

// Script to deploy CP and CP with an AxelarScript Adapter.
contract AxelarDeployer is FullDeployer {
    function run() public {
        address axelarGateway = address(vm.envAddress("AXELAR_GATEWAY"));
        address axelarGasService = address(vm.envAddress("AXELAR_GAS_SERVICE"));

        vm.startBroadcast();

        deployFull(ISafe(vm.envAddress("ADMIN")));

        AxelarAdapter adapter = new AxelarAdapter(gateway, axelarGateway, axelarGasService, address(this));
        wire(adapter);

        removeFullDeployerAccess();

        vm.stopBroadcast();
    }
}
