// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {CFG} from "src/cfg/CFG.sol";
import "forge-std/Script.sol";

// Script to deploy the CFG token
contract CFGScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        uint256 initialMint = 100; // TODO
        address mintDestination = address(1); // TODO
        address initialOwner = 0x423420Ae467df6e90291fd0252c0A8a637C1e03f; // TODO

        CFG cfg = new CFG();
        cfg.rely(initialOwner);
        cfg.mint(mintDestination, initialMint);
        // cfg.deny(address(this)); // TODO

        vm.stopBroadcast();
    }
}
