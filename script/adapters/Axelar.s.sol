// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AxelarAdapter} from "src/common/AxelarAdapter.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {FullDeployer, PoolsDeployer, VaultsDeployer} from "script/FullDeployer.s.sol";

// Script to deploy CP and CP with an AxelarScript Adapter.
contract AxelarDeployer is FullDeployer {
    function run() public {
        uint16 centrifugeChainId = uint16(vm.envUint("CENTRIFUGE_CHAIN_ID"));
        address axelarGateway = address(vm.envAddress("AXELAR_GATEWAY"));
        address axelarGasService = address(vm.envAddress("AXELAR_GAS_SERVICE"));

        vm.startBroadcast();

        deployFull(centrifugeChainId, ISafe(vm.envAddress("ADMIN")), msg.sender);

        AxelarAdapter adapter = new AxelarAdapter(gateway, axelarGateway, axelarGasService);
        wire(adapter, msg.sender);

        removeFullDeployerAccess(msg.sender);

        vm.stopBroadcast();
    }
}
