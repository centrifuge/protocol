// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AxelarForwarder} from "src/vaults/gateway/adapters/axelar/Forwarder.sol";
import "forge-std/Script.sol";

// Script to deploy Axelar over XCM relayer.
contract ForwarderScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address admin = vm.envAddress("ADMIN");

        AxelarForwarder adapter = new AxelarForwarder(address(vm.envAddress("AXELAR_GATEWAY")));

        adapter.rely(admin);

        vm.stopBroadcast();
    }
}
