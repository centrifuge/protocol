// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {WormholeAdapter} from "src/common/WormholeAdapter.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {FullDeployer, PoolsDeployer, VaultsDeployer} from "script/FullDeployer.s.sol";

// Script to deploy CP and CP with an Wormhole Adapter.
contract WormholeDeployer is FullDeployer {
    function run() public {
        address relayer = address(vm.envAddress("WORMHOLE_RELAYER"));
        uint16 localChainId = uint16(vm.envUint("WORMHOLE_LOCAL_CHAIN_ID"));

        vm.startBroadcast();

        deployFull(ISafe(vm.envAddress("ADMIN")));

        WormholeAdapter adapter = new WormholeAdapter(gateway, relayer, localChainId, address(this));
        wire(adapter);

        removeFullDeployerAccess();

        vm.stopBroadcast();
    }
}
