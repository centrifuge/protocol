// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PermissionlessAdapter} from "test/vaults/mocks/PermissionlessAdapter.sol";
import {InvestmentManager} from "src/vaults/InvestmentManager.sol";
import {Deployer} from "script/vaults/Deployer.sol";

// Script to deploy Liquidity Pools with a permissionless adapter for testing.
contract PermissionlessScript is Deployer {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        adminSafe = msg.sender;

        deploy(msg.sender);
        PermissionlessAdapter adapter = new PermissionlessAdapter(address(gateway));
        wire(address(adapter));

        vm.stopBroadcast();
    }
}
