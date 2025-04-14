// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {WormholeAdapter} from "src/common/WormholeAdapter.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";

import "forge-std/Script.sol";

// Script to deploy a Wormhole Adapter.
contract WormholeDeployer is Script {
    function run() public {
        uint16 remoteCentrifugeId = uint16(vm.envUint("REMOTE_CENTRIFUGE_ID"));
        address relayer = address(vm.envAddress("WORMHOLE_RELAYER"));
        uint16 localWormholeId = uint16(vm.envUint("WORMHOLE_LOCAL_CHAIN_ID"));

        vm.startBroadcast();

        WormholeAdapter adapter = new WormholeAdapter(gateway, relayer, localWormholeId, msg.sender);

        guardian.setAdapter();

        vm.stopBroadcast();
    }
}
