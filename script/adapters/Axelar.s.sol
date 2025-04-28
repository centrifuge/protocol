// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AxelarAdapter} from "src/common/adapters/AxelarAdapter.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {FullDeployer} from "script/FullDeployer.s.sol";

// Script to deploy CP and CP with an AxelarScript Adapter.
contract AxelarDeployer is FullDeployer {
    function run() public {
        uint16 localCentrifugeId = uint16(vm.envUint("CENTRIFUGE_ID"));
        uint16 remoteCentrifugeId = uint16(vm.envUint("REMOTE_CENTRIFUGE_ID"));
        address axelarGateway = address(vm.envAddress("AXELAR_GATEWAY"));
        address axelarGasService = address(vm.envAddress("AXELAR_GAS_SERVICE"));

        vm.startBroadcast();

        deployFull(localCentrifugeId, ISafe(vm.envAddress("ADMIN")), msg.sender, false);

        AxelarAdapter adapter = new AxelarAdapter(gateway, axelarGateway, axelarGasService, msg.sender);
        wire(remoteCentrifugeId, adapter, msg.sender);

        removeFullDeployerAccess(msg.sender);

        vm.stopBroadcast();
    }
}
