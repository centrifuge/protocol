// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {WormholeAdapter} from "src/common/WormholeAdapter.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {VaultsDeployer} from "script/VaultsDeployer.s.sol";

// Script to deploy Vaults with an Wormhole Adapter.
contract WormholeScript is VaultsDeployer {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        deployVaults(ISafe(vm.envAddress("ADMIN")), msg.sender);

        WormholeAdapter adapter = new WormholeAdapter(
            vaultGateway, address(vm.envAddress("WORMHOLE_RELAYER")), uint16(vm.envUint("WORMHOLE_LOCAL_CHAIN_ID"))
        );
        wire(adapter);

        removeVaultsDeployerAccess(msg.sender);
        adapter.deny(msg.sender);

        vm.stopBroadcast();
    }
}
