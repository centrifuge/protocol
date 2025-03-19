// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AxelarAdapter} from "src/common/AxelarAdapter.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {FullDeployer, PoolsDeployer, VaultsDeployer} from "script/FullDeployer.s.sol";

// Script to deploy Vaults with an Axelar Adapter.
contract AxelarScript is FullDeployer {
    function setUp() public {}

    function run() public {
        address axelarGateway = address(vm.envAddress("AXELAR_GATEWAY"));
        address axelarGasService = address(vm.envAddress("AXELAR_GAS_SERVICE"));

        vm.startBroadcast();

        deployFull(ISafe(vm.envAddress("ADMIN")), msg.sender);

        AxelarAdapter poolAdapter = new AxelarAdapter(poolGateway, axelarGateway, axelarGasService);
        // TODO: configure endpoints using adapter.file()
        wirePoolAdapter(poolAdapter, msg.sender);

        AxelarAdapter vaultAdapter = new AxelarAdapter(vaultGateway, axelarGateway, axelarGasService);
        // TODO: configure endpoints using adapter.file()
        wireVaultAdapter(vaultAdapter, msg.sender);

        removeFullDeployerAccess(msg.sender);

        vm.stopBroadcast();
    }
}
