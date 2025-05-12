// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AxelarAdapter} from "src/common/adapters/AxelarAdapter.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {FullDeployer} from "script/FullDeployer.s.sol";

// Script to deploy CP and CP with an AxelarScript Adapter.
contract AxelarDeployer is FullDeployer {
    function deploy() public {
        uint16 remoteCentrifugeId = uint16(vm.envUint("REMOTE_CENTRIFUGE_ID"));
        address axelarGateway = address(vm.envAddress("AXELAR_GATEWAY"));
        address axelarGasService = address(vm.envAddress("AXELAR_GAS_SERVICE"));

        AxelarAdapter adapter = new AxelarAdapter(gateway, axelarGateway, axelarGasService, msg.sender);
        wire(remoteCentrifugeId, adapter, msg.sender);
    }
}
