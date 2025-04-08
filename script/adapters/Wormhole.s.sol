// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {WormholeAdapter} from "src/common/WormholeAdapter.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {FullDeployer, HubDeployer, VaultsDeployer} from "script/FullDeployer.s.sol";

// Script to deploy CP and CP with an Wormhole Adapter.
contract WormholeDeployer is FullDeployer {
    function run() public {
        uint16 localCentrifugeId = uint16(vm.envUint("CENTRIFUGE_ID"));
        uint16 remoteCentrifugeId = uint16(vm.envUint("REMOTE_CENTRIFUGE_ID"));
        address relayer = address(vm.envAddress("WORMHOLE_RELAYER"));
        uint16 localWormholeId = uint16(vm.envUint("WORMHOLE_LOCAL_CHAIN_ID"));

        vm.startBroadcast();

        deployFull(localCentrifugeId, ISafe(vm.envAddress("ADMIN")), msg.sender);

        WormholeAdapter adapter = new WormholeAdapter(gateway, relayer, localWormholeId, msg.sender);
        wire(remoteCentrifugeId, adapter, msg.sender);

        removeFullDeployerAccess(msg.sender);

        vm.stopBroadcast();
    }
}
