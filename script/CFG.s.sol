// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {CFG} from "src/cfg/CFG.sol";
import "forge-std/Script.sol";

// Script to deploy the CFG token
contract CFGScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        CFG cfg = new CFG();
        cfg.rely(0x423420Ae467df6e90291fd0252c0A8a637C1e03f);

        vm.stopBroadcast();
    }
}
