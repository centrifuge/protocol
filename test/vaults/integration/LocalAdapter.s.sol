// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {Deployer} from "script/vaults/Deployer.sol";
import {LocalAdapter} from "./LocalAdapter.sol";

// Script to deploy Liquidity Pools with an Axelar adapter.
contract LocalAdapterScript is Deployer {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // NOTE: 0x361c43cd5Fd700923Aae9dED678851a201839fc6 is the H160 of Keyring::Admin in the Centrifuge Chain
        // repository
        adminSafe = ISafe(address(0x361c43cd5Fd700923Aae9dED678851a201839fc6));

        deploy(msg.sender);
        LocalAdapter adapter = new LocalAdapter();
        wire(address(adapter));

        adapter.file("gateway", address(gateway));
        adapter.file("sourceChain", "TestDomain");
        adapter.file("sourceAddress", "0x1111111111111111111111111111111111111111");

        removeDeployerAccess(address(adapter), msg.sender);

        vm.stopBroadcast();
    }
}
